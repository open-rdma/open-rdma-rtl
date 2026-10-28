package RetxStateManager;

import Vector::*;
import FIFOF::*;
import RetxTypes::*;
import CommonTypes::*;

// ---------------------------------------------------------------------------
// m9: SQ Scoreboard, WQE Record and snapshot authority.
// Functional MVP model: 4 QP x 16 PSN window, 64 records, 64 packet journals.
// ---------------------------------------------------------------------------

typedef struct {
    Bool valid;
    Bit#(32) handle;
    Bit#(24) qpn;
    Bit#(24) destQpn;
    Bit#(16) epoch;
    Bit#(16) requestId;
    Bit#(24) psnBase;
    Bit#(18) psnCount;
    Bit#(18) packetCount;
    Bit#(18) remaining;
    Bit#(3) pmtu;
    Bit#(25) messageLen;
    Bit#(64) addr;
    Bit#(32) key;
    Bit#(8) opcode;
    Bit#(18) slotId;
    Bit#(2) wp;
    Bit#(2) ep;
    Bit#(16) mrcMsn;
    Bit#(1) msnValid;
    Bit#(2) state; // 0 free, 1 active, 2 complete
} Rec deriving(Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bit#(3) state; // 0 free,1 reserved,2 sent,3 sacked,4 cum-acked
    Bit#(24) qpn;
    Bit#(24) destQpn;
    Bit#(16) epoch;
    Bit#(24) psn;
    Bit#(32) handle;
    Bit#(18) pidx;
    Bit#(32) replay;
    Bit#(25) msgOff;
    Bit#(13) plen;
    Bit#(25) msgLen;
    Bit#(64) addr;
    Bit#(32) key;
    Bit#(8) opcode;
    Bit#(3) pmtu;
    Bit#(18) slot;
    Bit#(2) wp;
    Bit#(2) ep;
    Bit#(16) msn;
    Bit#(1) msnValid;
    Bit#(1) first;
    Bit#(1) last;
    Bit#(16) reqId;
    Bit#(18) pcount;
} Jnl deriving(Bits, Eq, FShow);

typedef struct {
    Bool enabled;
    Bit#(24) qpn;
    Bit#(16) epoch;
    Bit#(24) ackPsn;
    Bit#(24) maxPsn;
    Bit#(32) sbGen;
    Bit#(1) nakValid;
    Bit#(7) nakCode;
    Bit#(24) nakPsn;
    Bit#(16) ooo;
} Qp deriving(Bits, Eq, FShow);

