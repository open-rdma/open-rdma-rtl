import RegFile :: * ;
import FIFOF :: *;
import ClientServer :: *;
import PAClib :: *;
import PrimUtils :: *;
import Vector :: *;
import GetPut :: *;
import Printf:: *;

import EthernetTypes :: *;
import NapWrapper :: *;
import FullyPipelineChecker :: *;

import Settings :: *;
import DtldStream :: *;
import StreamDataTypes :: *;
import BasicDataTypes :: *;
import RdmaUtils :: *;
import RdmaHeaders :: *;

import CsrRootConnector :: *;
import CsrAddress :: *;
import CsrFramework :: *;

import ConnectableF :: *;

import IoChannels :: *;

interface InputPacketClassifier;
    interface BlueRdmaCsrUpStreamPort                   csrUpStreamPort;
    interface PipeInB0#(IoChannelEthDataStream)         ethRawPacketPipeIn;
    interface PipeOut#(DataStream)                      rdmaRawPacketPipeOut;
    interface PipeOut#(ThinMacIpUdpMetaDataForRecv)     rdmaMacIpUdpMetaPipeOut;
    interface PipeOut#(DataStream)                      otherRawPacketPipeOut;
    method Action setLocalNetworkSettings(LocalNetworkSettings networkSettings);
endinterface


typedef 14 IP_HEADER_OFFSET_IN_FIRST_BEAT;
typedef 34 UDP_HEADER_OFFSET_IN_FIRST_BEAT;
typedef 16 MAC_ADDR_PARTIAL_COMPARE_BIT_WIDTH;

typedef 16 IP_ADDR_COMPARE_PARTIAL_POINT;



typedef enum {
    InputPacketClassifierStateHandleFirstBeat = 0,
    InputPacketClassifierStateHandleSecondBeat = 1,
    InputPacketClassifierStateHandleMoreBeat = 2
} InputPacketClassifierState deriving(Bits, FShow, Eq);

typedef struct {
    Bool mustNotBeRdmaPacket;
    ThinMacIpUdpMetaDataForRecv macIpUdpMeta;
    Bool macUnicastMatch;
    Bool macAddrBroadcastMatch;
    EthHeader ethHeader;
} EthernetPacketMetaExtractPipelineEntry deriving(Bits, FShow, Eq);

typedef struct {
    Bool            isRdmaPacket;
    Bool            isError;
    Bool            isAddrMatch;
    SimulationTime  fpDebugTime;
} EthernetPacketMeta deriving(Bits, FShow, Eq);

