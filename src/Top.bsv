import Connectable :: *;
import FIFOF :: *;
import ClientServer :: *;
import GetPut :: *;
import Vector :: *;
import Clocks :: *;
import CommitIfc :: * ;

import ConnectableF :: *;
import RdmaUtils :: *;
import PrimUtils :: *;

import DtldStream :: *;
import StreamDataTypes :: *;
import BasicDataTypes :: *;
import IoChannels :: *;
import Arbitration :: *;
import PacketGenAndParse :: *;
import EthernetTypes :: *;
import PacketGenAndParse :: *;
import MemRegionAndAddressTranslate :: *;
import QPContext :: *;
import PayloadGenAndCon :: *;
import CsrRootConnector :: *;
import CsrFramework :: *;
import Ringbuf :: *;
import DescriptorParsers :: *;
import CsrAddress :: *;
import AutoAckGenerator :: *;
import SimpleNic :: *;
import CnpPacketGen :: *;

import EthernetFrameIO256 :: *;

import FullyPipelineChecker :: *;

import Settings :: *;
import Utils4Test :: *;

import SQ :: *;
import RQ :: *;

import RTilePcieAdaptor :: *;
import FTileMacAdaptor :: *;


interface BsvTop;
        (* always_ready, always_enabled *)
        interface RTilePcieAdaptorRx rtilePcieAdaptorRxRawIfc;
        (* always_ready, always_enabled *)
        interface RTilePcieAdaptorTx rtilePcieAdaptorTxRawIfc;

        (* always_ready, always_enabled *)
        interface FTileMacAdaptorRx ftileMacAdaptorRxRawIfc;
        (* always_ready, always_enabled *)
        interface FTileMacAdaptorTx ftileMacAdaptorTxRawIfc;
endinterface


(* synthesize *)
module mkBsvTop#(
        Clock ftileClk,
        Reset ftileRst,
        Reset partitionReset
    )(BsvTop);

    BsvTopOnlyHardIp            bsvTopOnlyHardIp            <- mkBsvTopOnlyHardIp(ftileClk, ftileRst);
    BsvTopWithoutHardIpInstance bsvTopWithoutHardIpInstance <- mkBsvTopWithoutHardIpInstance(partitionReset);


    mkConnection(bsvTopOnlyHardIp.rtilepcieStreamMasterIfc, bsvTopWithoutHardIpInstance.dmaSlavePipeIfc);
    mkConnection(bsvTopWithoutHardIpInstance.dmaMasterPipeIfcVec, bsvTopOnlyHardIp.rtilepcieStreamSlaveIfcVec);

    for (Integer idx = 0; idx < valueOf(HARDWARE_QP_CHANNEL_CNT); idx = idx + 1) begin
        // loopback test
        mkConnection(bsvTopWithoutHardIpInstance.qpEthDataStreamIfcVec[idx].dataPipeOut, bsvTopWithoutHardIpInstance.qpEthDataStreamIfcVec[idx].dataPipeIn);

        // mkConnection(bsvTopOnlyHardIp.ftilemacRxStreamPipeOutVec[idx], bsvTopWithoutHardIpInstance.qpEthDataStreamIfcVec[idx].dataPipeIn);
        // mkConnection(bsvTopOnlyHardIp.ftilemacTxStreamPipeInVec[idx], bsvTopWithoutHardIpInstance.qpEthDataStreamIfcVec[idx].dataPipeOut);
    end


    interface rtilePcieAdaptorRxRawIfc  = bsvTopOnlyHardIp.rtilePcieAdaptorRxRawIfc;
    interface rtilePcieAdaptorTxRawIfc  = bsvTopOnlyHardIp.rtilePcieAdaptorTxRawIfc;
    interface ftileMacAdaptorRxRawIfc   = bsvTopOnlyHardIp.ftileMacAdaptorRxRawIfc;
    interface ftileMacAdaptorTxRawIfc   = bsvTopOnlyHardIp.ftileMacAdaptorTxRawIfc;


endmodule


interface BsvTopOnlyHardIp;
    // to verilog side ===================================================
    
    (* always_ready, always_enabled *)
    interface RTilePcieAdaptorRx rtilePcieAdaptorRxRawIfc;
    (* always_ready, always_enabled *)
    interface RTilePcieAdaptorTx rtilePcieAdaptorTxRawIfc;

    (* always_ready, always_enabled *)
    interface FTileMacAdaptorRx ftileMacAdaptorRxRawIfc;
    (* always_ready, always_enabled *)
    interface FTileMacAdaptorTx ftileMacAdaptorTxRawIfc;

    // to bsv side =======================================================

    interface PcieBiDirUserDataStreamMasterPipes                                                    rtilepcieStreamMasterIfc;
    interface Vector#(RTILE_PCIE_USER_LOGIC_CHANNEL_CNT, PcieBiDirUserDataStreamSlavePipes)         rtilepcieStreamSlaveIfcVec;
    interface Vector#(FTILE_MAC_USER_LOGIC_CHANNEL_CNT,  PipeInB0#(FtileMacTxUserStream))           ftilemacTxStreamPipeInVec;
    interface Vector#(FTILE_MAC_USER_LOGIC_CHANNEL_CNT,  PipeOut#(FtileMacRxUserStream))            ftilemacRxStreamPipeOutVec;
    
endinterface

