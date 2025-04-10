import ClientServer :: *;
import GetPut :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;
import Cntrs :: * ;

import DtldStream :: *;
import StreamDataTypes :: *;
import BasicDataTypes :: *;
import RdmaHeaders :: *;
import PrimUtils :: *;
import Settings :: *;
import RdmaUtils :: *;
import Arbitration :: *;
import Ringbuf :: *;
import ConnectableF :: *;
import Descriptors :: *;

import IoChannels :: *;
import FullyPipelineChecker :: *;

typedef ServerP#(addrType, dataType)                    BramRead#(type addrType, type dataType);
typedef ServerP#(Tuple2#(addrType, dataType), Bool)     BramWrite#(type addrType, type dataType);

interface BramCache#(type addrType, type dataType, numeric type splitCntExp);
    interface BramRead #(addrType, dataType)   read;
    interface BramWrite#(addrType, dataType)   write;
endinterface


module mkBramCache(BramCache#(addrType, dataType, splitCntExp)) provisos(
    Bits#(addrType, addrTypeSize),
    Bits#(dataType, dataTypeSize),
    Add#(subAddrTypeSize, splitCntExp, addrTypeSize),
    Alias#(Bit#(subAddrTypeSize), subAddrType),
    Alias#(Bit#(splitCntExp), subBlockIdxType),
    FShow#(addrType),
    FShow#(dataType)
);


    Vector#(TExp#(splitCntExp), AutoInferBram#(subAddrType, dataType)) subBramVec <- replicateM(mkAutoInferBramUG(False, "", "mkBramCache subBramVec"));

    FIFOF#(subBlockIdxType) orderKeepQueuePortA <- mkSizedFIFOF(6);

    PipeInAdapterB0#(addrType)   bramReadReqQ <- mkPipeInAdapterB0;
    FIFOF#(dataType)  bramReadRespQ <- mkLFIFOFWithFullAssert(DebugConf{name:"mkBramCache bramReadRespQ", enableDebug:True});

    PipeInAdapterB0#(Tuple2#(addrType, dataType))  bramWriteReqQ  <- mkPipeInAdapterB0;
    FIFOF#(Bool)                         bramWriteRespQ <- mkLFIFOF;


    rule handleBramReadReq;
        let cacheAddr = bramReadReqQ.first;
        bramReadReqQ.deq;

        subAddrType addr = unpack(truncate(pack(cacheAddr)));
        subBlockIdxType subIdx = truncateLSB(pack(cacheAddr));
        subBramVec[subIdx].putReadReq(addr);
        orderKeepQueuePortA.enq(subIdx);
        // $display("send BRAM read req to sub block =", fshow(subIdx), "addr=", fshow(addr));
    endrule

    rule handleBramReadResp;
        let subIdx = orderKeepQueuePortA.first;
        orderKeepQueuePortA.deq;
        let readRespData <- subBramVec[subIdx].getReadResp;
        bramReadRespQ.enq(readRespData);
        // $display("recv BRAM read resp from sub block=", fshow(subIdx) , ", res=", fshow(readRespData));
    endrule


    rule handleBramWriteReq;
        let {cacheAddr, writeData} = bramWriteReqQ.first;
        bramWriteReqQ.deq;
        
        subAddrType addr = unpack(truncate(pack(cacheAddr)));
        subBlockIdxType subIdx = truncateLSB(pack(cacheAddr));
        subBramVec[subIdx].write(addr, writeData);
        bramWriteRespQ.enq(True);
        // $display("send BRAM write req to sub block =", fshow(subIdx), "addr=", fshow(addr));
    endrule


    interface read =  toGPServerP(toPipeInB0(bramReadReqQ),  toPipeOut(bramReadRespQ));
    interface write = toGPServerP(toPipeInB0(bramWriteReqQ), toPipeOut(bramWriteRespQ));
endmodule


