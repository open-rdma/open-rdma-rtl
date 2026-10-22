package RetxContractTb;

import RetxTypes::*;

interface RetxContractTbIfc;
    method Action setReportHeader(Bit#(512) v);
    method Bit#(512) getReportHeader;
    method Action setHoleEntry(Bit#(320) v);
    method Bit#(320) getHoleEntry;
    method Action setRetryBatchHeader(Bit#(128) v);
    method Bit#(128) getRetryBatchHeader;
    method Action setRetryEntry(Bit#(320) v);
    method Bit#(320) getRetryEntry;
    method Action setRetryResult(Bit#(320) v);
    method Bit#(320) getRetryResult;
    method Action setOnDemandRequest(Bit#(256) v);
    method Bit#(256) getOnDemandRequest;
    method Action setNotification(Bit#(256) v);
    method Bit#(256) getNotification;
    method Action setRingCredit(Bit#(128) v);
    method Bit#(128) getRingCredit;
    method Action setNegotiationRequest(Bit#(640) v);
    method Bit#(640) getNegotiationRequest;
    method Action setNegotiationResponse(Bit#(640) v);
    method Bit#(640) getNegotiationResponse;
endinterface

(* synthesize *)
module mkRetxContractTb(RetxContractTbIfc);
    Reg#(Bit#(512)) reportHeaderReg <- mkReg(0);
    Reg#(Bit#(320)) holeEntryReg <- mkReg(0);
    Reg#(Bit#(128)) retryBatchHeaderReg <- mkReg(0);
    Reg#(Bit#(320)) retryEntryReg <- mkReg(0);
    Reg#(Bit#(320)) retryResultReg <- mkReg(0);
    Reg#(Bit#(256)) onDemandRequestReg <- mkReg(0);
    Reg#(Bit#(256)) notificationReg <- mkReg(0);
    Reg#(Bit#(128)) ringCreditReg <- mkReg(0);
    Reg#(Bit#(640)) negotiationRequestReg <- mkReg(0);
    Reg#(Bit#(640)) negotiationResponseReg <- mkReg(0);
    method Action setReportHeader(Bit#(512) v);
        reportHeaderReg <= v;
    endmethod
    method Bit#(512) getReportHeader = retxPackReportHeader(retxUnpackReportHeader(reportHeaderReg));
    method Action setHoleEntry(Bit#(320) v);
        holeEntryReg <= v;
    endmethod
    method Bit#(320) getHoleEntry = retxPackHoleEntry(retxUnpackHoleEntry(holeEntryReg));
    method Action setRetryBatchHeader(Bit#(128) v);
        retryBatchHeaderReg <= v;
    endmethod
    method Bit#(128) getRetryBatchHeader = retxPackRetryBatchHeader(retxUnpackRetryBatchHeader(retryBatchHeaderReg));
    method Action setRetryEntry(Bit#(320) v);
        retryEntryReg <= v;
    endmethod
    method Bit#(320) getRetryEntry = retxPackRetryEntry(retxUnpackRetryEntry(retryEntryReg));
    method Action setRetryResult(Bit#(320) v);
        retryResultReg <= v;
    endmethod
    method Bit#(320) getRetryResult = retxPackRetryResult(retxUnpackRetryResult(retryResultReg));
    method Action setOnDemandRequest(Bit#(256) v);
        onDemandRequestReg <= v;
    endmethod
    method Bit#(256) getOnDemandRequest = retxPackOnDemandRequest(retxUnpackOnDemandRequest(onDemandRequestReg));
    method Action setNotification(Bit#(256) v);
        notificationReg <= v;
    endmethod
    method Bit#(256) getNotification = retxPackNotification(retxUnpackNotification(notificationReg));
    method Action setRingCredit(Bit#(128) v);
        ringCreditReg <= v;
    endmethod
    method Bit#(128) getRingCredit = retxPackRingCredit(retxUnpackRingCredit(ringCreditReg));
    method Action setNegotiationRequest(Bit#(640) v);
        negotiationRequestReg <= v;
    endmethod
    method Bit#(640) getNegotiationRequest = retxPackNegotiationRequest(retxUnpackNegotiationRequest(negotiationRequestReg));
    method Action setNegotiationResponse(Bit#(640) v);
        negotiationResponseReg <= v;
    endmethod
    method Bit#(640) getNegotiationResponse = retxPackNegotiationResponse(retxUnpackNegotiationResponse(negotiationResponseReg));
endmodule

endpackage