(* synthesize *)
module mkBsvTopOnlyHardIp#(
        Clock ftileClk,
        Reset ftileRst
    )(BsvTopOnlyHardIp);
    RTilePcieAdaptor rtilePcieAdaptor   <- mkRTilePcieAdaptor;
    RTilePcie        rtilePcie          <- mkRTilePcie;

    FTileMacAdaptor  ftileMacAdaptor    <- mkFTileMacAdaptor(clocked_by ftileClk, reset_by ftileRst);
    FTileMac         ftileMac           <- mkFTileMac;

    mkConnection(rtilePcieAdaptor.pcieRxPipeOut, rtilePcie.pcieRxPipeIn);
    mkConnection(rtilePcieAdaptor.pcieTxPipeIn, rtilePcie.pcieTxPipeOut);
    mkConnection(rtilePcieAdaptor.rxFlowControlReleaseReqPipeIn, rtilePcie.rxFlowControlReleaseReqPipeOut);   // already Nr
    mkConnection(rtilePcieAdaptor.txFlowControlConsumeReqPipeIn, rtilePcie.txFlowControlConsumeReqPipeOut);   // already Nr
    mkConnection(rtilePcieAdaptor.txFlowControlAvaliablePipeOut, rtilePcie.txFlowControlAvaliablePipeIn);

    SyncFIFOIfc#(FtileMacRxBeat) ftileRxSyncQueue <- mkSyncFIFOToCC(valueOf(NUMERIC_TYPE_FOUR), ftileClk, ftileRst);
    SyncFIFOIfc#(FtileMacTxBeat) ftileTxSyncQueue <- mkSyncFIFOFromCC(valueOf(NUMERIC_TYPE_FOUR), ftileClk);

    mkConnection(ftileMacAdaptor.ftilemacRxPipeOut, toPipeInSync(ftileRxSyncQueue));
    mkConnection(toPipeOutSync(ftileRxSyncQueue), ftileMac.ftilemacRxPipeIn, clocked_by ftileClk, reset_by ftileRst);

    mkConnection(toPipeInSync(ftileTxSyncQueue), ftileMac.ftilemacTxPipeOut);
    mkConnection(ftileMacAdaptor.ftilemacTxPipeIn, toPipeOutSync(ftileTxSyncQueue), clocked_by ftileClk, reset_by ftileRst);

    interface rtilePcieAdaptorRxRawIfc      = rtilePcieAdaptor.rx;
    interface rtilePcieAdaptorTxRawIfc      = rtilePcieAdaptor.tx;
    interface ftileMacAdaptorRxRawIfc       = ftileMacAdaptor.rx;
    interface ftileMacAdaptorTxRawIfc       = ftileMacAdaptor.tx;

    interface rtilepcieStreamMasterIfc      = rtilePcie.streamMasterIfc;
    interface rtilepcieStreamSlaveIfcVec    = rtilePcie.streamSlaveIfcVec;
    interface ftilemacTxStreamPipeInVec     = ftileMac.ftilemacTxStreamPipeInVec;
    interface ftilemacRxStreamPipeOutVec    = ftileMac.ftilemacRxStreamPipeOutVec;
endmodule


interface TopLevelDmaChannelMux;
    // upstream port
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemoryMasterPipe)   dmaMasterPipeIfcVec;

    // downstream port
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemorySlavePipe)   qpRingbufDmaSlavePipeIfcVec;
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemorySlavePipe)   qpDmaRequestSlaveIfcVec;
    interface IoChannelMemorySlavePipe cmdQueueRingbufDmaSlavePipeIfc;
    interface IoChannelMemorySlavePipe pgtUpdateDmaSlavePipe;
    interface IoChannelMemorySlavePipe simpleNicRingbufDmaSlavePipeIfc;
    interface IoChannelMemorySlavePipe simpleNicPacketDmaSlavePipeIfc;
endinterface

(* synthesize *)
module mkTopLevelDmaChannelMux(TopLevelDmaChannelMux);
    Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelThreeChannelDmaMux)       muxVector <- replicateM(mkDtldStreamArbiterSlave(256, 16, True, DebugConf{name: "mkTopLevelDmaChannelMux muxInst", enableDebug: False}));
    Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemoryMasterPipe)     dmaMasterPipeIfcVecInst = newVector;
    Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemorySlavePipe)      qpRingbufDmaSlavePipeIfcVecInst = newVector;
    Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemorySlavePipe)      qpDmaRequestSlaveIfcVecInst = newVector;

    for (Integer idx = 0; idx < valueOf(HARDWARE_QP_CHANNEL_CNT); idx = idx + 1) begin
        dmaMasterPipeIfcVecInst[idx] = muxVector[idx].masterIfc;
        qpRingbufDmaSlavePipeIfcVecInst[idx] = muxVector[idx].slaveIfcVec[0];
        qpDmaRequestSlaveIfcVecInst[idx] = muxVector[idx].slaveIfcVec[1];

        rule discardUselessPipeOutSignal;
            if (muxVector[idx].writeSourceChannelIdPipeOut.notEmpty) begin
                muxVector[idx].writeSourceChannelIdPipeOut.deq;
            end
            if (muxVector[idx].readSourceChannelIdPipeOut.notEmpty) begin
                muxVector[idx].readSourceChannelIdPipeOut.deq;
            end
        endrule
    end

    // upstream port
    interface dmaMasterPipeIfcVec = dmaMasterPipeIfcVecInst;

    // downstream port
    interface qpRingbufDmaSlavePipeIfcVec = qpRingbufDmaSlavePipeIfcVecInst;
    interface qpDmaRequestSlaveIfcVec = qpDmaRequestSlaveIfcVecInst;
    interface cmdQueueRingbufDmaSlavePipeIfc    = muxVector[0].slaveIfcVec[2]; // use channel 0 for cmd queue.
    interface pgtUpdateDmaSlavePipe             = muxVector[1].slaveIfcVec[2]; // use channel 1 for pgt update.
    interface simpleNicRingbufDmaSlavePipeIfc   = muxVector[2].slaveIfcVec[2]; // use channel 2 for simpleNic descriptor.
    interface simpleNicPacketDmaSlavePipeIfc    = muxVector[3].slaveIfcVec[2]; // use channel 3 for simpleNic payload.
endmodule

interface BsvTopWithoutHardIpInstance;
    interface IoChannelMemorySlavePipe dmaSlavePipeIfc;
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemoryMasterPipe)       dmaMasterPipeIfcVec;
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelBiDirStreamNoMetaPipe)  qpEthDataStreamIfcVec;
endinterface


