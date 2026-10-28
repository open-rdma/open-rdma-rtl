package RetxM3Bridge;

import FIFOF :: *;

import CommonTypes :: *;
import RetxTypes :: *;
import TxTypes :: *;

// M11 输出的是 retx 内部 descriptor/beat 类型；M3 需要 TX 公共类型。
// 该桥接只做类型转换，并把 trafficClass 固定为 TRAFFIC_RETRY，因此 M3 的
// retry 仲裁路径会把它当作独立流量类别插入主数据流。
interface RetxM3BridgeIfc;
    interface PipeIn#(RetxM3DescHw) retxDescriptorIn;
    interface PipeIn#(RetxM3BeatHw) retxBeatIn;
    interface PipeOut#(PacketDescriptor) descriptorOut;
    interface PipeOut#(PacketPayloadBeat) payloadOut;
endinterface

module mkRetxM3Bridge(RetxM3BridgeIfc);
    FIFOF#(RetxM3DescHw) descriptorInQ <- mkSizedFIFOF(4);
    FIFOF#(RetxM3BeatHw) beatInQ <- mkSizedFIFOF(8);
    FIFOF#(PacketDescriptor) descriptorOutQ <- mkSizedFIFOF(4);
    FIFOF#(PacketPayloadBeat) payloadOutQ <- mkSizedFIFOF(8);

    rule convertDescriptor (descriptorInQ.notEmpty && descriptorOutQ.notFull);
        let source = descriptorInQ.first;
        descriptorOutQ.enq(PacketDescriptor {
            requestId: source.requestId,
            qpn: source.qpn,
            destQpn: source.destQpn,
            slotId: 0,
            debugSeq: 0,
            pmtu: source.pmtu,
            psn: source.psn,
            packetIndex: source.packetIndex,
            packetCount: source.packetCount,
            opcode: unpack(source.opcode),
            remoteAddr: source.remoteAddr,
            remoteKey: source.remoteKey,
            messageOffset: source.messageOffset,
            payloadLength: source.payloadLength,
            messageLength: source.messageLength,
            isFirst: source.first,
            isLast: source.last,
            trafficClass: TRAFFIC_RETRY,
            wireProfile: unpack(source.wireProfile),
            evProfileId: source.evProfile,
            mrcMsn: source.mrcMsn,
            mrcMsnValid: 0
        });
        descriptorInQ.deq;
    endrule

    rule convertBeat (beatInQ.notEmpty && payloadOutQ.notFull);
        let source = beatInQ.first;
        payloadOutQ.enq(PacketPayloadBeat {
            requestId: source.requestId,
            psn: source.psn,
            data: source.data,
            keep: source.keep,
            sop: source.sop,
            eop: source.eop
        });
        beatInQ.deq;
    endrule

    interface retxDescriptorIn = toPipeIn(descriptorInQ);
    interface retxBeatIn = toPipeIn(beatInQ);
    interface descriptorOut = toPipeOut(descriptorOutQ);
    interface payloadOut = toPipeOut(payloadOutQ);
endmodule

endpackage
