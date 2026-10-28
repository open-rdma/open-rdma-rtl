package RetxWqeMonitor;

import FIFOF :: *;

import CommonTypes :: *;
import E2eTypes :: *;
import RetxTypes :: *;
import TxTypes :: *;

// 在 MessageContext 进入 M2 的同一条路径上做旁路 WQE 注册：每个 message
// 只登记一次，返回的 recordHandle 按 message 顺序转发给 packet tap。
// 该模块不改变 context 流的内容，只额外声明 M9 需要的生命周期元数据。
interface RetxWqeMonitorIfc;
    interface PipeIn#(MessageContext) contextIn;
    interface PipeOut#(MessageContext) contextOut;
    interface PipeOut#(RetxWqeRegisterHw) wqeRegisterOut;
    interface PipeIn#(RetxWqeRegisterRespHw) wqeRegisterRespIn;
    interface PipeOut#(RetxRecordMeta) recordOut;
    method Action setEpoch(Bit#(16) epoch);
endinterface

module mkRetxWqeMonitor(RetxWqeMonitorIfc);
    FIFOF#(MessageContext) contextInQ <- mkSizedFIFOF(4);
    FIFOF#(MessageContext) contextOutQ <- mkSizedFIFOF(4);
    FIFOF#(RetxWqeRegisterHw) registerQ <- mkSizedFIFOF(4);
    FIFOF#(RetxWqeRegisterRespHw) respQ <- mkSizedFIFOF(4);
    FIFOF#(RetxRecordMeta) recordQ <- mkSizedFIFOF(8);
    FIFOF#(TxRequestId) pendingQ <- mkSizedFIFOF(8);

    Reg#(Bit#(16)) epoch <- mkReg(1);

    rule forwardContext (contextInQ.notEmpty && contextOutQ.notFull
                         && registerQ.notFull && pendingQ.notFull);
        let ctx = contextInQ.first;
        TxPsnCount packetCount = packetCountForContext(ctx);
        PktOpcode firstOpcode = packetOpcodeForProfile(
            ctx.wireProfile, 1, pack(packetCount == 1));
        registerQ.enq(RetxWqeRegisterHw {
            qpn: ctx.qpn,
            destQpn: ctx.destQpn,
            qpEpoch: epoch,
            requestId: ctx.requestId,
            psnBase: ctx.startPsn,
            psnCount: ctx.psnCount,
            packetCount: packetCount,
            pmtu: ctx.pmtu,
            messageLength: ctx.len,
            remoteAddr: ctx.remoteAddr,
            remoteKey: ctx.remoteKey,
            opcode: zeroExtend(pack(firstOpcode)),
            slotId: ctx.slotId,
            wireProfile: zeroExtend(pack(ctx.wireProfile)),
            evProfile: zeroExtend(pack(ctx.evProfileId)),
            mrcMsn: ctx.mrcMsn,
            msnValid: ctx.mrcMsnValid
        });
        pendingQ.enq(ctx.requestId);
        contextOutQ.enq(ctx);
        contextInQ.deq;
    endrule

    rule takeResponse (respQ.notEmpty && pendingQ.notEmpty && recordQ.notFull);
        let response = respQ.first;
        recordQ.enq(RetxRecordMeta {
            requestId: pendingQ.first,
            recordHandle: response.recordHandle
        });
        respQ.deq;
        pendingQ.deq;
    endrule

    interface contextIn = toPipeIn(contextInQ);
    interface contextOut = toPipeOut(contextOutQ);
    interface wqeRegisterOut = toPipeOut(registerQ);
    interface wqeRegisterRespIn = toPipeIn(respQ);
    interface recordOut = toPipeOut(recordQ);
    method Action setEpoch(Bit#(16) value);
        epoch <= value;
    endmethod
endmodule

endpackage
