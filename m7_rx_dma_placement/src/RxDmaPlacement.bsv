// 这个包 RxDmaPlacement 是接收路径中的DMA 放置模块。它位于 RxRqBitmapManager 之后，负责把已经允许的包（RxAdmittedPacket）转换成 DMA 写请求和负载 beat，从 RxPacketBuffer 读取 payload，等待 DMA 完成，然后产生退休信号 RxDmaRetire，并释放缓冲区。顶层支持 4 条 lane 并行处理，但退休按 globalSeq 全局有序。
package RxDmaPlacement;
import Vector::*;
import FIFOF::*;
import CommonTypes::*;
import TxTypes::*;
import RxTypes::*;

Integer rxDmaLaneQueueDepth = 4;
Integer rxDmaErrorQueueDepth = 8;
Integer rxDmaRetireQueueDepth = 8;
Integer rxDmaWordBytes = 32;
Integer rxDmaWordShift = 5;
Integer rxDmaBitsPerByte = 8;

// 定义一条 lane 的 DMA 放置模块对外接口
interface RxDmaLaneIfc;
    method Action configureEpoch(RxEpoch value);
    interface PipeIn#(RxAdmittedPacket) admittedIn;
    interface PipeOut#(RxDmaWriteRequest) requestOut;
    interface PipeOut#(RxDmaPayloadBeat) payloadOut;
    interface PipeIn#(RxDmaCompletion) completionIn;
    interface PipeOut#(RxPayloadReadRequest) readRequestOut;
    interface PipeIn#(RxPayloadReadResponse) readResponseIn;
    interface PipeOut#(RxBufferRelease) releaseOut;
    interface PipeOut#(RxDmaRetire) completedOut;
    interface PipeOut#(RxError) errorOut;
    method Bool faulted;
endinterface