(* synthesize *)
module mkBsvTopWithoutHardIpInstance#(Reset partitionReset)(BsvTopWithoutHardIpInstance);
    let qpMrPgtQpc <- mkQpMrPgtQpc(partitionReset);
    let ringbufAndDescriptorHandler <- mkRingbufAndDescriptorHandler;
    mkConnection(ringbufAndDescriptorHandler.wqePipeOut, qpMrPgtQpc.wqePipeIn);  // already Nr

    TopLevelDmaChannelMux topLevelDmaChannelMux <- mkTopLevelDmaChannelMux;
    

    let csrRootConnector <- mkCsrRootConnector;
    function ActionValue#(CsrNodeResultFork8) csrMatchFunc(CsrAccessReq req);
        actionvalue
            let regIdx = req.addr >> valueOf(BYTE_DWORD_CONVERT_SHIFT_NUM);
            let addrBlockMask = ~fromInteger(valueOf(CSR_ADDR_BLOCK_SIZE_FOR_RINGBUFS) - 1);
            let maskedAddr = addrBlockMask & regIdx;
            if (fromInteger(valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_RINGBUFS)) == maskedAddr) begin
                return tagged CsrNodeResultForward 0;
            end
            else begin
                return tagged CsrNodeResultForward 1;
            end
        endactionvalue
    endfunction
    CsrNodeFork8 csrNode <- mkCsrNode(csrMatchFunc, valueOf(NUMERIC_TYPE_TWO), "mkBsvTopWithoutHardIpInstance");
    
    mkConnection(csrRootConnector.csrNodeRootPortIfc, csrNode.upStreamPort);
    mkConnection(ringbufAndDescriptorHandler.csrUpStreamPort, csrNode.downStreamPortsVec[0]);
    mkConnection(qpMrPgtQpc.csrUpStreamPort, csrNode.downStreamPortsVec[1]);


    mkConnection(qpMrPgtQpc.pgtUpdateDmaMasterPipe, topLevelDmaChannelMux.pgtUpdateDmaSlavePipe);    // already Nr
    mkConnection(qpMrPgtQpc.qpDmaRequestMasterIfcVec, topLevelDmaChannelMux.qpDmaRequestSlaveIfcVec);  // already Nr
    mkConnection(ringbufAndDescriptorHandler.qpRingbufDmaMasterPipeIfcVec, topLevelDmaChannelMux.qpRingbufDmaSlavePipeIfcVec); // already Nr
    mkConnection(ringbufAndDescriptorHandler.cmdQueueRingbufDmaMasterPipeIfc, topLevelDmaChannelMux.cmdQueueRingbufDmaSlavePipeIfc);  // already Nr
    mkConnection(ringbufAndDescriptorHandler.simpleNicRingbufDmaMasterPipeIfc, topLevelDmaChannelMux.simpleNicRingbufDmaSlavePipeIfc);  // already Nr
    mkConnection(ringbufAndDescriptorHandler.qpResetReqPipeOut, qpMrPgtQpc.qpResetReqPipeIn);
    mkConnection(qpMrPgtQpc.metaReportDescPipeOutVec, ringbufAndDescriptorHandler.metaReportDescPipeInVec);
    mkConnection(ringbufAndDescriptorHandler.mrAndPgtManagerClt, qpMrPgtQpc.mrAndPgtModifyDescSrv);
    mkConnection(ringbufAndDescriptorHandler.qpcModifyClt, qpMrPgtQpc.qpContextUpdateSrv);

    mkConnection(qpMrPgtQpc.simpleNicRxDescPipeOut, ringbufAndDescriptorHandler.simpleNicRxDescPipeIn);
    mkConnection(qpMrPgtQpc.simpleNicTxDescPipeIn, ringbufAndDescriptorHandler.simpleNicTxDescPipeOut);
    mkConnection(qpMrPgtQpc.simpleNicPacketDmaMasterPipeIfc, topLevelDmaChannelMux.simpleNicPacketDmaSlavePipeIfc);
    rule forwardSetNetworkParamReqPipeOut;
        ringbufAndDescriptorHandler.setNetworkParamReqPipeOut.deq;
        qpMrPgtQpc.setLocalNetworkSettings(ringbufAndDescriptorHandler.setNetworkParamReqPipeOut.first);
    endrule
 

    interface dmaSlavePipeIfc = csrRootConnector.dmaSidePipeIfc;
    interface dmaMasterPipeIfcVec = topLevelDmaChannelMux.dmaMasterPipeIfcVec;
    interface qpEthDataStreamIfcVec = qpMrPgtQpc.qpEthDataStreamIfcVec;
endmodule



interface RingbufAndDescriptorHandler;
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemoryMasterPipe)       qpRingbufDmaMasterPipeIfcVec;
    interface IoChannelMemoryMasterPipe                                         cmdQueueRingbufDmaMasterPipeIfc;
    interface IoChannelMemoryMasterPipe                                         simpleNicRingbufDmaMasterPipeIfc;
    interface BlueRdmaCsrUpStreamPort                                           csrUpStreamPort;

    interface PipeOut#(WorkQueueElem)                                           wqePipeOut;
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, PipeInB0#(RingbufRawDescriptor)) metaReportDescPipeInVec;

    interface PipeIn#(RingbufRawDescriptor)                                     simpleNicRxDescPipeIn;
    interface PipeOut#(RingbufRawDescriptor)                                    simpleNicTxDescPipeOut;
    
    interface ClientP#(RingbufRawDescriptor, Bool)                               mrAndPgtManagerClt;
    interface ClientP#(WriteReqQPC, Bool)                                        qpcModifyClt;
    interface PipeOut#(LocalNetworkSettings)                                    setNetworkParamReqPipeOut;
    interface PipeOut#(IndexQP)                                                 qpResetReqPipeOut;
endinterface