(*synthesize*)
module mkInputPacketClassifier(InputPacketClassifier);
    Reg#(InputPacketClassifierState) stateReg <- mkReg(InputPacketClassifierStateHandleFirstBeat);

    PipeInAdapterB0#(IoChannelEthDataStream) ethRawPacketInQ <- mkPipeInAdapterB0;
    FIFOF#(DataStream) rdmaRawPacketOutQ <- mkFIFOF;
    FIFOF#(ThinMacIpUdpMetaDataForRecv) rdmaMacIpUdpMetaOutQ <- mkFIFOF;
    FIFOF#(DataStream) otherRawPacketOutQ <- mkFIFOF;

    FIFOF#(DataStream) waitingForRouteQ <- mkSizedFIFOF(valueOf(NUMERIC_TYPE_FOUR));
    FIFOF#(EthernetPacketMeta) ethPacketMetaQ <- mkFIFOF;   // maybe not need FIFOF


    Reg#(Bool) networkSettingsIsSetReg <- mkReg(False);
    Reg#(LocalNetworkSettings) networkSettingsReg <- mkRegU;
    Reg#(Bool) canAcceptRawInputPacketReg <- mkReg(False);


    FIFOF#(Tuple3#(DataStream, Bool, SimulationTime)) ethRawPacketForHandleQ <- mkLFIFOF;

    let fpChecker <- mkStreamFullyPipelineChecker(DebugConf{name: "mkInputPacketClassifier", enableDebug: True});


    // Metrics Regs
    Reg#(Dword) metricsDiscardPacketCntReg      <- mkReg(0);
    Reg#(Dword) metricsSimpleNicPacketCntReg    <- mkReg(0);
    Reg#(Dword) metricsRdmaPacketCntReg         <- mkReg(0);
    Reg#(Dword) metricsNetworkNotReadyCntReg    <- mkReg(0);


    function ActionValue#(CsrNodeResultFork8) csrMatchFunc(CsrAccessReq req);
        actionvalue
            let regIdx = req.addr >> valueOf(BYTE_DWORD_CONVERT_SHIFT_NUM);
            let leafMask = fromInteger(valueOf(CSR_ADDR_LEAF_MASK_FOR_METRICS_ETHERNET_FRAME_IO));

            if (req.isWrite) begin
                return tagged CsrNodeResultNotMatched;
            end
            else begin
                case (regIdx & leafMask)
                    fromInteger(valueOf(CSR_ADDR_OFFSET_METRICS_ETHERNET_FRAME_IO_DISCARD_PACKET_CNT)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: metricsDiscardPacketCntReg};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_METRICS_ETHERNET_FRAME_IO_SIMPLE_NIC_PACKET_CNT)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: metricsSimpleNicPacketCntReg};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_METRICS_ETHERNET_FRAME_IO_RDMA_PACKET_CNT)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: metricsRdmaPacketCntReg};
                    end
                    fromInteger(valueOf(CSR_ADDR_OFFSET_METRICS_ETHERNET_FRAME_IO_NOT_READY_PACKET_CNT)): begin
                        return tagged CsrNodeResultReadHandled CsrReadWriteResp {value: metricsNetworkNotReadyCntReg};
                    end
                    default: begin
                        return tagged CsrNodeResultNotMatched;
                    end
                endcase
            end
        endactionvalue
    endfunction
    CsrNodeFork8 csrNode <- mkCsrNode(csrMatchFunc, valueOf(NUMERIC_TYPE_ONE), "mkInputPacketClassifier");



    rule printDebugInfo;
        if (!rdmaRawPacketOutQ.notFull) $display("time=%0t, ", $time, "FullQueue: mkInputPacketClassifier rdmaRawPacketOutQ");
        if (!waitingForRouteQ.notFull) $display("time=%0t, ", $time, "FullQueue: mkInputPacketClassifier waitingForRouteQ");
        if (waitingForRouteQ.notEmpty && !ethPacketMetaQ.notEmpty) $display("time=%0t, ", $time, "EmptyQueue: mkInputPacketClassifier ethPacketMetaQ");
    endrule

    rule discardPacketWhenNetworkSettingsNotReady;
        let curFpDebugTime <- getSimulationTime;
        let ds = ethRawPacketInQ.first;
        ethRawPacketInQ.deq;

        EthHeader ethHeader         = unpack(truncateLSB(swapEndianByte(pack(ds.data))));
        Bool macUnicastMatch = ethHeader.dstMacAddr == networkSettingsReg.macAddr;

        if (networkSettingsIsSetReg && ds.isFirst) begin
            canAcceptRawInputPacketReg <= True;

            ethRawPacketForHandleQ.enq(tuple3(ds, macUnicastMatch, curFpDebugTime));
            waitingForRouteQ.enq(ds);
            let _ <- fpChecker.putStreamBeatInfo(ds.isFirst, ds.isLast);
        end
        else if (canAcceptRawInputPacketReg) begin
            ethRawPacketForHandleQ.enq(tuple3(ds, macUnicastMatch, curFpDebugTime));
            waitingForRouteQ.enq(ds);
            let _ <- fpChecker.putStreamBeatInfo(ds.isFirst, ds.isLast);
        end
        else begin
            metricsNetworkNotReadyCntReg <= metricsNetworkNotReadyCntReg + 1;
            $display(
                "time=%0t:", $time, toRed(" mkInputPacketClassifier discardPacketWhenNetworkSettingsNotReady >>>>> DISCARD PACKET <<<<< since network settings not set"),
                toBlue(", ds="), fshow(ds)
            );
        end
        // $display(
        //     "time=%0t:", $time, toGreen(" mkInputPacketClassifier discardPacketWhenNetworkSettingsNotReady"),
        //     toBlue(", ethHeader="), fshow(ethHeader),
        //     toBlue(", ds="), fshow(ds)
        // );
    endrule

    rule handleFirstBeatStage if (stateReg == InputPacketClassifierStateHandleFirstBeat);
        let curFpDebugTime <- getSimulationTime;
        let {ds, macUnicastMatch, fpDebugTime} = ethRawPacketForHandleQ.first;
        ethRawPacketForHandleQ.deq;

        ds.data = swapEndianByte(ds.data);

        EthHeader ethHeader         = unpack(truncateLSB(pack(ds.data)));

        IpHeader  ipHeader   = unpack(truncateLSB(pack(ds.data) << valueOf(IP_HEADER_OFFSET_IN_FIRST_BEAT) * valueOf(BYTE_WIDTH)));

        Bool mustNotBeRdmaPacket = False;
        if (ethHeader.ethType != fromInteger(valueOf(ETH_TYPE_IP))) begin
            mustNotBeRdmaPacket = True;
        end
        if (ipHeader.ipProtocol != fromInteger(valueOf(IP_PROTOCOL_UDP))) begin
            mustNotBeRdmaPacket = True;
        end

        let macIpUdpMeta = ThinMacIpUdpMetaDataForRecv{
            srcMacAddr: ethHeader.srcMacAddr,
            ipDscp: ipHeader.ipDscp,
            ipEcn: ipHeader.ipEcn,
            srcIpAddr:ipHeader.srcIpAddr,
            srcPort: ?
        };

        Bool macAddrBroadcastMatch = ethHeader.dstMacAddr == -1;
        Bool ipBroadcastMatch = (ipHeader.dstIpAddr | networkSettingsReg.netMask) == -1;



        Bool ipUnicastMatch = networkSettingsReg.ipAddr == ipHeader.dstIpAddr;
        Bool ipAddrMatch = ipUnicastMatch || ipBroadcastMatch;
        Bool macAddrMatch = macUnicastMatch || macAddrBroadcastMatch;
        
        if (!ipAddrMatch) begin
            $display(
                "time=%0t:", $time, toRed(" mkInputPacketClassifier IP address check failed"),
                toBlue(", networkSettingsReg="), fshow(networkSettingsReg),
                toBlue(", ipHeader="), fshow(ipHeader)
            );
        end

        if (!macAddrMatch) begin
            $display(
                "time=%0t:", $time, toRed(" mkInputPacketClassifier mac address check failed"),
                toBlue(", networkSettingsReg="), fshow(networkSettingsReg),
                toBlue(", ethHeader="), fshow(ethHeader)
            );
        end

        let isAddrMatch = macAddrMatch && ipAddrMatch;

        UdpHeader udpHeader = unpack(truncateLSB(pack(ds.data) << valueOf(UDP_HEADER_OFFSET_IN_FIRST_BEAT) * valueOf(BYTE_WIDTH)));

        if (udpHeader.dstPort != fromInteger(valueOf(UDP_PORT_RDMA))) begin
            mustNotBeRdmaPacket = True;
        end

        // error packet should already be filtered by Eth Mac
        let isError = False;

        // This is the final check condition. so if it is not "mustn't be RDMA", then it is RDMA
        Bool isRDMA = !mustNotBeRdmaPacket;
        ethPacketMetaQ.enq(EthernetPacketMeta{
            isRdmaPacket: isRDMA,
            isError: isError,
            isAddrMatch: isAddrMatch,
            fpDebugTime: curFpDebugTime
        });

        if (isAddrMatch && isRDMA && !isError) begin
            rdmaMacIpUdpMetaOutQ.enq(macIpUdpMeta);
        end

        if (!ds.isLast) begin
            stateReg <= InputPacketClassifierStateHandleMoreBeat;
        end

        
        // $display(
        //     "time=%0t:", $time, toGreen(" mkInputPacketClassifier handleFirstBeatStage"),
        //     toBlue(", ipHeader="), fshow(ipHeader),
        //     toBlue(", ds="), fshow(ds),
        //     toBlue(", outPipelineEntry="), fshow(outPipelineEntry)
        // );

    endrule

    rule handleMoreBeatStage if (stateReg == InputPacketClassifierStateHandleMoreBeat);
        let {ds, macUnicastMatch, fpDebugTime} = ethRawPacketForHandleQ.first;
        ethRawPacketForHandleQ.deq;

        immAssert(
            !ds.isFirst,
            "mkInputPacketClassifier second beat error",
            $format("isFirst should be False handleMoreBeatStage, ds=", fshow(ds))
        );
        
        if (ds.isLast) begin
            stateReg <= InputPacketClassifierStateHandleFirstBeat;
        end

        // $display(
        //     "time=%0t:", $time, toGreen(" mkInputPacketClassifier handleMoreBeatStage"),
        //     toBlue(", ds="), fshow(ds)
        // );
        checkFullyPipeline(fpDebugTime, 1, 2000, DebugConf{name: "mkInputPacketClassifier handleMoreBeatStage", enableDebug: True});
    endrule

    rule dispatchStream;
        let curFpDebugTime <- getSimulationTime;
        let ds = waitingForRouteQ.first;
        waitingForRouteQ.deq;
        let ethPktMeta = ethPacketMetaQ.first;

        // discard error packet.
        if (!ethPktMeta.isError && ethPktMeta.isAddrMatch) begin
            if (ethPktMeta.isRdmaPacket) begin
                rdmaRawPacketOutQ.enq(ds);
                metricsRdmaPacketCntReg <= metricsRdmaPacketCntReg + 1;
                // $display(
                //     "time=%0t:", $time, toGreen(" mkInputPacketClassifier dispatchStream recv rdma packte"),
                //     toBlue(", ds="), fshow(ds),
                //     toBlue(", metricsRdmaPacketCntReg="), fshow(metricsRdmaPacketCntReg)
                // );
            end
            else begin
                otherRawPacketOutQ.enq(ds);
                metricsSimpleNicPacketCntReg <= metricsSimpleNicPacketCntReg + 1;
            end
        end
        else begin
            $display(
                "time=%0t:", $time, toRed(" mkInputPacketClassifier dispatchStream >>>>> DISCARD PACKET <<<<<"),
                toBlue(", ethPktMeta.isError="), fshow(ethPktMeta.isError),
                toBlue(", ethPktMeta.isAddrMatch="), fshow(ethPktMeta.isAddrMatch),
                toBlue(", ds="), fshow(ds)
            );
            metricsDiscardPacketCntReg <= metricsDiscardPacketCntReg + 1;
        end

        if (ds.isLast) begin
            ethPacketMetaQ.deq;
        end
        if (ds.isFirst) begin
            checkFullyPipeline(ethPktMeta.fpDebugTime, 1, 2000, DebugConf{name: "mkInputPacketClassifier dispatchStream", enableDebug: True});
        end
    endrule


    method Action setLocalNetworkSettings(LocalNetworkSettings networkSettings);
        networkSettingsReg <= networkSettings;
        networkSettingsIsSetReg <= True;
    endmethod

    interface csrUpStreamPort           = csrNode.upStreamPort;
    interface ethRawPacketPipeIn        = toPipeInB0(ethRawPacketInQ);
    interface rdmaRawPacketPipeOut      = toPipeOut(rdmaRawPacketOutQ);
    interface rdmaMacIpUdpMetaPipeOut   = toPipeOut(rdmaMacIpUdpMetaOutQ);
    interface otherRawPacketPipeOut     = toPipeOut(otherRawPacketOutQ);