module mkRxDmaLane#(RxLaneId lane)(RxDmaLaneIfc);
    FIFOF#(RxAdmittedPacket) admittedQ <- mkSizedFIFOF(rxDmaLaneQueueDepth);
    FIFOF#(RxDmaWriteRequest) requestQ <- mkFIFOF;
    FIFOF#(RxDmaPayloadBeat) payloadQ <- mkSizedFIFOF(rxDmaLaneQueueDepth);
    FIFOF#(RxDmaCompletion) completionQ <- mkSizedFIFOF(rxDmaLaneQueueDepth);
    FIFOF#(RxPayloadReadRequest) readRequestQ <- mkSizedFIFOF(rxDmaLaneQueueDepth);
    FIFOF#(RxPayloadReadResponse) readResponseQ <- mkSizedFIFOF(rxDmaLaneQueueDepth);
    FIFOF#(RxBufferRelease) releaseQ <- mkSizedFIFOF(rxDmaLaneQueueDepth);
    FIFOF#(RxDmaRetire) completedQ <- mkSizedFIFOF(rxDmaLaneQueueDepth);
    FIFOF#(RxError) errorQ <- mkSizedFIFOF(rxDmaErrorQueueDepth);

    Reg#(Bool) failed <- mkReg(False);
    Reg#(Bool) epochConfigured <- mkReg(False);
    Reg#(RxEpoch) currentEpoch <- mkReg(0);
    Reg#(Bool) active <- mkReg(False);
    Reg#(Bool) descriptorSent <- mkReg(False);
    Reg#(Bool) descriptorAccepted <- mkReg(False);
    Reg#(Bool) payloadAccepted <- mkReg(False);
    Reg#(Bool) waitingRead <- mkReg(False);
    Reg#(Bool) payloadDone <- mkReg(False);
    Reg#(RxAdmittedPacket) current <- mkReg(unpack(0));
    Reg#(Bit#(13)) payloadOffset <- mkReg(0);
    Reg#(Bit#(8)) expectedWord <- mkReg(0);

    // 开始处理新包：当空闲且 epoch 已配置时，从 admittedQ 取出一个包开始处理。
    rule beginPacket(!failed && epochConfigured && !active);
        let packet = admittedQ.first;
        admittedQ.deq;
        if (packet.lane != lane) begin
            errorQ.enq(RxError{qpn:packet.qpn, psn:packet.psn,
                code:RX_DMA_BAD_PAYLOAD});
            releaseQ.enq(RxBufferRelease{tag:packet.payloadTag});
            failed <= True;
        end
        else begin
            current <= packet;
            payloadOffset <= 0;
            descriptorSent <= False;
            descriptorAccepted <= False;
            payloadAccepted <= False;
            waitingRead <= False;
            payloadDone <= False;
            active <= True;
        end
    endrule

    // 向 DMA 发送写请求描述符。
    rule sendDescriptor(!failed && active && !descriptorSent);
        requestQ.enq(RxDmaWriteRequest{globalSeq:current.globalSeq,
            epoch:currentEpoch, lane:lane, qpn:current.qpn, psn:current.psn,
            addr:current.dmaAddr, bytes:current.payloadBytes});
        descriptorSent <= True;
    endrule

    // 当 DMA 已接受描述符且还有负载未读完时，向 RxPacketBuffer 发起读请求。
    rule requestPayload(!failed && active && descriptorAccepted
            && !waitingRead && !payloadDone);
        Bit#(13) bytePosition = zeroExtend(current.payloadStart) + payloadOffset;
        Bit#(8) word = truncate(bytePosition >> rxDmaWordShift);
        readRequestQ.enq(RxPayloadReadRequest{tag:current.payloadTag,
            wordIndex:word});
        expectedWord <= word;
        waitingRead <= True;
    endrule

    // 处理 RxPacketBuffer 返回的读响应，提取 payload 并生成 DMA 负载 beat。
    rule consumePayloadRead(!failed && active && waitingRead);
        let response = readResponseQ.first;
        readResponseQ.deq;
        Bool valid = response.valid && response.tag == current.payloadTag
            && response.wordIndex == expectedWord;
        if (!valid) begin
            errorQ.enq(RxError{qpn:current.qpn, psn:current.psn,
                code:RX_DMA_BAD_PAYLOAD});
            releaseQ.enq(RxBufferRelease{tag:current.payloadTag});
            waitingRead <= False;
            active <= False;
            failed <= True;
        end
        else begin
            Bit#(13) remaining = current.payloadBytes - payloadOffset;
            Bit#(6) take = remaining < fromInteger(rxDmaWordBytes)
                ? truncate(remaining) : fromInteger(rxDmaWordBytes);
            Bit#(13) bytePosition = zeroExtend(current.payloadStart) + payloadOffset;
            Bit#(5) intraWord = truncate(bytePosition);
            Bit#(512) window = {response.high, response.low};
            Bit#(9) shift = zeroExtend(intraWord) * fromInteger(rxDmaBitsPerByte);
            Bit#(13) nextOffset = payloadOffset + zeroExtend(take);
            Bool firstBeat = payloadOffset == 0;
            Bool lastBeat = nextOffset == current.payloadBytes;
            payloadQ.enq(RxDmaPayloadBeat{globalSeq:current.globalSeq,
                epoch:currentEpoch, data:truncate(window >> shift), be:byteMask32(take),
                sop:pack(firstBeat), eop:pack(lastBeat)});
            payloadOffset <= nextOffset;
            waitingRead <= False;
            if (lastBeat)
                payloadDone <= True;
        end
    endrule

    // 当负载已全部发出且被 DMA 接受后，等待 DMA 完成，产生退休信号。
    rule finishPacket(!failed && active && payloadDone && payloadAccepted);
        let completion = completionQ.first;
        completionQ.deq;
        Bool identityOk = completion.globalSeq == current.globalSeq
            && completion.epoch == currentEpoch && completion.lane == lane;
        if (!identityOk || !completion.success) begin
            errorQ.enq(RxError{qpn:current.qpn, psn:current.psn,
                code:identityOk ? RX_DMA_FAILED : RX_DMA_BAD_COMPLETION});
            failed <= True;
        end
        else begin
            completedQ.enq(RxDmaRetire{globalSeq:current.globalSeq,
                qp:current.qp, qpn:current.qpn, psn:current.psn, success:True,
                ackValid:current.ackValid,
                ackPsnAfterMerge:current.ackPsnAfterMerge,
                messageComplete:current.messageComplete,
                messageLastPsn:current.messageLastPsn,
                messageBytes:current.messageBytes});
        end
        releaseQ.enq(RxBufferRelease{tag:current.payloadTag});
        active <= False;
        payloadDone <= False;
    endrule

    // 处理意外的完成消息，即在没有活动包或负载未完成时收到的完成消息。
    rule rejectUnexpectedCompletion(!failed && completionQ.notEmpty
            && (!active || !payloadDone));
        let completion = completionQ.first;
        completionQ.deq;
        errorQ.enq(RxError{qpn:active ? current.qpn : 0,
            psn:active ? current.psn : 0, code:RX_DMA_BAD_COMPLETION});
        if (active)
            releaseQ.enq(RxBufferRelease{tag:current.payloadTag});
        active <= False;
        failed <= True;
    endrule

    // 处理意外的读响应，即在没有活动包或不在等待读响应时收到的读响应。
    rule rejectUnexpectedRead(!failed && readResponseQ.notEmpty && !waitingRead);
        readResponseQ.deq;
        errorQ.enq(RxError{qpn:active ? current.qpn : 0,
            psn:active ? current.psn : 0, code:RX_DMA_BAD_PAYLOAD});
        if (active)
            releaseQ.enq(RxBufferRelease{tag:current.payloadTag});
        active <= False;
        failed <= True;
    endrule

    // 配置 epoch，仅在非活跃时允许。
    method Action configureEpoch(RxEpoch value) if (!active);
        currentEpoch <= value;
        epochConfigured <= True;
    endmethod
    // 自定义 admittedIn，只有不失败、epoch 已配置、队列不满时才允许入队。
    interface admittedIn = interface PipeIn;
        method Action enq(RxAdmittedPacket packet)
                if (!failed && epochConfigured && admittedQ.notFull);
            admittedQ.enq(packet);
        endmethod
        method Bit#(1) notFull = pack(!failed && epochConfigured
            && admittedQ.notFull);
    endinterface;
    // 自定义 requestOut，出队时置 descriptorAccepted。
    interface requestOut = interface PipeOut;
        method RxDmaWriteRequest first if (requestQ.notEmpty);
            return requestQ.first;
        endmethod
        method Action deq if (requestQ.notEmpty);
            requestQ.deq;
            descriptorAccepted <= True;
        endmethod
        method Bit#(1) notEmpty = pack(requestQ.notEmpty);
    endinterface;
    // 自定义 payloadOut，出队时若 eop=1 则置 payloadAccepted。
    interface payloadOut = interface PipeOut;
        method RxDmaPayloadBeat first if (payloadQ.notEmpty);
            return payloadQ.first;
        endmethod
        method Action deq if (payloadQ.notEmpty);
            if (payloadQ.first.eop == 1)
                payloadAccepted <= True;
            payloadQ.deq;
        endmethod
        method Bit#(1) notEmpty = pack(payloadQ.notEmpty);
    endinterface;
    interface completionIn = toPipeIn(completionQ);
    interface readRequestOut = toPipeOut(readRequestQ);
    interface readResponseIn = toPipeIn(readResponseQ);
    interface releaseOut = toPipeOut(releaseQ);
    interface completedOut = toPipeOut(completedQ);
    interface errorOut = toPipeOut(errorQ);
    method Bool faulted = failed;
