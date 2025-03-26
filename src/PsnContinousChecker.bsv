import Vector :: *;
import BuildVector :: *;
import FIFOF :: *;
import ConfigReg :: * ;

import PrimUtils :: *;
import BasicDataTypes :: *;

import RdmaHeaders :: *;
import PrioritySearchBuffer :: *;


import ConnectableF :: *;


typedef TSub#(PSN_WIDTH, TLog#(ACK_WINDOW_STRIDE)) PSN_MERGE_WINDOW_BOUNDARY_WIDTH;
typedef Bit#(PSN_MERGE_WINDOW_BOUNDARY_WIDTH) PsnMergeWindowBoundary;
typedef Bit#(TLog#(ACK_BITMAP_WIDTH)) PsnMergeWindowBitOffset;

typedef struct {
    tData                               data;
    tBoundary                           leftBound;
    KeyQP                               qpnKeyPart;
} BitmapWindowStorageEntry#(type tData, type tBoundary) deriving(Bits, FShow);

typedef struct {
    QPN                                    qpn;
    PSN                                    psn;
} BitmapWindowStorageUpdateReq deriving(Bits, FShow);

typedef struct {
    tRowAddr                                    rowAddr;
    Bool                                        isShiftWindow;
    Bool                                        isShiftOutOfBoundary;
    tData                                       windowShiftedOutData;
    BitmapWindowStorageEntry#(tData, tBoundary) oldEntry;
    BitmapWindowStorageEntry#(tData, tBoundary) newEntry;
} BitmapWindowStorageUpdateResp#(type tRowAddr, type tData, type tBoundary) deriving(Bits, FShow);

typedef struct {
    tRowAddr    rowAddr;
    BitmapWindowStorageEntry#(tData, tBoundary) newEntry;
    Bool isReset;
} BitmapWindowStorageStageOneToTwoPipelineEntry#(type tRowAddr, type tData, type tBoundary) deriving(Bits, FShow);

typedef struct {
    tRowAddr        rowAddr;
    BitmapWindowStorageEntry#(tData, tBoundary) newEntry;
} BitmapWindowStorageStageTwoToThreePipelineEntry#(type tRowAddr, type tData, type tBoundary, type tShiftOffset) deriving(Bits, FShow);



interface BitmapWindowStorage#(type tRowAddr, type tData, type tBoundary, numeric type szStride);
    interface PipeInB0#(BitmapWindowStorageUpdateReq) reqPipeIn;
    interface PipeOut#(BitmapWindowStorageUpdateResp#(tRowAddr, tData, tBoundary)) respPipeOut;
    
    interface PipeIn#(tRowAddr)                                         readOnlyReqPipeIn;
    interface PipeOut#(BitmapWindowStorageEntry#(tData, tBoundary))     readOnlyRespPipeOut;

    interface PipeIn#(tRowAddr) resetReqPipeIn;
    // interface PipeOut#(Bit#(0)) resetRespPipeOut;
endinterface