interface MemRegionTable;
    interface ServerP#(MrTableQueryReq, Maybe#(MemRegionTableEntry)) querySrv;
    interface ServerP#(MrTableModifyReq, MrTableModifyResp) modifySrv;
endinterface

(* synthesize *)
module mkMemRegionTable(MemRegionTable);
    BramCache#(IndexMR, Maybe#(MemRegionTableEntry), 1) mrTableStorage <- mkBramCache;
    QueuedServerP#(MrTableQueryReq, Maybe#(MemRegionTableEntry)) querySrvInst <- mkQueuedServerP(DebugConf{name: "mkMemRegionTable querySrvInst", enableDebug: False} );
    QueuedServerP#(MrTableModifyReq, MrTableModifyResp) modifySrvInst <- mkQueuedServerP(DebugConf{name: "MemRegionTable modifySrvInst", enableDebug: False});


    let mrTableStorageReadRequestAdapter <- mkPipeInB0ToPipeIn(mrTableStorage.read.request, 1);
    let mrTableStorageWriteRequestAdapter <- mkPipeInB0ToPipeIn(mrTableStorage.write.request, 1);

    rule handleQueryReq;
        let req <- querySrvInst.getReq;
        mrTableStorageReadRequestAdapter.enq(req.idx);
        $display("get MrTable query req: ", fshow(req));
    endrule

    // TODO: can we remove this rule?
    rule handleQueryResp;
        let resp = mrTableStorage.read.response.first;
        mrTableStorage.read.response.deq;
        querySrvInst.putResp(resp);
        $display("send MrTable query resp: ", fshow(resp));
    endrule

    rule handleModifyReq;
        let req <- modifySrvInst.getReq;
        mrTableStorageWriteRequestAdapter.enq(tuple2(req.idx, req.entry));
        $display("get MrTable update req: ", fshow(req));
    endrule

    rule handleModifyResp;
        let resp = mrTableStorage.write.response.first;
        mrTableStorage.write.response.deq;
        modifySrvInst.putResp(MrTableModifyResp{success: resp});
    endrule

    interface querySrv = querySrvInst.srv;
    interface modifySrv = modifySrvInst.srv;
endmodule


interface MemRegionTableTwoWayQuery;
    interface Vector#(NUMERIC_TYPE_TWO, ServerP#(MrTableQueryReq, Maybe#(MemRegionTableEntry))) querySrvVec;
    interface ServerP#(MrTableModifyReq, MrTableModifyResp) modifySrv;
endinterface

(* synthesize *)
module mkMemRegionTableTwoWayQuery(MemRegionTableTwoWayQuery);
    
    function Bool alwaysTrue(anytype resp);
        return True;
    endfunction

    MemRegionTable memRegionTable <- mkMemRegionTable;

    // MR Table need 10 beat for worst case to generate resp.
    // For in RQ path, packet must have payload, which is at least 4 beats, then the arbiter's keep order queue depth should be at least 3
    // For in SQ path, each WQE taks 2 beat, then the arbiter's keep order queue depth should be at least 5
    // so, we use depth 5 here.
    let arbiter <- mkServerToClientArbitFixPriorityP(
        5,
        True,
        alwaysTrue,
        alwaysTrue,
        DebugConf{name: "MemRegionTableTwoWayQuery", enableDebug: True}
    );

    mkConnection(arbiter.cltIfc, memRegionTable.querySrv);

    interface querySrvVec = arbiter.srvIfcVec;
    interface modifySrv = memRegionTable.modifySrv;

endmodule



interface MemRegionTableEightWayQuery;
    interface Vector#(NUMERIC_TYPE_EIGHT, ServerP#(MrTableQueryReq, Maybe#(MemRegionTableEntry))) querySrvVec;
    interface ServerP#(MrTableModifyReq, MrTableModifyResp) modifySrv;
endinterface

