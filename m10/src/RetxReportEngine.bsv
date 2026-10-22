package RetxReportEngine;

import Vector::*;
import FIFOF::*;
import RetxTypes::*;
import CommonTypes::*;

// m10: snapshot -> versioned Report header + hole entries + notification.
// CRC is filled by the host ABI codec at the transaction boundary.
interface RetxReportEngineIfc;
    method Action configure(Bit#(32) nicSession, Bit#(32) hostSession);
    interface PipeIn#(RetxSnapshotHdrHw) snapshotIn;
    interface PipeIn#(RetxHoleEntry) entryIn;
    interface PipeOut#(RetxReportHeader) reportHeaderOut;
    interface PipeOut#(RetxHoleEntry) reportEntryOut;
    interface PipeOut#(RetxNotificationHw) notificationOut;
    interface PipeIn#(RetxOnDemandReqHw) onDemandIn;
    interface PipeOut#(RetxOnDemandReqHw) onDemandOut;
    method Bit#(32) reportGeneration;
endinterface

typedef enum { IDLE, COLLECT, EMIT_HDR, EMIT_ENTRIES } Phase deriving(Bits, Eq, FShow);

(* synthesize *)
module mkRetxReportEngine(RetxReportEngineIfc);
    Reg#(Bit#(32)) nicSession <- mkReg(0);
    Reg#(Bit#(32)) hostSession <- mkReg(0);
    Reg#(Bit#(32)) nextGen <- mkReg(0);

    FIFOF#(RetxSnapshotHdrHw) snapQ <- mkSizedFIFOF(4);
    FIFOF#(RetxHoleEntry) entryQ <- mkSizedFIFOF(16);
    FIFOF#(RetxReportHeader) hdrQ <- mkSizedFIFOF(4);
    FIFOF#(RetxHoleEntry) outEntryQ <- mkSizedFIFOF(16);
    FIFOF#(RetxNotificationHw) notifQ <- mkSizedFIFOF(8);
    FIFOF#(RetxOnDemandReqHw) onDemandQ <- mkSizedFIFOF(4);
    FIFOF#(RetxOnDemandReqHw) onDemandEchoQ <- mkSizedFIFOF(4);

    Reg#(Phase) phase <- mkReg(IDLE);
    Reg#(RetxSnapshotHdrHw) hdr <- mkReg(unpack(0));
    Reg#(Vector#(16, RetxHoleEntry)) entries <- mkReg(unpack(0));
    Reg#(Bit#(5)) count <- mkReg(0);
    Reg#(Bit#(5)) cursor <- mkReg(0);
    Reg#(Bit#(32)) pendingGen <- mkReg(0);

    rule startCapture (phase == IDLE && snapQ.notEmpty && hdrQ.notFull);
        let h = snapQ.first;
        hdr <= h;
        count <= truncate(h.entryCount);
        cursor <= 0;
        pendingGen <= nextGen + 1;
        snapQ.deq;
        phase <= h.entryCount == 0 ? EMIT_HDR : COLLECT;
    endrule

    rule collectEntry (phase == COLLECT && entryQ.notEmpty);
        entries <= update(entries, cursor[3:0], entryQ.first);
        entryQ.deq;
        cursor <= cursor + 1;
        if (cursor + 1 == count) phase <= EMIT_HDR;
    endrule

    rule emitHeader (phase == EMIT_HDR && hdrQ.notFull);
        RetxReportHeader h = unpack(0);
        h.version = 1;
        h.flags = (hdr.holeCount > 0) ? 2 : 1;
        h.byte_length = 64 + 40 * zeroExtend(hdr.entryCount);
        h.qpn = hdr.qpn;
        h.qp_epoch = hdr.qpEpoch;
        h.sack_valid_bits = hdr.sackValidBits;
        h.report_generation = pendingGen;
        h.scoreboard_generation = hdr.scoreboardGeneration;
        h.nic_session_id = nicSession;
        h.ack_psn = hdr.ackPsn;
        h.sack_base = hdr.sackBase;
        h.outstanding_base = hdr.sackBase;
        h.nak_psn = hdr.nakPsn;
        h.outstanding_count = hdr.outstandingCount;
        h.ooo_count = hdr.oooCount;
        h.hole_count = hdr.holeCount;
        h.hole_entries_included = hdr.entryCount;
        h.nak_valid_and_code = (hdr.nakValid == 1)
            ? (8'h80 | zeroExtend(hdr.nakCode)) : 0;
        h.sack_bitmap = hdr.bitmap;
        h.crc32 = 0;
        hdrQ.enq(h);
        cursor <= 0;
        phase <= hdr.entryCount == 0 ? IDLE : EMIT_ENTRIES;
        if (hdr.entryCount == 0) begin
            RetxNotificationHw n = unpack(0);
            n.ringSlot = 0;
            n.reportByteLength = 64;
            n.qpn = hdr.qpn;
            n.qpEpoch = hdr.qpEpoch;
            n.reportGeneration = pendingGen;
            n.nicSessionId = nicSession;
            n.hostSessionId = hostSession;
            notifQ.enq(n);
            nextGen <= pendingGen;
        end
    endrule

    rule emitEntries (phase == EMIT_ENTRIES && outEntryQ.notFull);
        outEntryQ.enq(entries[cursor[3:0]]);
        if (cursor + 1 == count) begin
            RetxNotificationHw n = unpack(0);
            n.ringSlot = 0;
            n.reportByteLength = 64 + 40 * zeroExtend(hdr.entryCount);
            n.qpn = hdr.qpn;
            n.qpEpoch = hdr.qpEpoch;
            n.reportGeneration = pendingGen;
            n.nicSessionId = nicSession;
            n.hostSessionId = hostSession;
            notifQ.enq(n);
            nextGen <= pendingGen;
            phase <= IDLE;
        end
        else cursor <= cursor + 1;
    endrule

    rule drainOnDemand (onDemandQ.notEmpty && onDemandEchoQ.notFull);
        onDemandEchoQ.enq(onDemandQ.first);
        onDemandQ.deq;
    endrule

    interface snapshotIn = toPipeIn(snapQ);
    interface entryIn = toPipeIn(entryQ);
    interface reportHeaderOut = toPipeOut(hdrQ);
    interface reportEntryOut = toPipeOut(outEntryQ);
    interface notificationOut = toPipeOut(notifQ);
    interface onDemandIn = toPipeIn(onDemandQ);
    interface onDemandOut = toPipeOut(onDemandEchoQ);
    method Action configure(Bit#(32) nicS, Bit#(32) hostS);
        nicSession <= nicS; hostSession <= hostS;
    endmethod
    method Bit#(32) reportGeneration = nextGen;
endmodule

endpackage