module mkBitmapWindowStorage(BitmapWindowStorage#(tRowAddr, tData, tBoundary, szStride)) provisos (
        Bits#(tRowAddr, szRowAddr),
        Bits#(tData, szData),
        Bitwise#(tData),
        Literal#(tData),
        Bits#(tBoundary, szBoundary),
        Bounded#(tRowAddr),
        Literal#(tRowAddr),
        Eq#(tRowAddr),
        Arith#(tBoundary),
        Bitwise#(tBoundary),
        Ord#(tBoundary),
        Eq#(tBoundary),
        NumAlias#(TLog#(TDiv#(szData, szStride)), szShiftOffset),
        NumAlias#(TAdd#(1, szShiftOffset), szWideShiftOffset),
        Alias#(Bit#(szShiftOffset), tShiftOffset),
        Alias#(Bit#(szWideShiftOffset), tWideShiftOffset),
        Add#(a__, szShiftOffset, szBoundary),
        Add#(b__, szShiftOffset, TLog#(szData)),
        Add#(c__, szWideShiftOffset, szBoundary),
        Add#(d__, szWideShiftOffset, TLog#(szData)),
        FShow#(BitmapWindowStorageUpdateReq),
        Add#(f__, TLog#(szData), szBoundary),
        Add#(e__, TLog#(szStride), SizeOf#(PSN)),
        Add#(szBoundary, g__, SizeOf#(PSN)),
        FShow#(tRowAddr),
        FShow#(BitmapWindowStorageEntry#(tData, tBoundary)),
        Add#(h__, QP_INDEX_WIDTH_SUPPORTED, szRowAddr),
        Add#(szStride, i__, szData)
    );

    PipeInAdapterB0#(BitmapWindowStorageUpdateReq) reqPipeInQueue <- mkPipeInAdapterB0;
    FIFOF#(BitmapWindowStorageUpdateResp#(tRowAddr, tData, tBoundary)) respPipeOutQueue <- mkFIFOF;

    FIFOF#(tRowAddr)                                        readOnlyReqPipeInQueue <- mkLFIFOF;
    FIFOF#(BitmapWindowStorageEntry#(tData, tBoundary))     readOnlyRespPipeOutQueue <- mkFIFOF;

    Vector#(NUMERIC_TYPE_TWO, AutoInferBramQueuedOutput#(tRowAddr, BitmapWindowStorageEntry#(tData, tBoundary))) storage = newVector;
    storage[0] <- mkAutoInferBramQueuedOutput(False, "", "mkBitmapWindowStorage 0");
    storage[1] <- mkAutoInferBramQueuedOutput(False, "", "mkBitmapWindowStorage 1");


    // Pipeline Queues
    FIFOF#(BitmapWindowStorageStageOneToTwoPipelineEntry#(tRowAddr, tData, tBoundary)) stageOneToTwoPipelineQueue <- mkLFIFOF;
    FIFOF#(BitmapWindowStorageStageTwoToThreePipelineEntry#(tRowAddr, tData, tBoundary, tShiftOffset)) stageTwoToThreePipelineQueue <- mkLFIFOF;

    FIFOF#(void) readOnlyRespPipelineQueue <- mkLFIFOF;

    FIFOF#(tRowAddr) resetReqPipeInQ <- mkLFIFOF;

    PrioritySearchBuffer#(NUMERIC_TYPE_SIX, tRowAddr, BitmapWindowStorageEntry#(tData, tBoundary)) storageForwardBuffer <- mkPrioritySearchBuffer(valueOf(NUMERIC_TYPE_SIX));

    // rule printDebugInfo0;
    //     if (!respPipeOutQueueVec[0].notFull) $display("time=%0t, ", $time, "FullQueue: mkBitmapWindowStorage respPipeOutQueueVec[0]");
    //     if (!respPipeOutQueueVec[1].notFull) $display("time=%0t, ", $time, "FullQueue: mkBitmapWindowStorage respPipeOutQueueVec[1]");
    // endrule

    Reg#(Bool) bramInitedReg <- mkReg(False);
    Reg#(tRowAddr) bramInitPtrReg <- mkReg(0);

    let resetValue = BitmapWindowStorageEntry{
        leftBound: -1,
        data: -1,
        qpnKeyPart: 0
    };

    rule bramInit if (!bramInitedReg);
        if (bramInitPtrReg == maxBound) begin
            bramInitedReg <= True;
        end
        storage[0].write(bramInitPtrReg, resetValue);
        storage[1].write(bramInitPtrReg, resetValue);
        bramInitPtrReg <= unpack(pack(bramInitPtrReg) + 1);

        // $display("time=%0t", $time, "mkBitmapWindowStorage bramInit");
    endrule


    // Merge Pipeline Stage One
    rule sendBramQueryReqAndGenOneHotBitmap if (bramInitedReg);
        if (reqPipeInQueue.notEmpty) begin
            let req = reqPipeInQueue.first;
            reqPipeInQueue.deq;

            tRowAddr rowAddr = unpack(zeroExtend(pack(getIndexQP(req.qpn))));
            storage[0].putReadReq(rowAddr);

            tBoundary leftBound = unpack(truncateLSB(req.psn));
            Bit#(TLog#(szStride)) offsetInStride = truncate(req.psn);
            Bit#(szStride) oneHotStride = 1 << offsetInStride;
            tData bitmap = unpack(zeroExtendLSB(oneHotStride));

            let pipelineEntryOut = BitmapWindowStorageStageOneToTwoPipelineEntry {
                rowAddr: rowAddr,
                newEntry: BitmapWindowStorageEntry{
                    leftBound: leftBound,
                    data: bitmap,
                    qpnKeyPart: getKeyQP(req.qpn)
                },
                isReset: False
            };
            stageOneToTwoPipelineQueue.enq(pipelineEntryOut);

            // $display("time=%0t", $time, "mkBitmapWindowStorage 1 sendBramQueryReq", 
            //         ", req=", fshow(req)
            // );
        end
        else if (resetReqPipeInQ.notEmpty) begin
            resetReqPipeInQ.deq;
            let pipelineEntryOut = BitmapWindowStorageStageOneToTwoPipelineEntry {
                rowAddr: resetReqPipeInQ.first,
                newEntry: resetValue,
                isReset: True
            };
            stageOneToTwoPipelineQueue.enq(pipelineEntryOut);
        end
        
        
  

    endrule

    // Merge Pipeline Stage Two
    rule getBramQueryRespAndMergeThem if (bramInitedReg);

        let pipelineEntryIn = stageOneToTwoPipelineQueue.first;
        stageOneToTwoPipelineQueue.deq;
        let entryFromBram = ?;

        if (pipelineEntryIn.isReset) begin
            let bramWriteBackReq = BitmapWindowStorageStageTwoToThreePipelineEntry {
               rowAddr : pipelineEntryIn.rowAddr,
               newEntry: pipelineEntryIn.newEntry
            };
            stageTwoToThreePipelineQueue.enq(bramWriteBackReq);
            storageForwardBuffer.enq(pipelineEntryIn.rowAddr, pipelineEntryIn.newEntry);
        end
        else begin
            entryFromBram = storage[0].readRespPipeOut.first;
            storage[0].readRespPipeOut.deq;
            let entryFromForwardCacheMaybe <- storageForwardBuffer.search(pipelineEntryIn.rowAddr);
            let newestAlreadyExistEntry = entryFromBram;
            if (entryFromForwardCacheMaybe matches tagged Valid .entryFromForwardCache) begin
                newestAlreadyExistEntry = entryFromForwardCache;
            end

            let oldEntry = newestAlreadyExistEntry;

            tBoundary boundaryDelta     = pipelineEntryIn.newEntry.leftBound - newestAlreadyExistEntry.leftBound;
            tBoundary boundaryDeltaNeg  = newestAlreadyExistEntry.leftBound - pipelineEntryIn.newEntry.leftBound;

            tBoundary boundaryDeltaAbs = msb(boundaryDelta) == 0 ? boundaryDelta : boundaryDeltaNeg;

            let newEntry = pipelineEntryIn.newEntry;
            tData windowShiftedOutData = -1;

            let isShiftOutOfBoundary = msb(boundaryDelta) == 0 ? (
               boundaryDelta > fromInteger(valueOf(TDiv#(szData, szStride)))
               ) : (
                  boundaryDeltaNeg > fromInteger(valueOf(TDiv#(szData, szStride)))
                  );

            // New entry falls behind the current window
            let skipMergeStale = msb(boundaryDelta) == 1 && isShiftOutOfBoundary;

            if (skipMergeStale) begin
                let resp = BitmapWindowStorageUpdateResp {
                   rowAddr                 : pipelineEntryIn.rowAddr,
                   oldEntry                : oldEntry,
                   windowShiftedOutData    : windowShiftedOutData,
                   isShiftOutOfBoundary    : isShiftOutOfBoundary,
                   isShiftWindow           : False,
                   newEntry                : newEntry
                   };
                respPipeOutQueue.enq(resp);
            end
            else begin
                let isShiftWindow = boundaryDelta > 0;
                if (!isShiftWindow) begin
                    newEntry.leftBound = newestAlreadyExistEntry.leftBound;
                end
                Bit#(TLog#(szData)) bitShiftCnt = truncate(pack(boundaryDeltaAbs)) << valueOf(TLog#(szStride));
                tData allOneData = unpack(-1);
                if (isShiftOutOfBoundary) begin
                    newestAlreadyExistEntry.data = unpack(0);
                    windowShiftedOutData = unpack(0);
                end
                else if (isShiftWindow) begin
                    let tmpToShift = {pack(newestAlreadyExistEntry.data), pack(allOneData)};
                    tmpToShift = tmpToShift >> bitShiftCnt;
                    newestAlreadyExistEntry.data = unpack(truncateLSB(tmpToShift));
                    windowShiftedOutData = unpack(truncate(tmpToShift));
                end
                else begin
                    newEntry.data = newEntry.data >> bitShiftCnt;
                end

                newEntry.data = newEntry.data | newestAlreadyExistEntry.data;

                let resp = BitmapWindowStorageUpdateResp {
                   rowAddr                 : pipelineEntryIn.rowAddr,
                   oldEntry                : oldEntry,
                   windowShiftedOutData    : windowShiftedOutData,
                   isShiftOutOfBoundary    : isShiftOutOfBoundary,
                   isShiftWindow           : isShiftWindow,
                   newEntry                : newEntry
                   };
                respPipeOutQueue.enq(resp);

                let bramWriteBackReq = BitmapWindowStorageStageTwoToThreePipelineEntry {
                   rowAddr : pipelineEntryIn.rowAddr,
                   newEntry: newEntry
                   };
                stageTwoToThreePipelineQueue.enq(bramWriteBackReq);
                storageForwardBuffer.enq(pipelineEntryIn.rowAddr, newEntry);
            end
        end
    endrule

    // Merge Pipeline Stage Three
    rule doBramWriteBack if (bramInitedReg);
        let writeBackReq = stageTwoToThreePipelineQueue.first;
        stageTwoToThreePipelineQueue.deq;

        storage[0].write(writeBackReq.rowAddr, writeBackReq.newEntry);
        storage[1].write(writeBackReq.rowAddr, writeBackReq.newEntry);

        // $display("time=%0t", $time, "mkBitmapWindowStorage 3 doBramWriteBack", 
        //         ", writeBackReq=", fshow(writeBackReq)
        // );
    endrule

    rule handleReadOnlyReq if (bramInitedReg);
        let addr = readOnlyReqPipeInQueue.first;
        readOnlyReqPipeInQueue.deq;
        storage[1].putReadReq(addr);
        readOnlyRespPipelineQueue.enq(unpack(0));
    endrule

    rule handleReadOnlyResp if (bramInitedReg);
        readOnlyRespPipelineQueue.deq;
        let resp = storage[1].readRespPipeOut.first;
        storage[1].readRespPipeOut.deq;
        readOnlyRespPipeOutQueue.enq(resp);
    endrule

    interface reqPipeIn = toPipeInB0(reqPipeInQueue);
    interface respPipeOut = toPipeOut(respPipeOutQueue);

    interface readOnlyReqPipeIn     = toPipeIn(readOnlyReqPipeInQueue);
    interface readOnlyRespPipeOut   = toPipeOut(readOnlyRespPipeOutQueue);

    interface resetReqPipeIn = toPipeIn(resetReqPipeInQ);
endmodule



typedef struct {
    tRowAddr    rowAddr;
    tReq        reqData;
} AtomicUpdateStorageUpdateReq#(type tRowAddr, type tReq) deriving(Bits, FShow);

typedef struct {
    tRowAddr    rowAddr;
    tData       oldValue;
    tData       newValue;
} AtomicUpdateStorageUpdateResp#(type tRowAddr, type tData) deriving(Bits, FShow);

typedef struct {
    tData       data;
} AtomicUpdateStorageEntry#(type tData) deriving(Bits, FShow);

typedef struct {
    tRowAddr    rowAddr;
    tReq        reqData;
    Bool        isReset;
} AtomicUpdateStorageStageOneToTwoPipelineEntry#(type tRowAddr, type tReq) deriving(Bits, FShow);


typedef struct {
    tRowAddr                            rowAddr;
    AtomicUpdateStorageEntry#(tData)    newEntry;
} AtomicUpdateStorageStageTwoToThreePipelineEntry#(type tRowAddr, type tData) deriving(Bits, FShow);


interface AtomicUpdateStorage#(type tRowAddr, type tData, type tReq);
    interface PipeIn#(AtomicUpdateStorageUpdateReq#(tRowAddr, tReq)) reqPipeIn;
    interface PipeOut#(AtomicUpdateStorageUpdateResp#(tRowAddr, tData)) respPipeOut;
    
    interface PipeIn#(tRowAddr) readOnlyReqPipeIn;
    interface PipeOut#(tData)   readOnlyRespPipeOut;

    interface PipeIn#(tRowAddr) resetReqPipeIn;
    // interface PipeOut#(Bit#(0)) resetRespPipeOut;
endinterface

module mkAtomicUpdateStorage#(
        function tData updateFunc(tData oldVal, tReq reqVal, Bool isReset),
        String initRamFileBaseName
    )(AtomicUpdateStorage#(tRowAddr, tData, tReq)) provisos (
        Bits#(tRowAddr, szRowAddr),
        Bits#(tData, szData),
        Bits#(tReq, szReq),
        Bounded#(tRowAddr),
        Literal#(tRowAddr),
        Eq#(tRowAddr),
        FShow#(AtomicUpdateStorageUpdateReq#(tRowAddr, tReq)),
        FShow#(AtomicUpdateStorageEntry#(tData))
    );

    FIFOF#(AtomicUpdateStorageUpdateReq#(tRowAddr, tReq)) reqPipeInQueue <- mkLFIFOF;
    FIFOF#(AtomicUpdateStorageUpdateResp#(tRowAddr, tData)) respPipeOutQueue <- mkFIFOF;

    FIFOF#(tRowAddr) readOnlyReqPipeInQueue    <- mkLFIFOF;
    FIFOF#(tData)    readOnlyRespPipeOutQueue  <- mkFIFOF;


    Vector#(NUMERIC_TYPE_TWO, AutoInferBramQueuedOutput#(tRowAddr, AtomicUpdateStorageEntry#(tData))) storage = newVector;
    storage[0] <- mkAutoInferBramQueuedOutput(False, "", "mkAtomicUpdateStorage 0");
    storage[1] <- mkAutoInferBramQueuedOutput(False, "", "mkAtomicUpdateStorage 1");
    
    
    PrioritySearchBuffer#(NUMERIC_TYPE_SIX, tRowAddr, AtomicUpdateStorageEntry#(tData)) storageForwardBuffer <- mkPrioritySearchBuffer(valueOf(NUMERIC_TYPE_SIX));

    // Pipeline Queues

    FIFOF#(AtomicUpdateStorageStageOneToTwoPipelineEntry#(tRowAddr, tReq)) stageOneToTwoPipelineQueue <- mkLFIFOF;
    FIFOF#(AtomicUpdateStorageStageTwoToThreePipelineEntry#(tRowAddr, tData)) stageTwoToThreePipelineQueue <- mkLFIFOF;
    FIFOF#(void) readOnlyRespPipelineQueue <- mkLFIFOF;


    FIFOF#(tRowAddr) resetReqPipeInQ <- mkLFIFOF;


    Reg#(Bool) bramInitedReg <- mkReg(False);
    Reg#(tRowAddr) bramInitPtrReg <- mkReg(0);

    let resetValue = AtomicUpdateStorageEntry {
        data: updateFunc(?, ?, True)
    };

    rule bramInit if (!bramInitedReg);
        if (bramInitPtrReg == maxBound) begin
            bramInitedReg <= True;
        end
        storage[0].write(bramInitPtrReg, resetValue);
        storage[1].write(bramInitPtrReg, resetValue);
        bramInitPtrReg <= unpack(pack(bramInitPtrReg) + 1);
    endrule

    // Merge Pipeline Stage One
    rule sendBramQueryReq if (bramInitedReg);
        
        if (reqPipeInQueue.notEmpty) begin
            let pipelineEntryIn = reqPipeInQueue.first;
            reqPipeInQueue.deq;

            storage[0].putReadReq(pipelineEntryIn.rowAddr);

            let pipelineEntryOut = AtomicUpdateStorageStageOneToTwoPipelineEntry {
                rowAddr     : pipelineEntryIn.rowAddr,
                reqData     : pipelineEntryIn.reqData,
                isReset     : False
            };
            stageOneToTwoPipelineQueue.enq(pipelineEntryOut);
            
            // $display("time=%0t", $time, "mkAtomicUpdateStorage 1 sendBramQueryReq", 
            //         ", pipelineEntryIn=", fshow(pipelineEntryIn)
            // );
        end
        else if (resetReqPipeInQ.notEmpty) begin
            resetReqPipeInQ.deq;
            let pipelineEntryOut = AtomicUpdateStorageStageOneToTwoPipelineEntry {
                rowAddr: resetReqPipeInQ.first,
                reqData: unpack(0),
                isReset: True
            };
            stageOneToTwoPipelineQueue.enq(pipelineEntryOut);
        end
    endrule

    // Merge Pipeline Stage Two
    rule getBramQueryRespAndMergeThem if (bramInitedReg);

        let pipelineEntryIn = stageOneToTwoPipelineQueue.first;
        stageOneToTwoPipelineQueue.deq;


        let entryFromBram = ?;
        if (!pipelineEntryIn.isReset) begin
            entryFromBram = storage[0].readRespPipeOut.first;
            storage[0].readRespPipeOut.deq;
        end
        let entryFromForwardCacheMaybe <- storageForwardBuffer.search(pipelineEntryIn.rowAddr);

        let newestAlreadyExistEntry = entryFromBram;
        if (entryFromForwardCacheMaybe matches tagged Valid .entryFromForwardCache) begin
            newestAlreadyExistEntry = entryFromForwardCache;
        end
        let oldEntry = newestAlreadyExistEntry;

        let newEntry = newestAlreadyExistEntry;
        newEntry.data = updateFunc(newestAlreadyExistEntry.data, pipelineEntryIn.reqData, pipelineEntryIn.isReset);
                
        if (!pipelineEntryIn.isReset) begin
            let resp = AtomicUpdateStorageUpdateResp {
                rowAddr : pipelineEntryIn.rowAddr,
                oldValue: oldEntry.data,
                newValue: newEntry.data
            };
            respPipeOutQueue.enq(resp);
        end

        let bramWriteBackReq = AtomicUpdateStorageStageTwoToThreePipelineEntry {
            rowAddr: pipelineEntryIn.rowAddr,
            newEntry: newEntry
        };
        stageTwoToThreePipelineQueue.enq(bramWriteBackReq);
        storageForwardBuffer.enq(pipelineEntryIn.rowAddr, newEntry);

        // $display("time=%0t", $time, "mkAtomicUpdateStorage 2 doMerge", 
        //         ", pipelineEntryIn=", fshow(pipelineEntryIn),
        //         ", entryFromForwardCacheMaybe=", fshow(entryFromForwardCacheMaybe)
        // ); 

    endrule

    // Merge Pipeline Stage Three
    rule doBramWriteBack if (bramInitedReg);

        let writeBackReq = stageTwoToThreePipelineQueue.first;
        stageTwoToThreePipelineQueue.deq;

        storage[0].write(writeBackReq.rowAddr, writeBackReq.newEntry);
        storage[1].write(writeBackReq.rowAddr, writeBackReq.newEntry);
        
        // $display("time=%0t", $time, "mkAtomicUpdateStorage 3 doBramWriteBack", 
        //         ", writeBackReq=", fshow(writeBackReq)
        // );
    endrule

    
    rule handleReadOnlyReq if (bramInitedReg);
        let addr = readOnlyReqPipeInQueue.first;
        readOnlyReqPipeInQueue.deq;
        storage[1].putReadReq(addr);
        readOnlyRespPipelineQueue.enq(unpack(0));
    endrule

    rule handleReadOnlyResp if (bramInitedReg);
        readOnlyRespPipelineQueue.deq;
        let resp = storage[1].readRespPipeOut.first;
        storage[1].readRespPipeOut.deq;
        readOnlyRespPipeOutQueue.enq(resp.data);
    endrule

    interface reqPipeIn = toPipeIn(reqPipeInQueue);
    interface respPipeOut = toPipeOut(respPipeOutQueue);

    interface readOnlyReqPipeIn     = toPipeIn(readOnlyReqPipeInQueue);
    interface readOnlyRespPipeOut   = toPipeOut(readOnlyRespPipeOutQueue);

    interface resetReqPipeIn = toPipeIn(resetReqPipeInQ);
endmodule