(* synthesize *)
module mkMemRegionTableEightWayQuery(MemRegionTableEightWayQuery);
    

    Vector#(NUMERIC_TYPE_FOUR, MemRegionTableTwoWayQuery) twoWayMemRegionTableVec <- replicateM(mkMemRegionTableTwoWayQuery);

    Vector#(NUMERIC_TYPE_EIGHT, ServerP#(MrTableQueryReq, Maybe#(MemRegionTableEntry))) querySrvVecInst = newVector;

    for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_EIGHT); idx = idx + 1) begin
        querySrvVecInst[idx] = twoWayMemRegionTableVec[idx / 2].querySrvVec[idx % 2 == 0 ? 0 : 1];
    end

    interface querySrvVec = querySrvVecInst;

    interface ServerP modifySrv;
        interface PipeInB0 request;
            method Action firstIn(MrTableModifyReq dataIn);
                for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_FOUR); idx = idx + 1) begin
                    twoWayMemRegionTableVec[idx].modifySrv.request.firstIn(dataIn);
                end
            endmethod
    
            method Action notEmptyIn(Bool val);
                for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_FOUR); idx = idx + 1) begin
                    twoWayMemRegionTableVec[idx].modifySrv.request.notEmptyIn(val);
                end
            endmethod
    
            // two QpContextTwoWayQuery should be in sync, so only care one's response is enough.
            method deqSignalOut = twoWayMemRegionTableVec[0].modifySrv.request.deqSignalOut;
        endinterface
    
        interface PipeOut response;
            // two QpContextTwoWayQuery should be in sync, so only care one's response is enough.
            method first = twoWayMemRegionTableVec[0].modifySrv.response.first;
            method Bool notEmpty = twoWayMemRegionTableVec[0].modifySrv.response.notEmpty;
              
            method Action deq;
                for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_FOUR); idx = idx + 1) begin
                    twoWayMemRegionTableVec[idx].modifySrv.response.deq;
                end
            endmethod
        endinterface
    endinterface
endmodule


// module mkBypassMemRegionTableForTest(MemRegionTable);
//     QueuedServer#(MrTableQueryReq, Maybe#(MemRegionTableEntry)) querySrvInst <- mkQueuedServer("mkMemRegionTable querySrvInst");
//     QueuedServer#(MrTableModifyReq, MrTableModifyResp) modifySrvInst <- mkQueuedServer("mkBypassMemRegionTableForTest modifySrvInst");

//     rule handleQueryReq;
//         let req <- querySrvInst.getReq;
//         let resp = tagged Valid unpack(0);
//         querySrvInst.putResp(resp);
//     endrule



//     rule handleModifyReq;
//         let req <- modifySrvInst.getReq;
//         immFail("not supported. this module is only for simple test", $format(""));
//     endrule

//     interface querySrv = querySrvInst.srv;
//     interface modifySrv = modifySrvInst.srv;
// endmodule



interface AddressTranslate;
    interface ServerP#(PgtAddrTranslateReq, ADDR) translateSrv;
    interface ServerP#(PgtModifyReq, PgtModifyResp) modifySrv;
endinterface

function PageOffset getPageOffset(ADDR addr);
    return truncate(addr);
endfunction

function ADDR restorePA(PageNumber pn, PageOffset po);
    return signExtend({ pn, po });
endfunction

function PageNumber getPageNumber(ADDR pa);
    return truncate(pa >> valueOf(PAGE_OFFSET_WIDTH));
endfunction