endmodule

typedef TMul#(1, DATA_BUS_BYTE_WIDTH) BYTE_NUM_OF_ONE_BEATS;            // 64
typedef TMul#(2, DATA_BUS_BYTE_WIDTH) BYTE_NUM_OF_TWO_BEATS;            // 128


typedef TSub#(BYTE_NUM_OF_ONE_BEATS, MAC_IP_UDP_TOTAL_HDR_BYTE_WIDTH)    MAX_BYTE_NUM_FOR_BTH_AND_ETH_IN_FIRST_BEAT;            // 22
typedef MAC_IP_UDP_TOTAL_HDR_BYTE_WIDTH                                  BTH_FIRST_BYTE_ONE_BASED_INDEX_IN_FIRST_BEAT;          // 42
typedef TMul#(BYTE_WIDTH, BTH_FIRST_BYTE_ONE_BASED_INDEX_IN_FIRST_BEAT)  BTH_FIRST_BIT_ONE_BASED_INDEX_IN_FIRST_BEAT;


typedef TSub#(96, MAC_IP_UDP_TOTAL_HDR_BYTE_WIDTH) RDMA_FIXED_HEADER_BYTE_NUM;     // 54
typedef Bit#(TMul#(BYTE_WIDTH, RDMA_FIXED_HEADER_BYTE_NUM)) RdmaFixedHeaderBuffer;


typedef TDiv#(DATA_BUS_WIDTH, 2) DATA_BUS_HALF_BEAT_BIT_WIDTH;
typedef TDiv#(DATA_BUS_HALF_BEAT_BIT_WIDTH, BYTE_WIDTH) DATA_BUS_HALF_BEAT_BYTE_WIDTH; // 32

typedef DATA_BUS_HALF_BEAT_BYTE_WIDTH NET_PACKET_PAYLOAD_BYTE_OFFSET_FROM_SECOND_BEAT;
typedef Bit#(DATA_BUS_HALF_BEAT_BIT_WIDTH) DataBeatHalf;

interface RdmaMetaAndPayloadExtractor;
    interface PipeInB0#(DataStream) ethPipeIn;
    interface PipeOut#(RdmaRecvPacketMeta) rdmaPacketMetaPipeOut;
    interface PipeOut#(RdmaRecvPacketTailMeta) rdmaPacketTailMetaPipeOut;
    interface PipeOut#(DataStream) rdmaPayloadPipeOut;
endinterface

typedef enum {
    RdmaMetaAndPayloadExtractorStateHandleFirstBeat = 0,
    RdmaMetaAndPayloadExtractorStateHandleSecondBeat = 1,
    RdmaMetaAndPayloadExtractorStateHandleMoreBeat = 2,
    RdmaMetaAndPayloadExtractorStateHandleExtraLastBeat = 3
} RdmaMetaAndPayloadExtractorState deriving(Bits, FShow, Eq);

