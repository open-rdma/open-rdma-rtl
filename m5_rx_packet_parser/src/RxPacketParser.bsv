//这个包 RxPacketParser 是接收路径中的帧解析模块。它从 RxPacketBuffer 拿到已经组装好的完整帧，对帧头做协议解析和合法性校验，识别出数据包、ACK、ECN 事件或错误，然后把结果分发到不同的输出通道。顶层支持 4 条 lane，并把各 lane 的反馈、ECN、错误轮询合并输出。
package RxPacketParser;
import Vector::*;
import FIFOF::*;
import CommonTypes::*;
import TxTypes::*;
import RxTypes::*;

Integer rxParserQueueDepth = 4;
Integer rxParserTopQueueDepth = 8;
Integer rxEthernetHeaderBytes = 14;
Integer rxIpv4HeaderBytes = 20;
Integer rxUdpHeaderBytes = 8;
Integer rxRoceBaseOffset = rxEthernetHeaderBytes + rxIpv4HeaderBytes
    + rxUdpHeaderBytes;
Integer rxQpnWithinBthOffset = 4;
Integer rxPsnWithinBthOffset = 8;
Integer rxDestinationMacOffset = 0;
Integer rxSourceMacOffset = 6;
Integer rxEtherTypeOffset = 12;
Integer rxIpv4VersionOffset = 14;
Integer rxOpOffset = rxRoceBaseOffset;
Integer rxQpnOffset = rxRoceBaseOffset + rxQpnWithinBthOffset;
Integer rxPsnOffset = rxRoceBaseOffset + rxPsnWithinBthOffset;
Integer rxIpEcnOffset = 15;
Integer rxIpTotalLengthOffset = 16;
Integer rxIpFlagsOffset = 20;
Integer rxIpProtocolOffset = 23;
Integer rxIpSourceOffset = 26;
Integer rxIpDestinationOffset = 30;
Integer rxUdpSourcePortOffset = 34;
Integer rxUdpDestinationPortOffset = 36;
Integer rxUdpLengthOffset = 38;
Integer rxUdpChecksumOffset = 40;
Integer rxBthReservedByteOffset = 43;
Integer rxRkeyOffset = 54;
Integer rxAethOffset = 54;
Integer rxRethReservedWordOffset = 44;
Integer rxRethReservedByteOffset = 49;
Integer rxRethReservedTailOffset = 53;
Integer rxRemoteAddressOffset = 58;
Integer rxMessageBytesOffset = 66;
Integer rxFirstHeaderBytes = 70;
Integer rxContinuationHeaderBytes = 54;
Integer rxAckLogicalBytes = 58;
Integer rxMinimumIpv4PacketBytes = 40;
Integer rxMinimumEthernetFrameBytes = 60;
Integer rxMaxLogicalFrameBytes = 4138;
Integer rxMaxWritePayloadBytes = 4084;
Integer rxBitsPerByte = 8;

Bit#(8) rxAckOpcode = 8'h11;
Bit#(8) rxUdpProtocol = 8'd17;
Bit#(8) rxIpv4VersionIhl = 8'h45;
Bit#(16) rxIpv4EtherType = 16'h0800;
Bit#(16) rxIpv4FlagsMask = 16'hbfff;
Bit#(16) rxUdpSourcePort = 16'hc1e8;
Bit#(16) rxUdpDestinationPort = 16'd4791;
Bit#(16) rxUdpZeroChecksum = 0;
Bit#(16) rxRethReservedWord = 16'hffff;
Bit#(32) rxMaxMessageBytes = 32'h01000000;
Bit#(7) rxFirstHeaderLength = fromInteger(rxFirstHeaderBytes);
Bit#(7) rxContinuationHeaderLength = fromInteger(rxContinuationHeaderBytes);
Bit#(17) rxMaxLogicalFrameLength = fromInteger(rxMaxLogicalFrameBytes);
Bit#(17) rxAckLogicalLength = fromInteger(rxAckLogicalBytes);
Bit#(16) rxMinimumIpv4PacketLength = fromInteger(rxMinimumIpv4PacketBytes);
Bit#(13) rxMaxPayloadLength = fromInteger(rxMaxWritePayloadBytes);