(* synthesize *)
module mkAddressTranslate(AddressTranslate);
    
    BramCache#(PTEIndex, PageTableEntry, 4) pageTableStorage <- mkBramCache;

    QueuedServerP#(PgtAddrTranslateReq, ADDR) translateSrvInst <- mkQueuedServerP(DebugConf{name: "translateSrvInst", enableDebug: False});
    QueuedServerP#(PgtModifyReq, PgtModifyResp) modifySrvInst <- mkQueuedServerP(DebugConf{name: "mkAddressTranslate modifySrvInst", enableDebug: False});

    FIFOF#(Bit#(PAGE_OFFSET_WIDTH)) offsetInputQ <- mkSizedFIFOF(10);

    let pageTableStorageReadRequestAdapter <- mkPipeInB0ToPipeIn(pageTableStorage.read.request, 1);
    let pageTableStorageWriteRequestAdapter <- mkPipeInB0ToPipeIn(pageTableStorage.write.request, 1);

    rule handleTranslateReq;
        let req <- translateSrvInst.getReq;
        let va = req.addrToTrans;

        let pageNumberOffset = getPageNumber(va) - getPageNumber(req.baseVA);
        PTEIndex pteIdx = req.pgtOffset + truncate(pageNumberOffset);


        pageTableStorageReadRequestAdapter.enq(pteIdx);
        offsetInputQ.enq(getPageOffset(va));

        $display("time=%0t, ", $time, " query AddressTranslate req = ", fshow(req), "pte index=", fshow(pteIdx));
    endrule

    rule handleTranslateResp;
        let pageOffset = offsetInputQ.first;
        offsetInputQ.deq;

        PageTableEntry pte = pageTableStorage.read.response.first;
        pageTableStorage.read.response.deq;

        let pa = restorePA(pte.pn, pageOffset);
        translateSrvInst.putResp(pa);

        $display("time=%0t, ", $time, "query AddressTranslate resp pageOffset= ", fshow(pageOffset), "pte =", fshow(pte));
        
    endrule

    rule handleModifyReq;
        let req <- modifySrvInst.getReq;

        pageTableStorageWriteRequestAdapter.enq(tuple2(req.idx, req.pte));
        $display("insert AddressTranslate = ", fshow(req));
    endrule

    rule handleModifyResp;
        let resp = pageTableStorage.write.response.first;
        pageTableStorage.write.response.deq;
        modifySrvInst.putResp(PgtModifyResp{success: resp});
        $display("insert AddressTranslate response = ", fshow(resp));
    endrule


    interface translateSrv = translateSrvInst.srv;
    interface modifySrv = modifySrvInst.srv;
endmodule






interface AddressTranslateTwoWayQuery;
    interface Vector#(NUMERIC_TYPE_TWO, ServerP#(PgtAddrTranslateReq, ADDR)) querySrvVec;
    interface ServerP#(PgtModifyReq, PgtModifyResp) modifySrv;
endinterface

(* synthesize *)
module mkAddressTranslateTwoWayQuery(AddressTranslateTwoWayQuery);
    
    function Bool alwaysTrue(anytype resp);
        return True;
    endfunction

    AddressTranslate addressTranslate <- mkAddressTranslate;

    // PGT need 10 beat for worst case to generate resp.
    // For RQ, packet must have payload, which is at least 4 beats, then the arbiter's keep order queue depth should be at least 3
    // For in SQ path, a big WQE can generate multi DMA read chunk and lead to query in every beat
    // so we use depth 10 here.
    let arbiter <- mkServerToClientArbitFixPriorityP(
        10,
        True,
        alwaysTrue,
        alwaysTrue,
        DebugConf{name: "AddressTranslateTwoWayQuery", enableDebug: True}
    );

    mkConnection(arbiter.cltIfc, addressTranslate.translateSrv);

    interface querySrvVec = arbiter.srvIfcVec;
    interface modifySrv = addressTranslate.modifySrv;

endmodule



interface AddressTranslateEightWayQuery;
    interface Vector#(NUMERIC_TYPE_EIGHT, ServerP#(PgtAddrTranslateReq, ADDR)) querySrvVec;
    interface ServerP#(PgtModifyReq, PgtModifyResp) modifySrv;
endinterface