(*synthesize*)
module mkRdmaMetaAndPayloadExtractor(RdmaMetaAndPayloadExtractor);

    Reg#(RdmaMetaAndPayloadExtractorState) stateReg <- mkReg(RdmaMetaAndPayloadExtractorStateHandleFirstBeat);

    PipeInAdapterB0#(DataStream) ethPipeInQ                   <- mkPipeInAdapterB0;
    FIFOF#(RdmaRecvPacketMeta) rdmaPacketMetaPipeOutQ   <- mkFIFOF;
    FIFOF#(RdmaRecvPacketTailMeta) rdmaPacketTailMetaPipeOutQ   <- mkSizedFIFOF(4);  // Since this queue span about 14 beat, if each message with payload is at least 4 beat, then the queue at least be 4 in depth
    FIFOF#(DataStream) rdmaPayloadPipeOutQ          <- mkFIFOF;

    Reg#(Bool) payloadStreamOutputIsFirstReg <- mkReg(True);

    Reg#(PktFragNum) beatCntReg <- mkReg(1);

    Reg#(DataStream) prevBeatReg <- mkRegU;
    Reg#(SimulationTime)  fpDebugTimeReg <- mkRegU;

    rule handleFirstBeat if (stateReg == RdmaMetaAndPayloadExtractorStateHandleFirstBeat);
        let curFpDebugTime <- getSimulationTime;
        // first beat is totally ETH and IP header, skip them
        let ds = ethPipeInQ.first;
        ethPipeInQ.deq;

        prevBeatReg <= ds;

        if (ds.isLast) begin
            // this is defensive code, shoud not enter this branch. but if it does, goto handle first packet state.
            immFail(
                "The first beat must not be last beat.",
                $format("ds=", fshow(ds))
            );
            stateReg <= RdmaMetaAndPayloadExtractorStateHandleFirstBeat;
        end
        else begin
            stateReg <= RdmaMetaAndPayloadExtractorStateHandleSecondBeat;
        end

        fpDebugTimeReg <= curFpDebugTime;


        $display(
            "time=%0t:", $time, toGreen(" mkRdmaMetaAndPayloadExtractor handleFirstBeat"),
            toBlue(", ds="), fshow(ds)
        );
    endrule

    
    rule handleSecondBeat if (stateReg == RdmaMetaAndPayloadExtractorStateHandleSecondBeat);
        let curFpDebugTime <- getSimulationTime;
        fpDebugTimeReg <= curFpDebugTime;

        let ds = ethPipeInQ.first;
        ethPipeInQ.deq;


        Tuple2#(MacIpUdpHeader, RdmaBthAndExtendHeader) macIpUdpBthEthTuple = unpack(truncateLSB({swapEndianByte(prevBeatReg.data) , swapEndianByte(ds.data)}));
        let {macIpUdpHeader, rdmaBthAndEth} = macIpUdpBthEthTuple;

        let ecnMarked = (pack(macIpUdpHeader.ipHeader.ipEcn) == pack(IpHeaderEcnFlagMarked));

        BTH bth = rdmaBthAndEth.bth;
        let hasPayload = rdmaOpCodeHasPayload(bth.opcode);

        let rdmaMeta = RdmaRecvPacketMeta{
            header: rdmaBthAndEth,
            hasPayload: hasPayload,
            isEcnMarked: ecnMarked,
            fpDebugTime: curFpDebugTime
        };

        rdmaPacketMetaPipeOutQ.enq(rdmaMeta);
    

        if (rdmaMeta.hasPayload) begin
            if (ds.isLast) begin
                let outDs = DataStream{
                    data: ds.data >> valueOf(TMul#(NET_PACKET_PAYLOAD_BYTE_OFFSET_FROM_SECOND_BEAT, BYTE_WIDTH)),
                    startByteIdx: 0,
                    byteNum: ds.byteNum - fromInteger(valueOf(NET_PACKET_PAYLOAD_BYTE_OFFSET_FROM_SECOND_BEAT)),
                    isFirst: True,
                    isLast: True
                };
                rdmaPayloadPipeOutQ.enq(outDs);
                rdmaPacketTailMetaPipeOutQ.enq(RdmaRecvPacketTailMeta{
                    beatCnt: 1,
                    fpDebugTime: curFpDebugTime
                });
                // $display(
                //     "time=%0t:", $time, toGreen(" mkRdmaMetaAndPayloadExtractor handleSecondBeat output only beat"),
                //     toBlue(", ds="), fshow(ds),
                //     toBlue(", outDs="), fshow(outDs)
                // );
            end
        end
        prevBeatReg <= ds;

        stateReg <= ds.isLast ? RdmaMetaAndPayloadExtractorStateHandleFirstBeat : RdmaMetaAndPayloadExtractorStateHandleMoreBeat;

        $display(
            "time=%0t:", $time, toGreen(" mkRdmaMetaAndPayloadExtractor handleSecondBeat"),
            toBlue(", ds="), fshow(ds),
            toBlue(", payload(with useless lower bits)="), rdmaMeta.hasPayload ? fshow(ds) : $format("No Payload"),
            toBlue(", rdmaMeta="), fshow(rdmaMeta)
        );
        checkFullyPipeline(fpDebugTimeReg, 1, 2000, DebugConf{name: "mkRdmaMetaAndPayloadExtractor handleSecondBeat", enableDebug: True});
    endrule


    rule handleMoreBeat if (stateReg == RdmaMetaAndPayloadExtractorStateHandleMoreBeat);
        let curFpDebugTime <- getSimulationTime;
        fpDebugTimeReg <= curFpDebugTime;
        let ds = ethPipeInQ.first;
        ethPipeInQ.deq;

        let canNewBeatFitInPreviousBeat = ds.byteNum <= fromInteger(valueOf(DATA_BUS_HALF_BEAT_BYTE_WIDTH));

        DataBeatHalf highPart = truncate(ds.data);
        DataBeatHalf lowPart = truncateLSB(prevBeatReg.data);

        let isFirst = payloadStreamOutputIsFirstReg;
        let isLast = ?;
        let byteNum = ?;

        if (ds.isLast) begin
            if (canNewBeatFitInPreviousBeat) begin
                byteNum = ds.byteNum + fromInteger(valueOf(NET_PACKET_PAYLOAD_BYTE_OFFSET_FROM_SECOND_BEAT));
                isLast = True;
                stateReg <= RdmaMetaAndPayloadExtractorStateHandleFirstBeat;
            end
            else begin
                byteNum = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                isLast = False;
                stateReg <= RdmaMetaAndPayloadExtractorStateHandleExtraLastBeat;
            end
        end
        else begin
            isLast = False;
            byteNum = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        end

        let outDs = DataStream{
            data: {highPart, lowPart},
            startByteIdx: 0,
            byteNum: byteNum,
            isFirst: isFirst,
            isLast: isLast
        };
        rdmaPayloadPipeOutQ.enq(outDs);

        if (isLast) begin
            beatCntReg <= 1;
            rdmaPacketTailMetaPipeOutQ.enq(RdmaRecvPacketTailMeta{
                beatCnt: beatCntReg,
                fpDebugTime: curFpDebugTime
            });
        end
        else begin
            beatCntReg <= beatCntReg + 1;
        end

        
        prevBeatReg <= ds;
        payloadStreamOutputIsFirstReg <= isLast;
        
        $display(
            "time=%0t:", $time, toGreen(" mkRdmaMetaAndPayloadExtractor handleMoreBeat"),
            toBlue(", ds="), fshow(ds),
            toBlue(", outDs="), fshow(outDs)
        );
        checkFullyPipeline(fpDebugTimeReg, 1, 2000, DebugConf{name: "mkRdmaMetaAndPayloadExtractor handleMoreBeat", enableDebug: True} );
    endrule


    rule handleExtraLastBeat if (stateReg == RdmaMetaAndPayloadExtractorStateHandleExtraLastBeat);
        let curFpDebugTime <- getSimulationTime;

        immAssert(
            prevBeatReg.isLast && !prevBeatReg.isFirst && prevBeatReg.byteNum > fromInteger(valueOf(DATA_BUS_HALF_BEAT_BYTE_WIDTH)),
            "last beat assert failed",
            $format("prevBeatReg=", fshow(prevBeatReg))
        );

        let outDs = DataStream{
            data: prevBeatReg.data >> valueOf(TMul#(NET_PACKET_PAYLOAD_BYTE_OFFSET_FROM_SECOND_BEAT, BYTE_WIDTH)),
            startByteIdx: 0,
            byteNum: prevBeatReg.byteNum - fromInteger(valueOf(NET_PACKET_PAYLOAD_BYTE_OFFSET_FROM_SECOND_BEAT)),
            isFirst: False,
            isLast: True
        };
        rdmaPayloadPipeOutQ.enq(outDs);

        rdmaPacketTailMetaPipeOutQ.enq(RdmaRecvPacketTailMeta{
            beatCnt: beatCntReg,
            fpDebugTime: curFpDebugTime
        });

        stateReg <= RdmaMetaAndPayloadExtractorStateHandleFirstBeat;
        beatCntReg <= 1;
        payloadStreamOutputIsFirstReg <= True;

        $display(
            "time=%0t:", $time, toGreen(" mkRdmaMetaAndPayloadExtractor handleExtraLastBeat"),
            toBlue(", outDs="), fshow(outDs)
        );
        checkFullyPipeline(fpDebugTimeReg, 1, 2000, DebugConf{name: "mkRdmaMetaAndPayloadExtractor handleExtraLastBeat", enableDebug: True});
    endrule

    interface ethPipeIn                     = toPipeInB0(ethPipeInQ);
    interface rdmaPacketMetaPipeOut         = toPipeOut(rdmaPacketMetaPipeOutQ);
    interface rdmaPacketTailMetaPipeOut     = toPipeOut(rdmaPacketTailMetaPipeOutQ);
    interface rdmaPayloadPipeOut            = toPipeOut(rdmaPayloadPipeOutQ);
endmodule




module mkIpHdrCheckSumStream#(
        PipeOut#(IpHeader) ipHeaderStream
    )(PipeOut#(IpCheckSum)) provisos(
        NumAlias#(TDiv#(IP_HDR_WORD_WIDTH, 2), firstStageOutNum),
        NumAlias#(TAdd#(IP_CHECKSUM_WIDTH, 1), firstStageOutWidth),
        NumAlias#(TDiv#(firstStageOutNum, 4), secondStageOutNum),
        NumAlias#(TAdd#(firstStageOutWidth, 2), secondStageOutWidth)
    );

    function Bit#(TAdd#(width, 1)) add(Bit#(width) a, Bit#(width) b) = zeroExtend(a) + zeroExtend(b);
    function Bit#(TAdd#(width, 1)) pass(Bit#(width) a) = zeroExtend(a);

    FIFOF#(Vector#(firstStageOutNum, Bit#(firstStageOutWidth))) firstStageOutBuf <- mkLFIFOF;
    FIFOF#(Vector#(secondStageOutNum, Bit#(secondStageOutWidth))) secondStageOutBuf <- mkLFIFOF;
    FIFOF#(IpCheckSum) ipCheckSumOutBuf <- mkFIFOF;

    rule firstStageAdder;
        let ipHeader = ipHeaderStream.first;
        ipHeaderStream.deq;
        Vector#(IP_HDR_WORD_WIDTH, Word) ipHdrVec = unpack(pack(ipHeader));
        let ipHdrVecReducedBy2 = mapPairs(add, pass, ipHdrVec);
        firstStageOutBuf.enq(ipHdrVecReducedBy2);
        $display(
            "time=%0t:", $time, toGreen(" mkIpHdrCheckSumStream firstStageAdder")
        );
    endrule

    rule secondStageAdder;
        let firstStageOutVec = firstStageOutBuf.first;
        firstStageOutBuf.deq;
        let firstStageOutReducedBy2 = mapPairs(add, pass, firstStageOutVec);
        let firstStageOutReducedBy4 = mapPairs(add, pass, firstStageOutReducedBy2);
        secondStageOutBuf.enq(firstStageOutReducedBy4);
        $display(
            "time=%0t:", $time, toGreen(" mkIpHdrCheckSumStream secondStageAdder")
        );
    endrule

    rule lastStageAdder;
        let secondStageOutVec = secondStageOutBuf.first;
        secondStageOutBuf.deq;

        let secondStageOutReducedBy2 = mapPairs(add, pass, secondStageOutVec);

        let sum = secondStageOutReducedBy2[0];
        Bit#(TLog#(IP_HDR_WORD_WIDTH)) overFlow = truncateLSB(sum);
        IpCheckSum remainder = truncate(sum);
        IpCheckSum checkSum = ~(remainder + zeroExtend(overFlow));
        ipCheckSumOutBuf.enq(checkSum);
        $display(
            "time=%0t:", $time, toGreen(" mkIpHdrCheckSumStream lastStageAdder")
        );
    endrule

    return toPipeOut(ipCheckSumOutBuf);
endmodule



interface EthernetPacketGenerator;
    interface PipeInB0#(ThinMacIpUdpMetaDataForSend) macIpUdpMetaPipeIn;
    interface PipeInB0#(RdmaSendPacketMeta) rdmaPacketMetaPipeIn;
    interface PipeInB0#(DataStream) rdmaPayloadPipeIn;
    interface PipeOut#(IoChannelEthDataStream) ethernetPacketPipeOut;

    method Action setLocalNetworkSettings(LocalNetworkSettings networkSettings);
endinterface

typedef enum {
    EthernetPacketGeneratorStateGenFirstBeat = 0,
    EthernetPacketGeneratorStateGenSecondBeat = 1,
    EthernetPacketGeneratorStateGenMoreBeat = 2,
    EthernetPacketGeneratorStateGenExtraLastBeat = 3
} EthernetPacketGeneratorState deriving(Bits, FShow, Eq);


function UdpIpHeader genUdpIpHeader(ThinMacIpUdpMetaDataForSend ethIpUdpMeta, LocalNetworkSettings localNetSettings, IpID ipId);
    // Calculate packet length
    UdpLength udpLen = ethIpUdpMeta.udpPayloadLen + fromInteger(valueOf(UDP_HDR_BYTE_WIDTH));
    IpTL ipLen = udpLen + fromInteger(valueOf(IP_HDR_BYTE_WIDTH));
    // generate ipHeader
    IpHeader ipHeader = IpHeader {
        ipVersion : fromInteger(valueOf(IP_VERSION_VAL)),
        ipIHL     : fromInteger(valueOf(IP_IHL_VAL)),
        ipDscp    : ethIpUdpMeta.ipDscp,
        ipEcn     : ethIpUdpMeta.ipEcn,
        ipTL      : ipLen,
        ipID      : ipId,
        ipFlag    : fromInteger(valueOf(IP_FLAGS_VAL)),
        ipOffset  : fromInteger(valueOf(IP_OFFSET_VAL)),
        ipTTL     : fromInteger(valueOf(IP_TTL_VAL)),
        ipProtocol: fromInteger(valueOf(IP_PROTOCOL_UDP)),
        ipChecksum: 0,
        srcIpAddr : localNetSettings.ipAddr,
        dstIpAddr : ethIpUdpMeta.dstIpAddr
    };
    // generate udpHeader
    UdpHeader udpHeader = UdpHeader {
        srcPort : ethIpUdpMeta.srcPort,
        dstPort : ethIpUdpMeta.dstPort,
        length  : udpLen,
        checksum: 0
    };
    // generate udpIpHeader
    UdpIpHeader udpIpHeader = UdpIpHeader {
        ipHeader: ipHeader,
        udpHeader: udpHeader
    };
    return udpIpHeader;
endfunction

typedef struct {
    MacIpUdpHeader               macIpUdpHeader;
    RdmaEthernetFrameByteLen     totalEthernetFrameLen;
} IpHeaderChecksumCalcPipelineEntry deriving(Bits, FShow);

typedef struct {
    Bool                         hasPayload;
    SimulationTime               fpDebugTime;
} PacketGeneratorFirstBeatToSecondBeatPipelineEntry deriving(Bits, FShow);

typedef struct {
    SimulationTime              fpDebugTime;
} PacketGeneratorSecondBeatToMoreBeatPipelineEntry deriving(Bits, FShow);

(*synthesize*)
module mkEthernetPacketGenerator(EthernetPacketGenerator);
    PipeInAdapterB0#(ThinMacIpUdpMetaDataForSend) macIpUdpMetaPipeInQ <- mkPipeInAdapterB0;
    PipeInAdapterB0#(RdmaSendPacketMeta) rdmaPacketMetaPipeInQ <- mkPipeInAdapterB0;
    PipeInAdapterB0#(DataStream) rdmaPayloadPipeInQ <- mkPipeInAdapterB0;
    FIFOF#(IoChannelEthDataStream) ethernetPacketPipeOutQ <- mkFIFOFWithFullAssert(DebugConf{name: "mkEthernetPacketGenerator ethernetPacketPipeOutQ", enableDebug: True});

    FIFOF#(IpHeader) ipHeaderForChecksumCalcQ <- mkFIFOF;

    // Pipeline FIFOs and Regs
    FIFOF#(IpHeaderChecksumCalcPipelineEntry) ipHeaderChecksumCalcPipelineQ <- mkSizedFIFOF(3);
    Reg#(PacketGeneratorFirstBeatToSecondBeatPipelineEntry) firstBeatToSecondBeatPipelineReg <- mkRegU;
    Reg#(PacketGeneratorSecondBeatToMoreBeatPipelineEntry)  secondBeatToMoreBeatPipelineReg <- mkRegU;

    Reg#(Maybe#(LocalNetworkSettings)) networkSettingsReg <- mkReg(tagged Invalid);

    Reg#(RdmaEthernetFrameByteLen) ethernetFrameLeftByteCounterReg <- mkRegU;


    Reg#(EthernetPacketGeneratorState) statusReg <- mkReg(EthernetPacketGeneratorStateGenFirstBeat);

    Reg#(SimulationTime) dataOutputFullyPipelineCheckTimeReg <- mkRegU;

    let ipHdrCheckSumStreamPipeOut <- mkIpHdrCheckSumStream(toPipeOut(ipHeaderForChecksumCalcQ));

    IpID defaultIpId = 1;

    Reg#(DataStream) prevBeatReg <- mkRegU;

    let fpChecker <- mkStreamFullyPipelineChecker(DebugConf{name: "mkEthernetPacketGenerator", enableDebug: True});

    rule prepareIpHeader;
        let curFpDebugTime <- getSimulationTime;
        let macIpUdpMeta = macIpUdpMetaPipeInQ.first;
        macIpUdpMetaPipeInQ.deq;

        // TODO: should we remove the Maybe wrapper in this type?
        LocalNetworkSettings localNetSettings = fromMaybe(?, networkSettingsReg);

        let udpIpHeader = genUdpIpHeader(macIpUdpMeta, localNetSettings, defaultIpId);
        let ethHeader = EthHeader {
            dstMacAddr: macIpUdpMeta.dstMacAddr,
            srcMacAddr: localNetSettings.macAddr,
            ethType: macIpUdpMeta.ethType
        };

        RdmaEthernetFrameByteLen ethFrameLen = truncate(macIpUdpMeta.udpPayloadLen) + fromInteger(valueOf(MAC_IP_UDP_TOTAL_HDR_BYTE_WIDTH));

        ipHeaderForChecksumCalcQ.enq(udpIpHeader.ipHeader);
        let outPipelineEntry = IpHeaderChecksumCalcPipelineEntry{
            macIpUdpHeader: MacIpUdpHeader{
                ethHeader: ethHeader,
                ipHeader: udpIpHeader.ipHeader,
                udpHeader: udpIpHeader.udpHeader
            },
            totalEthernetFrameLen: ethFrameLen
        };

        ipHeaderChecksumCalcPipelineQ.enq(outPipelineEntry);

        $display(
            "time=%0t:", $time, toGreen(" mkEthernetPacketGenerator prepareIpHeader"),
            toBlue(", udpPayloadLen="), fshow(macIpUdpMeta.udpPayloadLen),
            toBlue(", outPipelineEntry="), fshow(outPipelineEntry)
        );
    endrule


    // rule debugFirstBeatFire;
    //     if (statusReg == EthernetPacketGeneratorStateGenFirstBeat && (!ipHdrCheckSumStreamPipeOut.notEmpty || !rdmaPacketMetaPipeInQ.notEmpty || ipHeaderChecksumCalcPipelineQ.notEmpty)) begin
    //         $display(
    //             "time=%0t:", $time, toRed(" mkEthernetPacketGenerator debugFirstBeatFire"),
    //             toRed(", ipHdrCheckSumStreamPipeOut.notEmpty="), fshow(ipHdrCheckSumStreamPipeOut.notEmpty),
    //             toRed(", rdmaPacketMetaPipeInQ.notEmpty="), fshow(rdmaPacketMetaPipeInQ.notEmpty),
    //             toRed(", ipHeaderChecksumCalcPipelineQ.notEmpty="), fshow(ipHeaderChecksumCalcPipelineQ.notEmpty)
    //         );
    //     end
    // endrule

    rule genFirstBeat if (statusReg == EthernetPacketGeneratorStateGenFirstBeat);
        let curFpDebugTime <- getSimulationTime;
        let checksum = ipHdrCheckSumStreamPipeOut.first;
        ipHdrCheckSumStreamPipeOut.deq;

        let rdmaMeta = rdmaPacketMetaPipeInQ.first;
        rdmaPacketMetaPipeInQ.deq;

        let pipelineEntry = ipHeaderChecksumCalcPipelineQ.first;
        ipHeaderChecksumCalcPipelineQ.deq;

        pipelineEntry.macIpUdpHeader.ipHeader.ipChecksum = checksum;
        let macIpUdpHeader = pipelineEntry.macIpUdpHeader;

        // make sure it exactly three 32-bytes, i.e., 96 bytes.
        Bit#(TMul#(3, DATA_BUS_HALF_BEAT_BIT_WIDTH)) macIpUdpBthEth = {pack(macIpUdpHeader), pack(rdmaMeta.header)};

        DATA data = truncateLSB(macIpUdpBthEth);
        let isLast = pipelineEntry.totalEthernetFrameLen <= fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        let outBeat = IoChannelEthDataStream{
            data: swapEndianByte(data),
            byteNum: fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)),
            startByteIdx: 0,
            isFirst: True,
            isLast: isLast
        };

        immAssert(
            !isLast,
            "send packet must be more than 1 beat in 512 bits wide bus",
            $format("pipelineEntry.totalEthernetFrameLen=", fshow(pipelineEntry.totalEthernetFrameLen))
        );

        ethernetPacketPipeOutQ.enq(outBeat);

        let outPipelineEntry = PacketGeneratorFirstBeatToSecondBeatPipelineEntry {
            hasPayload      : rdmaMeta.hasPayload,
            fpDebugTime     : curFpDebugTime
        };
        DataBeatHalf prevBeatHalfData = truncate(macIpUdpBthEth);
        prevBeatReg <= DataStream {
            data: zeroExtendLSB(prevBeatHalfData),
            startByteIdx: dontCareValue,
            byteNum: dontCareValue,
            isFirst: dontCareValue,
            isLast: dontCareValue
        };

        firstBeatToSecondBeatPipelineReg <= outPipelineEntry;
        statusReg <= EthernetPacketGeneratorStateGenSecondBeat;
        ethernetFrameLeftByteCounterReg <= pipelineEntry.totalEthernetFrameLen - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));

        $display(
            "time=%0t:", $time, toGreen(" mkEthernetPacketGenerator genFirstBeat"),
            toBlue(", outBeat="), fshow(outBeat),
            toBlue(", pipelineEntry.totalEthernetFrameLen="), fshow(pipelineEntry.totalEthernetFrameLen),
            toBlue(", outPipelineEntry="), fshow(outPipelineEntry)
        );

        // No need to check fully-pipeline here, since first beat is generated without payload, so it can be very fast, and second need payload, will delay a lot
        // checkFullyPipeline(firstBeatToSecondBeatPipelineReg.fpDebugTime, 2, 2000, "mkEthernetPacketGenerator genSecondBeat");
        // let _ <- fpChecker.putStreamBeatInfo(outBeat.isFirst, outBeat.isLast);
    endrule



    rule genSecondBeat if (statusReg == EthernetPacketGeneratorStateGenSecondBeat);
        let curFpDebugTime <- getSimulationTime;
        let isLast = ethernetFrameLeftByteCounterReg <= fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        
        let outBeat = ?;
        let hasPayload = firstBeatToSecondBeatPipelineReg.hasPayload;
        DataBeatHalf payloadDataPartFromPreviousBeat = truncateLSB(prevBeatReg.data);
        if (hasPayload) begin
            let payloadDs = rdmaPayloadPipeInQ.first;
            rdmaPayloadPipeInQ.deq;

            DataBeatHalf payloadDataPartConsumedByThisBeat = truncate(payloadDs.data);

            // note: the payload data is aligned to Dword, so the first beat of payload's start idx may not be zero.
            //       when concat to headers, the byteNum shoud be adjusted, i.e., add startByeIdx to byteNum.
            let payloadDataByteNum = zeroExtend(payloadDs.startByteIdx) + payloadDs.byteNum;

            if (isLast) begin
                immAssert(
                    payloadDs.isFirst && payloadDs.isLast && payloadDs.byteNum <= fromInteger(valueOf(DATA_BUS_HALF_BEAT_BYTE_WIDTH)),
                    "payload beat is not correct",
                    $format(
                        "payloadDs=", fshow(payloadDs),
                        ", ethernetFrameLeftByteCounterReg=", fshow(ethernetFrameLeftByteCounterReg)
                    )
                );

                statusReg <= EthernetPacketGeneratorStateGenFirstBeat;
            end
            else begin
                immAssert(
                    payloadDs.isFirst && payloadDs.byteNum > fromInteger(valueOf(DATA_BUS_HALF_BEAT_BYTE_WIDTH)),
                    "payload beat is not correct",
                    $format(
                        "payloadDs=", fshow(payloadDs),
                        ", ethernetFrameLeftByteCounterReg=", fshow(ethernetFrameLeftByteCounterReg)
                    )
                );
                if (payloadDs.isLast) begin
                    statusReg <= EthernetPacketGeneratorStateGenExtraLastBeat;
                end
                else begin
                    statusReg <= EthernetPacketGeneratorStateGenMoreBeat;
                end
            end

            prevBeatReg <= payloadDs;

            outBeat = IoChannelEthDataStream{
                data: {payloadDataPartConsumedByThisBeat, swapEndianByte(payloadDataPartFromPreviousBeat)},
                byteNum: fromInteger(valueOf(DATA_BUS_HALF_BEAT_BYTE_WIDTH)) + payloadDataByteNum,
                startByteIdx: 0,
                isFirst: False,
                isLast: isLast
            };
        end
        else begin
            immAssert(
                isLast,
                "when no payload, the second beat must be last beat",
                $format("ethernetFrameLeftByteCounterReg=", fshow(ethernetFrameLeftByteCounterReg))
            );
            
            outBeat = IoChannelEthDataStream{
                data: {0, swapEndianByte(payloadDataPartFromPreviousBeat)},
                byteNum: fromInteger(valueOf(DATA_BUS_HALF_BEAT_BYTE_WIDTH)),
                startByteIdx: 0,
                isFirst: False,
                isLast: isLast
            };
            statusReg <= EthernetPacketGeneratorStateGenFirstBeat;
        end
        ethernetPacketPipeOutQ.enq(outBeat);
        

        let outPipelineEntry = PacketGeneratorSecondBeatToMoreBeatPipelineEntry{
            fpDebugTime     : curFpDebugTime
        };
        secondBeatToMoreBeatPipelineReg <= outPipelineEntry;
        ethernetFrameLeftByteCounterReg <= ethernetFrameLeftByteCounterReg - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));

        $display(
            "time=%0t:", $time, toGreen(" mkEthernetPacketGenerator genSecondBeat"),
            toBlue(", outBeat="), fshow(outBeat),
            toBlue(", ethernetFrameLeftByteCounterReg="), fshow(ethernetFrameLeftByteCounterReg),
            toBlue(", outPipelineEntry="), fshow(outPipelineEntry)
        );

        
        dataOutputFullyPipelineCheckTimeReg <= curFpDebugTime; // needed for genMoreBeat's check

        // No need to check fully-pipeline here, since first beat is generated without payload, so it can be very fast, and second need payload, will delay a lot
        // checkFullyPipeline(firstBeatToSecondBeatPipelineReg.fpDebugTime, 2, 2000, "mkEthernetPacketGenerator genSecondBeat");

        // But from the second beat to last beat, it should be continous
        let _ <- fpChecker.putStreamBeatInfo(True, outBeat.isLast);
    endrule

    rule genMoreBeat if (statusReg == EthernetPacketGeneratorStateGenMoreBeat);
        let curFpDebugTime <- getSimulationTime;

        let isLast = ethernetFrameLeftByteCounterReg <= fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));

        let payloadDs = rdmaPayloadPipeInQ.first;
        rdmaPayloadPipeInQ.deq;

        DataBeatHalf payloadDataPartConsumedByThisBeat = truncate(payloadDs.data);
        DataBeatHalf payloadDataPartFromPreviousBeat = truncateLSB(prevBeatReg.data);

        if (isLast) begin
            immAssert(
                !payloadDs.isFirst && payloadDs.isLast && payloadDs.byteNum <= fromInteger(valueOf(DATA_BUS_HALF_BEAT_BYTE_WIDTH)),
                "payload beat is not correct",
                $format(
                    "payloadDs=", fshow(payloadDs),
                    ", ethernetFrameLeftByteCounterReg=", fshow(ethernetFrameLeftByteCounterReg)
                )
            );

            statusReg <= EthernetPacketGeneratorStateGenFirstBeat;
        end
        else begin
            if (payloadDs.isLast) begin
                statusReg <= EthernetPacketGeneratorStateGenExtraLastBeat;
            end
            else begin
                statusReg <= EthernetPacketGeneratorStateGenMoreBeat;
            end
        end

        let byteNum = isLast ? truncate(ethernetFrameLeftByteCounterReg) : fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));

        let outBeat = IoChannelEthDataStream{
            data: {payloadDataPartConsumedByThisBeat, payloadDataPartFromPreviousBeat},
            byteNum: byteNum,
            startByteIdx: 0,
            isFirst: False,
            isLast: isLast
        };

        ethernetPacketPipeOutQ.enq(outBeat);
        prevBeatReg <= payloadDs;
        ethernetFrameLeftByteCounterReg <= ethernetFrameLeftByteCounterReg - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));

        dataOutputFullyPipelineCheckTimeReg <= curFpDebugTime;

        $display(
            "time=%0t:", $time, toGreen(" mkEthernetPacketGenerator genMoreBeat"),
            toBlue(", outBeat="), fshow(outBeat),
            toBlue(", ethernetFrameLeftByteCounterReg="), fshow(ethernetFrameLeftByteCounterReg)
        );
        if (!payloadDs.isFirst) begin
            checkFullyPipeline(dataOutputFullyPipelineCheckTimeReg, 1, 2000, DebugConf{name: "mkEthernetPacketGenerator genMoreBeat", enableDebug: True});
        end
        let _ <- fpChecker.putStreamBeatInfo(outBeat.isFirst, outBeat.isLast);
    endrule

    rule genExtraLastBeat if (statusReg == EthernetPacketGeneratorStateGenExtraLastBeat);
        let curFpDebugTime <- getSimulationTime;

        
        let isLast = ethernetFrameLeftByteCounterReg <= fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        immAssert(
            isLast,
            "must be last beat here",
            $format("ethernetFrameLeftByteCounterReg=", fshow(ethernetFrameLeftByteCounterReg))
        );

        DataBeatHalf payloadDataPartFromPreviousBeat = truncateLSB(prevBeatReg.data);

        BusByteIdx mod = truncate(ethernetFrameLeftByteCounterReg);

        
        BusByteCnt byteNum = prevBeatReg.byteNum - fromInteger(valueOf(DATA_BUS_HALF_BEAT_BYTE_WIDTH));
        DATA data = zeroExtend(payloadDataPartFromPreviousBeat);
        let outBeat = IoChannelEthDataStream{
            data: data,
            byteNum: byteNum,
            startByteIdx: 0,
            isFirst: False,
            isLast: True
        };
        ethernetPacketPipeOutQ.enq(outBeat);


        BusByteCnt byteNumCalcFromByteCounter = mod == 0 ? fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) : zeroExtend(pack(mod));
        immAssert(
            byteNumCalcFromByteCounter == byteNum,
            "last beat of payload length calcaluted by two different ways have different result.",
            $format(
                "Got prevBeatReg = ", fshow(prevBeatReg),
                ", outBeat=", fshow(outBeat),
                ", mod=", fshow(mod),
                ", ethernetFrameLeftByteCounterReg=", fshow(ethernetFrameLeftByteCounterReg),
                ", byteNumCalcFromByteCounter=", fshow(byteNumCalcFromByteCounter)
            )
        );

        statusReg <= EthernetPacketGeneratorStateGenFirstBeat;

        $display(
            "time=%0t:", $time, toGreen(" mkEthernetPacketGenerator genExtraLastBeat"),
            toBlue(", outBeat="), fshow(outBeat),
            toBlue(", ethernetFrameLeftByteCounterReg="), fshow(ethernetFrameLeftByteCounterReg)
        );
        checkFullyPipeline(dataOutputFullyPipelineCheckTimeReg, 1, 2000, DebugConf{name: "mkEthernetPacketGenerator genExtraLastBeat", enableDebug: True});
        let _ <- fpChecker.putStreamBeatInfo(outBeat.isFirst, outBeat.isLast);
    endrule

    method Action setLocalNetworkSettings(LocalNetworkSettings networkSettings);
        networkSettingsReg <= tagged Valid networkSettings;
    endmethod

    interface macIpUdpMetaPipeIn    = toPipeInB0(macIpUdpMetaPipeInQ);
    interface rdmaPacketMetaPipeIn  = toPipeInB0(rdmaPacketMetaPipeInQ);
    interface rdmaPayloadPipeIn     = toPipeInB0(rdmaPayloadPipeInQ);
    interface ethernetPacketPipeOut = toPipeOut(ethernetPacketPipeOutQ);
endmodule
