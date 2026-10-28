package RetxReplayStore;

import Assert :: *;
import FIFOF :: *;
import RegFile :: *;

import CommonTypes :: *;
import E2eTypes :: *;
import RetxTypes :: *;
import TxTypes :: *;

// 每个 M9 journal slot 对应一份 packet payload snapshot。64 个 slot x 32
// 个 128 B beat。写入来自 TX tap 的首次发送，读取给 M11 的重传 fetch。
interface RetxReplayStoreIfc;
    interface PipeIn#(RetxReplayWriteHw) writeIn;
    interface PipeIn#(RetxFetchReqHw) fetchReqIn;
    interface PipeOut#(RetxFetchBeatHw) fetchBeatOut;
endinterface

module mkRetxReplayStore(RetxReplayStoreIfc);
    RegFile#(Bit#(11), Bit#(1024)) memory <- mkRegFileFull;

    FIFOF#(RetxReplayWriteHw) writeQ <- mkSizedFIFOF(8);
    FIFOF#(RetxFetchReqHw) requestQ <- mkSizedFIFOF(4);
    FIFOF#(RetxFetchBeatHw) beatQ <- mkSizedFIFOF(8);

    Reg#(Bool) active <- mkReg(False);
    Reg#(Bit#(16)) fetchId <- mkReg(0);
    Reg#(Bit#(32)) replayHandle <- mkReg(0);
    Reg#(Bit#(13)) remaining <- mkReg(0);
    Reg#(Bit#(5)) wordIndex <- mkReg(0);

    rule acceptWrite (writeQ.notEmpty);
        let write = writeQ.first;
        dynamicAssert(write.beatIndex < 32, "RETX_REPLAY_BEAT_INDEX");
        memory.upd({write.replayHandle[5:0], write.beatIndex[4:0]}, write.data);
        writeQ.deq;
    endrule

    rule startFetch (!active && requestQ.notEmpty);
        let request = requestQ.first;
        dynamicAssert(request.length != 0, "RETX_REPLAY_ZERO_LENGTH");
        dynamicAssert(request.length <= 4096, "RETX_REPLAY_LENGTH_TOO_LARGE");
        fetchId <= request.fetchId;
        replayHandle <= request.replayHandle;
        remaining <= request.length;
        wordIndex <= 0;
        active <= True;
        requestQ.deq;
    endrule

    rule emitBeat (active && beatQ.notFull);
        Bit#(13) count = remaining > 128 ? 128 : remaining;
        Bit#(1) last = pack(remaining <= 128);
        beatQ.enq(RetxFetchBeatHw {
            fetchId: fetchId,
            data: memory.sub({replayHandle[5:0], wordIndex}),
            keep: byteMask128(truncate(count)),
            sop: pack(wordIndex == 0),
            eop: last,
            valid: 1,
            last: last
        });
        remaining <= remaining - count;
        wordIndex <= wordIndex + 1;
        if (last == 1)
            active <= False;
    endrule

    interface writeIn = toPipeIn(writeQ);
    interface fetchReqIn = toPipeIn(requestQ);
    interface fetchBeatOut = toPipeOut(beatQ);
endmodule

endpackage