(* synthesize *)
module mkAddressTranslateEightWayQuery(AddressTranslateEightWayQuery);
    

    Vector#(NUMERIC_TYPE_FOUR, AddressTranslateTwoWayQuery) twoWayAddressTranslateVec <- replicateM(mkAddressTranslateTwoWayQuery);
    Vector#(NUMERIC_TYPE_EIGHT, ServerP#(PgtAddrTranslateReq, ADDR)) querySrvVecInst = newVector;

    for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_EIGHT); idx = idx + 1) begin
        querySrvVecInst[idx] = twoWayAddressTranslateVec[idx / 2].querySrvVec[((idx % 2) == 0) ? 0 : 1];
    end

    interface querySrvVec = querySrvVecInst;

    interface ServerP modifySrv;
        interface PipeInB0 request;
            method Action firstIn(PgtModifyReq dataIn);
                for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_FOUR); idx = idx + 1) begin
                    twoWayAddressTranslateVec[idx].modifySrv.request.firstIn(dataIn);
                end
            endmethod
    
            method Action notEmptyIn(Bool val);
                for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_FOUR); idx = idx + 1) begin
                    twoWayAddressTranslateVec[idx].modifySrv.request.notEmptyIn(val);
                end
            endmethod
    
            // two QpContextTwoWayQuery should be in sync, so only care one's response is enough.
            method deqSignalOut = twoWayAddressTranslateVec[0].modifySrv.request.deqSignalOut;
        endinterface
    
        interface PipeOut response;
            // two QpContextTwoWayQuery should be in sync, so only care one's response is enough.
            method first = twoWayAddressTranslateVec[0].modifySrv.response.first;
            method Bool notEmpty = twoWayAddressTranslateVec[0].modifySrv.response.notEmpty;
              
            method Action deq;
                for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_FOUR); idx = idx + 1) begin
                    twoWayAddressTranslateVec[idx].modifySrv.response.deq;
                end
            endmethod
        endinterface
    endinterface
endmodule


// module mkBypassAddressTranslateForTest(AddressTranslate);
//     QueuedServer#(PgtAddrTranslateReq, ADDR) translateSrvInst <- mkQueuedServer("translateSrvInst");
//     QueuedServer#(PgtModifyReq, PgtModifyResp) modifySrvInst <- mkQueuedServer("mkBypassAddressTranslateForTest modifySrvInst");

//     rule handleTranslateReq;
//         let req <- translateSrvInst.getReq;
//         let va = req.addrToTrans;
//         let pa = va;
//         translateSrvInst.putResp(pa);
//     endrule

//     rule handleModifyReq;
//         let req <- modifySrvInst.getReq;
//         immFail("not supported. this module is only for simple test", $format(""));
//     endrule


//     interface translateSrv = translateSrvInst.srv;
//     interface modifySrv = modifySrvInst.srv;
// endmodule




interface MrAndPgtUpdater;
    interface PipeOut#(PgtUpdateDmaReadReq) dmaReadReqPipeOut;
    interface PipeIn#(PgtUpdateDmaReadResp) dmaReadRespPipeIn;

    interface ServerP#(RingbufRawDescriptor, Bool) mrAndPgtModifyDescSrv;
    interface ClientP#(MrTableModifyReq, MrTableModifyResp) mrModifyClt;
    interface ClientP#(PgtModifyReq, PgtModifyResp) pgtModifyClt;
endinterface


typedef enum {
    MrAndPgtManagerFsmStateIdle,
    MrAndPgtManagerFsmStateWaitMRModifyResponse,
    MrAndPgtManagerFsmStateHandlePGTUpdate,
    MrAndPgtManagerFsmStateWaitPGTUpdateLastResp
} MrAndPgtManagerFsmState deriving(Bits, Eq);

typedef 64 PGT_SECOND_STAGE_ENTRY_BIT_WIDTH_PADDED;
typedef TDiv#(PGT_SECOND_STAGE_ENTRY_BIT_WIDTH_PADDED, BYTE_WIDTH) PGT_SECOND_STAGE_ENTRY_BYTE_WIDTH_PADDED;

