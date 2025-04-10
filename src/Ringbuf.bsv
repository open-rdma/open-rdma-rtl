import Vector :: *;
import Settings :: *;
import DtldStream :: *;
import StreamDataTypes :: *;
import BasicDataTypes :: *;
import RdmaHeaders :: *;
import FIFOF :: *;
import Cntrs :: * ;
import Arbitration :: *;
import PAClib :: *;
import PrimUtils :: *;
import ClientServer :: *;
import Connectable :: *;
import GetPut :: *;
import ConfigReg :: * ;
import Randomizable :: *;
import PrimUtils :: *;
import RdmaUtils :: *;
import IoChannels :: *;

import ConnectableF :: *;
import NapWrapper :: *;
import Descriptors :: *;

typedef 3 RINGBUF_NUMBER_WIDTH;

typedef 32   USER_LOGIC_DESCRIPTOR_BYTE_WIDTH;
typedef TMul#(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH, BYTE_WIDTH)  USER_LOGIC_DESCRIPTOR_BIT_WIDTH; // 256 bit

typedef Bit#(USER_LOGIC_DESCRIPTOR_BIT_WIDTH)   RingbufRawDescriptor;
typedef Bit#(RINGBUF_NUMBER_WIDTH)              RingbufNumber;

function Bool isRingbufNotEmpty(RingbufPointer#(sz_rbp) head, RingbufPointer#(sz_rbp) tail);
    return !(head == tail);
endfunction

function Bool isRingbufNotFull(RingbufPointer#(sz_rbp) head, RingbufPointer#(sz_rbp) tail);
    return !((head.idx == tail.idx) && (head.guard != tail.guard));
endfunction


typedef struct {
    Bool guard;
    UInt#(w) idx;
} RingbufPointer#(numeric type w) deriving(Bits, Eq);

instance Arith#(RingbufPointer#(w)) provisos(Alias#(RingbufPointer#(w), data_t), Bits#(data_t, TAdd#(w, 1)));
    function data_t \+ (data_t x, data_t y);
        UInt#(TAdd#(w,1)) tx = unpack(pack(x));
        UInt#(TAdd#(w,1)) ty = unpack(pack(y));
        return unpack(pack(tx + ty));
    endfunction

    function data_t \- (data_t x, data_t y);
        UInt#(TAdd#(w,1)) tx = unpack(pack(x));
        UInt#(TAdd#(w,1)) ty = unpack(pack(y));
        return unpack(pack(tx - ty));
    endfunction

    function data_t \* (data_t x, data_t y);
        return error ("The operator " + quote("*") +
                      " is not defined for " + quote("RingbufPointer") + ".");
    endfunction

    function data_t \/ (data_t x, data_t y);
        return error ("The operator " + quote("/") +
                      " is not defined for " + quote("RingbufPointer") + ".");
    endfunction

    function data_t \% (data_t x, data_t y);
        return error ("The operator " + quote("%") +
                      " is not defined for " + quote("RingbufPointer") + ".");
    endfunction

    function data_t negate (data_t x);
        return error ("The operator " + quote("negate") +
                      " is not defined for " + quote("RingbufPointer") + ".");
    endfunction

endinstance

instance Literal#(RingbufPointer#(w));

   function fromInteger(n) ;
        return unpack(fromInteger(n)) ;
   endfunction
   function inLiteralRange(a, i);
        UInt#(w) idxPart = ?;
        return inLiteralRange(idxPart, i);
   endfunction
endinstance


typedef 4096  USER_LOGIC_RING_BUF_4096_DEEP; 
typedef TLog#(USER_LOGIC_RING_BUF_4096_DEEP)  USER_LOGIC_RING_BUF_4096_DEEP_WIDTH; 
typedef RingbufPointer#(USER_LOGIC_RING_BUF_4096_DEEP_WIDTH) Fix128kBRingBufPointer;
typedef RingbufC2h#(USER_LOGIC_RING_BUF_4096_DEEP_WIDTH) RingbufC2hSlot4096;
typedef RingbufH2c#(USER_LOGIC_RING_BUF_4096_DEEP_WIDTH) RingbufH2cSlot4096;
typedef RingbufMetadata#(USER_LOGIC_RING_BUF_4096_DEEP_WIDTH) RingbufSlot4096Meta;

typedef 16 RINGBUF_DESC_ENTRY_PER_READ_BLOCK;
typedef 4 RINGBUF_DESC_ENTRY_PER_WRITE_BLOCK;


typedef Bit#(TLog#(RINGBUF_DESC_ENTRY_PER_READ_BLOCK)) RingBufReadBlockOffset;
typedef Bit#(TLog#(RINGBUF_DESC_ENTRY_PER_WRITE_BLOCK)) RingBufWriteBlockOffset;

typedef struct {
    ADDR addr;
    RingBufReadBlockOffset zeroBasedDescReadCnt;
} RingbufDmaReadReq deriving(Bits, FShow);

typedef struct {
    DescDataStream data;
} RingbufDmaReadResp deriving(Bits, FShow);

typedef struct {
    ADDR addr;
    RingBufWriteBlockOffset zeroBasedDescWriteCnt;
} RingbufDmaWriteReq deriving(Bits, FShow);

typedef struct {
    Bool isSuccess;
} RingbufDmaWriteResp deriving(Bits, FShow);


interface RingbufH2c#(numeric type szPtrIdx);
    interface RingbufMetadata#(szPtrIdx) controlRegs;
    interface PipeOut#(RingbufDmaReadReq) dmaReadReqPipeOut;
    interface PipeIn#(RingbufDmaReadResp) dmaReadRespPipeIn;
    interface PipeOut#(RingbufRawDescriptor) descPipeOut;
endinterface


// Important Note: The whole algorithm below based on the fact that the NAP bit width is 256 bits, and
// is the same as our descriptor size, so when doing aligned memory read, each NAP read beat is a 
// complete descriptor.
module mkRingbufH2c(RingbufNumber qIdx, RingbufH2c#(szPtrIdx) ifc) provisos(
        NumAlias#(TAdd#(1, szPtrIdx), szPtrWithGuard),
        Alias#(Bit#(TSub#(szPtrWithGuard, TLog#(RINGBUF_DESC_ENTRY_PER_WRITE_BLOCK))), tReadBlockIndex),
        Alias#(RingbufPointer#(szPtrIdx), tPtrWithGuard),
        Add#(a__, 2, TAdd#(1, szPtrIdx)),
        Add#(d__, 3, TAdd#(1, szPtrIdx)),
        Add#(b__, 4, TAdd#(1, szPtrIdx)),
        Add#(c__, szPtrIdx, SizeOf#(ADDR))
    );

    FIFOF#(RingbufRawDescriptor) bufQ <- mkSizedFIFOF(valueOf(RINGBUF_DESC_ENTRY_PER_READ_BLOCK));
    FIFOF#(RingbufRawDescriptor) outputQ <- mkSizedFIFOF(valueOf(RINGBUF_DESC_ENTRY_PER_READ_BLOCK));

    mkConnection(toGet(bufQ), toPut(outputQ));
    
    Reg#(ADDR) baseAddrReg <- mkReg(0);
    Reg#(tPtrWithGuard) headReg[2] <- mkCReg(2, unpack(0));
    Reg#(tPtrWithGuard) tailReg[2] <- mkCReg(2, unpack(0));
    Reg#(tPtrWithGuard) tailShadowReg <- mkConfigReg(unpack(0));
    FIFOF#(RingbufDmaReadReq) dmaReqQ <- mkFIFOF;
    FIFOF#(RingbufDmaReadResp) dmaRespQ <- mkLFIFOF;

    Reg#(Bool) isWaitingDmaRespReg <- mkReg(False);
    
    rule sendDmaReq if (isWaitingDmaRespReg == False);

        tReadBlockIndex readBlockIdxOfHead = truncate(pack(headReg[0]) >> valueOf(TLog#(RINGBUF_DESC_ENTRY_PER_READ_BLOCK)));
        tReadBlockIndex readBlockIdxOfTailShadow = truncate(pack(tailShadowReg) >> valueOf(TLog#(RINGBUF_DESC_ENTRY_PER_READ_BLOCK)));

        Bool isHeadAndTailShadowInTheSameReadBlock = readBlockIdxOfHead == readBlockIdxOfTailShadow;
        Bool needDoDMA = isRingbufNotEmpty(headReg[0], tailShadowReg) && !bufQ.notEmpty;

        RingBufReadBlockOffset tailShadowRingBufReadBlockOffset = truncate(pack(tailShadowReg));
        let zeroBasedMaxDescReadCnt = fromInteger(valueOf(RINGBUF_DESC_ENTRY_PER_READ_BLOCK) - 1) - tailShadowRingBufReadBlockOffset;
        RingBufReadBlockOffset spanBetweenHeadAndTailShadow = truncate(pack(headReg[0])) - truncate(pack(tailShadowReg));

        tPtrWithGuard nextReadBlockAlignedPointer = unpack(pack(tailShadowReg) >> valueOf(TLog#(RINGBUF_DESC_ENTRY_PER_READ_BLOCK)));
        nextReadBlockAlignedPointer = nextReadBlockAlignedPointer + 1;
        nextReadBlockAlignedPointer = unpack(pack(nextReadBlockAlignedPointer) << valueOf(TLog#(RINGBUF_DESC_ENTRY_PER_READ_BLOCK)));
        
        ADDR dmaReadStartAddr = baseAddrReg + (zeroExtend(pack(tailShadowReg.idx)) << valueOf(DESC_DATA_BUS_BYTE_NUM_WIDTH));

        if (needDoDMA) begin

            RingBufReadBlockOffset zeroBasedDescReadCnt = ?;
            tPtrWithGuard newTailShadow = ?;
            if (isHeadAndTailShadowInTheSameReadBlock) begin
                zeroBasedDescReadCnt = spanBetweenHeadAndTailShadow - 1;
                newTailShadow = headReg[0];
            end
            else begin
                zeroBasedDescReadCnt = zeroBasedMaxDescReadCnt;
                newTailShadow = nextReadBlockAlignedPointer;
            end
            
            dmaReqQ.enq(RingbufDmaReadReq{
                    addr: dmaReadStartAddr,
                    zeroBasedDescReadCnt: zeroBasedDescReadCnt
            });

            tailShadowReg <= newTailShadow;
            isWaitingDmaRespReg <= True;

            // $display(
            //     "time=%0t:", $time, toGreen(" mkRingbufH2c sendDmaReq"),
            //     toBlue(", qIdx="), fshow(qIdx),
            //     toBlue(", headReg="), fshow(pack(headReg[0])),
            //     toBlue(", old tailReg="), fshow(pack(tailReg[0])),
            //     toBlue(", tailShadowReg="), fshow(pack(tailShadowReg)),
            //     toBlue(", zeroBasedDescReadCnt="), fshow(pack(zeroBasedDescReadCnt)),
            //     toBlue(", head-tail="), fshow(pack(headReg[0]-tailReg[0])),
            //     toBlue(", head-tailS="), fshow(pack(headReg[0]-tailShadowReg))
            // );
        end

        
    endrule


    rule recvDmaResp if (isWaitingDmaRespReg == True);
        let readRespDs = dmaRespQ.first;
        dmaRespQ.deq;

        bufQ.enq(unpack(readRespDs.data.data));
        let newTail = tailReg[0] + 1;
        tailReg[0] <= newTail;

        if (readRespDs.data.isLast) begin
            // $display("current read block finished.");
            isWaitingDmaRespReg <= False;
            immAssert(
                newTail == tailShadowReg,
                "shadowTail assertion @ mkRingbufH2c",
                $format(
                    "newTail=%h should == shadowTail=%h, ",
                    newTail, tailShadowReg
                )
            );
        end

        // $display(
        //     "time=%0t:", $time, toGreen(" mkRingbufH2c recvDmaResp"),
        //     toBlue(", qIdx="), fshow(qIdx),
        //     toBlue(", headReg="), fshow(pack(headReg[0])),
        //     toBlue(", old tailReg="), fshow(pack(tailReg[0])),
        //     toBlue(", new tailReg="), fshow(pack(newTail)),
        //     toBlue(", tailShadowReg="), fshow(pack(tailShadowReg)),
        //     toBlue(", desc="), fshow(readRespDs)
        // );
    endrule

    interface RingbufMetadata controlRegs;
        interface addr = baseAddrReg;
        interface head = headReg[1];
        interface tail = tailReg[1];
    endinterface

    interface dmaReadReqPipeOut = toPipeOut(dmaReqQ);
    interface dmaReadRespPipeIn = toPipeIn(dmaRespQ);

    interface descPipeOut = toPipeOut(outputQ);
endmodule



interface RingbufMetadata#(numeric type szPtrIdx);
    interface Reg#(ADDR) addr;
    interface Reg#(RingbufPointer#(szPtrIdx)) head;
    interface Reg#(RingbufPointer#(szPtrIdx)) tail;
endinterface

interface RingbufC2h#(numeric type szPtrIdx);
    interface RingbufMetadata#(szPtrIdx) controlRegs;
    interface PipeOut#(RingbufDmaWriteReq) dmaWriteReqPipeOut;
    interface PipeOut#(DescDataStream) dmaWriteDataPipeOut;
    interface PipeIn#(Bool) dmaWriteRespPipeIn;
    interface PipeIn#(RingbufRawDescriptor) descPipeIn;
endinterface


module mkRingbufC2h(RingbufNumber qIdx, RingbufC2h#(szPtrIdx) ifc) provisos(
        NumAlias#(TAdd#(1, szPtrIdx), szPtrWithGuard),
        Alias#(Bit#(TSub#(szPtrWithGuard, TLog#(RINGBUF_DESC_ENTRY_PER_WRITE_BLOCK))), tWriteBlockIndex),
        Alias#(RingbufPointer#(szPtrIdx), tPtrWithGuard),
        Add#(a__, 2, TAdd#(1, szPtrIdx)),
        Add#(b__, 4, TAdd#(1, szPtrIdx)),
        Add#(c__, szPtrIdx, SizeOf#(ADDR))
    );

    Count#(Bit#(TAdd#(1, TLog#(NUMERIC_TYPE_EIGHT)))) validCounter <- mkCount(0);
    FIFOF#(RingbufRawDescriptor) bufQ <- mkSizedFIFOF(valueOf(NUMERIC_TYPE_EIGHT));
    FIFOF#(RingbufRawDescriptor)                            inputQ  <- mkLFIFOF;

    rule forwardInput;
        inputQ.deq;
        bufQ.enq(inputQ.first);
        validCounter.incr(1);
    endrule

    Reg#(ADDR)                      baseAddrReg     <- mkReg(0);
    Reg#(tPtrWithGuard)    headReg[2]      <- mkCReg(2, unpack(0));
    Reg#(tPtrWithGuard)    tailReg[2]      <- mkCReg(2, unpack(0));
    Reg#(tPtrWithGuard)    headShadowReg   <- mkConfigReg(unpack(0));
    FIFOF#(RingbufDmaWriteReq)      dmaWriteAddrQ   <- mkFIFOF;
    FIFOF#(DescDataStream)          dmaWriteDataQ   <- mkFIFOF;
    FIFOF#(Bool)                    dmaWriteRespQ   <- mkLFIFOF;
    FIFOF#(tPtrWithGuard)           inFlightWriteReqHeaadUpdateQ <- mkLFIFOF;

    Reg#(Bit#(NUMERIC_TYPE_FOUR))      batchDelayCounterReg        <- mkReg(0);
    Reg#(Bool)                         isSendingDescBodyReg        <- mkReg(False);
    Reg#(RingBufWriteBlockOffset)      zeroBasedDescWriteCntReg    <- mkRegU;
    Reg#(Bool)                         isWriteStreamFirstBeatReg   <- mkReg(True);                     

    rule handleBatchDelay;
        if (!bufQ.notEmpty) begin
            batchDelayCounterReg <= 0;
        end
        else begin
            if (batchDelayCounterReg != -1) begin
                batchDelayCounterReg <= batchDelayCounterReg + 1;
            end
        end
    endrule
    
    rule prepareDmaWrite if (!isSendingDescBodyReg);

        Bool isBatchDelayCounterFired = batchDelayCounterReg == -1;
        tPtrWithGuard freeSlotCnt = fromInteger(valueOf(TExp#(szPtrIdx))) - (headShadowReg - tailReg[0]);
        tPtrWithGuard zeroBasedFreeSlotCnt = fromInteger(valueOf(TExp#(szPtrIdx)) - 1) - (headShadowReg - tailReg[0]);
        tPtrWithGuard zeroBasedAvailableDescToWrite = unpack(zeroExtend(pack(validCounter-1)));
        RingBufWriteBlockOffset headShadowRingBufWriteBlockOffset = truncate(pack(headShadowReg));
        tPtrWithGuard zeroBasedMaxDescWriteCntIfAlignedToWriteBlock = fromInteger(valueOf(RINGBUF_DESC_ENTRY_PER_WRITE_BLOCK) - 1) - unpack(zeroExtend(headShadowRingBufWriteBlockOffset));

        RingBufWriteBlockOffset zeroBasedDescWriteCnt = truncate(min(min(pack(zeroBasedMaxDescWriteCntIfAlignedToWriteBlock), pack(zeroBasedAvailableDescToWrite)), pack(zeroBasedFreeSlotCnt)));

        Bool needDoDMA = isBatchDelayCounterFired && bufQ.notEmpty && (pack(freeSlotCnt) > 0);
        if (needDoDMA) begin
            ADDR dmaWriteStartAddr = baseAddrReg + (zeroExtend(pack(headShadowReg.idx)) << valueOf(DESC_DATA_BUS_BYTE_NUM_WIDTH));
            dmaWriteAddrQ.enq(RingbufDmaWriteReq{
                addr: dmaWriteStartAddr,
                zeroBasedDescWriteCnt: zeroBasedDescWriteCnt
            });
            zeroBasedDescWriteCntReg <= zeroBasedDescWriteCnt;
            isSendingDescBodyReg <= True;

            // $display(
            //     "time=%0t:", $time, toGreen(" mkRingbufC2h prepareDmaWrite"),
            //     "needDoDMA=", fshow(needDoDMA),
            //     ", isBatchDelayCounterFired=",fshow(isBatchDelayCounterFired),
            //     ", bufQ.notEmpty=", fshow(bufQ.notEmpty),
            //     ", freeSlotCnt=", fshow(pack(freeSlotCnt)),
            //     ", zeroBasedDescWriteCnt=", fshow(pack(zeroBasedDescWriteCnt)),
            //     ", headReg=", fshow(pack(headReg[0])),
            //     ", headShadowReg=", fshow(pack(headShadowReg)),
            //     ", tailReg=", fshow(pack(tailReg[0])),
            //     ", head-tail=", fshow(pack(headReg[0] - tailReg[0])),
            //     ", headS-tail=", fshow(pack(headShadowReg - tailReg[0])),
            //     ", validCounter=", fshow(pack(validCounter)),
            //     ", zeroBasedAvailableDescToWrite=", fshow(pack(zeroBasedAvailableDescToWrite))
            // );
        end

    endrule

    rule doDmaWrite if (isSendingDescBodyReg);
        Bool isLast = False;

        let newHeadShadow = headShadowReg + 1;

        
        if (isZeroR(zeroBasedDescWriteCntReg)) begin
            isSendingDescBodyReg <= False;
            isLast = True;
            inFlightWriteReqHeaadUpdateQ.enq(newHeadShadow);
        end

        DescDataStream ds;
        ds.isLast = isLast; 
        ds.isFirst = isWriteStreamFirstBeatReg;
        ds.byteNum = fromInteger(valueOf(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH));
        ds.data = unpack(pack(bufQ.first));
        ds.startByteIdx = 0;
        bufQ.deq;
        validCounter.decr(1);

        dmaWriteDataQ.enq(ds);
        
        zeroBasedDescWriteCntReg <= zeroBasedDescWriteCntReg - 1;
        headShadowReg <= newHeadShadow;
        isWriteStreamFirstBeatReg <= isLast;

        // $display(
        //     "time=%0t:", $time, toGreen(" mkRingbufC2h doDmaWrite"),
        //     toBlue(", qIdx="), fshow(qIdx),
        //     toBlue(", tailReg="), fshow(pack(tailReg[0])),
        //     toBlue(", headReg="), fshow(pack(headReg[0])),
        //     toBlue(", old headShadowReg="), fshow(pack(headShadowReg)),
        //     toBlue(", new headShadowReg="), fshow(pack(newHeadShadow)),
        //     toBlue(", desc="), fshow(ds)
        // );
    endrule

    rule handleWriteResp;
        dmaWriteRespQ.deq;
        let newHead = inFlightWriteReqHeaadUpdateQ.first;
        inFlightWriteReqHeaadUpdateQ.deq;

        headReg[0] <= newHead;
        
        // $display(
        //     "time=%0t:", $time, toGreen(" mkRingbufC2h handleWriteResp"),
        //     toBlue(", qIdx="), fshow(qIdx),
        //     toBlue(", headReg="), fshow(pack(headReg[0])),
        //     toBlue(", newHead="), fshow(pack(newHead))
        // );
    endrule


    interface RingbufMetadata controlRegs;
        interface addr = baseAddrReg;
        interface head = headReg[1];
        interface tail = tailReg[1];
    endinterface

    interface dmaWriteReqPipeOut    = toPipeOut(dmaWriteAddrQ);
    interface dmaWriteDataPipeOut   = toPipeOut(dmaWriteDataQ);
    interface dmaWriteRespPipeIn    = toPipeIn(dmaWriteRespQ);

    interface descPipeIn = toPipeIn(inputQ);
endmodule

interface RingbufDmaIfcConvertor;
    // ringbuf side interface
    interface PipeInB0#(RingbufDmaReadReq) dmaReadReqPipeIn;
    interface PipeOut#(RingbufDmaReadResp) dmaReadRespPipeOut;
    interface PipeInB0#(RingbufDmaWriteReq) dmaWriteReqPipeIn;
    interface PipeInB0#(DescDataStream) dmaWriteDataPipeIn;
    interface PipeOut#(Bool) dmaWriteRespPipeOut;

    // dma side interface
    interface IoChannelMemoryMasterPipeB0In dmaMasterPipeIfc;
endinterface

(* synthesize *)
module mkRingbufDmaIfcConvertor(RingbufDmaIfcConvertor);
    PipeInAdapterB0#(RingbufDmaReadReq)     dmaReadReqPipeInQ       <- mkPipeInAdapterB0;
    FIFOF#(RingbufDmaReadResp)              dmaReadRespPipeOutQ     <- mkFIFOF;
    PipeInAdapterB0#(RingbufDmaWriteReq)    dmaWriteReqPipeInQ      <- mkPipeInAdapterB0;
    PipeInAdapterB0#(DescDataStream)        dmaWriteDataPipeInQ     <- mkPipeInAdapterB0;
    FIFOF#(Bool)                            dmaWriteRespPipeOutQ    <- mkFIFOF;

    FIFOF#(IoChannelMemoryAccessMeta)                       dmaReadMetaPipeOutQueue     <- mkFIFOF;
    PipeInAdapterB0#(IoChannelMemoryAccessDataStream)       dmaReadDataPipeInQueue      <- mkPipeInAdapterB0;
    FIFOF#(IoChannelMemoryAccessMeta)                       dmaWriteMetaPipeOutQueue    <- mkFIFOF;
    FIFOF#(IoChannelMemoryAccessDataStream)                 dmaWriteDataPipeOutQueue    <- mkFIFOF;

    let needWidthConvert = valueOf(DATA_BUS_WIDTH) != valueOf(DESC_DATA_WIDTH);

    Reg#(Bit#(TMax#(1, TLog#(TDiv#(DATA_BUS_WIDTH, DESC_DATA_WIDTH))))) writeDataWidthConvertDescIdxInBeatNowReg <- mkReg(0);
    Reg#(Bit#(TMax#(1, TLog#(TDiv#(DATA_BUS_WIDTH, DESC_DATA_WIDTH))))) readDataWidthConvertDescIdxInBeatNowReg <- mkReg(0);
    Reg#(Bit#(TMax#(1, TLog#(TDiv#(DATA_BUS_WIDTH, DESC_DATA_WIDTH))))) readDataWidthConvertDescIdxInBeatTargetReg <- mkReg(0);

    Reg#(DATA) writeDataWidthConvertBufReg <- mkReg(unpack(0));
    Reg#(IoChannelMemoryAccessDataStream) readDataWidthConvertBufReg  <- mkRegU;
    Reg#(Bool) writeDataWidthConvertIsFirstFlagReg <- mkReg(True);
    Reg#(Bool) readDataWidthConvertIsFirstFlagReg <- mkReg(True);

    rule forwardWriteAddr;
        let req = dmaWriteReqPipeInQ.first;
        dmaWriteReqPipeInQ.deq;

        IoChannelMemoryAccessMeta meta = IoChannelMemoryAccessMeta {
            addr: req.addr,
            totalLen: unpack((zeroExtend(req.zeroBasedDescWriteCnt) + 1) << valueOf(TLog#(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH)))
        };
        dmaWriteMetaPipeOutQueue.enq(meta);

        $display(
            "time=%0t:", $time, toGreen(" mkRingbufDmaIfcConvertor forwardWriteAddr"),
            toBlue(", qmeta="), fshow(meta)
        );
    endrule

    if (needWidthConvert) begin
        rule forwardWriteData;
            let descDs = dmaWriteDataPipeInQ.first;
            dmaWriteDataPipeInQ.deq;
            
            DATA wideNewData = zeroExtend(descDs.data);
            let wideExistData = writeDataWidthConvertBufReg;

            BusBitIdx bitShiftOffset = zeroExtend(writeDataWidthConvertDescIdxInBeatNowReg) << valueOf(TLog#(USER_LOGIC_DESCRIPTOR_BIT_WIDTH));
            DATA wideShiftedNewData = wideNewData << bitShiftOffset;

            DATA newWideData = wideExistData | wideShiftedNewData;

            let nowIdx = writeDataWidthConvertDescIdxInBeatNowReg;
            let newIdx = nowIdx + 1;
            let totalDescInWideBeatNow = zeroExtend(writeDataWidthConvertDescIdxInBeatNowReg) + 1;

            if (nowIdx == maxBound || descDs.isLast) begin
                let ds = DataStream {
                    data: newWideData,
                    startByteIdx: 0,
                    byteNum: totalDescInWideBeatNow << valueOf(TLog#(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH)),
                    isFirst: writeDataWidthConvertIsFirstFlagReg,
                    isLast: descDs.isLast
                };
                dmaWriteDataPipeOutQueue.enq(ds);
                newIdx = 0;
                writeDataWidthConvertIsFirstFlagReg <= descDs.isLast;
                newWideData = unpack(0);
                $display(
                    "time=%0t:", $time, toGreen(" mkRingbufDmaIfcConvertor forwardWriteData output wide DS"),
                    toBlue(", ds="), fshow(ds),
                    toBlue(", wideNewData="), fshow(wideNewData),
                    toBlue(", wideExistData="), fshow(wideExistData),
                    toBlue(", wideShiftedNewData="), fshow(wideShiftedNewData),
                    toBlue(", writeDataWidthConvertDescIdxInBeatNowReg="), fshow(writeDataWidthConvertDescIdxInBeatNowReg)
                );
            end

            writeDataWidthConvertDescIdxInBeatNowReg <= newIdx;
            writeDataWidthConvertBufReg <= newWideData;

            if (descDs.isLast) begin
                dmaWriteRespPipeOutQ.enq(True);
            end
            $display(
                "time=%0t:", $time, toGreen(" mkRingbufDmaIfcConvertor forwardWriteData"),
                toBlue(", descDs="), fshow(descDs)
            );
        endrule
    end
    else begin
        rule forwardWriteData;
            let ds = dmaWriteDataPipeInQ.first;
            dmaWriteDataPipeInQ.deq;
            dmaWriteDataPipeOutQueue.enq(DataStream{
                data: zeroExtend(ds.data),
                startByteIdx: 0,
                byteNum: fromInteger(valueOf(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH)),
                isFirst: ds.isFirst,
                isLast: ds.isLast
            });
            if (ds.isLast) begin
                dmaWriteRespPipeOutQ.enq(True);
            end
            // $display(
            //     "time=%0t:", $time, toGreen(" mkRingbufDmaIfcConvertor forwardWriteData"),
            //     toBlue(", ds="), fshow(ds)
            // );
        endrule
    end



    rule forwardReadReq;
        let req = dmaReadReqPipeInQ.first;
        dmaReadReqPipeInQ.deq;

        IoChannelMemoryAccessMeta meta = IoChannelMemoryAccessMeta {
            addr: req.addr,
            totalLen: unpack((zeroExtend(req.zeroBasedDescReadCnt) + 1) << valueOf(TLog#(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH)))
        };
        dmaReadMetaPipeOutQueue.enq(meta);

        $display(
            "time=%0t:", $time, toGreen(" mkRingbufDmaIfcConvertor forwardReadReq"),
            toBlue(", meta="), fshow(meta)
        );
    endrule

    if (needWidthConvert) begin
        rule forwardReadResp;
            let wideDataDs = readDataWidthConvertBufReg;
            let targetIdx = readDataWidthConvertDescIdxInBeatTargetReg;
            let nowIdx = readDataWidthConvertDescIdxInBeatNowReg;
            if (nowIdx == 0) begin
                let dmaResp = dmaReadDataPipeInQueue.first;
                dmaReadDataPipeInQueue.deq;
                wideDataDs = dmaResp;
                targetIdx = truncate((dmaResp.byteNum >> valueOf(TLog#(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH))) - 1);

                immAssert(
                    // make sure the received payload is power of 2, and also can hold atleast one desc.
                    countOnes(dmaResp.byteNum) == 1 && dmaResp.byteNum >= fromInteger(valueOf(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH)),
                    "the received payload size must be power of two, and at least have one descriptor in it.",
                    $format("dmaResp=", fshow(dmaResp))
                );
            end
            

            let isLast = (targetIdx == nowIdx) && wideDataDs.isLast;

            let resp = RingbufDmaReadResp {
                data: DescDataStream {
                    data: truncate(wideDataDs.data),
                    startByteIdx: 0,
                    byteNum: fromInteger(valueOf(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH)),
                    isFirst: readDataWidthConvertIsFirstFlagReg,
                    isLast: isLast
                }
            };

            dmaReadRespPipeOutQ.enq(resp);
            wideDataDs.data = wideDataDs.data >> valueOf(USER_LOGIC_DESCRIPTOR_BIT_WIDTH);
            readDataWidthConvertBufReg <= wideDataDs;
            readDataWidthConvertDescIdxInBeatTargetReg <= targetIdx;
            readDataWidthConvertDescIdxInBeatNowReg <= (targetIdx == nowIdx) ? 0 : (nowIdx + 1);
            readDataWidthConvertIsFirstFlagReg <= isLast;

            $display(
                "time=%0t:", $time, toGreen(" mkRingbufDmaIfcConvertor forwardReadResp"),
                toBlue(", resp="), fshow(resp),
                toBlue(", nowIdx="), fshow(nowIdx),
                toBlue(", targetIdx="), fshow(targetIdx),
                toBlue(", wideDataDs="), fshow(wideDataDs)
            );
        endrule
    end
    else begin
        rule forwardReadResp;
            let dmaResp = dmaReadDataPipeInQueue.first;
            dmaReadDataPipeInQueue.deq;

            let resp = RingbufDmaReadResp {
                data: DescDataStream {
                    data: truncate(dmaResp.data),
                    startByteIdx: 0,
                    byteNum: fromInteger(valueOf(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH)),
                    isFirst: dmaResp.isFirst,
                    isLast: dmaResp.isLast
                }
            };

            dmaReadRespPipeOutQ.enq(resp);

            $display(
                "time=%0t:", $time, toGreen(" mkRingbufDmaIfcConvertor forwardReadResp"),
                toBlue(", resp="), fshow(resp)
            );
        endrule
    end

    interface dmaReadReqPipeIn = toPipeInB0(dmaReadReqPipeInQ);
    interface dmaReadRespPipeOut = toPipeOut(dmaReadRespPipeOutQ);
    interface dmaWriteReqPipeIn = toPipeInB0(dmaWriteReqPipeInQ);
    interface dmaWriteDataPipeIn = toPipeInB0(dmaWriteDataPipeInQ);
    interface dmaWriteRespPipeOut = toPipeOut(dmaWriteRespPipeOutQ);

    interface IoChannelMemoryMasterPipeB0In dmaMasterPipeIfc;
        interface DtldStreamMasterWritePipes  writePipeIfc ;
            interface writeMetaPipeOut = toPipeOut(dmaWriteMetaPipeOutQueue);
            interface writeDataPipeOut = toPipeOut(dmaWriteDataPipeOutQueue);
        endinterface
        interface DtldStreamMasterReadPipesB0In  readPipeIfc;
            interface readMetaPipeOut = toPipeOut(dmaReadMetaPipeOutQueue);
            interface readDataPipeIn = toPipeInB0(dmaReadDataPipeInQueue);
        endinterface
    endinterface
endmodule

typedef 3 DESCRIPTOR_MAX_SEGMENT_CNT;
typedef Bit#(TLog#(DESCRIPTOR_MAX_SEGMENT_CNT)) DescriptorSegmentIndex;

interface RingbufDescriptorReadProxy#(numeric type n_desc);
    interface PipeIn#(RingbufRawDescriptor) rawDescPipeIn;
    interface PipeOut#(Tuple2#(Vector#(n_desc, RingbufRawDescriptor), DescriptorSegmentIndex)) descFragsPipeOut;
endinterface

interface RingbufDescriptorWriteProxy#(numeric type n_desc);
    interface PipeOut#(RingbufRawDescriptor) rawDescPipeOut;
    interface PipeIn#(Tuple2#(Vector#(n_desc, RingbufRawDescriptor), DescriptorSegmentIndex)) descFragsPipeIn;
endinterface

module mkRingbufDescriptorReadProxy(RingbufDescriptorReadProxy#(n_desc));
    FIFOF#(RingbufRawDescriptor) ringbufQ <- mkLFIFOF;
    FIFOF#(Tuple2#(Vector#(n_desc, RingbufRawDescriptor), DescriptorSegmentIndex)) descFragQ <- mkFIFOF;

    Vector#(n_desc, Reg#(RingbufRawDescriptor)) segBuf <- replicateM(mkRegU);
    Reg#(DescriptorSegmentIndex) curSegCntReg <- mkReg(0);

    rule fillAllReqSegments;
        let rawDesc = ringbufQ.first;
        ringbufQ.deq;
        segBuf[0] <= rawDesc;
        RingbufDescCommonHead head = unpack(truncate(rawDesc >> 240));

        let hasMoreSegs = head.hasNextFrag;
        if (!hasMoreSegs) begin
            curSegCntReg <= 0;

            Vector#(n_desc, RingbufRawDescriptor) outVec = newVector;
            for (Integer idx = 0; idx < valueOf(n_desc) - 1; idx=idx+1) begin
                outVec[idx+1] = segBuf[idx];
            end
            outVec[0] = rawDesc;
            descFragQ.enq(tuple2(outVec, curSegCntReg));
        end 
        else begin
            curSegCntReg <= curSegCntReg + 1;
        end
        for (Integer idx = 0; idx < valueOf(n_desc) - 1; idx=idx+1) begin
            segBuf [idx+1] <= segBuf[idx];
        end

    endrule

    interface rawDescPipeIn = toPipeIn(ringbufQ);
    interface descFragsPipeOut = toPipeOut(descFragQ);
endmodule



module mkRingbufDescriptorWriteProxy(RingbufDescriptorWriteProxy#(n_desc));
    FIFOF#(RingbufRawDescriptor) ringbufQ <- mkFIFOF;
    FIFOF#(Tuple2#(Vector#(n_desc, RingbufRawDescriptor), DescriptorSegmentIndex)) descFragQ <- mkLFIFOF;

    Vector#(n_desc, Reg#(RingbufRawDescriptor)) segBuf <- replicateM(mkRegU);

    Reg#(Bool) isSendingFirstDescReg <- mkReg(True); 
    Reg#(DescriptorSegmentIndex) segCntReg <- mkRegU;
    
    rule sendFirstBeat if (isSendingFirstDescReg);
        let {descs, zeroBasedDescCnt} = descFragQ.first;
        descFragQ.deq;

        if (zeroBasedDescCnt != 0) begin
            isSendingFirstDescReg <= False;
        end

        segCntReg <= zeroBasedDescCnt;
        writeVReg(segBuf, descs);
        ringbufQ.enq(descs[0]);
    endrule

    rule sendExtraBeat if (!isSendingFirstDescReg);
        
        for (Integer idx = 0; idx < valueOf(n_desc) - 1; idx=idx+1) begin
            segBuf [idx] <= segBuf[idx+1];
        end
        if (segCntReg == 1) begin
            isSendingFirstDescReg <= True;
        end
        segCntReg <= segCntReg - 1;
    endrule

    interface rawDescPipeOut = toPipeOut(ringbufQ);
    interface descFragsPipeIn = toPipeIn(descFragQ);
endmodule