endmodule

// 4 通道顶层接口
interface RxDmaPlacementIfc;
    method Action configureEpoch(RxEpoch value);
    method RxGlobalSeq retireHead;
    method Bool faulted;
    interface Vector#(RxLaneCount, PipeIn#(RxAdmittedPacket)) admitted;
    interface Vector#(RxLaneCount, PipeOut#(RxDmaWriteRequest)) requests;
    interface Vector#(RxLaneCount, PipeOut#(RxDmaPayloadBeat)) payloads;
    interface Vector#(RxLaneCount, PipeIn#(RxDmaCompletion)) completions;
    interface Vector#(RxLaneCount, PipeOut#(RxPayloadReadRequest)) readRequests;
    interface Vector#(RxLaneCount, PipeIn#(RxPayloadReadResponse)) readResponses;
    interface Vector#(RxLaneCount, PipeOut#(RxBufferRelease)) releases;
    interface Vector#(RxLaneCount, PipeOut#(RxError)) errors;
    interface PipeOut#(RxDmaRetire) retireOut;
endinterface

// 顶层模块
module mkRxDmaPlacement(RxDmaPlacementIfc);
    // 为 4 条 lane 各实例化一个 DMA 放置模块；建立退休队列和头指针。
    Vector#(RxLaneCount, RxDmaLaneIfc) lanes;
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1)
        lanes[i] <- mkRxDmaLane(fromInteger(i));
    FIFOF#(RxDmaRetire) retireQ <- mkSizedFIFOF(rxDmaRetireQueueDepth);
    Reg#(RxGlobalSeq) head <- mkReg(0);

    // 故障聚合：任意 lane 故障则 anyFault 为真。
    Bool anyFault = False;
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1)
        anyFault = anyFault || lanes[i].faulted;

    // 按 globalSeq 顺序从各 lane 的 completedOut 中取出退休信号，放入顶层 retireQ。
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1) begin
        rule retireCompletedLane(!anyFault && lanes[i].completedOut.notEmpty == 1
                && lanes[i].completedOut.first.globalSeq == head);
            retireQ.enq(lanes[i].completedOut.first);
            lanes[i].completedOut.deq;
            head <= head + 1;
        endrule
    end

    // 把顶层 4 路接口连接到各 lane，并为 admitted 添加 anyFault 条件。
    Vector#(RxLaneCount, PipeIn#(RxAdmittedPacket)) admittedInputs;
    Vector#(RxLaneCount, PipeOut#(RxDmaWriteRequest)) requestOutputs;
    Vector#(RxLaneCount, PipeOut#(RxDmaPayloadBeat)) payloadOutputs;
    Vector#(RxLaneCount, PipeIn#(RxDmaCompletion)) completionInputs;
    Vector#(RxLaneCount, PipeOut#(RxPayloadReadRequest)) readRequestOutputs;
    Vector#(RxLaneCount, PipeIn#(RxPayloadReadResponse)) readResponseInputs;
    Vector#(RxLaneCount, PipeOut#(RxBufferRelease)) releaseOutputs;
    Vector#(RxLaneCount, PipeOut#(RxError)) errorOutputs;
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1) begin
        admittedInputs[i] = interface PipeIn;
            method Action enq(RxAdmittedPacket packet)
                    if (!anyFault && lanes[i].admittedIn.notFull == 1);
                lanes[i].admittedIn.enq(packet);
            endmethod
            method Bit#(1) notFull = pack(!anyFault
                && lanes[i].admittedIn.notFull == 1);
        endinterface;
        requestOutputs[i] = lanes[i].requestOut;
        payloadOutputs[i] = lanes[i].payloadOut;
        completionInputs[i] = lanes[i].completionIn;
        readRequestOutputs[i] = lanes[i].readRequestOut;
        readResponseInputs[i] = lanes[i].readResponseIn;
        releaseOutputs[i] = lanes[i].releaseOut;
        errorOutputs[i] = lanes[i].errorOut;
    end

    // 广播 epoch 配置，暴露头指针和故障标志，绑定各接口。
    method Action configureEpoch(RxEpoch value);
        for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1)
            lanes[i].configureEpoch(value);
    endmethod
    method RxGlobalSeq retireHead = head;
    method Bool faulted = anyFault;
    interface admitted = admittedInputs;
    interface requests = requestOutputs;
    interface payloads = payloadOutputs;
    interface completions = completionInputs;
    interface readRequests = readRequestOutputs;
    interface readResponses = readResponseInputs;
    interface releases = releaseOutputs;
    interface errors = errorOutputs;
    interface retireOut = toPipeOut(retireQ);
endmodule
endpackage