typedef TDiv#(PCIE_MAX_BYTE_IN_BURST, PGT_SECOND_STAGE_ENTRY_BYTE_WIDTH_PADDED) PGT_SECOND_STAGE_ENTRY_MAX_CNT_IN_DMA_BURST;
typedef Bit#(TLog#(PGT_SECOND_STAGE_ENTRY_MAX_CNT_IN_DMA_BURST)) ZeroBasedPgtSecondStageEntryCnt;

typedef Bit#(TLog#(TDiv#(PCIE_BYTE_PER_BEAT, PGT_SECOND_STAGE_ENTRY_BYTE_WIDTH_PADDED))) ZeroBasedPgtEntryCntInDmaBeat;

(* synthesize *)
module mkMrAndPgtUpdater(MrAndPgtUpdater);

    PipeInAdapterB0#(RingbufRawDescriptor) reqQ <- mkPipeInAdapterB0;
    FIFOF#(Bool) respQ <- mkLFIFOF;

    FIFOF#(PgtUpdateDmaReadReq) dmaReadReqQ <- mkFIFOF;
    FIFOF#(PgtUpdateDmaReadResp) dmaReadRespQ <- mkLFIFOF;

    QueuedClientP#(MrTableModifyReq, MrTableModifyResp) mrModifyCltInst <- mkQueuedClientP(DebugConf{name: "mrModifyCltInst", enableDebug: False});
    QueuedClientP#(PgtModifyReq, PgtModifyResp) pgtModifyCltInst <- mkQueuedClientP(DebugConf{name: "pgtModifyCltInst", enableDebug: False});
    

    Reg#(MrAndPgtManagerFsmState) state <- mkReg(MrAndPgtManagerFsmStateIdle);

    Reg#(DataStream) curBeatOfDataReg <- mkReg(unpack(0));
    Reg#(PTEIndex) curSecondStagePgtWriteIdxReg <- mkRegU;
    Reg#(ZeroBasedPgtSecondStageEntryCnt) zeroBasedPgtEntryTotalCntReg <- mkRegU;
    Reg#(ZeroBasedPgtEntryCntInDmaBeat) zeroBasedPgtEntryBeatCntReg <- mkReg(0);
    
    
    
    Integer bytesPerPgtSecondStageEntry = valueOf(PGT_SECOND_STAGE_ENTRY_BYTE_WIDTH_PADDED);

    // we set max inflight pgt update request is 2^3 = 8;
    Count#(Bit#(3)) pgtUpdateRespCounter <- mkCount(0);

    rule updateMrAndPgtStateIdle if (state == MrAndPgtManagerFsmStateIdle);
        let descRaw = reqQ.first;
        reqQ.deq;
        // $display("PGT get modify request", fshow(descRaw));

        RingbufDescCommonHead descComHdr = unpack(truncate(descRaw >> 240));

        case (unpack(truncate(descComHdr.opCode)))
            CmdQueueOpcodeUpdateMrTable: begin
                state <= MrAndPgtManagerFsmStateWaitMRModifyResponse;
                CmdQueueReqDescUpdateMrTable desc = unpack(descRaw);
                let modifyReq = MrTableModifyReq {
                    idx: lkey2IndexMR(unpack(desc.mrKey)),
                    entry: isZeroR(desc.mrLength) ?
                            tagged Invalid : 
                            tagged Valid MemRegionTableEntry {
                                pgtOffset: desc.pgtOffset,
                                baseVA: desc.mrBaseVA,
                                len: desc.mrLength,
                                accFlags: unpack(desc.accFlags),
                                keyPart: lkey2KeyPartMR(desc.mrKey)
                            }
                };
                mrModifyCltInst.putReq(modifyReq);
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware receive cmd queue descriptor: ", fshow(desc));
            end
            CmdQueueOpcodeUpdatePGT: begin
                CmdQueueReqDescUpdatePGT desc = unpack(descRaw);

                immAssertAddressAlign(desc.dmaAddr, AddressAlignAssertionMask512B, "PGT table update dma request");
                Length dmaReadLengthInByte = (zeroExtend(desc.zeroBasedEntryCount) + 1) << valueOf(TLog#(PGT_SECOND_STAGE_ENTRY_BYTE_WIDTH_PADDED)); 
                immAssertAddressAndLengthNotCross4kBoundary(desc.dmaAddr, dmaReadLengthInByte, "PGT table update dma request");
                immAssert(
                    dmaReadLengthInByte <= fromInteger(valueOf(PCIE_MAX_BYTE_IN_BURST)),
                    "PGT update dma request length exceed max PCIe read burst",
                    $format("dmaReadLengthInByte=", fshow(dmaReadLengthInByte), ", maxburst='h%x", valueOf(PCIE_MAX_BYTE_IN_BURST))
                );

                dmaReadReqQ.enq(PgtUpdateDmaReadReq{
                    addr: desc.dmaAddr,
                    zeroBasedEntryCount: truncate(desc.zeroBasedEntryCount)
                });
                curSecondStagePgtWriteIdxReg <= truncate(desc.startIndex);
                zeroBasedPgtEntryTotalCntReg <= truncate(desc.zeroBasedEntryCount);
                pgtUpdateRespCounter <= 0;
                state <= MrAndPgtManagerFsmStateHandlePGTUpdate;
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware receive cmd queue descriptor: ", fshow(desc));
            end
        endcase
    endrule

    rule handleMrModifyResp if (state == MrAndPgtManagerFsmStateWaitMRModifyResponse);
        let _ <- mrModifyCltInst.getResp;
        respQ.enq(True);
        state <= MrAndPgtManagerFsmStateIdle;
    endrule


    rule updatePgtStateHandlePGTUpdate if (state == MrAndPgtManagerFsmStateHandlePGTUpdate);
        // since this is the control path, it's not fully pipelined to make it simple.
        
        if (isZeroR(zeroBasedPgtEntryTotalCntReg)) begin
            state <= MrAndPgtManagerFsmStateWaitPGTUpdateLastResp;
            $display("addr translate modify second stage finished.");
        end
        zeroBasedPgtEntryTotalCntReg <= zeroBasedPgtEntryTotalCntReg - 1;
        
        let ds = ?;
        if (isZeroR(zeroBasedPgtEntryBeatCntReg)) begin
            let newFrag = dmaReadRespQ.first.data;
            dmaReadRespQ.deq;
            $display("beat deq");
            ds = newFrag;
        end
        else begin
            ds = curBeatOfDataReg;
        end

        zeroBasedPgtEntryBeatCntReg <= zeroBasedPgtEntryBeatCntReg + 1;

        let modifyReq = PgtModifyReq {
            idx: curSecondStagePgtWriteIdxReg,
            pte: PageTableEntry {
                pn: truncate(ds.data >> valueOf(PAGE_OFFSET_WIDTH))
            }
        };
        pgtModifyCltInst.putReq(modifyReq);
        pgtUpdateRespCounter.incr(1);
        $display("addr translate modify second stage:", fshow(modifyReq));
        curSecondStagePgtWriteIdxReg <= curSecondStagePgtWriteIdxReg + 1;

        ds.data = ds.data >> valueOf(PGT_SECOND_STAGE_ENTRY_BIT_WIDTH_PADDED);
        curBeatOfDataReg <= ds;
    endrule

    rule handlePgtModifyResp;
        $display("pgtModifyCltInst.getResp");
        let _ <- pgtModifyCltInst.getResp;
        pgtUpdateRespCounter.decr(1);
    endrule

    rule handlePgtModifyLastResp if (state == MrAndPgtManagerFsmStateWaitPGTUpdateLastResp);
        if (pgtUpdateRespCounter == 0) begin
            respQ.enq(True);
            state <= MrAndPgtManagerFsmStateIdle;
        end
    endrule

    interface mrAndPgtModifyDescSrv = toGPServerP(toPipeInB0(reqQ), toPipeOut(respQ));

    interface dmaReadReqPipeOut = toPipeOut(dmaReadReqQ);
    interface dmaReadRespPipeIn = toPipeIn(dmaReadRespQ);

    interface mrModifyClt = mrModifyCltInst.clt;
    interface pgtModifyClt = pgtModifyCltInst.clt;
endmodule



typedef struct {
    ADDR addr;
    ZeroBasedPgtSecondStageEntryCnt zeroBasedEntryCount;
} PgtUpdateDmaReadReq deriving(Bits, FShow);

typedef struct {
    DataStream data;
} PgtUpdateDmaReadResp deriving(Bits, FShow);





interface PgtUpdateDmaInterfaceConvertor;
    interface IoChannelMemoryMasterPipeB0In dmaSidePipeIfc;

    interface PipeInB0#(PgtUpdateDmaReadReq) dmaReadReqPipeIn;
    interface PipeOut#(PgtUpdateDmaReadResp) dmaReadRespPipeOut;
endinterface

module mkPgtUpdateDmaInterfaceConvertor(PgtUpdateDmaInterfaceConvertor);
    FIFOF#(IoChannelMemoryAccessMeta)       busReadMetaPipeOutQueue  <- mkFIFOF;
    PipeInAdapterB0#(IoChannelMemoryAccessDataStream) busReadDataPipeInQueue   <- mkPipeInAdapterB0;
    FIFOF#(IoChannelMemoryAccessMeta)       busWriteMetaPipeOutQueue <- mkFIFOF;
    FIFOF#(IoChannelMemoryAccessDataStream) busWriteDataPipeOutQueue <- mkFIFOF;

    PipeInAdapterB0#(PgtUpdateDmaReadReq)   dmaReadReqPipeInQ       <- mkPipeInAdapterB0;
    FIFOF#(PgtUpdateDmaReadResp)  dmaReadRespPipeOutQ     <- mkFIFOF;

    rule forwardReadReq;
        let req = dmaReadReqPipeInQ.first;
        dmaReadReqPipeInQ.deq;

        Length dmaReadLengthInByte = (zeroExtend(req.zeroBasedEntryCount) + 1) << valueOf(TLog#(PGT_SECOND_STAGE_ENTRY_BYTE_WIDTH_PADDED)); 

        let meta = IoChannelMemoryAccessMeta {
            addr: req.addr,
            totalLen: dmaReadLengthInByte
        };
        busReadMetaPipeOutQueue.enq(meta);
    endrule

    rule forwardReadResp;
        let resp = busReadDataPipeInQueue.first;
        busReadDataPipeInQueue.deq;

        let ds = PgtUpdateDmaReadResp {
            data: resp
        };

        dmaReadRespPipeOutQ.enq(ds);
    endrule

    interface IoChannelMemoryMasterPipeB0In dmaSidePipeIfc;
        interface DtldStreamMasterWritePipes writePipeIfc;
            interface writeMetaPipeOut = toPipeOut(busWriteMetaPipeOutQueue);
            interface writeDataPipeOut = toPipeOut(busWriteDataPipeOutQueue);
        endinterface
        interface DtldStreamMasterReadPipesB0In readPipeIfc;
            interface readMetaPipeOut = toPipeOut(busReadMetaPipeOutQueue);
            interface readDataPipeIn  = toPipeInB0(busReadDataPipeInQueue);
        endinterface
    endinterface

    interface dmaReadReqPipeIn = toPipeInB0(dmaReadReqPipeInQ);
    interface dmaReadRespPipeOut = toPipeOut(dmaReadRespPipeOutQ);
endmodule


