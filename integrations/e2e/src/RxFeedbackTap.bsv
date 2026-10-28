package RxFeedbackTap;

import FIFOF :: *;

import CommonTypes :: *;
import RetxTypes :: *;
import RxTypes :: *;
import TxTypes :: *;

// RxTop 的本地 feedback 有两个消费者：
//   * M9 scoreboard：转成 RetxFeedbackEventHw，推进 ACK/SACK/NAK；
//   * CPU 观测端口：保留原始 RxFeedback，用于 host 侧监控/调试。
// 两个输出都按 FIFO 反压，任何一侧都不丢事件。
interface RxFeedbackTapIfc;
    interface PipeIn#(RxFeedback) feedbackIn;
    interface PipeOut#(RetxFeedbackEventHw) retxOut;
    interface PipeOut#(RxFeedback) observeOut;
    method Action setEpoch(Bit#(16) epoch);
endinterface

module mkRxFeedbackTap(RxFeedbackTapIfc);
    FIFOF#(RxFeedback) inputQ <- mkSizedFIFOF(8);
    FIFOF#(RetxFeedbackEventHw) retxQ <- mkSizedFIFOF(8);
    FIFOF#(RxFeedback) observeQ <- mkSizedFIFOF(8);

    Reg#(Bit#(16)) epoch <- mkReg(1);

    function Bit#(2) feedbackKind(RxFeedback feedback);
        if (feedback.kind == RX_NACK) return 2;
        else if (feedback.sackBitmap != 0) return 1;
        else return 0;
    endfunction

    rule distribute (inputQ.notEmpty && retxQ.notFull && observeQ.notFull);
        let feedback = inputQ.first;
        let kind = feedbackKind(feedback);
        Bit#(1) nak = pack(kind == 2);
        retxQ.enq(RetxFeedbackEventHw {
            qpn: feedback.qpn,
            qpEpoch: epoch,
            kind: kind,
            ackPsn: feedback.ackPsn,
            sackBase: feedback.sackBase,
            sackBitmap: zeroExtend(feedback.sackBitmap),
            sackValidBits: 16,
            nakValid: nak,
            nakCode: nak == 1 ? 7'h01 : 7'h00,
            nakPsn: nak == 1 ? feedback.triggerPsn : 0,
            oooCount: zeroExtend(feedback.oooCount),
            triggerPsn: feedback.triggerPsn
        });
        observeQ.enq(feedback);
        inputQ.deq;
    endrule

    interface feedbackIn = toPipeIn(inputQ);
    interface retxOut = toPipeOut(retxQ);
    interface observeOut = toPipeOut(observeQ);
    method Action setEpoch(Bit#(16) value);
        epoch <= value;
    endmethod
endmodule

endpackage
