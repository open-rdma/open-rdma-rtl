// PacketAssembly: channel-neutral M2 packetizer.
//
// M2 consumes a serialized 1024-bit message stream and emits one descriptor
// followed by that packet's 1024-bit payload stream. Ethernet/RoCE headers
// and physical-channel selection belong to M3.

package PacketAssembly;

import Assert :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import Vector :: *;

import CommonTypes :: *;
import TxTypes :: *;

// ---------------------------------------------------------------------------
// 1024-bit byte aligner
// ---------------------------------------------------------------------------

typedef struct {
    Bit#(1024) data;
    Bit#(8)    payloadTaken;
} AlignedBeat deriving(Bits, Eq, FShow);

typedef struct {
    Bit#(1024) data;
    Bit#(8)    length;
} ResidualUpdate deriving(Bits, Eq, FShow);

interface ByteAlignerIfc;
    interface PipeIn#(MessagePayloadBeat) payloadIn;
    method ActionValue#(AlignedBeat) request(
        Bit#(8) need, TxRequestId expectedId, TxLength expectedOffset);
    method Action flush;
    method Bit#(8) residualBytes;
    method Bit#(9) supplyBytes;
endinterface

(* synthesize *)
module mkByteAligner(ByteAlignerIfc);
    Reg#(Bit#(1024)) residual <- mkReg(0);
    Reg#(Bit#(8)) residualLen <- mkReg(0);
    Wire#(Maybe#(ResidualUpdate)) residualUpdateReq <- mkDWire(tagged Invalid);
    Wire#(Bool) residualFlushReq <- mkDWire(False);

    rule commitResidual;
        dynamicAssert(!(residualFlushReq && isValid(residualUpdateReq)),
            "M2 residual request and flush conflict");
        if (residualFlushReq) begin
            residual <= 0;
            residualLen <= 0;
        end else begin
            case (residualUpdateReq) matches
                tagged Valid .update: begin
                    residual <= update.data;
                    residualLen <= update.length;
                end
            endcase
        end
    endrule

    // A register queue keeps first/notEmpty out of method guards. This is the
    // same commit pattern used by the proven 256-bit aligner.
    Reg#(MessagePayloadBeat) qHead <- mkReg(unpack(0));
    Reg#(MessagePayloadBeat) qTail <- mkReg(unpack(0));
    Reg#(Bool) qHeadV <- mkReg(False);
    Reg#(Bool) qTailV <- mkReg(False);
    Wire#(Maybe#(MessagePayloadBeat)) enqReq <- mkDWire(tagged Invalid);
    Wire#(Bool) deqReq <- mkDWire(False);
    Wire#(Bool) deq2Req <- mkDWire(False);

    // MessagePayloadBeat is a strict framed stream: EOP is the final byte and
    // no stale beat may arrive after EOP. Queue cleanup therefore consumes only
    // explicit request() dequeues; flush clears residual state but never drops a
    // future beat by requestId, so a completed ID can be reused safely.
    rule commitQueue;
        case (enqReq) matches
            tagged Valid .v: begin
                if (deqReq || deq2Req) begin
                    qHead <= v;
                    qHeadV <= True;
                    qTailV <= False;
                end else if (qHeadV) begin
                    qTail <= v;
                    qTailV <= True;
                end else begin
                    qHead <= v;
                    qHeadV <= True;
                end
            end
            tagged Invalid: begin
                if (deq2Req) begin
                    qHeadV <= False;
                    qTailV <= False;
                end else if (deqReq) begin
                    qHead <= qTail;
                    qHeadV <= qTailV;
                    qTailV <= False;
                end
            end
        endcase
    endrule

    Bit#(8) headAvail = qHeadV ? pack(countOnes(qHead.keep)) : 8'd0;
    Bit#(8) tailAvail = qTailV ? pack(countOnes(qTail.keep)) : 8'd0;
    Bit#(9) supply = zeroExtend(residualLen) + zeroExtend(headAvail)
        + zeroExtend(tailAvail);

    method ActionValue#(AlignedBeat) request(
        Bit#(8) need, TxRequestId expectedId, TxLength expectedOffset);
        dynamicAssert(need != 0, "M2 byte aligner zero-byte request");
        dynamicAssert(supply >= zeroExtend(need),
            "M2 byte aligner request beyond supply");

        Bit#(8) fromResidual = need < residualLen ? need : residualLen;
        Bit#(8) takenFromPayload = need - fromResidual;
        Bit#(8) residualLeft = residualLen - fromResidual;
        Bit#(11) fromShift = 8 * zeroExtend(fromResidual);
        Bit#(11) takenShift = 8 * zeroExtend(takenFromPayload);

        Bit#(1024) payloadData = 0;
        Bit#(1024) tailData = 0;
        Bit#(8) payloadLeft = 0;
        Bit#(8) tailTake = 0;

        if (takenFromPayload > 0) begin
            dynamicAssert(qHeadV, "M2 byte aligner payload underflow");
            dynamicAssert(qHead.requestId == expectedId,
                "M2 payload requestId mismatch");
            dynamicAssert(qHead.messageOffset ==
                    expectedOffset + zeroExtend(fromResidual),
                "M2 payload messageOffset mismatch");

            Bit#(8) headTake =
                takenFromPayload < headAvail ? takenFromPayload : headAvail;
            tailTake = takenFromPayload - headTake;
            Bit#(11) headShift = 8 * zeroExtend(headAvail);
            Bit#(1024) headData = qHead.data
                & truncate((1025'h1 << headShift) - 1025'h1);
            payloadData = headData;

            if (tailTake > 0) begin
                dynamicAssert(qTailV, "M2 byte aligner tail underflow");
                dynamicAssert(qTail.requestId == expectedId,
                    "M2 payload requestId mismatch");
                dynamicAssert(qTail.messageOffset ==
                        qHead.messageOffset + zeroExtend(headAvail),
                    "M2 payload stream has an offset gap");
                Bit#(11) tailShift = 8 * zeroExtend(tailAvail);
                tailData = qTail.data
                    & truncate((1025'h1 << tailShift) - 1025'h1);
                payloadData = headData | (tailData << headShift);
                deq2Req <= True;
            end else begin
                deqReq <= True;
            end

            payloadLeft = tailTake > 0
                ? (tailAvail - tailTake) : (headAvail - headTake);
        end

        Bit#(1024) taken = residual | (payloadData << fromShift);
        Bit#(8) newResidualLen =
            takenFromPayload > 0 ? payloadLeft : residualLeft;
        Bit#(11) tailTakeShift = 8 * zeroExtend(tailTake);
        Bit#(1024) newResidual = takenFromPayload > 0
            ? ((tailTake > 0)
                ? (tailData >> tailTakeShift)
                : (payloadData >> takenShift))
            : (residual >> fromShift);
        Bit#(11) residualShift = 8 * zeroExtend(newResidualLen);
        residualUpdateReq <= tagged Valid ResidualUpdate {
            data: newResidual
                & truncate((1025'h1 << residualShift) - 1025'h1),
            length: newResidualLen
        };

        return AlignedBeat { data: taken, payloadTaken: takenFromPayload };
    endmethod

    method Action flush;
        residualFlushReq <= True;
    endmethod

    method Bit#(8) residualBytes = residualLen;
    method Bit#(9) supplyBytes = supply;

    interface PipeIn payloadIn;
        method Action enq(MessagePayloadBeat v) if (!qTailV);
            dynamicAssert(isPrefixKeep128(v.keep),
                "M2 input keep must be non-zero and prefix-contiguous");
            dynamicAssert(v.messageSop == pack(v.messageOffset == 0),
                "M2 input SOP does not match message offset");
            dynamicAssert(v.messageEop == 1 || v.keep == '1,
                "M2 non-EOP input beat must be full width");
            enqReq <= tagged Valid v;
        endmethod
        method Bit#(1) notFull = pack(!qTailV);
    endinterface
endmodule

// ---------------------------------------------------------------------------
// Packetizer
// ---------------------------------------------------------------------------

typedef enum {
    P_IDLE,
    P_DESCRIPTOR,
    P_PAYLOAD
} PacketizerState deriving(Bits, Eq, FShow);

// descriptor 构造保持纯组合；startMessage 已验证整段 remote range，
// 后续 packet 的 offset 因此也不会溢出。
function PacketDescriptor buildPacketDescriptor(
    MessageContext ctx,
    TxPsnCount index,
    TxPsnCount count,
    TxLength offset,
    Bit#(13) payloadLength);
    Bit#(1) isFirst = pack(index == 0);
    Bit#(1) isLast = pack(index + 1 == count);
    Bit#(64) remoteAddr = ctx.remoteAddr + zeroExtend(offset);
    return PacketDescriptor {
        requestId: ctx.requestId,
        qpn: ctx.qpn,
        destQpn: ctx.destQpn,
        slotId: ctx.slotId,
        debugSeq: ctx.debugSeq,
        pmtu: ctx.pmtu,
        psn: ctx.startPsn + zeroExtend(index),
        packetIndex: index,
        packetCount: count,
        opcode: packetOpcodeForProfile(ctx.wireProfile, isFirst, isLast),
        remoteAddr: remoteAddr,
        remoteKey: ctx.remoteKey,
        messageOffset: offset,
        payloadLength: payloadLength,
        messageLength: ctx.len,
        isFirst: isFirst,
        isLast: isLast,
        trafficClass: TRAFFIC_FIRST,
        wireProfile: ctx.wireProfile,
        evProfileId: ctx.evProfileId,
        mrcMsn: ctx.mrcMsn,
        mrcMsnValid: ctx.mrcMsnValid
    };
endfunction

interface PacketAssemblyEngineIfc;
    interface PipeIn#(MessageContext) contextIn;
    interface PipeIn#(MessagePayloadBeat) payloadIn;
    interface PipeOut#(PacketDescriptor) descriptorOut;
    interface PipeOut#(PacketPayloadBeat) payloadOut;
endinterface

(* synthesize *)
module mkPacketAssemblyEngine(PacketAssemblyEngineIfc);
    Reg#(PacketizerState) state <- mkReg(P_IDLE);
    Reg#(MessageContext) ctxLatch <- mkReg(unpack(0));
    Reg#(TxPsnCount) packetIndex <- mkReg(0);
    Reg#(TxPsnCount) packetCount <- mkReg(0);
    Reg#(TxLength) messageRemaining <- mkReg(0);
    Reg#(TxLength) messageOffset <- mkReg(0);
    Reg#(Bit#(13)) packetRemaining <- mkReg(0);
    Reg#(Bit#(13)) packetPayloadLength <- mkReg(0);

    FIFOF#(MessageContext) contextQ <- mkSizedFIFOF(8);
    FIFOF#(PacketDescriptor) descriptorQ <- mkSizedFIFOF(2);
    FIFOF#(PacketPayloadBeat) payloadQ <- mkPipelineFIFOF;
    ByteAlignerIfc aligner <- mkByteAligner;

    rule startMessage (state == P_IDLE && contextQ.notEmpty &&
                       descriptorQ.notFull);
        let ctx = contextQ.first;
        let count = packetCountForContext(ctx);
        Bit#(65) remoteEnd = zeroExtend(ctx.remoteAddr) +
            zeroExtend(ctx.len) - 1;
        dynamicAssert(ctx.len != 0, "M2 zero-length messages are unsupported");
        dynamicAssert(aligner.residualBytes == 0,
            "M2 stale aligner residual at message start");
        dynamicAssert(remoteEnd[64] == 0, "M2 remote address range overflow");
        dynamicAssert(ctx.pmtu <= 4, "M2 invalid PMTU code");
        dynamicAssert(isSupportedWireProfile(ctx.wireProfile),
            "M2 unsupported wire profile");
        dynamicAssert(ctx.wireProfile != WIRE_MRC_IPV4_ECMP_NO_ICRC ||
                ctx.mrcMsnValid == 1,
            "M2 MRC profile requires a valid MSN");
        if (ctx.wireProfile == WIRE_MRC_IPV4_ECMP_NO_ICRC)
            dynamicAssert(ctx.psnCount == count,
                "M2 MRC reserved PSN range must match packet count");
        else
            dynamicAssert(ctx.psnCount >= count,
                "M2 reserved PSN range is smaller than packet count");

        contextQ.deq;
        ctxLatch <= ctx;
        packetIndex <= 0;
        packetCount <= count;
        messageRemaining <= ctx.len;
        messageOffset <= 0;

        Bit#(13) firstLimit = packetPayloadLimitForProfile(
            ctx.wireProfile, ctx.pmtu, 1);
        Bit#(25) firstLength =
            ctx.len < zeroExtend(firstLimit) ? ctx.len : zeroExtend(firstLimit);
        Bit#(13) firstPayloadLength = truncate(firstLength);
        packetRemaining <= firstPayloadLength;
        packetPayloadLength <= firstPayloadLength;
        descriptorQ.enq(buildPacketDescriptor(
            ctx, 0, count, 0, firstPayloadLength));
        state <= P_PAYLOAD;
    endrule

    rule emitDescriptor (state == P_DESCRIPTOR && descriptorQ.notFull);
        Bit#(65) remoteAddrWide = zeroExtend(ctxLatch.remoteAddr) +
            zeroExtend(messageOffset);
        dynamicAssert(remoteAddrWide[64] == 0,
            "M2 remote address overflow");
        descriptorQ.enq(buildPacketDescriptor(
            ctxLatch,
            packetIndex,
            packetCount,
            messageOffset,
            packetPayloadLength));
        state <= P_PAYLOAD;
    endrule

    Bit#(13) requested13 = packetRemaining < 13'd128
        ? packetRemaining : 13'd128;
    Bit#(8) requested = truncate(requested13);

    rule emitPayload (state == P_PAYLOAD && payloadQ.notFull &&
                      aligner.supplyBytes >= zeroExtend(requested));
        let aligned <- aligner.request(
            requested, ctxLatch.requestId, messageOffset);
        let packetEnd = packetRemaining == zeroExtend(requested);
        let messageLeft = messageRemaining - zeroExtend(requested);
        let packetSop = packetRemaining == packetPayloadLength;

        payloadQ.enq(PacketPayloadBeat {
            requestId: ctxLatch.requestId,
            psn: ctxLatch.startPsn + zeroExtend(packetIndex),
            data: aligned.data,
            keep: byteMask128(requested),
            sop: pack(packetSop),
            eop: pack(packetEnd)
        });

        messageRemaining <= messageLeft;
        messageOffset <= messageOffset + zeroExtend(requested);

        if (packetEnd) begin
            if (messageLeft == 0) begin
                // 最后一次 request 精确消费 canonical EOP，aligner residual
                // 已经为空，因此直接返回 idle，不再插入固定气泡。
                state <= P_IDLE;
            end else begin
                Bit#(13) limit = packetPayloadLimitForProfile(
                    ctxLatch.wireProfile, ctxLatch.pmtu, 0);
                Bit#(25) nextLength = messageLeft < zeroExtend(limit)
                    ? messageLeft : zeroExtend(limit);
                packetIndex <= packetIndex + 1;
                packetRemaining <= truncate(nextLength);
                packetPayloadLength <= truncate(nextLength);
                state <= P_DESCRIPTOR;
            end
        end else begin
            packetRemaining <= packetRemaining - zeroExtend(requested);
        end
    endrule

    interface contextIn = toPipeIn(contextQ);
    interface payloadIn = aligner.payloadIn;
    interface descriptorOut = toPipeOut(descriptorQ);
    interface payloadOut = toPipeOut(payloadQ);
endmodule

endpackage
