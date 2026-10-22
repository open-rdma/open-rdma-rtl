package RetxRetryEngine;

import FIFOF::*;
import RetxTypes::*;
import CommonTypes::*;

// m11: Retry Request validation, Admission, payload replay fetch, M3 dispatch
// and Retry Result emission. One active request at a time in this MVP model.
interface RetxRetryEngineIfc;
    method Action configure(Bit#(32) hostSession, Bit#(32) nicSession);
    interface PipeIn#(RetxRetryEntry) retryIn;
    interface PipeOut#(RetxAdmissionReqHw) admissionReqOut;
    interface PipeIn#(RetxAdmissionGrantHw) admissionGrantIn;
    interface PipeOut#(RetxFetchReqHw) fetchReqOut;
    interface PipeIn#(RetxFetchBeatHw) fetchBeatIn;
    interface PipeOut#(RetxM3DescHw) m3DescOut;
    interface PipeOut#(RetxM3BeatHw) m3BeatOut;
    interface PipeOut#(RetxRetryResultHw) resultOut;
    method Bit#(1) busy;
endinterface

typedef enum { IDLE, WAIT_GRANT, FETCH } Phase deriving(Bits, Eq, FShow);

(* synthesize *)
module mkRetxRetryEngine(RetxRetryEngineIfc);
    Reg#(Bit#(32)) hostSession <- mkReg(0);
    Reg#(Bit#(32)) nicSession <- mkReg(0);
    Reg#(Phase) phase <- mkReg(IDLE);
    Reg#(RetxRetryEntry) cur <- mkReg(unpack(0));
    Reg#(RetxAdmissionGrantHw) grant <- mkReg(unpack(0));
    Reg#(Bit#(16)) fetchId <- mkReg(0);
    Reg#(Bool) descSent <- mkReg(False);

    FIFOF#(RetxRetryEntry) retryQ <- mkSizedFIFOF(8);
    FIFOF#(RetxAdmissionReqHw) admQ <- mkSizedFIFOF(4);
    FIFOF#(RetxAdmissionGrantHw) grantQ <- mkSizedFIFOF(4);
    FIFOF#(RetxFetchReqHw) fetchQ <- mkSizedFIFOF(4);
    FIFOF#(RetxFetchBeatHw) beatQ <- mkSizedFIFOF(64);
    FIFOF#(RetxM3DescHw) descQ <- mkSizedFIFOF(4);
    FIFOF#(RetxM3BeatHw) m3BeatQ <- mkSizedFIFOF(64);
    FIFOF#(RetxRetryResultHw) resultQ <- mkSizedFIFOF(16);

    function RetxRetryResultHw mkResult(RetxRetryEntry e, Bit#(8) status,
                                        Bit#(8) reason, Bit#(8) resultSeq);
        RetxRetryResultHw r = unpack(0);
        r.retryRequestId = e.retry_request_id;
        r.hostSessionId = hostSession;
        r.nicSessionId = nicSession;
        r.qpn = e.qpn;
        r.qpEpoch = e.qp_epoch;
        r.psn = e.psn;
        r.status = status;
        r.reason = reason;
        r.fetchId = fetchId;
        r.reportGeneration = e.report_generation;
        r.egressSequence = 0;
        r.resultSequence = resultSeq;
        return r;
    endfunction

    rule startRequest (phase == IDLE && retryQ.notEmpty && admQ.notFull);
        let e = retryQ.first;
        cur <= e;
        fetchId <= fetchId + 1;
        descSent <= False;
        RetxAdmissionReqHw req = unpack(0);
        req.retryRequestId = e.retry_request_id;
        req.hostSessionId = e.host_session_id;
        req.nicSessionId = nicSession;
        req.qpn = e.qpn;
        req.qpEpoch = e.qp_epoch;
        req.psn = e.psn;
        req.recordHandle = e.record_handle;
        req.expectedRequestId = e.expected_request_id;
        req.expectedPacketIndex = truncate(e.expected_packet_index);
        req.reportGeneration = e.report_generation;
        req.triggerReason = truncate(e.trigger_reason);
        req.retryAttempt = e.retry_attempt;
        admQ.enq(req);
        retryQ.deq;
        phase <= WAIT_GRANT;
    endrule

    rule handleGrant (phase == WAIT_GRANT && grantQ.notEmpty && resultQ.notFull);
        let g = grantQ.first;
        grantQ.deq;
        if (g.ok == 0) begin
            resultQ.enq(mkResult(cur, zeroExtend(g.status), g.reason, 0));
            phase <= IDLE;
        end
        else begin
            grant <= g;
            resultQ.enq(mkResult(cur, 1, 0, 0)); // ACCEPTED_FETCHING, non-terminal
            RetxFetchReqHw f = unpack(0);
            f.fetchId = fetchId;
            f.replayHandle = g.replayHandle;
            f.offset = 0;
            f.length = g.payloadLength;
            f.token = g.recordHandle;
            fetchQ.enq(f);
            phase <= FETCH;
        end
    endrule

    rule forwardFetch (phase == FETCH && beatQ.notEmpty
                       && descQ.notFull && m3BeatQ.notFull);
        let b = beatQ.first;
        beatQ.deq;
        if (!descSent) begin
            RetxM3DescHw d = unpack(0);
            d.qpn = cur.qpn; d.qpEpoch = cur.qp_epoch;
            d.requestId = grant.requestId; d.psn = cur.psn;
            d.packetIndex = grant.packetIndex;
            d.packetCount = grant.packetCount;
            d.pmtu = grant.pmtu; d.opcode = grant.opcode;
            d.remoteAddr = grant.remoteAddr; d.remoteKey = grant.remoteKey;
            d.messageOffset = grant.messageOffset;
            d.payloadLength = grant.payloadLength;
            d.first = grant.first; d.last = grant.last;
            d.wireProfile = grant.wireProfile; d.evProfile = grant.evProfile;
            d.mrcMsn = grant.mrcMsn;
            descQ.enq(d);
            descSent <= True;
        end
        RetxM3BeatHw mb = unpack(0);
        mb.requestId = grant.requestId;
        mb.psn = cur.psn;
        mb.data = b.data; mb.keep = b.keep; mb.sop = b.sop; mb.eop = b.eop;
        m3BeatQ.enq(mb);
        if (b.eop == 1) begin
            resultQ.enq(mkResult(cur, 2, 0, 1)); // SENT, terminal
            phase <= IDLE;
        end
    endrule

    interface retryIn = toPipeIn(retryQ);
    interface admissionReqOut = toPipeOut(admQ);
    interface admissionGrantIn = toPipeIn(grantQ);
    interface fetchReqOut = toPipeOut(fetchQ);
    interface fetchBeatIn = toPipeIn(beatQ);
    interface m3DescOut = toPipeOut(descQ);
    interface m3BeatOut = toPipeOut(m3BeatQ);
    interface resultOut = toPipeOut(resultQ);
    method Action configure(Bit#(32) hostS, Bit#(32) nicS);
        hostSession <= hostS; nicSession <= nicS;
    endmethod
    method Bit#(1) busy = phase == IDLE ? 0 : 1;
endmodule

endpackage