(* synthesize *)
module mkRingbufAndDescriptorHandler(RingbufAndDescriptorHandler);

    Vector#(HARDWARE_QP_CHANNEL_CNT, RingbufH2cSlot4096) wqeRingbufVec = newVector;
    Vector#(HARDWARE_QP_CHANNEL_CNT, RingbufC2hSlot4096) rqMetaReportRingbufVec = newVector;
    Vector#(HARDWARE_QP_CHANNEL_CNT, WorkQueueDescParser) workQueueDescParserVec <- replicateM(mkWorkQueueDescParser);
    CommandQueueDescParserAndDispatcher cmdQueueDescParserAndDispatcher <- mkCommandQueueDescParserAndDispatcher;


    Vector#(HARDWARE_QP_CHANNEL_CNT, RingbufDmaIfcConvertor) qpRingbufDmaIfcConvertorVec <- replicateM(mkRingbufDmaIfcConvertor);
    Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemoryMasterPipe) qpRingbufDmaMasterPipeIfcVecInst = newVector;

    // SimpleRoundRobinPipeArbiter#(HARDWARE_QP_CHANNEL_CNT, RingbufRawDescriptor) metaReportDescCollector <- mkSimpleRoundRobinPipeArbiter(valueOf(MULTI_CHANNEL_TO_ONE_CHANNEL_ARBITER_BUFFER_DEPTH));
    Vector#(HARDWARE_QP_CHANNEL_CNT, PipeInB0#(RingbufRawDescriptor)) metaReportDescPipeInVecInst = newVector;
    

    // TODO: FIXME change 4 channel to one channel, infact, only first channel is working now.
    for (Integer idx = 0; idx < valueOf(HARDWARE_QP_CHANNEL_CNT); idx = idx + 1) begin
        wqeRingbufVec[idx] <- mkRingbufH2c(fromInteger(idx));
        rqMetaReportRingbufVec[idx] <- mkRingbufC2h(fromInteger(idx));

        mkConnection(wqeRingbufVec[idx].descPipeOut, workQueueDescParserVec[idx].rawDescPipeIn);
        mkConnection(wqeRingbufVec[idx].dmaReadReqPipeOut, qpRingbufDmaIfcConvertorVec[idx].dmaReadReqPipeIn);               // already Nr
        mkConnection(wqeRingbufVec[idx].dmaReadRespPipeIn, qpRingbufDmaIfcConvertorVec[idx].dmaReadRespPipeOut);

        mkConnection(rqMetaReportRingbufVec[idx].dmaWriteReqPipeOut, qpRingbufDmaIfcConvertorVec[idx].dmaWriteReqPipeIn);    // already Nr
        mkConnection(rqMetaReportRingbufVec[idx].dmaWriteDataPipeOut, qpRingbufDmaIfcConvertorVec[idx].dmaWriteDataPipeIn);  // already Nr
        mkConnection(rqMetaReportRingbufVec[idx].dmaWriteRespPipeIn, qpRingbufDmaIfcConvertorVec[idx].dmaWriteRespPipeOut);

        qpRingbufDmaMasterPipeIfcVecInst[idx] = qpRingbufDmaIfcConvertorVec[idx].dmaMasterPipeIfc;
    end
    
    
    
    // mkConnection(metaReportDescCollector.pipeOut, rqMetaReportRingbufVec[0].descPipeIn);
    metaReportDescPipeInVecInst[0] <- mkPipeInToPipeInB0(rqMetaReportRingbufVec[0].descPipeIn);

    RingbufH2cSlot4096 cmdReqQueueRingbuf <- mkRingbufH2c(4);
    RingbufC2hSlot4096 cmdRespQueueRingbuf <- mkRingbufC2h(4);
    RingbufDmaIfcConvertor cmdQueueRingbufDmaIfcConvertor <- mkRingbufDmaIfcConvertor;

    mkConnection(cmdReqQueueRingbuf.descPipeOut, cmdQueueDescParserAndDispatcher.reqRawDescPipeIn);
    mkConnection(cmdRespQueueRingbuf.descPipeIn, cmdQueueDescParserAndDispatcher.respRawDescPipeOut);

    mkConnection(cmdReqQueueRingbuf.dmaReadReqPipeOut, cmdQueueRingbufDmaIfcConvertor.dmaReadReqPipeIn);        // already Nr
    mkConnection(cmdReqQueueRingbuf.dmaReadRespPipeIn, cmdQueueRingbufDmaIfcConvertor.dmaReadRespPipeOut);
    mkConnection(cmdRespQueueRingbuf.dmaWriteReqPipeOut, cmdQueueRingbufDmaIfcConvertor.dmaWriteReqPipeIn);     // already Nr
    mkConnection(cmdRespQueueRingbuf.dmaWriteDataPipeOut, cmdQueueRingbufDmaIfcConvertor.dmaWriteDataPipeIn);   // already Nr
    mkConnection(cmdRespQueueRingbuf.dmaWriteRespPipeIn, cmdQueueRingbufDmaIfcConvertor.dmaWriteRespPipeOut);


    RingbufH2cSlot4096 simpleNicTxQueueRingbuf <- mkRingbufH2c(5);
    RingbufC2hSlot4096 simpleNicRxQueueRingbuf <- mkRingbufC2h(5);
    RingbufDmaIfcConvertor simpleNicRingbufDmaIfcConvertor <- mkRingbufDmaIfcConvertor;

    mkConnection(simpleNicTxQueueRingbuf.dmaReadReqPipeOut, simpleNicRingbufDmaIfcConvertor.dmaReadReqPipeIn);      // already Nr
    mkConnection(simpleNicTxQueueRingbuf.dmaReadRespPipeIn, simpleNicRingbufDmaIfcConvertor.dmaReadRespPipeOut);    
    mkConnection(simpleNicRxQueueRingbuf.dmaWriteReqPipeOut, simpleNicRingbufDmaIfcConvertor.dmaWriteReqPipeIn);    // already Nr
    mkConnection(simpleNicRxQueueRingbuf.dmaWriteDataPipeOut, simpleNicRingbufDmaIfcConvertor.dmaWriteDataPipeIn);  // already Nr
    mkConnection(simpleNicRxQueueRingbuf.dmaWriteRespPipeIn, simpleNicRingbufDmaIfcConvertor.dmaWriteRespPipeOut);
    




    function ActionValue#(CsrNodeResultFork8) csrMatchFunc(CsrAccessReq req);
        actionvalue
            if (req.isWrite) begin
                case (req.addr >> valueOf(BYTE_DWORD_CONVERT_SHIFT_NUM))
                    // QP ring bufs
                    fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_LOW)      + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        let t = wqeRingbufVec[0].controlRegs.addr;
                        t[31:0] = req.value;
                        wqeRingbufVec[0].controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_HIGH)     + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        let t = wqeRingbufVec[0].controlRegs.addr;
                        t[63:32] = req.value;
                        wqeRingbufVec[0].controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_HEAD)               + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        wqeRingbufVec[0].controlRegs.head <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_TAIL)               + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        wqeRingbufVec[0].controlRegs.tail <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_LOW)     + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        let t = rqMetaReportRingbufVec[0].controlRegs.addr;
                        t[31:0] = req.value;
                        rqMetaReportRingbufVec[0].controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_HIGH)    + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        let t = rqMetaReportRingbufVec[0].controlRegs.addr;
                        t[63:32] = req.value;
                        rqMetaReportRingbufVec[0].controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_HEAD)              + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        rqMetaReportRingbufVec[0].controlRegs.head <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_TAIL)              + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        rqMetaReportRingbufVec[0].controlRegs.tail <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_LOW)      + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = wqeRingbufVec[1].controlRegs.addr;
                    //     t[31:0] = req.value;
                    //     wqeRingbufVec[1].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_HIGH)     + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = wqeRingbufVec[1].controlRegs.addr;
                    //     t[63:32] = req.value;
                    //     wqeRingbufVec[1].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_HEAD)               + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     wqeRingbufVec[1].controlRegs.head <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_TAIL)               + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     wqeRingbufVec[1].controlRegs.tail <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_LOW)     + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = rqMetaReportRingbufVec[1].controlRegs.addr;
                    //     t[31:0] = req.value;
                    //     rqMetaReportRingbufVec[1].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_HIGH)    + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = rqMetaReportRingbufVec[1].controlRegs.addr;
                    //     t[63:32] = req.value;
                    //     rqMetaReportRingbufVec[1].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_HEAD)              + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     rqMetaReportRingbufVec[1].controlRegs.head <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_TAIL)              + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     rqMetaReportRingbufVec[1].controlRegs.tail <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_LOW)      + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = wqeRingbufVec[2].controlRegs.addr;
                    //     t[31:0] = req.value;
                    //     wqeRingbufVec[2].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_HIGH)     + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = wqeRingbufVec[2].controlRegs.addr;
                    //     t[63:32] = req.value;
                    //     wqeRingbufVec[2].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_HEAD)               + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     wqeRingbufVec[2].controlRegs.head <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_TAIL)               + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     wqeRingbufVec[2].controlRegs.tail <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_LOW)     + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = rqMetaReportRingbufVec[2].controlRegs.addr;
                    //     t[31:0] = req.value;
                    //     rqMetaReportRingbufVec[2].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_HIGH)    + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = rqMetaReportRingbufVec[2].controlRegs.addr;
                    //     t[63:32] = req.value;
                    //     rqMetaReportRingbufVec[2].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_HEAD)              + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     rqMetaReportRingbufVec[2].controlRegs.head <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_TAIL)              + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     rqMetaReportRingbufVec[2].controlRegs.tail <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_LOW)      + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = wqeRingbufVec[3].controlRegs.addr;
                    //     t[31:0] = req.value;
                    //     wqeRingbufVec[3].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_HIGH)     + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = wqeRingbufVec[3].controlRegs.addr;
                    //     t[63:32] = req.value;
                    //     wqeRingbufVec[3].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_HEAD)               + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     wqeRingbufVec[3].controlRegs.head <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_TAIL)               + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     wqeRingbufVec[3].controlRegs.tail <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_LOW)     + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = rqMetaReportRingbufVec[3].controlRegs.addr;
                    //     t[31:0] = req.value;
                    //     rqMetaReportRingbufVec[3].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_HIGH)    + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     let t = rqMetaReportRingbufVec[3].controlRegs.addr;
                    //     t[63:32] = req.value;
                    //     rqMetaReportRingbufVec[3].controlRegs.addr <= t;
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_HEAD)              + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     rqMetaReportRingbufVec[3].controlRegs.head <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_TAIL)              + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     rqMetaReportRingbufVec[3].controlRegs.tail <= unpack(truncate(req.value));
                    //     return tagged CsrNodeResultWriteHandled;
                    // end

                    // Cmd Queue ring bufs
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_REQ_Q_RINGBUF_BASE_ADDR_LOW) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        let t =cmdReqQueueRingbuf.controlRegs.addr;
                        t[31:0] = req.value;
                        cmdReqQueueRingbuf.controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_REQ_Q_RINGBUF_BASE_ADDR_HIGH) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        let t = cmdReqQueueRingbuf.controlRegs.addr;
                        t[63:32] = req.value;
                        cmdReqQueueRingbuf.controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_REQ_Q_RINGBUF_HEAD) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        cmdReqQueueRingbuf.controlRegs.head <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_REQ_Q_RINGBUF_TAIL) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        cmdReqQueueRingbuf.controlRegs.tail <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_RESP_Q_RINGBUF_BASE_ADDR_LOW) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        let t = cmdRespQueueRingbuf.controlRegs.addr;
                        t[31:0] = req.value;
                        cmdRespQueueRingbuf.controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_RESP_Q_RINGBUF_BASE_ADDR_HIGH) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        let t = cmdRespQueueRingbuf.controlRegs.addr;
                        t[63:32] = req.value;
                        cmdRespQueueRingbuf.controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_RESP_Q_RINGBUF_HEAD) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        cmdRespQueueRingbuf.controlRegs.head <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_RESP_Q_RINGBUF_TAIL) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        cmdRespQueueRingbuf.controlRegs.tail <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end

                    // Simple NIC Ringbuf
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_TX_Q_RINGBUF_BASE_ADDR_LOW) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        let t =simpleNicTxQueueRingbuf.controlRegs.addr;
                        t[31:0] = req.value;
                        simpleNicTxQueueRingbuf.controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_TX_Q_RINGBUF_BASE_ADDR_HIGH) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        let t = simpleNicTxQueueRingbuf.controlRegs.addr;
                        t[63:32] = req.value;
                        simpleNicTxQueueRingbuf.controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_TX_Q_RINGBUF_HEAD) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        simpleNicTxQueueRingbuf.controlRegs.head <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_TX_Q_RINGBUF_TAIL) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        simpleNicTxQueueRingbuf.controlRegs.tail <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_RX_Q_RINGBUF_BASE_ADDR_LOW) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        let t = simpleNicRxQueueRingbuf.controlRegs.addr;
                        t[31:0] = req.value;
                        simpleNicRxQueueRingbuf.controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_RX_Q_RINGBUF_BASE_ADDR_HIGH) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        let t = simpleNicRxQueueRingbuf.controlRegs.addr;
                        t[63:32] = req.value;
                        simpleNicRxQueueRingbuf.controlRegs.addr <= t;
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_RX_Q_RINGBUF_HEAD) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        simpleNicRxQueueRingbuf.controlRegs.head <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_RX_Q_RINGBUF_TAIL) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        simpleNicRxQueueRingbuf.controlRegs.tail <= unpack(truncate(req.value));
                        return tagged CsrNodeResultWriteHandled;
                    end

                    default: begin
                        return tagged CsrNodeResultNotMatched;
                    end
                endcase
            end
            else begin
                case (req.addr >> valueOf(BYTE_DWORD_CONVERT_SHIFT_NUM))
                    // QP ring bufs
                    fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_LOW)      + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: wqeRingbufVec[0].controlRegs.addr[31:0]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_HIGH)     + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: wqeRingbufVec[0].controlRegs.addr[63:32]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_HEAD)               + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(wqeRingbufVec[0].controlRegs.head)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_TAIL)               + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(wqeRingbufVec[0].controlRegs.tail)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_LOW)     + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: rqMetaReportRingbufVec[0].controlRegs.addr[31:0]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_HIGH)    + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: rqMetaReportRingbufVec[0].controlRegs.addr[63:32]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_HEAD)              + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(rqMetaReportRingbufVec[0].controlRegs.head)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_TAIL)              + 0 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(rqMetaReportRingbufVec[0].controlRegs.tail)))};
                    end

                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_LOW)      + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: wqeRingbufVec[1].controlRegs.addr[31:0]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_HIGH)     + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: wqeRingbufVec[1].controlRegs.addr[63:32]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_HEAD)               + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(wqeRingbufVec[1].controlRegs.head)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_TAIL)               + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(wqeRingbufVec[1].controlRegs.tail)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_LOW)     + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: rqMetaReportRingbufVec[1].controlRegs.addr[31:0]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_HIGH)    + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: rqMetaReportRingbufVec[1].controlRegs.addr[63:32]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_HEAD)              + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(rqMetaReportRingbufVec[1].controlRegs.head)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_TAIL)              + 1 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(rqMetaReportRingbufVec[1].controlRegs.tail)))};
                    // end

                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_LOW)      + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: wqeRingbufVec[2].controlRegs.addr[31:0]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_HIGH)     + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: wqeRingbufVec[2].controlRegs.addr[63:32]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_HEAD)               + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(wqeRingbufVec[2].controlRegs.head)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_TAIL)               + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(wqeRingbufVec[2].controlRegs.tail)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_LOW)     + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: rqMetaReportRingbufVec[2].controlRegs.addr[31:0]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_HIGH)    + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: rqMetaReportRingbufVec[2].controlRegs.addr[63:32]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_HEAD)              + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(rqMetaReportRingbufVec[2].controlRegs.head)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_TAIL)              + 2 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(rqMetaReportRingbufVec[2].controlRegs.tail)))};
                    // end

                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_LOW)      + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: wqeRingbufVec[3].controlRegs.addr[31:0]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_BASE_ADDR_HIGH)     + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: wqeRingbufVec[3].controlRegs.addr[63:32]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_HEAD)               + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(wqeRingbufVec[3].controlRegs.head)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_WQE_RINGBUF_TAIL)               + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(wqeRingbufVec[3].controlRegs.tail)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_LOW)     + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: rqMetaReportRingbufVec[3].controlRegs.addr[31:0]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_BASE_ADDR_HIGH)    + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: rqMetaReportRingbufVec[3].controlRegs.addr[63:32]};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_HEAD)              + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(rqMetaReportRingbufVec[3].controlRegs.head)))};
                    // end
                    // fromInteger(valueOf(CSR_ADDR_OFFSET_RECV_RINGBUF_TAIL)              + 3 * valueOf(CSR_ADDR_BLOCK_SIZE_FOR_EACH_QP) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_QP)): begin
                    //     return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(rqMetaReportRingbufVec[3].controlRegs.tail)))};
                    // end

                    //  Cmd Queue ring bufs
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_REQ_Q_RINGBUF_BASE_ADDR_LOW) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: cmdReqQueueRingbuf.controlRegs.addr[31:0]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_REQ_Q_RINGBUF_BASE_ADDR_HIGH) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: cmdReqQueueRingbuf.controlRegs.addr[63:32]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_REQ_Q_RINGBUF_HEAD) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(cmdReqQueueRingbuf.controlRegs.head)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_REQ_Q_RINGBUF_TAIL) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(cmdReqQueueRingbuf.controlRegs.tail)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_RESP_Q_RINGBUF_BASE_ADDR_LOW) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: cmdRespQueueRingbuf.controlRegs.addr[31:0]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_RESP_Q_RINGBUF_BASE_ADDR_HIGH) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: cmdRespQueueRingbuf.controlRegs.addr[63:32]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_RESP_Q_RINGBUF_HEAD) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(cmdRespQueueRingbuf.controlRegs.head)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_CMD_RESP_Q_RINGBUF_TAIL) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_CMDQ)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(cmdRespQueueRingbuf.controlRegs.tail)))};
                    end
                    
                    // Simple NIC Ringbuf
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_TX_Q_RINGBUF_BASE_ADDR_LOW) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: simpleNicTxQueueRingbuf.controlRegs.addr[31:0]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_TX_Q_RINGBUF_BASE_ADDR_HIGH) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: simpleNicTxQueueRingbuf.controlRegs.addr[63:32]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_TX_Q_RINGBUF_HEAD) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(simpleNicTxQueueRingbuf.controlRegs.head)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_TX_Q_RINGBUF_TAIL) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(simpleNicTxQueueRingbuf.controlRegs.tail)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_RX_Q_RINGBUF_BASE_ADDR_LOW) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: simpleNicRxQueueRingbuf.controlRegs.addr[31:0]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_RX_Q_RINGBUF_BASE_ADDR_HIGH) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: simpleNicRxQueueRingbuf.controlRegs.addr[63:32]};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_RX_Q_RINGBUF_HEAD) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(simpleNicRxQueueRingbuf.controlRegs.head)))};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_SIMPLE_NIC_RX_Q_RINGBUF_TAIL) + valueOf(CSR_ADDR_BLOCK_START_ADDR_FOR_SIMPLE_NIC)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: unpack(zeroExtend(pack(simpleNicRxQueueRingbuf.controlRegs.tail)))};
                    end
                    default: begin
                        return tagged CsrNodeResultNotMatched;
                    end
                endcase
            end
        endactionvalue
    endfunction
    CsrNodeFork8 csrNode <- mkCsrNode(csrMatchFunc, valueOf(NUMERIC_TYPE_TWO), "mkRingbufAndDescriptorHandler");


    interface qpRingbufDmaMasterPipeIfcVec = qpRingbufDmaMasterPipeIfcVecInst;
    interface cmdQueueRingbufDmaMasterPipeIfc = cmdQueueRingbufDmaIfcConvertor.dmaMasterPipeIfc;
    interface simpleNicRingbufDmaMasterPipeIfc = simpleNicRingbufDmaIfcConvertor.dmaMasterPipeIfc;
    interface csrUpStreamPort = csrNode.upStreamPort;
    
    interface wqePipeOut = workQueueDescParserVec[0].workReqPipeOut;
    interface metaReportDescPipeInVec = metaReportDescPipeInVecInst;

    interface simpleNicRxDescPipeIn = simpleNicRxQueueRingbuf.descPipeIn;
    interface simpleNicTxDescPipeOut = simpleNicTxQueueRingbuf.descPipeOut;

    interface mrAndPgtManagerClt = cmdQueueDescParserAndDispatcher.mrAndPgtManagerClt;
    interface qpcModifyClt = cmdQueueDescParserAndDispatcher.qpcModifyClt;
    interface setNetworkParamReqPipeOut = cmdQueueDescParserAndDispatcher.setNetworkParamReqPipeOut;
    interface qpResetReqPipeOut = cmdQueueDescParserAndDispatcher.qpResetReqPipeOut;