// 定义解码结果的种类
typedef enum {
    RX_DECODE_DATA,
    RX_DECODE_DATA_ECN,
    RX_DECODE_ACK,
    RX_DECODE_ACK_ECN,
    RX_DECODE_ERROR
} RxDecodeKind deriving(Bits, Eq, FShow);
// 把一次解码产生的所有可能结果打包在一起。
typedef struct {
    RxDecodeKind kind;
    RxParsedPacket packet;
    RxTxFeedback feedback;
    RxEcnEvent ecn;
    RxBufferRelease releaseEvent;
    RxError error;
} RxDecodeResult deriving(Bits, Eq, FShow);
// 一个 lane 的帧解码器对外接口
interface RxFrameDecoderIfc;
    method Action configure(RxNetworkConfig cfg);
    interface PipeIn#(RxBufferedFrame) frameIn;
    interface PipeOut#(RxParsedPacket) packetOut;
    interface PipeOut#(RxTxFeedback) feedbackOut;
    interface PipeOut#(RxEcnEvent) ecnOut;
    interface PipeOut#(RxBufferRelease) releaseOut;
    interface PipeOut#(RxError) errorOut;
endinterface

// 单通道解码器模块：保存配置，建立输入帧队列、中间结果队列和各输出队列
module mkRxFrameDecoder(RxFrameDecoderIfc);
    Reg#(RxNetworkConfig) cfg <- mkReg(unpack(0));
    FIFOF#(RxBufferedFrame) inQ <- mkFIFOF;
    FIFOF#(RxDecodeResult) resultQ <- mkSizedFIFOF(rxParserQueueDepth);
    FIFOF#(RxParsedPacket) packetQ <- mkFIFOF;
    FIFOF#(RxTxFeedback) feedbackQ <- mkSizedFIFOF(rxParserQueueDepth);
    FIFOF#(RxEcnEvent) ecnQ <- mkSizedFIFOF(rxParserQueueDepth);
    FIFOF#(RxBufferRelease) releaseQ <- mkSizedFIFOF(rxParserQueueDepth);
    FIFOF#(RxError) errorQ <- mkSizedFIFOF(rxParserQueueDepth);

    // 协议解析、合法性校验和分类：把原始帧变成结构化的解析结果，并标记类型
    rule decode;
        let frame = inQ.first;
        let op = rxHeaderByte(frame, rxOpOffset);
        let qpn = rxHeaderBE24(frame, rxQpnOffset);
        let psn = rxHeaderBE24(frame, rxPsnOffset);
        let ecn = rxHeaderByte(frame, rxIpEcnOffset)[1:0];
        Bool first = op == zeroExtend(pack(OP_WRITE_FIRST))
            || op == zeroExtend(pack(OP_WRITE_ONLY));
        Bool last = op == zeroExtend(pack(OP_WRITE_LAST))
            || op == zeroExtend(pack(OP_WRITE_ONLY));
        Bool writeOp = first || last || op == zeroExtend(pack(OP_WRITE_MIDDLE));
        Bool ackOp = op == rxAckOpcode;
        Bit#(7) headerBytes = first ? rxFirstHeaderLength : rxContinuationHeaderLength;
        Bit#(16) ipBytes = rxHeaderBE16(frame, rxIpTotalLengthOffset);
        Bit#(16) udpBytes = rxHeaderBE16(frame, rxUdpLengthOffset);
        Bit#(17) logicalWide = zeroExtend(ipBytes)
            + fromInteger(rxEthernetHeaderBytes);
        Bit#(13) logicalBytes = truncate(logicalWide);
        Bit#(13) payloadBytes = logicalWide >= zeroExtend(headerBytes)
            ? logicalBytes - zeroExtend(headerBytes) : 0;
        Bool paddingZero = True;
        for (Integer i = rxContinuationHeaderBytes;
                i < rxMinimumEthernetFrameBytes; i = i + 1) begin
            Bit#(17) byteOffset = fromInteger(i);
            if (byteOffset >= logicalWide && byteOffset < zeroExtend(frame.bytes)
                    && rxHeaderByte(frame, i) != 0)
                paddingZero = False;
        end
        Bool physicalLengthOk = logicalWide == zeroExtend(frame.bytes)
            || (logicalWide < fromInteger(rxMinimumEthernetFrameBytes)
                && frame.bytes == fromInteger(rxMinimumEthernetFrameBytes)
                && paddingZero);
        Bit#(160) ipHeader = 0;
        for (Integer i = 0; i < rxIpv4HeaderBytes; i = i + 1)
            ipHeader[rxBitsPerByte * i + 7 : rxBitsPerByte * i]
                = rxHeaderByte(frame, rxEthernetHeaderBytes + i);

        Bool envelope = frame.bytes >= fromInteger(rxContinuationHeaderBytes)
            && physicalLengthOk
            && ipBytes >= rxMinimumIpv4PacketLength
            && logicalWide <= rxMaxLogicalFrameLength
            && rxHeaderBE48(frame, rxDestinationMacOffset) == cfg.localMac
            && rxHeaderBE48(frame, rxSourceMacOffset) == cfg.peerMac
            && rxHeaderBE16(frame, rxEtherTypeOffset) == rxIpv4EtherType
            && rxHeaderByte(frame, rxIpv4VersionOffset) == rxIpv4VersionIhl
            && (rxHeaderBE16(frame, rxIpFlagsOffset) & rxIpv4FlagsMask) == 0
            && rxHeaderByte(frame, rxIpProtocolOffset) == rxUdpProtocol
            && ipv4Checksum(ipHeader) == 0
            && rxHeaderBE32(frame, rxIpSourceOffset) == cfg.peerIp
            && rxHeaderBE32(frame, rxIpDestinationOffset) == cfg.localIp
            && rxHeaderBE16(frame, rxUdpSourcePortOffset) == rxUdpSourcePort
            && rxHeaderBE16(frame, rxUdpDestinationPortOffset) == rxUdpDestinationPort
            && udpBytes == ipBytes - fromInteger(rxIpv4HeaderBytes)
            && rxHeaderBE16(frame, rxUdpChecksumOffset) == rxUdpZeroChecksum
            && rxHeaderByte(frame, rxBthReservedByteOffset) == 0
            && rxHeaderBE16(frame, rxRethReservedWordOffset) == rxRethReservedWord
            && rxHeaderByte(frame, rxRethReservedByteOffset) == 0
            && rxHeaderByte(frame, rxRethReservedTailOffset) == 0;
        Bool validWrite = writeOp && logicalWide >= zeroExtend(headerBytes)
            && payloadBytes != 0 && payloadBytes <= rxMaxPayloadLength
            && (!first || (rxHeaderBE32(frame, rxMessageBytesOffset) != 0
                && rxHeaderBE32(frame, rxMessageBytesOffset) <= rxMaxMessageBytes));
        Bool validAck = ackOp && logicalWide == rxAckLogicalLength;

        let parsedPacket = RxParsedPacket{payloadTag:frame.tag,
            lane:frame.tag.lane, qpn:qpn, psn:psn, opcode:op, ecn:ecn,
            payloadStart:headerBytes, payloadBytes:payloadBytes,
            remoteAddr:first ? rxHeaderBE64(frame, rxRemoteAddressOffset) : 0,
            rkey:first ? rxHeaderBE32(frame, rxRkeyOffset) : 0,
            messageBytes:first ? truncate(rxHeaderBE32(frame, rxMessageBytesOffset)) : 0,
            first:first, last:last};
        let feedbackEvent = RxTxFeedback{qpn:qpn, psn:psn,
            aeth:rxHeaderBE32(frame, rxAethOffset)};
        let ecnEvent = RxEcnEvent{lane:frame.tag.lane, qpn:qpn,
            psn:psn, ecn:ecn};
        let releaseEvent = RxBufferRelease{tag:frame.tag};
        let errorEvent = RxError{qpn:qpn, psn:psn, code:RX_BAD_HEADER};
        RxDecodeKind kind = RX_DECODE_ERROR;
        if (envelope && validAck)
            kind = ecn == 3 ? RX_DECODE_ACK_ECN : RX_DECODE_ACK;
        else if (envelope && validWrite)
            kind = ecn == 3 ? RX_DECODE_DATA_ECN : RX_DECODE_DATA;
        resultQ.enq(RxDecodeResult{kind:kind, packet:parsedPacket,
            feedback:feedbackEvent, ecn:ecnEvent, releaseEvent:releaseEvent,
            error:errorEvent});
        inQ.deq;
    endrule

    // 根据 resultQ.first.kind 把解码结果分发到不同输出队列
    rule routeData(resultQ.first.kind == RX_DECODE_DATA);
        packetQ.enq(resultQ.first.packet);
        resultQ.deq;
    endrule
    rule routeDataEcn(resultQ.first.kind == RX_DECODE_DATA_ECN);
        packetQ.enq(resultQ.first.packet);
        ecnQ.enq(resultQ.first.ecn);
        resultQ.deq;
    endrule
    rule routeAck(resultQ.first.kind == RX_DECODE_ACK);
        feedbackQ.enq(resultQ.first.feedback);
        releaseQ.enq(resultQ.first.releaseEvent);
        resultQ.deq;
    endrule
    rule routeAckEcn(resultQ.first.kind == RX_DECODE_ACK_ECN);
        feedbackQ.enq(resultQ.first.feedback);
        ecnQ.enq(resultQ.first.ecn);
        releaseQ.enq(resultQ.first.releaseEvent);
        resultQ.deq;
    endrule
    rule routeError(resultQ.first.kind == RX_DECODE_ERROR);
        errorQ.enq(resultQ.first.error);
        releaseQ.enq(resultQ.first.releaseEvent);
        resultQ.deq;
    endrule
    
    // 提供配置方法，并把内部队列包装成接口
    method Action configure(RxNetworkConfig value);
        cfg <= value;
    endmethod
    interface frameIn = toPipeIn(inQ);
    interface packetOut = toPipeOut(packetQ);
    interface feedbackOut = toPipeOut(feedbackQ);
    interface ecnOut = toPipeOut(ecnQ);
    interface releaseOut = toPipeOut(releaseQ);
    interface errorOut = toPipeOut(errorQ);