interface RetxStateManagerIfc;
    method Action configureQp(RetxQpConfigHw cfg);
    method Action configureQpAt(Bit#(2) idx, RetxQpConfigHw cfg);
    method Action resetQp(Bit#(24) qpn);
    interface PipeIn#(RetxWqeRegisterHw) wqeRegisterIn;
    interface PipeOut#(RetxWqeRegisterRespHw) wqeRegisterRespOut;
    interface PipeIn#(RetxPacketReserveHw) packetReserveIn;
    interface PipeOut#(RetxPacketGrantHw) packetGrantOut;
    interface PipeIn#(RetxSentEventHw) sentEventIn;
    interface PipeIn#(RetxFeedbackEventHw) feedbackIn;
    interface PipeIn#(RetxSnapshotReqHw) snapshotReqIn;
    interface PipeOut#(RetxSnapshotHdrHw) snapshotHdrOut;
    interface PipeOut#(RetxHoleEntry) snapshotEntryOut;
    interface PipeIn#(RetxAdmissionReqHw) admissionReqIn;
    interface PipeOut#(RetxAdmissionGrantHw) admissionGrantOut;
    interface PipeOut#(RetxRecordTerminateHw) releaseOut;
    method Bit#(16) debugAckQp(Bit#(2) idx);
endinterface

function Bool psnLE(Bit#(24) a, Bit#(24) b);
    return ((b - a) & 24'hFFFFFF) < 24'h800000;
endfunction

function Bool psnInWindow(Bit#(24) ackPsn, Bit#(24) psn);
    Bit#(24) d = psn - ackPsn;
    return d != 0 && d <= 16;
endfunction

function Maybe#(Bit#(6)) firstSetBit(Bit#(64) m, Integer i);
    if (i >= 64) return tagged Invalid;
    else if (m[i] == 1) return tagged Valid fromInteger(i);
    else return firstSetBit(m, i + 1);
endfunction

function Vector#(4, Qp) disableQp(Vector#(4, Qp) qs, Bit#(24) qpn, Integer i);
    if (i >= 4) return qs;
    else begin
        Qp q = qs[i];
        Qp nq = q;
        if (q.qpn == qpn) nq.enabled = False;
        return disableQp(update(qs, fromInteger(i), nq), qpn, i + 1);
    end
endfunction

function Maybe#(Bit#(6)) firstFreeRec(Vector#(64, Rec) v, Integer i);
    if (i >= 64) return tagged Invalid;
    else if (!v[i].valid) return tagged Valid fromInteger(i);
    else return firstFreeRec(v, i + 1);
endfunction

function Maybe#(Bit#(6)) firstFreeJnl(Vector#(64, Jnl) v, Integer i);
    if (i >= 64) return tagged Invalid;
    else if (!v[i].valid) return tagged Valid fromInteger(i);
    else return firstFreeJnl(v, i + 1);
endfunction

function Maybe#(Bit#(2)) findQp(Vector#(4, Qp) qps, Bit#(24) qpn, Integer i);
    if (i >= 4) return tagged Invalid;
    else if (qps[i].qpn == qpn) return tagged Valid fromInteger(i);
    else return findQp(qps, qpn, i + 1);
endfunction

function Bool isTerminal(Bit#(3) st);
    return st == 3 || st == 4;
endfunction

function Jnl ackJournal(Jnl j, Bit#(24) qpn, Bit#(16) epoch,
                        Bit#(24) ackPsn, Bit#(24) sackBase,
                        Bit#(128) bitmap, Bit#(16) validBits);
    Jnl n = j;
    if (j.valid && j.qpn == qpn && j.epoch == epoch) begin
        Bool cum = psnLE(j.psn, ackPsn);
        Bit#(24) off = j.psn - sackBase;
        Bool inCoverage = off < zeroExtend(validBits);
        Bool sack = inCoverage && bitmap[off[6:0]] == 1;
        if (cum) n.state = 4;
        else if (sack && j.state == 2) n.state = 3;
    end
    return n;
endfunction

function Vector#(64, Jnl) ackJournals(Vector#(64, Jnl) v, Integer i,
                                      Bit#(24) qpn, Bit#(16) epoch,
                                      Bit#(24) ackPsn, Bit#(24) sackBase,
                                      Bit#(128) bitmap, Bit#(16) validBits);
    if (i >= 64) return v;
    else begin
        Vector#(64, Jnl) nv = update(v, fromInteger(i),
            ackJournal(v[i], qpn, epoch, ackPsn, sackBase, bitmap, validBits));
        return ackJournals(nv, i + 1, qpn, epoch, ackPsn, sackBase, bitmap, validBits);
    end
endfunction

function Bit#(64) releaseMaskFor(Vector#(64, Jnl) old, Vector#(64, Jnl) nw, Integer i);
    if (i >= 64) return 0;
    else begin
        Bool newly = old[i].valid && old[i].state == 2 && isTerminal(nw[i].state);
        Bit#(64) rest = releaseMaskFor(old, nw, i + 1);
        return newly ? (rest | (1 << fromInteger(i))) : rest;
    end
endfunction

function Vector#(64, Rec) completeRecords(Vector#(64, Rec) rs, Bit#(24) qpn,
                                         Bit#(16) epoch, Bit#(24) ackPsn, Integer i);
    if (i >= 64) return rs;
    else begin
        Rec r = rs[i];
        Rec nr = r;
        if (r.valid && r.qpn == qpn && r.epoch == epoch) begin
            Bit#(24) lastPsn = r.psnBase + zeroExtend(r.packetCount) - 1;
            if (psnLE(lastPsn, ackPsn)) nr.state = 2;
        end
        return completeRecords(update(rs, fromInteger(i), nr), qpn, epoch, ackPsn, i + 1);
    end
endfunction

function Maybe#(Bit#(6)) findJnlByPsn(Vector#(64, Jnl) v, Bit#(24) qpn,
                                     Bit#(16) epoch, Bit#(24) psn, Integer i);
    if (i >= 64) return tagged Invalid;
    else if (v[i].valid && v[i].qpn == qpn && v[i].epoch == epoch && v[i].psn == psn)
        return tagged Valid fromInteger(i);
    else return findJnlByPsn(v, qpn, epoch, psn, i + 1);
endfunction

function Maybe#(Bit#(6)) findRecByHandle(Vector#(64, Rec) v, Bit#(32) handle, Integer i);
    if (i >= 64) return tagged Invalid;
    else if (v[i].valid && v[i].handle == handle) return tagged Valid fromInteger(i);
    else return findRecByHandle(v, handle, i + 1);
endfunction

function Vector#(64, Jnl) markSent(Vector#(64, Jnl) v, Maybe#(Bit#(6)) m);
    if (!isValid(m)) return v;
    else begin
        Bit#(6) idx = fromMaybe(0, m);
        Jnl j = v[idx];
        j.state = 2;
        return update(v, idx, j);
    end
endfunction

function Qp applyFeedbackQp(Qp q, RetxFeedbackEventHw fb);
    Qp n = q;
    if (q.qpn == fb.qpn && q.epoch == fb.qpEpoch) begin
        if (psnLE(q.ackPsn, fb.ackPsn)) n.ackPsn = fb.ackPsn;
        n.sbGen = q.sbGen + 1;
        n.nakValid = fb.nakValid; n.nakCode = fb.nakCode;
        n.nakPsn = fb.nakPsn; n.ooo = fb.oooCount;
    end
    return n;
endfunction

function Vector#(4, Qp) applyFeedbackAll(Vector#(4, Qp) qs, RetxFeedbackEventHw fb, Integer i);
    if (i >= 4) return qs;
    else return applyFeedbackAll(update(qs, fromInteger(i),
        applyFeedbackQp(qs[i], fb)), fb, i + 1);
endfunction

function Vector#(4, Qp) applySentAll(Vector#(4, Qp) qs, RetxSentEventHw ev,
                                     Bool hit, Integer i);
    if (i >= 4) return qs;
    else begin
        Qp q = qs[i];
        Qp nq = q;
        if (hit && q.qpn == ev.qpn && q.epoch == ev.qpEpoch) begin
            nq.maxPsn = ev.psn;
            nq.sbGen = q.sbGen + 1;
        end
        return applySentAll(update(qs, fromInteger(i), nq), ev, hit, i + 1);
    end
endfunction

function Jnl fillFromRec(Jnl j, Rec r);
    Jnl n = j;
    n.destQpn = r.destQpn;
    n.addr = r.addr; n.key = r.key; n.opcode = r.opcode; n.pmtu = r.pmtu;
    n.slot = r.slotId; n.wp = r.wp; n.ep = r.ep; n.msn = r.mrcMsn;
    n.msnValid = r.msnValid; n.msgLen = r.messageLen;
    return n;
endfunction

function Bit#(128) bitmapFor(Vector#(64, Jnl) js, Bit#(24) ackPsn, Bit#(24) sackBase,
                             Bit#(16) validBits, Integer i);
    if (i >= 64) return 0;
    else begin
        Bit#(128) rest = bitmapFor(js, ackPsn, sackBase, validBits, i + 1);
        Bit#(24) off = js[i].psn - sackBase;
        Bool inCov = off < zeroExtend(validBits);
        return (js[i].valid && js[i].state == 3 && inCov)
            ? (rest | (128'h1 << off[6:0])) : rest;
    end
endfunction

function Bit#(16) countState(Vector#(64, Jnl) js, Bit#(24) qpn, Bit#(16) epoch,
                             Bit#(3) st, Integer i);
    if (i >= 64) return 0;
    else begin
        Bit#(16) c = (js[i].valid && js[i].qpn == qpn && js[i].epoch == epoch
                      && js[i].state == st) ? 1 : 0;
        return c + countState(js, qpn, epoch, st, i + 1);
    end
endfunction

(* synthesize *)
module mkRetxStateManager(RetxStateManagerIfc);
    Reg#(Vector#(4, Qp)) qps <- mkReg(unpack(0));
    Reg#(Vector#(64, Rec)) recs <- mkReg(unpack(0));
    Reg#(Vector#(64, Jnl)) jnls <- mkReg(unpack(0));
    Reg#(Vector#(64, Bit#(26))) recGen <- mkReg(unpack(0));
    Reg#(Vector#(64, Bit#(26))) replayGen <- mkReg(unpack(0));
    Reg#(Bit#(64)) pendingRelease <- mkReg(0);

    FIFOF#(RetxWqeRegisterHw) wqeQ <- mkSizedFIFOF(4);
    FIFOF#(RetxWqeRegisterRespHw) wqeRespQ <- mkSizedFIFOF(4);
    FIFOF#(RetxPacketReserveHw) resQ <- mkSizedFIFOF(4);
    FIFOF#(RetxPacketGrantHw) grantQ <- mkSizedFIFOF(4);
    FIFOF#(RetxSentEventHw) sentQ <- mkSizedFIFOF(8);
    FIFOF#(RetxFeedbackEventHw) fbQ <- mkSizedFIFOF(8);
    FIFOF#(RetxSnapshotReqHw) snapReqQ <- mkSizedFIFOF(4);
    FIFOF#(RetxSnapshotHdrHw) snapHdrQ <- mkSizedFIFOF(4);
    FIFOF#(RetxHoleEntry) snapEntryQ <- mkSizedFIFOF(16);
    FIFOF#(RetxAdmissionReqHw) admQ <- mkSizedFIFOF(4);
    FIFOF#(RetxAdmissionGrantHw) admGrantQ <- mkSizedFIFOF(4);
    FIFOF#(RetxRecordTerminateHw) relQ <- mkSizedFIFOF(64);

    Reg#(Bool) scanning <- mkReg(False);
    Reg#(Bit#(6)) scanIndex <- mkReg(0);
    Reg#(Bit#(24)) scanQpn <- mkReg(0);
    Reg#(Bit#(16)) scanEpoch <- mkReg(0);
    Reg#(Bit#(18)) emitted <- mkReg(0);

    rule emitRelease (pendingRelease != 0 && relQ.notFull);
        let m = firstSetBit(pendingRelease, 0);
        Bit#(6) idx = fromMaybe(0, m);
        let j = jnls[idx];
        relQ.enq(RetxRecordTerminateHw { qpn: j.qpn, qpEpoch: j.epoch,
                                          psn: j.psn, recordHandle: j.handle });
        pendingRelease <= pendingRelease & ~(1 << idx);
    endrule

    rule doWqeRegister (wqeQ.notEmpty && wqeRespQ.notFull);
        let req = wqeQ.first;
        Maybe#(Bit#(6)) m = firstFreeRec(recs, 0);
        if (isValid(m)) begin
            Bit#(6) idx = fromMaybe(0, m);
            Bit#(32) handle = {recGen[idx], idx};
            Rec r = Rec { valid: True, handle: handle, qpn: req.qpn,
                destQpn: req.destQpn, epoch: req.qpEpoch,
                requestId: req.requestId, psnBase: req.psnBase,
                psnCount: req.psnCount, packetCount: req.packetCount,
                remaining: req.packetCount, pmtu: req.pmtu,
                messageLen: req.messageLength, addr: req.remoteAddr,
                key: req.remoteKey, opcode: req.opcode, slotId: req.slotId,
                wp: req.wireProfile, ep: req.evProfile, mrcMsn: req.mrcMsn,
                msnValid: req.msnValid, state: 1 };
            recs <= update(recs, idx, r);
            recGen <= update(recGen, idx, recGen[idx] + 1);
            wqeRespQ.enq(RetxWqeRegisterRespHw { ok: 1, recordHandle: handle });
            wqeQ.deq;
        end
    endrule

    rule doReserve (resQ.notEmpty && grantQ.notFull && !scanning);
        let req = resQ.first;
        Maybe#(Bit#(2)) qm = findQp(qps, req.qpn, 0);
        Bool ok = isValid(qm) && qps[fromMaybe(0, qm)].enabled
            && qps[fromMaybe(0, qm)].epoch == req.qpEpoch
            && psnInWindow(qps[fromMaybe(0, qm)].ackPsn, req.psn);
        Maybe#(Bit#(6)) rm = findRecByHandle(recs, req.recordHandle, 0);
        Bool recOk = isValid(rm) && recs[fromMaybe(0, rm)].qpn == req.qpn
            && recs[fromMaybe(0, rm)].epoch == req.qpEpoch;
        Maybe#(Bit#(6)) jm = firstFreeJnl(jnls, 0);
        if (ok && recOk && isValid(jm)) begin
            Bit#(6) idx = fromMaybe(0, jm);
            Bit#(32) replay = {replayGen[idx] + 1, idx};
            Jnl j = Jnl { valid: True, state: 1, qpn: req.qpn,
                destQpn: 0, epoch: req.qpEpoch, psn: req.psn, handle: req.recordHandle,
                pidx: req.packetIndex, replay: replay, msgOff: 0, plen: 0,
                msgLen: 0, addr: 0, key: 0, opcode: 0, pmtu: 0, slot: 0,
                wp: 0, ep: 0, msn: 0, msnValid: 0, first: 0, last: 0,
                reqId: req.requestId, pcount: req.packetCount };
            j = fillFromRec(j, recs[fromMaybe(0, rm)]);
            j.msgOff = req.messageOffset;
            j.plen = req.payloadLength;
            j.opcode = req.opcode;
            j.first = req.first;
            j.last = req.last;
            jnls <= update(jnls, idx, j);
            replayGen <= update(replayGen, idx, replayGen[idx] + 1);
            grantQ.enq(RetxPacketGrantHw { ok: 1, reason: 0, replayHandle: replay });
            resQ.deq;
        end
        else if (!ok) begin
            grantQ.enq(RetxPacketGrantHw { ok: 0, reason: 3, replayHandle: 0 });
            resQ.deq;
        end
    endrule

    rule doSent (sentQ.notEmpty);
        let ev = sentQ.first;
        Maybe#(Bit#(6)) m = findJnlByPsn(jnls, ev.qpn, ev.qpEpoch, ev.psn, 0);
        Bool hit = isValid(m) && jnls[fromMaybe(0, m)].state == 1;
        jnls <= markSent(jnls, m);
        qps <= applySentAll(qps, ev, hit, 0);
        sentQ.deq;
    endrule

    rule doFeedback (fbQ.notEmpty);
        let fb = fbQ.first;
        Vector#(64, Jnl) njs = ackJournals(jnls, 0, fb.qpn, fb.qpEpoch,
            fb.ackPsn, fb.sackBase, fb.sackBitmap, fb.sackValidBits);
        Bit#(64) rel = releaseMaskFor(jnls, njs, 0);
        pendingRelease <= pendingRelease | rel;
        jnls <= njs;
        recs <= completeRecords(recs, fb.qpn, fb.qpEpoch, fb.ackPsn, 0);
        qps <= applyFeedbackAll(qps, fb, 0);
        fbQ.deq;
    endrule

    rule startSnapshot (snapReqQ.notEmpty && !scanning && snapHdrQ.notFull);
        let req = snapReqQ.first;
        Maybe#(Bit#(2)) qm = findQp(qps, req.qpn, 0);
        if (isValid(qm)) begin
            let q = qps[fromMaybe(0, qm)];
            Bit#(16) holes = countState(jnls, q.qpn, q.epoch, 2, 0);
            Bit#(16) sacked = countState(jnls, q.qpn, q.epoch, 3, 0);
            Bit#(16) span = truncate(q.maxPsn - q.ackPsn);
            Bit#(16) validBits = span > 16 ? 16 : span;
            snapHdrQ.enq(RetxSnapshotHdrHw {
                qpn: q.qpn, qpEpoch: q.epoch, scoreboardGeneration: q.sbGen,
                ackPsn: q.ackPsn, sackBase: q.ackPsn + 1,
                outstandingCount: span, holeCount: holes, sackValidBits: validBits,
                nakValid: q.nakValid, nakCode: q.nakCode, nakPsn: q.nakPsn,
                oooCount: q.ooo,
                bitmap: bitmapFor(jnls, q.ackPsn, q.ackPsn + 1, validBits, 0),
                flags: 0, entryCount: truncate(holes) });
            scanQpn <= q.qpn; scanEpoch <= q.epoch;
            scanIndex <= 0; emitted <= 0; scanning <= True;
            snapReqQ.deq;
        end
        else begin
            snapHdrQ.enq(unpack(0));
            snapReqQ.deq;
        end
    endrule

    rule scanSnapshot (scanning && snapEntryQ.notFull);
        let j = jnls[scanIndex];
        if (j.valid && j.qpn == scanQpn && j.epoch == scanEpoch
            && j.state == 2) begin
            snapEntryQ.enq(RetxHoleEntry {
                psn: j.psn, record_handle: j.handle, request_id: j.reqId,
                packet_index: j.pidx, packet_count: j.pcount,
                message_offset: j.msgOff, payload_length: j.plen,
                remote_addr: j.addr, remote_key: j.key, opcode: j.opcode,
                pmtu: j.pmtu, slot_id: j.slot, wire_profile: j.wp,
                ev_profile: j.ep, mrc_msn: j.msn, msn_valid: j.msnValid,
                is_first: j.first, is_last: j.last, reserved0: 0 });
        end
        if (scanIndex == 63) scanning <= False;
        else scanIndex <= scanIndex + 1;
    endrule

    rule doAdmission (admQ.notEmpty && admGrantQ.notFull);
        let req = admQ.first;
        Maybe#(Bit#(2)) qm = findQp(qps, req.qpn, 0);
        Bool qpOk = isValid(qm) && qps[fromMaybe(0, qm)].enabled
            && qps[fromMaybe(0, qm)].epoch == req.qpEpoch;
        Maybe#(Bit#(6)) jm = findJnlByPsn(jnls, req.qpn, req.qpEpoch, req.psn, 0);
        Bool psnOk = isValid(jm) && jnls[fromMaybe(0, jm)].state == 2;
        Bool recOk = isValid(jm) && jnls[fromMaybe(0, jm)].handle == req.recordHandle
            && jnls[fromMaybe(0, jm)].pidx == req.expectedPacketIndex
            && jnls[fromMaybe(0, jm)].reqId == req.expectedRequestId;
        Bit#(32) replay = isValid(jm) ? jnls[fromMaybe(0, jm)].replay : 0;
        RetxAdmissionGrantHw g = unpack(0);
        if (!qpOk) begin g.ok = 0; g.status = 6; g.reason = 9; end
        else if (!psnOk) begin g.ok = 0; g.status = 3; g.reason = 1; end
        else if (!recOk) begin g.ok = 0; g.status = 6; g.reason = 10; end
        else begin
            g.ok = 1; g.status = 1; g.reason = 0;
            g.recordHandle = req.recordHandle; g.replayHandle = replay;
            let j = jnls[fromMaybe(0, jm)];
            g.requestId = j.reqId; g.packetIndex = j.pidx;
            g.packetCount = j.pcount; g.psn = j.psn; g.opcode = j.opcode;
            g.pmtu = j.pmtu; g.remoteAddr = j.addr; g.remoteKey = j.key;
            g.messageOffset = j.msgOff; g.payloadLength = j.plen;
            g.messageLength = j.msgLen; g.destQpn = j.destQpn;
            g.first = j.first; g.last = j.last; g.wireProfile = j.wp;
            g.evProfile = j.ep; g.mrcMsn = j.msn;
        end
        admGrantQ.enq(g);
        admQ.deq;
    endrule

    method Action configureQp(RetxQpConfigHw cfg);
        Maybe#(Bit#(2)) m = findQp(qps, cfg.qpn, 0);
        Bit#(2) idx = isValid(m) ? fromMaybe(0, m) : truncate(cfg.qpn);
        qps <= update(qps, idx, Qp { enabled: cfg.enable == 1, qpn: cfg.qpn,
                       epoch: cfg.qpEpoch, ackPsn: cfg.initialPsn - 1,
                       maxPsn: cfg.initialPsn - 1, sbGen: 0, nakValid: 0,
                       nakCode: 0, nakPsn: 0, ooo: 0 });
    endmethod

    method Action configureQpAt(Bit#(2) idx, RetxQpConfigHw cfg);
        qps <= update(qps, idx, Qp { enabled: cfg.enable == 1, qpn: cfg.qpn,
                       epoch: cfg.qpEpoch, ackPsn: cfg.initialPsn - 1,
                       maxPsn: cfg.initialPsn - 1, sbGen: 0, nakValid: 0,
                       nakCode: 0, nakPsn: 0, ooo: 0 });
    endmethod

    method Action resetQp(Bit#(24) qpn);
        qps <= disableQp(qps, qpn, 0);
    endmethod

    interface wqeRegisterIn = toPipeIn(wqeQ);
    interface wqeRegisterRespOut = toPipeOut(wqeRespQ);
    interface packetReserveIn = toPipeIn(resQ);
    interface packetGrantOut = toPipeOut(grantQ);
    interface sentEventIn = toPipeIn(sentQ);
    interface feedbackIn = toPipeIn(fbQ);
    interface snapshotReqIn = toPipeIn(snapReqQ);
    interface snapshotHdrOut = toPipeOut(snapHdrQ);
    interface snapshotEntryOut = toPipeOut(snapEntryQ);
    interface admissionReqIn = toPipeIn(admQ);
    interface admissionGrantOut = toPipeOut(admGrantQ);
    interface releaseOut = toPipeOut(relQ);
    method Bit#(16) debugAckQp(Bit#(2) idx) = qps[idx].ackPsn[15:0];
endmodule

endpackage