endmodule


interface QpMrPgtQpc;
    interface BlueRdmaCsrUpStreamPort                   csrUpStreamPort;

    // DMA interfaces
    interface IoChannelMemoryMasterPipe pgtUpdateDmaMasterPipe;
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemoryMasterPipe)           qpDmaRequestMasterIfcVec;
    interface IoChannelMemoryMasterPipe                                             simpleNicPacketDmaMasterPipeIfc;

    interface PipeIn#(WorkQueueElem)                                                wqePipeIn;
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, PipeOut#(RingbufRawDescriptor))      metaReportDescPipeOutVec;
    interface Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelBiDirStreamNoMetaPipe)      qpEthDataStreamIfcVec;

    interface PipeOut#(RingbufRawDescriptor)                                        simpleNicRxDescPipeOut;
    interface PipeIn#(RingbufRawDescriptor)                                         simpleNicTxDescPipeIn;

    interface PipeIn#(IndexQP)                                                      qpResetReqPipeIn;
        
    interface ServerP#(WriteReqQPC, Bool)                                            qpContextUpdateSrv;
    interface ServerP#(RingbufRawDescriptor, Bool)                                   mrAndPgtModifyDescSrv;
    method Action setLocalNetworkSettings(LocalNetworkSettings networkSettings); 
endinterface



