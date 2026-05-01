import FIFOF :: *;
import PAClib :: *;
import Printf :: *;
import RegFile :: *;
import Vector :: *;
import List :: *;
import Clocks :: *;
import ClientServer :: *;
import GetPut :: *;
import SpecialFIFOs :: *;
import Cntrs :: * ;

import Connectable :: *;
import ConnectableF :: *;
import BasicDataTypes :: *;
import FullyPipelineChecker :: *;

function Bool isZero(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    Bool ret = unpack(|bits);
    return !ret;
endfunction

// TODO: consider using fold
function Bool isZeroR(Bit#(nSz) bits) provisos(
    NumAlias#(TDiv#(nSz, 2), halfSz)
);
    if (valueOf(halfSz) > 1) begin
        Tuple2#(Bit#(TSub#(nSz, halfSz)), Bit#(halfSz)) pair = split(bits);
        let { left, right } = pair;
        return isZeroR(left) && isZeroR(right);
    end
    else begin
        return isZero(bits);
    end
endfunction

function Bool isZeroByteEn(Bit#(nSz) byteEn); // provisos(Add#(1, anysize, nSz));
    return isZero({ msb(byteEn), lsb(byteEn) });
endfunction

function Bool isLessOrEqOne(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    Bool ret = isZero(bits >> 1);
    // Bool ret = isZero(bits >> 1) && unpack(bits[0]);
    return ret;
endfunction

function Bool isLessOrEqOneR(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    Bool ret = isZeroR(bits >> 1);
    return ret;
endfunction

function Bool isOne(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    return isLessOrEqOne(bits) && unpack(lsb(bits));
endfunction

function Bool isOneR(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    return isLessOrEqOneR(bits) && unpack(lsb(bits));
endfunction

function Bool isTwo(Bit#(nSz) bits) provisos(Add#(2, anysize, nSz));
    return isZero(bits >> 2) && unpack(bits[1]) && !unpack(lsb(bits));
endfunction

function Bool isTwoR(Bit#(nSz) bits) provisos(Add#(2, anysize, nSz));
    return isZero(bits >> 2) && unpack(bits[1]) && !unpack(lsb(bits));
endfunction

// function Bool isAllOnes(Bit#(nSz) bits);
//     Bool ret = unpack(&bits);
//     return ret;
// endfunction

function Bool isAllOnesR(Bit#(nSz) bits) provisos(
    NumAlias#(TDiv#(nSz, 2), halfSz)
);
    if (valueOf(halfSz) > 1) begin
        Tuple2#(Bit#(TSub#(nSz, halfSz)), Bit#(halfSz)) pair = split(bits);
        let { left, right } = pair;
        return isAllOnesR(left) && isAllOnesR(right);
    end
    else begin
        Bool ret = unpack(&bits);
        return ret;
    end
endfunction

function Bool isLargerThanOne(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    return !isZero(bits >> 1);
endfunction

// 64 >= nSz >= 32
function Tuple2#(Bool, Bool) isZero4LargeBits(Bit#(nSz) bits) provisos(
    Add#(32, anysizeJ, nSz),
    Add#(nSz, anysizeK, 64),
    NumAlias#(TDiv#(nSz, 2), lowPartSz),
    NumAlias#(TSub#(nSz, lowPartSz), highPartSz),
    Add#(anysizeL, TDiv#(nSz, 2), nSz),
    // Add#(1, anysizeM, TDiv#(nSz, 2)),
    // Add#(1, anysizeN, TSub#(nSz, TDiv#(nSz, 2))),
    Add#(lowPartSz, highPartSz, nSz)
);
    Bit#(lowPartSz)   lowPartBits = truncate(bits);
    Bit#(highPartSz) highPartBits = truncateLSB(bits);
    let isLowPartZero  = isZero(lowPartBits);
    let isHighPartZero = isZero(highPartBits);
    return tuple2(isHighPartZero, isLowPartZero);
endfunction

function Bit#(nSz) zeroExtendLSB(Bit#(mSz) bits) provisos(Add#(mSz, anysize, nSz));
    return { bits, 0 };
endfunction

function Bit#(TSub#(nSz, 1)) removeMSB(Bit#(nSz) bits) provisos(Add#(1, anysize, nSz));
    return truncateLSB(bits << 1);
endfunction

function anytype dontCareValue() provisos(Bits#(anytype, tSz));
    return ?;
endfunction

function anytype unwrapMaybe(Maybe#(anytype) maybe) provisos(Bits#(anytype, tSz));
    return fromMaybe(?, maybe);
endfunction

function anytype unwrapMaybeWithDefault(
    Maybe#(anytype) maybe, anytype defaultVal
) provisos(Bits#(anytype, nSz));
    return fromMaybe(defaultVal, maybe);
endfunction

function anytype1 getTupleFirst(Tuple2#(anytype1, anytype2) tupleVal);
    return tpl_1(tupleVal);
endfunction

function anytype2 getTupleSecond(Tuple2#(anytype1, anytype2) tupleVal);
    return tpl_2(tupleVal);
endfunction

function anytype3 getTupleThird(Tuple3#(anytype1, anytype2, anytype3) tupleVal);
    return tpl_3(tupleVal);
endfunction

function anytype4 getTupleFourth(Tuple4#(anytype1, anytype2, anytype3, anytype4) tupleVal);
    return tpl_4(tupleVal);
endfunction

function anytype5 getTupleFifth(Tuple5#(anytype1, anytype2, anytype3, anytype4, anytype5) tupleVal);
    return tpl_5(tupleVal);
endfunction

function anytype6 getTupleSixth(Tuple6#(anytype1, anytype2, anytype3, anytype4, anytype5, anytype6) tupleVal);
    return tpl_6(tupleVal);
endfunction

function anytype identityFunc(anytype inputVal);
    return inputVal;
endfunction

function Action immAssert(Bool condition, String assertName, Fmt assertFmtMsg);
    action
        let pos = printPosition(getStringPosition(assertName));
        // let pos = printPosition(getEvalPosition(condition));
        if (!condition) begin
            $error(
                "ImmAssert failed in %m @time=%0t: %s-- %s: ",
                $time, pos, assertName, assertFmtMsg
            );
`ifdef BLUERDMA_IMMFAIL_ENABLE_TIME
            let curTime <- $time;
            if (curTime >= fromInteger(`BLUERDMA_IMMFAIL_ENABLE_TIME)) begin
                $finish(1);
            end
            else begin
                $error("ImmFail triggered but not enabled yet, current time=%0t, enable time=%0t", curTime, fromInteger(`BLUERDMA_IMMFAIL_ENABLE_TIME));
            end
`else
            $finish(1);
`endif
        end
    endaction
endfunction

function Action immFail(String assertName, Fmt assertFmtMsg);
    action
        let pos = printPosition(getStringPosition(assertName));
        // let pos = printPosition(getEvalPosition(condition));
        $error(
            "ImmAssert failed in %m @time=%0t: %s-- %s: ",
            $time, pos, assertName, assertFmtMsg
        );
`ifdef BLUERDMA_IMMFAIL_ENABLE_TIME
        let curTime <- $time;
        if (curTime >= fromInteger(`BLUERDMA_IMMFAIL_ENABLE_TIME)) begin
            $finish(1);
        end
        else begin
            $error("ImmFail triggered but not enabled yet, current time=%0t, enable time=%0t", curTime, fromInteger(`BLUERDMA_IMMFAIL_ENABLE_TIME));
        end
`else
        $finish(1);
`endif
    endaction
endfunction



function Bit#(width) swapEndianByte(Bit#(width) data) provisos(Mul#(8, byteNum, width));
    Vector#(byteNum, Bit#(BYTE_WIDTH)) dataVec = unpack(data);
    return pack(reverse(dataVec));
endfunction

function Bit#(width) swapEndianBit(Bit#(width) data) provisos(Mul#(1, byteNum, width));
    Vector#(byteNum, Bit#(1)) dataVec = unpack(data);
    return pack(reverse(dataVec));
endfunction






// module mkSyncFifoToFifoF#(SyncFIFOIfc#(tData) syncFifo)(FIFOF#(tData)) provisos(Bits#(tData, szData));
//     method deq = syncFifo.deq;
//     method enq = syncFifo.enq;
//     method first = syncFifo.first;
//     method notEmpty = syncFifo.notEmpty;
//     method notFull = syncFifo.notFull;

//     method Action clear;
//         immFail("not supported", $format(""));
//     endmethod
// endmodule

typedef enum {
    QueuedClientServerQueueTypeNormal = 0,
    QueuedClientServerQueueTypeBypass = 1,
    QueuedClientServerQueueTypePipeline = 2,
    QueuedClientServerQueueTypeSync = 3
} QueuedClientServerQueueType deriving(Bits, Eq);

module mkFifofByType#(Integer depth, QueuedClientServerQueueType typ, Clock srcClk, Clock dstClk, Reset srcRst)(FIFOF#(tData)) provisos(Bits#(tData, szData));
    FIFOF#(tData) q;
    if (typ == QueuedClientServerQueueTypeNormal) begin
        q <- mkSizedFIFOF(depth);
    end
    else if (typ == QueuedClientServerQueueTypeBypass) begin
        q <- mkSizedBypassFIFOF(depth);
    end
    else if (typ == QueuedClientServerQueueTypePipeline) begin
        q <- mkLFIFOF;
    end
    else if (typ == QueuedClientServerQueueTypeSync) begin
        SyncFIFOIfc#(tData) syncQ <- mkSyncFIFO(depth, srcClk, srcRst, dstClk);
        q = f_Sync_FIFOF_to_FIFOF(syncQ);
    end
    return q;
endmodule


interface QueuedClientP#(type t_req, type t_resp);
    interface ClientP#(t_req, t_resp) clt;
    method Action putReq(t_req req);
    method Bool canPutReq;

    method ActionValue#(t_resp) getResp();
    method Bool hasResp;
endinterface


module mkSizedQueuedClientP#(
        Integer reqDepth, 
        Integer respDepth, 
        QueuedClientServerQueueType reqType,
        QueuedClientServerQueueType respType,
        DebugConf dbgConf,
        Clock srcClk,
        Clock dstClk,
        Reset srcRst,
        Reset dstRst
    )(QueuedClientP#(t_req, t_resp)) provisos (
        Bits#(t_req, sz_req),
        Bits#(t_resp, sz_resp),
        FShow#(t_req),
        FShow#(t_resp)
    );
    
    FIFOF#(t_req) reqQ <- mkFifofByType(reqDepth, reqType, srcClk, dstClk, srcRst);
    FIFOF#(t_resp) respQ <- mkFifofByType(respDepth, respType, dstClk, srcClk, dstRst);

    rule debug if (dbgConf.enableDebug);
        if (!reqQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkQueuedClient ", fshow(dbgConf.name) , " reqQ");
        end
        if (!respQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkQueuedClient ", fshow(dbgConf.name) , " respQ");
        end

        if (!reqQ.notEmpty) begin
            $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkQueuedClient ", fshow(dbgConf.name) , " reqQ");
        end

        if (!respQ.notEmpty) begin
            $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkQueuedClient ", fshow(dbgConf.name) , " respQ");
        end
    endrule

    interface clt = toGPClientP(toPipeOut(reqQ), toPipeIn(respQ));

    method Action putReq(t_req req);
        reqQ.enq(req);
        if (dbgConf.enableDebug) begin
            $display(
                "time=%0t: ", $time, "mkQueuedClient [", fshow(dbgConf.name) , "] put req:",
                ", req=", fshow(req)
            );
        end
    endmethod

    method Bool canPutReq = reqQ.notFull;

    method ActionValue#(t_resp) getResp();
        respQ.deq;

        if (dbgConf.enableDebug) begin
            $display(
                "time=%0t: ", $time, "mkQueuedClient [", fshow(dbgConf.name) , "] get resp:",
                ", resp=", fshow(respQ.first)
            );
        end

        return respQ.first;
    endmethod

    method Bool hasResp = respQ.notEmpty;
endmodule

module mkQueuedClientPWithDebug#(DebugConf dbgConf)(QueuedClientP#(t_req, t_resp)) provisos (
    Bits#(t_req, sz_req),
    Bits#(t_resp, sz_resp),
    FShow#(t_req),
    FShow#(t_resp)
);
    let curClk <- exposeCurrentClock;
    let curRst <- exposeCurrentReset;
    let t <- mkSizedQueuedClientP(2, 2, QueuedClientServerQueueTypeNormal, QueuedClientServerQueueTypeNormal, dbgConf, curClk, curClk, curRst, curRst);
    return t;
endmodule

module mkQueuedClientP#(DebugConf dbgConf)(QueuedClientP#(t_req, t_resp)) provisos (
    Bits#(t_req, sz_req),
    Bits#(t_resp, sz_resp),
    FShow#(t_req),
    FShow#(t_resp)
);
    let t <- mkQueuedClientPWithDebug(dbgConf);
    return t;
endmodule

// module mkSyncQueuedClient#(
//         String name,
//         Clock srvClk,
//         Reset srvRst
//     )(QueuedClient#(t_req, t_resp)) provisos (
//         Bits#(t_req, sz_req),
//         Bits#(t_resp, sz_resp),
//         FShow#(t_req),
//         FShow#(t_resp)
//     );
//     let cltClk <- exposeCurrentClock;
//     let cltRst <- exposeCurrentReset;
//     let t <- mkSizedQueuedClient(name, 2, 2, QueuedClientServerQueueTypeSync, QueuedClientServerQueueTypeSync, cltClk, srvClk, cltRst, srvRst);
//     return t;
// endmodule


interface QueuedServerP#(type t_req, type t_resp);
    interface ServerP#(t_req, t_resp) srv;

    method ActionValue#(t_req) getReq();
    method Bool hasReq;

    method Action putResp(t_resp resp);
    method Bool canPutResp;
endinterface

module mkSizedQueuedServerP#(
        Integer reqDepth,
        Integer respDepth, 
        QueuedClientServerQueueType reqType, 
        QueuedClientServerQueueType respType,
        DebugConf dbgConf,
        Clock srcClk,
        Clock dstClk,
        Reset srcRst,
        Reset dstRst
    )(QueuedServerP#(t_req, t_resp)) provisos (
        Bits#(t_req, sz_req),
        Bits#(t_resp, sz_resp),
        FShow#(t_req),
        FShow#(t_resp)
    );

    FIFOF#(t_req) reqQ <- mkFifofByType(reqDepth, reqType, srcClk, dstClk, srcRst);
    FIFOF#(t_resp) respQ <- mkFifofByType(respDepth, respType, dstClk, srcClk, dstRst);

    rule debug;
        if (!reqQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkQueuedServer ", fshow(dbgConf.name) , " reqQ");
        end
        if (!respQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkQueuedServer ", fshow(dbgConf.name) , " respQ");
        end
    endrule

    interface srv = toGPServerP(toPipeIn(reqQ), toPipeOut(respQ));

    method Action putResp(t_resp resp);
        respQ.enq(resp);
    endmethod

    method Bool canPutResp = respQ.notFull;

    method ActionValue#(t_req) getReq();
        reqQ.deq;
        // $display("time=%0t: ", $time, "mkQueuedServer get req [", fshow(dbgConf.name) , "] req=", fshow(reqQ.first));
        return reqQ.first;
    endmethod

    method Bool hasReq = reqQ.notEmpty;

endmodule


module mkQueuedServerP#(DebugConf dbgConf)(QueuedServerP#(t_req, t_resp)) provisos (
    Bits#(t_req, sz_req),
    Bits#(t_resp, sz_resp),
    FShow#(t_req),
    FShow#(t_resp)
);
    let curClk <- exposeCurrentClock;
    let curRst <- exposeCurrentReset;
    let t <- mkSizedQueuedServerP(2, 2, QueuedClientServerQueueTypeNormal, QueuedClientServerQueueTypeNormal, dbgConf, curClk, curClk, curRst, curRst);
    return t;
endmodule

// module mkSyncQueuedServer#(
//         String name,
//         Clock cltClk,
//         Reset cltRst
//     )(QueuedServer#(t_req, t_resp)) provisos (
//         Bits#(t_req, sz_req),
//         Bits#(t_resp, sz_resp),
//         FShow#(t_req),
//         FShow#(t_resp)
//     );
//     let srvClk <- exposeCurrentClock;
//     let srvRst <- exposeCurrentReset;
//     let t <- mkSizedQueuedServer(name, 2, 2, QueuedClientServerQueueTypeNormal, QueuedClientServerQueueTypeNormal, cltClk, srvClk, cltRst, srvRst);
//     return t;
// endmodule

function tData getAbsValue(tData a) provisos(Arith#(tData), Bitwise#(tData));
    return msb(a) == 0 ? a : (~a) + 1;
endfunction

interface Server2Client#(type tReq, type tResp);
    interface Server#(tReq, tResp) srv;
    interface Client#(tReq, tResp) clt;
endinterface

module mkServer2ClientTwoBeat(Server2Client#(tReq, tResp)) provisos (
        Bits#(tReq, szReq),
        Bits#(tResp, szResp),
        FShow#(tReq),
        FShow#(tResp)
    );

    FIFOF#(tReq) reqQ <- mkFIFOF;
    FIFOF#(tResp) respQ <- mkFIFOF;

    interface Server srv;
        interface Put request;
            method Action put(tReq req);
                reqQ.enq(req);
            endmethod
        endinterface

        interface Get response;
            method ActionValue#(tResp) get;
                respQ.deq;
                return respQ.first;
            endmethod
        endinterface
    endinterface

    interface Client clt;
        interface Put response;
            method Action put(tResp resp);
                respQ.enq(resp);
            endmethod
        endinterface

        interface Get request;
            method ActionValue#(tReq) get;
                reqQ.deq;
                return reqQ.first;
            endmethod
        endinterface
    endinterface

endmodule






function FlagsType#(enumType) enum2Flag(enumType inputVal) provisos(
    Bits#(enumType, tSz),
    Flags#(enumType)
);
    // TODO: check inputVal is onehot or zero
    // immAssert(
    //     isOneHotOrZero(inputVal),
    //     "numOnes assertion @ convert2Flag",
    //     $format(
    //         "inputVal=", fshow(inputVal),
    //         " should be one-hot but its value=%0d", pack(inputValue)
    //     )
    // );
    return unpack(pack(inputVal));
endfunction

// Check flags1 contains flags2 or not
function Bool containFlags(FlagsType#(enumType) flags1, FlagsType#(enumType) flags2) provisos(
    Bits#(enumType, tSz),
    Flags#(enumType)
);
    return (flags1 & flags2) == flags2;
    // Bit#(tSz) bitWiseResult = pack((flags1 & flags2) ^ flags2);
    // return isZero(bitWiseResult);
endfunction

function Bool containEnum(FlagsType#(enumType) flags, enumType enumVal) provisos(
    Bits#(enumType, tSz),
    Flags#(enumType)
);
    return !isZero(pack(flags & enum2Flag(enumVal)));
endfunction

// _read SB (incr CF decr) SB _write
interface CountCF#(type anytype);
    method Action incrOne();
    method Action decrOne();
    method Action _write (anytype write_val);
    method anytype _read();
endinterface

module mkCountCF#(anytype resetVal)(CountCF#(anytype)) provisos(
    Arith#(anytype), Bits#(anytype, tSz)
);
    Reg#(anytype) cntReg <- mkReg(resetVal);
    FIFOF#(Bool)   incrQ <- mkFIFOF;
    FIFOF#(Bool)   decrQ <- mkFIFOF;

    Reg#(Maybe#(anytype)) writeReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool) incrReg[2] <- mkCReg(2, False);
    Reg#(Bool) decrReg[2] <- mkCReg(2, False);

    (* no_implicit_conditions, fire_when_enabled *)
    rule write if (writeReg[1] matches tagged Valid .writeVal);
        cntReg <= writeVal;
        incrQ.clear;
        decrQ.clear;
        writeReg[1] <= tagged Invalid;
        incrReg[1]  <= False;
        decrReg[1]  <= False;
    endrule

    (* fire_when_enabled *)
    rule increment if (!isValid(writeReg[1]));
        incrReg[0] <= True;
        incrQ.deq;
    endrule

    (* fire_when_enabled *)
    rule decrement if (!isValid(writeReg[1]));
        decrReg[0] <= True;
        decrQ.deq;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule incrAndDecr if (!isValid(writeReg[1]));
        if (incrReg[1] && !decrReg[1]) begin
            cntReg <= cntReg + 1;
        end
        else if (!incrReg[1] && decrReg[1]) begin
            cntReg <= cntReg - 1;
        end

        incrReg[1] <= False;
        decrReg[1] <= False;
    endrule

    method Action incrOne();
        incrQ.enq(True);
    endmethod
    method Action decrOne();
        decrQ.enq(True);
    endmethod
    method Action _write(anytype writeVal);
        writeReg[0] <= tagged Valid writeVal;
    endmethod
    method anytype _read() = cntReg;
endmodule

module mkFixPriorityTwoInputArbiterPipeOut#(PipeOut#(tData) highPriChannel, PipeOut#(tData) lowPriChannel)(PipeOut#(tData)) provisos (Bits#(tData, szData));
    FIFOF#(tData) outQ <- mkFIFOF;

    rule doArbit;
        if (highPriChannel.notEmpty) begin
            highPriChannel.deq;
            outQ.enq(highPriChannel.first);
        end
        else if (lowPriChannel.notEmpty) begin
            lowPriChannel.deq;
            outQ.enq(lowPriChannel.first);
        end
    endrule

    return toPipeOut(outQ);
endmodule


module mkFixPriorityTwoInputArbiterNoOutputBufferPipeOut#(PipeOut#(tData) highPriChannel, PipeOut#(tData) lowPriChannel)(PipeOut#(tData)) provisos (Bits#(tData, szData));

    Bool _notEmpty = highPriChannel.notEmpty || lowPriChannel.notEmpty;
    method notEmpty = _notEmpty;

    method tData first if (_notEmpty);
        if (highPriChannel.notEmpty) begin
            return highPriChannel.first;
        end
        else begin
            return lowPriChannel.first;
        end
    endmethod

    method Action deq if (_notEmpty);
        if (highPriChannel.notEmpty) begin
            highPriChannel.deq;
        end
        else begin
            lowPriChannel.deq;
        end
    endmethod
endmodule

function String toGreen(String s);
    return sprintf("\033[32m%s\033[0m", s);
endfunction

function String toRed(String s);
    return sprintf("\033[31m%s\033[0m", s);
endfunction

function String toBlue(String s);
    return sprintf("\033[96m%s\033[0m", s);
endfunction

interface AutoInferBram#(type tAddr, type tData);
    method Action write(tAddr addr, tData data);
    method Action putReadReq(tAddr addr);
    method ActionValue#(tData) getReadResp;
endinterface

interface AutoInferBramQueuedOutput#(type tAddr, type tData);
    method Action write(tAddr addr, tData data);
    method Action putReadReq(tAddr addr);
    interface PipeOut#(tData) readRespPipeOut;
endinterface

module mkAutoInferBram(AutoInferBram#(tAddr, tData)) provisos (
        Bits#(tAddr, szAddr),
        Bits#(tData, szData),
        Bounded#(tAddr)
    );

    RegFile#(tAddr, tData) storage <- mkRegFileFull;
    Reg#(tData) tReg <- mkRegU;

    FIFOF#(Bit#(1)) readSignalQ <- mkFIFOF;
    FIFOF#(tData) outputBufQ <- mkFIFOF;
    
    rule bufferReadResp;
        readSignalQ.deq;
        outputBufQ.enq(tReg);
    endrule

    method Action write(tAddr addr, tData data);
        storage.upd(addr, data);
    endmethod

    method Action putReadReq(tAddr addr);
        let resp = storage.sub(addr);
        tReg <= resp;
        readSignalQ.enq(0);
    endmethod

    method ActionValue#(tData) getReadResp;
        outputBufQ.deq;
        return outputBufQ.first;
    endmethod
endmodule

interface AutoInferBramSingleClockWr#(type tAddr, type tData);
    method Action upd(tAddr addr, tData data);
    method Action sendReadAddr(tAddr addr);
    method tData getReadResp;
endinterface

import "BVI" bram_single_clock_wr_with_read_bypass =
module mkAutoInferBramSingleClockWrBVI#(Bool bypassWriteData, String initFile)(AutoInferBramSingleClockWr#(tAddr, tData)) provisos (
        Bits#(tAddr, szAddr),
        Bits#(tData, szData)
    );

    let clk <- exposeCurrentClock;

    parameter ADDR_WIDTH = valueOf(szAddr);
    parameter DATA_WIDTH = valueOf(szData);
    parameter FILE = initFile;
    parameter BYPASS_WRITE_DATA = bypassWriteData;

    input_clock (clk) = clk;
    // input_reset = no_reset;
    default_clock no_clock;
    default_reset no_reset;

    // input port
    method upd(write_address, d) enable(we) clocked_by(clk) reset_by(no_reset);
    method sendReadAddr(read_address)  enable((*inhigh*) EN_NO_USE_1) clocked_by(clk) reset_by(no_reset);

    // output port
    method q getReadResp clocked_by(clk) reset_by(no_reset);

    schedule (upd, sendReadAddr, getReadResp) CF (upd, sendReadAddr, getReadResp);
endmodule

module mkAutoInferBramSingleClockWrBSV#(Bool bypassWriteData, String initFile)(AutoInferBramSingleClockWr#(tAddr, tData)) provisos (
        Bits#(tAddr, szAddr),
        Bits#(tData, szData),
        Eq#(tAddr),
        Bounded#(tAddr),
        Literal#(tAddr)
    );
    RegFile#(tAddr, tData) storage;
    
    if (initFile != "") begin
        storage <- mkRegFileWCFLoadBin(initFile, 0, maxBound);
    end
    else begin
        storage <- mkRegFileWCF(0, maxBound);
    end

    Reg#(tData) tReg <- mkRegU;

    RWire#(Tuple2#(tAddr, tData)) writeReqWire <- mkRWire;


    method Action upd(tAddr addr, tData data);
        storage.upd(addr, data);
        writeReqWire.wset(tuple2(addr, data));
    endmethod

    method Action sendReadAddr(tAddr addr);
        if (bypassWriteData &&& writeReqWire.wget matches tagged Valid .writeReq) begin
            let {addrWrite, dataWrite} = writeReq;
            if (addr == addrWrite) begin
                tReg <= dataWrite;
            end
            else begin
                tReg <= storage.sub(addr);
            end
        end
        else begin
            tReg <= storage.sub(addr);
        end
    endmethod

    method tData getReadResp;
        return tReg;
    endmethod

endmodule

module mkAutoInferBramSingleClockWr#(Bool bypassWriteData, String initFile)(AutoInferBramSingleClockWr#(tAddr, tData)) provisos (
        Bits#(tAddr, szAddr),
        Bits#(tData, szData),
        Eq#(tAddr),
        Bounded#(tAddr),
        Literal#(tAddr)
    );

    AutoInferBramSingleClockWr#(tAddr, tData) inst;

    if (genVerilog) begin
        inst <- mkAutoInferBramSingleClockWrBVI(bypassWriteData, initFile);
    end
    else begin
        inst <- mkAutoInferBramSingleClockWrBSV(bypassWriteData, initFile);
    end

    return inst;
endmodule

// ungarded interface, use with care!
module mkAutoInferBramUG#(Bool bypassWriteData, String initFile, String debugName)(AutoInferBram#(tAddr, tData)) provisos (
        Bits#(tAddr, szAddr),
        Bits#(tData, szData),
        Bounded#(tAddr),
        Eq#(tAddr),
        Literal#(tAddr),
        FShow#(tAddr),
        FShow#(tData)
    );

    AutoInferBramSingleClockWr#(tAddr, tData) storage <- mkAutoInferBramSingleClockWr(bypassWriteData, initFile);

    Wire#(tAddr) readAddrWire <- mkDWire (unpack(0));

    Count#(Bit#(8)) illegalReadMonitorCounter <- mkCount(0);

    rule incrGuard;
        illegalReadMonitorCounter.incr(1);
    endrule
    
    rule forwardReadAddr;
        storage.sendReadAddr(readAddrWire);
    endrule

    method Action write(tAddr addr, tData data);
        storage.upd(addr, data);
    endmethod

    method Action putReadReq(tAddr addr);
        // $display("time=%0t", $time, "putReadReq", 
        //     ", addr=", fshow(addr)
        // );
        readAddrWire <= addr;
        illegalReadMonitorCounter.update(0);
    endmethod

    method ActionValue#(tData) getReadResp;
        immAssert(
            illegalReadMonitorCounter == 1,
            "mkAutoInferBramUG, illegal read, illegalReadMonitorCounter must be 1, 0 means read not ready, and greater than 1 means some data is lost due to not read timely.",
            $format("debugName=", fshow(debugName), ", illegalReadMonitorCounter=", fshow(illegalReadMonitorCounter))
        );

        // $display("time=%0t", $time, "getReadResp", 
        //     ", tReg=", fshow(tReg)
        // );
        return storage.getReadResp;
    endmethod
endmodule


module mkAutoInferBramQueuedOutput#(Bool bypassWriteData, String initFile, String debugName)(AutoInferBramQueuedOutput#(tAddr, tData)) provisos (
        Bits#(tAddr, szAddr),
        Bits#(tData, szData),
        Bounded#(tAddr),
        Eq#(tAddr),
        Literal#(tAddr),
        FShow#(tAddr),
        FShow#(tData)
    );

    AutoInferBram#(tAddr, tData) storage <- mkAutoInferBramUG(bypassWriteData, initFile, debugName);

    FIFOF#(Bit#(0)) hasPendingReadReqSignalQueue <- mkUGFIFOF;
    FIFOF#(tData)   outputQ <- mkUGSizedFIFOF(3);
    Count#(Bit#(2)) backPreasureCounter <- mkCount(0);
    

    (* no_implicit_conditions, fire_when_enabled *)
    rule handleReadResp;
        if (hasPendingReadReqSignalQueue.notEmpty) begin
            hasPendingReadReqSignalQueue.deq;
            immAssert(
                outputQ.notFull,
                "output Q is full, the back preasure not work",
                $format("")
            );
            let ret <- storage.getReadResp;
            outputQ.enq(ret);
        end
    endrule

    method Action write(tAddr addr, tData data);
        storage.write(addr, data);
    endmethod

    method Action putReadReq(tAddr addr) if (backPreasureCounter != 3);
        storage.putReadReq(addr);
        hasPendingReadReqSignalQueue.enq(0);
        backPreasureCounter.incr(1);
    endmethod

    interface PipeOut readRespPipeOut;
        method Bool notEmpty = outputQ.notEmpty;
        method tData first  = outputQ.first;
        method Action deq if (outputQ.notEmpty);
            outputQ.deq;
            backPreasureCounter.decr(1);
        endmethod
    endinterface
endmodule

typedef enum {
    AddressAlignAssertionMask512B = 'h1FF,
    AddressAlignAssertionMask4KB = 'hFFF,
    AddressAlignAssertionMask2MB = 'h1FFFFF
} AddressAlignAssertionMask deriving (Bits, Eq);

function Action immAssertAddressAlign(tAddr addr, AddressAlignAssertionMask alignMask, String name) provisos (
    Bits#(tAddr, szAddr),
    Bits#(AddressAlignAssertionMask, szMask),
    Add#(anySize, szMask, szAddr)
);
    action
        tAddr maskedAddr = unpack(zeroExtend(pack(alignMask)) & pack(addr));
        immAssert(
            pack(maskedAddr) == 0,
            "address not aligned @ immAssertAddressAlign",
            $format("name=%s, addr=%x, maskedLowerBIts=%x", name, addr, maskedAddr)
        );
    endaction
endfunction


function Action immAssertAddressAndLengthNotCross4kBoundary(tAddr addr, tLen len, String name) provisos (
    Bits#(tAddr, szAddr),
    Bits#(tLen, szLen),
    Add#(anySize, szLen, szAddr)
);
    action
        tAddr addedAddr = unpack(pack(addr) + zeroExtend(pack(len)) - 1);
        immAssert(
            (pack(addr) >> 12) == (pack(addedAddr) >> 12),   // 2 ^ 12 = 4096
            "address plus length crossed 4kB boundary @ immAssertAddressAndLengthNotCross4kBoundary",
            $format("name=%s, addr=%x, len=%x", name, addr, len)
        );
    endaction
endfunction



module mkRegisteredSizedFIFOFInnerModule#(Integer depth)(FIFOF#(tData)) provisos(Bits#(tData, szData));
    FIFOF#(tData) inputQ <- mkLFIFOF;
    FIFOF#(tData) outputQ <- mkLFIFOF;
    FIFOF#(tData) bufferQ <- mkSizedFIFOF(depth-2);
    mkConnection(toPipeOut(inputQ), toPipeIn(bufferQ));
    mkConnection(toPipeOut(bufferQ), toPipeIn(outputQ));
    
    method enq = inputQ.enq;
    method deq = outputQ.deq;
    method first = outputQ.first;
    method notFull = inputQ.notFull;
    method notEmpty = outputQ.notEmpty;
    method Action clear;
        inputQ.clear;
        outputQ.clear;
        bufferQ.clear;
    endmethod
endmodule

module mkRegisteredSizedFIFOF#(Integer depth)(FIFOF#(tData)) provisos(Bits#(tData, szData));
    if (depth <= 2) begin
        let inst <- mkSizedFIFOF(depth);
        return inst;
    end
    else begin
        let inst <- mkRegisteredSizedFIFOFInnerModule(depth);
        return inst;
    end
endmodule


module mkDelayFIFOF#(Integer beat)(FIFOF#(tData)) provisos(Bits#(tData, szData));

    if (beat == 1) begin
        FIFOF#(tData) inputQ <- mkLFIFOF;
        return inputQ;
    end
    else begin

        List #(FIFOF#(tData)) fifoList;

        for (Integer idx = 0; idx < beat; idx = idx + 1) begin
            FIFOF#(tData) queue <- mkLFIFOF;
            fifoList = List :: cons(queue, fifoList);
        end

        for (Integer idx = 1; idx < beat; idx = idx + 1) begin
            rule forward;
                fifoList[idx-1].deq;
                fifoList[idx].enq(fifoList[idx-1].first);
            endrule
        end

        method enq      = fifoList[0].enq;
        method notFull  = fifoList[0].notFull;
        method first    = fifoList[beat-1].first;
        method deq      = fifoList[beat-1].deq;
        method notEmpty = fifoList[beat-1].notEmpty;

        method Action clear;
            for (Integer idx = 0; idx < beat; idx = idx + 1) begin
                fifoList[idx].clear;
            end
        endmethod

    end
endmodule


// function tOut getLogValueOfOneHot(tIn onehotIn) provisos (
//         Bits#(tOut, szOut),
//         Bits#(tIn, szIn),
//         Add#(0, TLog#(szIn), szOut)
//     );
//     Vector#(szOut, tOut) tmpBufferVec = newVector;
//     for (Integer idx = 0; idx < valueOf(szOut); idx = idx + 1) begin
//         tmpBufferVec[idx] = onehotIn[idx] == 1 ? fromInteger(idx) : 0;
//     end
//     // TODO: not finished
// endfunction

function DebugConf concatDebugName(DebugConf dbgConf, String name);
    return DebugConf{name: dbgConf.name + " " + name, enableDebug: dbgConf.enableDebug};
endfunction
