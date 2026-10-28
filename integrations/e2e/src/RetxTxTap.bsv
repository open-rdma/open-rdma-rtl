package RetxTxTap;

import Assert :: *;
import FIFOF :: *;

import CommonTypes :: *;
import E2eTypes :: *;
import RetxTypes :: *;
import TxTypes :: *;

// M2 -> M3 主数据通路上的 retx 观察/登记点。
//
// 对每个 packet：
//   * 向 M9 发 packetReserve，拿到 replayHandle 后才放行 descriptor；
//   * 随 packet 首 beat 发出 sentEvent，让 M9 从 reserved 进入 sent；
//   * 把 payload beat 写入 replay store，供 M11 重传 fetch 使用。
// 正常 first-traffic 的 descriptor/payload 本身不被修改，因此 TX 主链路
// 的语义与未接入 retx 时完全一致。
interface RetxTxTapIfc;
    interface PipeIn#(PacketDescriptor) descriptorIn;
    interface PipeIn#(PacketPayloadBeat) payloadIn;
    interface PipeOut#(PacketDescriptor) descriptorOut;
    interface PipeOut#(PacketPayloadBeat) payloadOut;
    interface PipeIn#(RetxRecordMeta) recordIn;
    interface PipeOut#(RetxPacketReserveHw) reserveOut;
    interface PipeIn#(RetxPacketGrantHw) grantIn;
    interface PipeOut#(RetxSentEventHw) sentOut;
    interface PipeOut#(RetxReplayWriteHw) replayWriteOut;
    method Action setEpoch(Bit#(16) epoch);
endinterface

module mkRetxTxTap(RetxTxTapIfc);
    FIFOF#(PacketDescriptor) descriptorInQ <- mkSizedFIFOF(4);
    FIFOF#(PacketPayloadBeat) payloadInQ <- mkSizedFIFOF(4);
    FIFOF#(PacketDescriptor) descriptorOutQ <- mkSizedFIFOF(4);
    FIFOF#(PacketPayloadBeat) payloadOutQ <- mkSizedFIFOF(4);
    FIFOF#(RetxRecordMeta) recordQ <- mkSizedFIFOF(4);
    FIFOF#(RetxPacketReserveHw) reserveQ <- mkSizedFIFOF(4);
    FIFOF#(RetxPacketGrantHw) grantQ <- mkSizedFIFOF(4);
    FIFOF#(RetxSentEventHw) sentQ <- mkSizedFIFOF(4);
    FIFOF#(RetxReplayWriteHw) replayWriteQ <- mkSizedFIFOF(8);

    Reg#(Bit#(16)) epoch <- mkReg(1);

    // 当前 message 的 WQE record。
    Reg#(Bool) messageValid <- mkReg(False);
    Reg#(Bit#(32)) messageHandle <- mkReg(0);
    Reg#(TxRequestId) messageRequestId <- mkReg(0);

    // 当前 packet 的 reserve 往返。
    Reg#(Bool) reservePending <- mkReg(False);
    Reg#(PacketDescriptor) pendingDescriptor <- mkReg(unpack(0));

    // 已获准进入 M3 的 packet。
    Reg#(Bool) packetActive <- mkReg(False);
    Reg#(Bit#(32)) replayHandle <- mkReg(0);
    Reg#(Bit#(8)) beatIndex <- mkReg(0);
    Reg#(TxQpn) activeQpn <- mkReg(0);
    Reg#(TxPsn) activePsn <- mkReg(0);
    Reg#(TxPsnCount) activePacketIndex <- mkReg(0);
    Reg#(Bit#(1)) activeLast <- mkReg(0);

    // 拆成 first/continuation 两条规则，避免在不需要 record 的 continuation
    // 上把 recordQ.notEmpty 变成隐式 guard。
    rule startFirstPacket (!reservePending && !packetActive
                           && descriptorInQ.notEmpty && recordQ.notEmpty
                           && descriptorInQ.first.isFirst == 1
                           && reserveQ.notFull);
        let descriptor = descriptorInQ.first;
        let record = recordQ.first;
        dynamicAssert(record.requestId == descriptor.requestId,
            "RETX_TX_TAP_RECORD_ORDER");
        reserveQ.enq(RetxPacketReserveHw {
            qpn: descriptor.qpn,
            qpEpoch: epoch,
            psn: descriptor.psn,
            requestId: descriptor.requestId,
            packetIndex: descriptor.packetIndex,
            packetCount: descriptor.packetCount,
            messageOffset: descriptor.messageOffset,
            payloadLength: descriptor.payloadLength,
            messageLength: descriptor.messageLength,
            opcode: pack(descriptor.opcode),
            first: descriptor.isFirst,
            last: descriptor.isLast,
            recordHandle: record.recordHandle,
            replayHandle: 0
        });
        messageValid <= True;
        messageHandle <= record.recordHandle;
        messageRequestId <= descriptor.requestId;
        recordQ.deq;
        pendingDescriptor <= descriptor;
        reservePending <= True;
        descriptorInQ.deq;
    endrule

    rule startContinuationPacket (!reservePending && !packetActive
                                  && descriptorInQ.notEmpty
                                  && descriptorInQ.first.isFirst == 0
                                  && messageValid
                                  && messageRequestId == descriptorInQ.first.requestId
                                  && reserveQ.notFull);
        let descriptor = descriptorInQ.first;
        reserveQ.enq(RetxPacketReserveHw {
            qpn: descriptor.qpn,
            qpEpoch: epoch,
            psn: descriptor.psn,
            requestId: descriptor.requestId,
            packetIndex: descriptor.packetIndex,
            packetCount: descriptor.packetCount,
            messageOffset: descriptor.messageOffset,
            payloadLength: descriptor.payloadLength,
            messageLength: descriptor.messageLength,
            opcode: pack(descriptor.opcode),
            first: descriptor.isFirst,
            last: descriptor.isLast,
            recordHandle: messageHandle,
            replayHandle: 0
        });
        pendingDescriptor <= descriptor;
        reservePending <= True;
        descriptorInQ.deq;
    endrule

    rule acceptGrant (reservePending && !packetActive && grantQ.notEmpty
                      && descriptorOutQ.notFull);
        let grant = grantQ.first;
        let descriptor = pendingDescriptor;
        dynamicAssert(grant.ok == 1, "RETX_TX_TAP_RESERVE_DENIED");

        descriptorOutQ.enq(descriptor);
        replayHandle <= grant.replayHandle;
        beatIndex <= 0;
        activeQpn <= descriptor.qpn;
        activePsn <= descriptor.psn;
        activePacketIndex <= descriptor.packetIndex;
        activeLast <= descriptor.isLast;
        packetActive <= True;
        reservePending <= False;
        grantQ.deq;
    endrule

    rule forwardPayload (packetActive && payloadInQ.notEmpty
                         && payloadOutQ.notFull && replayWriteQ.notFull
                         && (beatIndex != 0 || sentQ.notFull));
        let beat = payloadInQ.first;
        dynamicAssert(beat.requestId == pendingDescriptor.requestId
            && beat.psn == activePsn,
            "RETX_TX_TAP_PAYLOAD_IDENTITY");
        dynamicAssert(beat.sop == pack(beatIndex == 0),
            "RETX_TX_TAP_PAYLOAD_SOP");

        payloadOutQ.enq(beat);
        replayWriteQ.enq(RetxReplayWriteHw {
            replayHandle: replayHandle,
            beatIndex: beatIndex,
            data: beat.data
        });
        if (beatIndex == 0) begin
            sentQ.enq(RetxSentEventHw {
                qpn: activeQpn,
                qpEpoch: epoch,
                psn: activePsn,
                packetIndex: activePacketIndex,
                recordHandle: messageHandle,
                replayHandle: replayHandle,
                commitToken: 0
            });
        end
        if (beat.eop == 1) begin
            packetActive <= False;
            beatIndex <= 0;
            if (activeLast == 1)
                messageValid <= False;
        end
        else
            beatIndex <= beatIndex + 1;
        payloadInQ.deq;
    endrule

    interface descriptorIn = toPipeIn(descriptorInQ);
    interface payloadIn = toPipeIn(payloadInQ);
    interface descriptorOut = toPipeOut(descriptorOutQ);
    interface payloadOut = toPipeOut(payloadOutQ);
    interface recordIn = toPipeIn(recordQ);
    interface reserveOut = toPipeOut(reserveQ);
    interface grantIn = toPipeIn(grantQ);
    interface sentOut = toPipeOut(sentQ);
    interface replayWriteOut = toPipeOut(replayWriteQ);
    method Action setEpoch(Bit#(16) value);
        epoch <= value;
    endmethod
endmodule

endpackage