(* synthesize *)
module mkQpMrPgtQpc#(Reset partitionReset)(QpMrPgtQpc);
    FIFOF#(WriteReqQPC) qpContextUpdateReqQueue <- mkFIFOF;
    FIFOF#(Bool) qpContextUpdateRespQueue <- mkLFIFOF;
    Vector#(HARDWARE_QP_CHANNEL_CNT, PipeOut#(RingbufRawDescriptor)) metaReportDescPipeOutVecInst = newVector;

    QpContext qpContext <- mkQpContext;
    MemRegionTableTwoWayQuery mrTable <- mkMemRegionTableTwoWayQuery;
    AddressTranslateTwoWayQuery addrTranslator <- mkAddressTranslateTwoWayQuery;
    MrAndPgtUpdater mrAndPgtUpdater <- mkMrAndPgtUpdater;
    PgtUpdateDmaInterfaceConvertor pgtUpdateDmaInterfaceConvertor <- mkPgtUpdateDmaInterfaceConvertor;
    SimpleNic simpleNic <- mkSimpleNic;


    SqGroup sqGroup <- mkSqGroup;
    RqGroup rqGroup <- mkRqGroup;
    Vector#(HARDWARE_QP_CHANNEL_CNT, DtldStreamNoMetaArbiterSlave#(NUMERIC_TYPE_TWO, DATA)) ethTxStreamArbiterVec <- replicateM(mkDtldStreamNoMetaArbiterSlave(valueOf(NUMERIC_TYPE_TWO)));


    Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelMemoryMasterPipe)             qpDmaRequestMasterIfcVecInst    = newVector;
    Vector#(HARDWARE_QP_CHANNEL_CNT, IoChannelBiDirStreamNoMetaPipe)        qpEthDataStreamIfcVecInst       = newVector;

    Vector#(HARDWARE_QP_CHANNEL_CNT, EthernetPacketGenerator)    ethernetPacketGenVecInst           <- replicateM(mkEthernetPacketGenerator);
    Vector#(HARDWARE_QP_CHANNEL_CNT, PacketGenReqArbiter)        packetGenReqArbiterVecInst         <- replicateM(mkPacketGenReqArbiter);

    mkConnection(mrAndPgtUpdater.dmaReadReqPipeOut, pgtUpdateDmaInterfaceConvertor.dmaReadReqPipeIn);   // already Nr
    mkConnection(mrAndPgtUpdater.dmaReadRespPipeIn, pgtUpdateDmaInterfaceConvertor.dmaReadRespPipeOut);    
    mkConnection(mrAndPgtUpdater.mrModifyClt, mrTable.modifySrv);
    mkConnection(mrAndPgtUpdater.pgtModifyClt, addrTranslator.modifySrv);

    mkConnection(rqGroup.simpleNicRxStreamPipeOut, simpleNic.rawEthernetPacketPipeIn);

    for (Integer idx = 0; idx < valueOf(HARDWARE_QP_CHANNEL_CNT); idx = idx + 1) begin
        // Connection for ethernet packet generate

        mkConnection(sqGroup.macIpUdpMetaPipeOutVec[idx], packetGenReqArbiterVecInst[idx].macIpUdpMetaPipeInVec[0]);
        mkConnection(sqGroup.rdmaPacketMetaPipeOutVec[idx], packetGenReqArbiterVecInst[idx].rdmaPacketMetaPipeInVec[0]);
        mkConnection(sqGroup.rdmaPayloadPipeOutVec[idx], packetGenReqArbiterVecInst[idx].rdmaPayloadPipeInVec[0]);

        // -------------------------------------------------------------------
        // | WARN： CNP Packet gen's output signal is ignored since in loopback mode, there is no ECN. no make the PnR more quickly, we "remove" this module for now.
        // -------------------------------------------------------------------
        // mkConnection(cnpPacketGeneratorVec[idx].macIpUdpMetaPipeOut, packetGenReqArbiterVecInst[idx].macIpUdpMetaPipeInVec[1]);
        // mkConnection(cnpPacketGeneratorVec[idx].rdmaPacketMetaPipeOut, packetGenReqArbiterVecInst[idx].rdmaPacketMetaPipeInVec[1]);
        // mkConnection(cnpPacketGeneratorVec[idx].rdmaPayloadPipeOut, packetGenReqArbiterVecInst[idx].rdmaPayloadPipeInVec[1]);

        mkConnection(packetGenReqArbiterVecInst[idx].macIpUdpMetaPipeOut, ethernetPacketGenVecInst[idx].macIpUdpMetaPipeIn);
        mkConnection(packetGenReqArbiterVecInst[idx].rdmaPacketMetaPipeOut, ethernetPacketGenVecInst[idx].rdmaPacketMetaPipeIn);
        mkConnection(packetGenReqArbiterVecInst[idx].rdmaPayloadPipeOut, ethernetPacketGenVecInst[idx].rdmaPayloadPipeIn);

        mkConnection(ethernetPacketGenVecInst[idx].ethernetPacketPipeOut, ethTxStreamArbiterVec[idx].pipeInIfcVec[0]);

        qpEthDataStreamIfcVecInst[idx] = (
                interface IoChannelBiDirStreamNoMetaPipe
                    interface dataPipeIn = rqGroup.ethernetFramePipeInVec[idx];
                    interface dataPipeOut = ethTxStreamArbiterVec[idx].pipeOutIfc;
                endinterface
            );

        // RDMA payload DMA Ifc
        qpDmaRequestMasterIfcVecInst[idx] = (
            interface IoChannelMemoryMasterPipe;
                interface writePipeIfc = rqGroup.rqDmaWriteRequestMasterIfcVec[idx];
                interface readPipeIfc = sqGroup.sqDmaReadRequestMasterIfcVec[idx];
            endinterface
        );

        rule deqNotused;
            ethTxStreamArbiterVec[idx].sourceChannelIdPipeOut.deq;
        endrule
    end

    // QPContext, MR Table and PGT
    mkConnection(rqGroup.qpcQueryCltIfc, qpContext.querySrv);

    mkConnection(sqGroup.mrQueryCltIfc, mrTable.querySrvVec[0]);
    mkConnection(rqGroup.mrQueryCltIfc, mrTable.querySrvVec[1]);

    mkConnection(rqGroup.pgtQueryCltIfc, addrTranslator.querySrvVec[0]);
    mkConnection(sqGroup.pgtQueryCltIfc, addrTranslator.querySrvVec[1]);

    // TODO: FIXME: change the following vector to a scalar, since only the firta channel is used
    metaReportDescPipeOutVecInst[0] = rqGroup.metaReportDescPipeOut;



    

    mkConnection(rqGroup.autoAckMacIpUdpMetaPipeOut, packetGenReqArbiterVecInst[0].macIpUdpMetaPipeInVec[2]);
    mkConnection(rqGroup.autoAckRdmaPacketMetaPipeOut, packetGenReqArbiterVecInst[0].rdmaPacketMetaPipeInVec[2]);
    mkConnection(rqGroup.autoAckRdmaPayloadPipeOut, packetGenReqArbiterVecInst[0].rdmaPayloadPipeInVec[2]);

    mkConnection(simpleNic.rawEthernetPacketPipeOut, ethTxStreamArbiterVec[1].pipeInIfcVec[1]);

    function ActionValue#(CsrNodeResultFork8) csrMatchFunc(CsrAccessReq req);
        actionvalue
            let regIdx = req.addr >> valueOf(BYTE_DWORD_CONVERT_SHIFT_NUM);
            let addrBlockMask = fromInteger(valueOf(CSR_ADDR_ROUTING_MASK_FOR_METRICS_OF_QPMRPGTQPC));
            let maskedAddr = addrBlockMask & regIdx;
            if (fromInteger(valueOf(CSR_ADDR_ROUTING_FOR_METRICS_RQ0)) == maskedAddr) begin
                return tagged CsrNodeResultForward 0;
            end
            else if (fromInteger(valueOf(CSR_ADDR_ROUTING_FOR_METRICS_RQ1)) == maskedAddr) begin
                return tagged CsrNodeResultForward 1;
            end
            else if (fromInteger(valueOf(CSR_ADDR_ROUTING_FOR_METRICS_RQ2)) == maskedAddr) begin
                return tagged CsrNodeResultForward 2;
            end
            else if (fromInteger(valueOf(CSR_ADDR_ROUTING_FOR_METRICS_RQ3)) == maskedAddr) begin
                return tagged CsrNodeResultForward 3;
            end
            else if (fromInteger(valueOf(CSR_ADDR_ROUTING_FOR_METRICS_PACKET_GEN_0)) == maskedAddr) begin
                return tagged CsrNodeResultForward 4;
            end
            else if (fromInteger(valueOf(CSR_ADDR_ROUTING_FOR_METRICS_PACKET_GEN_1)) == maskedAddr) begin
                return tagged CsrNodeResultForward 5;
            end
            else if (fromInteger(valueOf(CSR_ADDR_ROUTING_FOR_METRICS_PACKET_GEN_2)) == maskedAddr) begin
                return tagged CsrNodeResultForward 6;
            end
            else if (fromInteger(valueOf(CSR_ADDR_ROUTING_FOR_METRICS_PACKET_GEN_3)) == maskedAddr) begin
                return tagged CsrNodeResultForward 7;
            end
            else begin
                return tagged CsrNodeResultNotMatched;
            end
        endactionvalue
    endfunction
    CsrNodeFork8 csrNode <- mkCsrNode(csrMatchFunc, valueOf(NUMERIC_TYPE_ONE), "mkQpMrPgtQpc");
    mkConnection(rqGroup.csrUpStreamPortVec[0], csrNode.downStreamPortsVec[0]);
    mkConnection(rqGroup.csrUpStreamPortVec[1], csrNode.downStreamPortsVec[1]);
    mkConnection(rqGroup.csrUpStreamPortVec[2], csrNode.downStreamPortsVec[2]);
    mkConnection(rqGroup.csrUpStreamPortVec[3], csrNode.downStreamPortsVec[3]);
    mkConnection(ethernetPacketGenVecInst[0].csrUpStreamPort, csrNode.downStreamPortsVec[4]);
    mkConnection(ethernetPacketGenVecInst[1].csrUpStreamPort, csrNode.downStreamPortsVec[5]);
    mkConnection(ethernetPacketGenVecInst[2].csrUpStreamPort, csrNode.downStreamPortsVec[6]);
    mkConnection(ethernetPacketGenVecInst[3].csrUpStreamPort, csrNode.downStreamPortsVec[7]);
    
    rule forwardQpContextUpdateReq;
        let req = qpContextUpdateReqQueue.first;
        qpContextUpdateReqQueue.deq;
        qpContext.updateSrv.request.enq(req);
    endrule
    
    rule forwardQpContextUpdateResp;
        let r1 = qpContext.updateSrv.response.first;
        qpContext.updateSrv.response.deq;
        qpContextUpdateRespQueue.enq(r1);
    endrule


    method Action setLocalNetworkSettings(LocalNetworkSettings networkSettings); 
        rqGroup.setLocalNetworkSettingsPipeIn.enq(networkSettings);
        for (Integer idx = 0; idx < valueOf(HARDWARE_QP_CHANNEL_CNT); idx = idx + 1) begin
            ethernetPacketGenVecInst[idx].setLocalNetworkSettingsPipeIn.enq(networkSettings);
        end
    endmethod

    interface csrUpStreamPort                   = csrNode.upStreamPort;
    interface pgtUpdateDmaMasterPipe            = pgtUpdateDmaInterfaceConvertor.dmaSidePipeIfc;
    interface wqePipeIn                         = sqGroup.wqePipeIn;
    interface metaReportDescPipeOutVec          = metaReportDescPipeOutVecInst;
    interface qpDmaRequestMasterIfcVec          = qpDmaRequestMasterIfcVecInst;
    interface qpEthDataStreamIfcVec             = qpEthDataStreamIfcVecInst;
    interface qpContextUpdateSrv                = toGPServerP(toPipeIn(qpContextUpdateReqQueue), toPipeOut(qpContextUpdateRespQueue));

    interface simpleNicRxDescPipeOut            = simpleNic.simpleNicRxDescPipeOut;
    interface simpleNicTxDescPipeIn             = simpleNic.simpleNicTxDescPipeIn;

    interface qpResetReqPipeIn                  = rqGroup.qpResetReqPipeIn;
    interface mrAndPgtModifyDescSrv             = mrAndPgtUpdater.mrAndPgtModifyDescSrv;

    interface simpleNicPacketDmaMasterPipeIfc   = simpleNic.simpleNicPacketDmaMasterPipeIfc;
endmodule