endmodule

// 四通道解析器封装
interface RxPacketParserIfc;
    method Action configure(RxNetworkConfig cfg);
    interface Vector#(RxLaneCount, PipeIn#(RxBufferedFrame)) frames;
    interface Vector#(RxLaneCount, PipeOut#(RxParsedPacket)) packets;
    interface PipeOut#(RxTxFeedback) feedbackOut;
    interface PipeOut#(RxEcnEvent) ecnOut;
    interface Vector#(RxLaneCount, PipeOut#(RxBufferRelease)) releases;
    interface PipeOut#(RxError) errorOut;
endinterface

// 顶层封装
module mkRxPacketParser(RxPacketParserIfc);
    Vector#(RxLaneCount, RxFrameDecoderIfc) decoders <- replicateM(mkRxFrameDecoder); // 实例化四个解码器
    // 建立顶层反馈、ECN、错误队列，以及轮询游标
    FIFOF#(RxTxFeedback) feedbackQ <- mkSizedFIFOF(rxParserTopQueueDepth);
    FIFOF#(RxEcnEvent) ecnQ <- mkSizedFIFOF(rxParserTopQueueDepth);
    FIFOF#(RxError) errorQ <- mkSizedFIFOF(rxParserTopQueueDepth);
    Reg#(RxLaneId) feedbackCursor <- mkReg(0);
    Reg#(RxLaneId) ecnCursor <- mkReg(0);
    Reg#(RxLaneId) errorCursor <- mkReg(0);

    // 检查各 lane 对应输出队列是否非空，返回 4 位掩码
    function Bit#(RxLaneCount) feedbackReadyMask();
        Bit#(RxLaneCount) ready = 0;
        for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1)
            ready[i] = decoders[i].feedbackOut.notEmpty;
        return ready;
    endfunction
    function Bit#(RxLaneCount) ecnReadyMask();
        Bit#(RxLaneCount) ready = 0;
        for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1)
            ready[i] = decoders[i].ecnOut.notEmpty;
        return ready;
    endfunction
    function Bit#(RxLaneCount) errorReadyMask();
        Bit#(RxLaneCount) ready = 0;
        for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1)
            ready[i] = decoders[i].errorOut.notEmpty;
        return ready;
    endfunction

    // 根据就绪掩码和当前游标，选择一个要服务的 lane
    let selectedFeedback = rxPickReadyLane(feedbackReadyMask(), feedbackCursor);
    let selectedEcn = rxPickReadyLane(ecnReadyMask(), ecnCursor);
    let selectedError = rxPickReadyLane(errorReadyMask(), errorCursor);
    // 当某个 lane 被选中时，把它的反馈、ECN 或错误搬到顶层队列，并更新游标
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1) begin
        rule mergeFeedbackLane(isValid(selectedFeedback)
                && fromMaybe(0, selectedFeedback) == fromInteger(i));
            feedbackQ.enq(decoders[i].feedbackOut.first);
            decoders[i].feedbackOut.deq;
            feedbackCursor <= fromInteger((i + 1) % valueOf(RxLaneCount));
        endrule
        rule mergeEcnLane(isValid(selectedEcn)
                && fromMaybe(0, selectedEcn) == fromInteger(i));
            ecnQ.enq(decoders[i].ecnOut.first);
            decoders[i].ecnOut.deq;
            ecnCursor <= fromInteger((i + 1) % valueOf(RxLaneCount));
        endrule
        rule mergeErrorLane(isValid(selectedError)
                && fromMaybe(0, selectedError) == fromInteger(i));
            errorQ.enq(decoders[i].errorOut.first);
            decoders[i].errorOut.deq;
            errorCursor <= fromInteger((i + 1) % valueOf(RxLaneCount));
        endrule
    end

    // 把各 lane 的输入帧、输出数据包、释放请求直接透传到顶层向量接口
    Vector#(RxLaneCount, PipeIn#(RxBufferedFrame)) frameInputs;
    Vector#(RxLaneCount, PipeOut#(RxParsedPacket)) packetOutputs;
    Vector#(RxLaneCount, PipeOut#(RxBufferRelease)) releaseOutputs;
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1) begin
        frameInputs[i] = decoders[i].frameIn;
        packetOutputs[i] = decoders[i].packetOut;
        releaseOutputs[i] = decoders[i].releaseOut;
    end

    // 把配置广播给 4 个解码器，并绑定顶层接口
    method Action configure(RxNetworkConfig value);
        for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1)
            decoders[i].configure(value);
    endmethod
    interface frames = frameInputs;
    interface packets = packetOutputs;
    interface feedbackOut = toPipeOut(feedbackQ);
    interface ecnOut = toPipeOut(ecnQ);
    interface releases = releaseOutputs;
    interface errorOut = toPipeOut(errorQ);
endmodule
endpackage
