import Vector :: *;
import Printf :: *;
import Clocks :: *;
import Settings :: *;
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
import FullyPipelineChecker :: *;

import ConnectableF :: *;
import NapWrapper :: *;
import Descriptors :: *;
import PacketGenAndParse :: *;

import Ringbuf :: *;
import EthernetTypes :: *;


typedef 2 COMMAND_QUEUE_DESCRIPTOR_MAX_IN_USE_SEG_COUNT;
typedef 2 SQ_DESCRIPTOR_MAX_IN_USE_SEG_COUNT;



interface WorkQueueDescParser;
    interface PipeIn#(RingbufRawDescriptor) rawDescPipeIn;
    interface PipeOut#(WorkQueueElem)       workReqPipeOut;
endinterface


(* synthesize *)
module mkWorkQueueDescParser(WorkQueueDescParser);

    FIFOF#(WorkQueueElem) workReqPipeOutQ <- mkFIFOF;

    RingbufDescriptorReadProxy#(SQ_DESCRIPTOR_MAX_IN_USE_SEG_COUNT) sqDescReadProxy <- mkRingbufDescriptorReadProxy;
    
    rule forwardSQ;
        let curFpDebugTime <- getSimulationTime;
        let {reqSegBuf, headDescIdx} = sqDescReadProxy.descFragsPipeOut.first;
        sqDescReadProxy.descFragsPipeOut.deq;

        SendQueueReqDescSeg0 desc0 = unpack(reqSegBuf[1]);
        SendQueueReqDescSeg1 desc1 = unpack(reqSegBuf[0]);


        WorkQueueElem req   = unpack(0);
        req.msn             = desc0.msn;
        req.opcode          = unpack(truncate(desc0.commonHeader.opCode));
        req.flags           = unpack(pack(desc0.flags));
        req.qpType          = desc0.qpType;
        req.psn             = desc0.psn;
        req.pmtu            = desc1.pmtu;
        req.dqpIP           = desc0.dqpIP;
        req.macAddr         = desc1.macAddr;
        req.laddr           = desc1.laddr;
        req.lkey            = desc1.lkey;
        req.raddr           = desc0.raddr;
        req.rkey            = desc0.rkey;
        req.len             = desc1.len;
        req.totalLen        = desc0.totalLen;
        req.dqpn            = desc0.dqpn;
        req.sqpn            = {desc1.sqpnHigh16Bits, desc1.sqpnLow8Bits};
        req.isFirst         = desc1.isFirst;
        req.isLast          = desc1.isLast;
        req.isRetry         = desc1.isRetry;
        req.fpDebugTime     = curFpDebugTime;
        

        let hasImmDt = workReqHasImmDt(req.opcode);
        let hasInv   = workReqHasInv(req.opcode);
        let immOrInv = hasImmDt ? tagged Imm desc1.imm : tagged RKey desc1.imm;
        req.immDtOrInvRKey = (hasImmDt || hasInv) ? tagged Valid immOrInv : tagged Invalid;

        workReqPipeOutQ.enq(req);
        $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "SQ read a new descriptor: ", fshow(req));
    endrule

    interface rawDescPipeIn = sqDescReadProxy.rawDescPipeIn;
    interface workReqPipeOut = toPipeOut(workReqPipeOutQ);
endmodule




interface CommandQueueDescParserAndDispatcher;
    interface PipeIn#(RingbufRawDescriptor)                                 reqRawDescPipeIn;
    interface PipeOut#(RingbufRawDescriptor)                                respRawDescPipeOut;
    interface ClientP#(RingbufRawDescriptor, Bool)                           mrAndPgtManagerClt;
    interface ClientP#(WriteReqQPC, Bool)                                    qpcModifyClt;
    interface PipeOut#(LocalNetworkSettings)                                setNetworkParamReqPipeOut;
    interface Get#(RawPacketReceiveMeta)                                    setRawPacketReceiveMetaReqOut;
    interface PipeOut#(IndexQP)                                             qpResetReqPipeOut;
endinterface


(* synthesize *)
module mkCommandQueueDescParserAndDispatcher(CommandQueueDescParserAndDispatcher ifc);

    // If we need to wait for response for some cycle to finish, then we need to set this to False;
    Reg#(Bool) isDispatchingReqReg                                                          <- mkReg(True);
    
    FIFOF#(RingbufRawDescriptor) mrAndPgtReqQ                                               <- mkLFIFOF;
    FIFOF#(RingbufRawDescriptor) mrAndPgtInflightReqQ                                       <- mkFIFOF;
    PipeInAdapterB0#(Bool) mrAndPgtRespQ                                                    <- mkPipeInAdapterB0;

    QueuedClientP#(WriteReqQPC, Bool) qpcUpdateCltInst <- mkQueuedClientP(DebugConf{name: "mkCommandQueueDescParserAndDispatcher qpcUpdateCltInst", enableDebug: False});
    FIFOF#(RingbufRawDescriptor) qpcInflightReqQ                                            <- mkFIFOF;

    FIFOF#(LocalNetworkSettings) setNetworkParamPipeOutQ                                    <- mkFIFOF;
    FIFOF#(RawPacketReceiveMeta) setRawPacketReceiveMetaReqQ                                <- mkLFIFOF;
    FIFOF#(IndexQP)              qpResetReqPipeOutQ                                         <- mkFIFOF;


    RingbufDescriptorReadProxy#(COMMAND_QUEUE_DESCRIPTOR_MAX_IN_USE_SEG_COUNT) descReadProxy <- mkRingbufDescriptorReadProxy;
    RingbufDescriptorWriteProxy#(COMMAND_QUEUE_DESCRIPTOR_MAX_IN_USE_SEG_COUNT) descWriteProxy <- mkRingbufDescriptorWriteProxy;
    
    rule dispatchRingbufRequestDescriptors if (isDispatchingReqReg);
        Vector#(COMMAND_QUEUE_DESCRIPTOR_MAX_IN_USE_SEG_COUNT, RingbufRawDescriptor) respRawDescSeg = ?;

        let {reqSegBuf, headDescIdx} = descReadProxy.descFragsPipeOut.first;
        descReadProxy.descFragsPipeOut.deq;

        RingbufRawDescriptor rawDesc = reqSegBuf[headDescIdx];
        RingbufDescCommonHead descComHdr = unpack(truncate(rawDesc >> 240));

        case (unpack(truncate(descComHdr.opCode)))
            CmdQueueOpcodeUpdateMrTable, CmdQueueOpcodeUpdatePGT: begin
                mrAndPgtReqQ.enq(rawDesc);
                mrAndPgtInflightReqQ.enq(rawDesc); // TODO, we can simplify this to only include 32-bit user_data field
                isDispatchingReqReg <= False;
            end
            CmdQueueOpcodeQpManagement: begin
                CmdQueueReqDescQpManagement desc0 = unpack(reqSegBuf[0]);

                let ent = EntryQPC {
                    peerQPN   :     desc0.peerQPN,
                    qpnKeyPart:     getKeyQP(desc0.qpn), 
                    qpType:         desc0.qpType,
                    rqAccessFlags:  desc0.rqAccessFlags,
                    pmtu:           desc0.pmtu,
                    peerMacAddr:    desc0.peerMacAddr,
                    peerIpAddr:     desc0.peerIpAddr,
                    localUdpPort:   desc0.localUdpPort
                };

                qpcInflightReqQ.enq(rawDesc);
                qpcUpdateCltInst.putReq(
                    WriteReqQPC {
                        qpn: desc0.qpn,
                        ent: desc0.isValid ? tagged Valid ent : tagged Invalid
                    }
                );
                qpResetReqPipeOutQ.enq(getIndexQP(desc0.qpn));
                isDispatchingReqReg <= False;
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware receive cmd queue descriptor: ", fshow(desc0));
            end
            CmdQueueOpcodeSetNetworkParam: begin
                CmdQueueReqDescSetNetworkParam reqDesc = unpack(rawDesc);
                let localNetworkConfig = LocalNetworkSettings {
                    macAddr     :   reqDesc.macAddr,
                    ipAddr      :   reqDesc.ipAddr,
                    netMask     :   reqDesc.netMask,
                    gatewayAddr :   reqDesc.gateWay
                };
                setNetworkParamPipeOutQ.enq(localNetworkConfig);
                CmdQueueRespDescOnlyCommonHeader respDesc = unpack(pack(reqDesc));
                respDesc.cmdQueueCommonHeader.isSuccess = True;
                respDesc.commonHeader.valid = True;
                respDesc.commonHeader.hasNextFrag = False;
                respRawDescSeg[0] = pack(respDesc);
                descWriteProxy.descFragsPipeIn.enq(tuple2(respRawDescSeg, 0));
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware receive cmd queue descriptor: ", fshow(reqDesc));
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware Send cmd queue response: ", fshow(respDesc));
            end
            CmdQueueOpcodeSetRawPacketReceiveMeta: begin
                CmdQueueReqDescSetRawPacketReceiveMeta reqDesc = unpack(rawDesc);
                setRawPacketReceiveMetaReqQ.enq(RawPacketReceiveMeta{
                    writeBaseAddr: reqDesc.writeBaseAddr
                });

                CmdQueueRespDescOnlyCommonHeader respDesc = unpack(pack(reqDesc));
                respDesc.cmdQueueCommonHeader.isSuccess = True;
                respDesc.commonHeader.valid = True;
                respDesc.commonHeader.hasNextFrag = False;
                respRawDescSeg[0] = pack(respDesc);
                descWriteProxy.descFragsPipeIn.enq(tuple2(respRawDescSeg, 0));
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware receive cmd queue descriptor: ", fshow(reqDesc));
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware Send cmd queue response: ", fshow(respDesc));
            end
        endcase

    endrule

    rule gatherResponse if (!isDispatchingReqReg);
        // TODO should we use a fair algorithm here?
        
        Vector#(COMMAND_QUEUE_DESCRIPTOR_MAX_IN_USE_SEG_COUNT, RingbufRawDescriptor) respRawDescSeg = ?;
        

        if (mrAndPgtRespQ.notEmpty) begin
            CmdQueueRespDescOnlyCommonHeader respDesc = unpack(mrAndPgtInflightReqQ.first);
            respDesc.cmdQueueCommonHeader.isSuccess = mrAndPgtRespQ.first;
            respDesc.commonHeader.valid = True;
            respDesc.commonHeader.hasNextFrag = False;
            mrAndPgtInflightReqQ.deq;
            mrAndPgtRespQ.deq;
            respRawDescSeg[0] = pack(respDesc);
            descWriteProxy.descFragsPipeIn.enq(tuple2(respRawDescSeg, 0));
            isDispatchingReqReg <= True;
            $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware Send cmd queue response: ", fshow(respDesc));
        end 
        else if (qpcUpdateCltInst.hasResp) begin 
            qpcInflightReqQ.deq;
           
            CmdQueueRespDescQpManagement respDesc = unpack(qpcInflightReqQ.first);
            respDesc.cmdQueueCommonHeader.isSuccess <- qpcUpdateCltInst.getResp;
            respDesc.commonHeader.valid = True;
            respDesc.commonHeader.hasNextFrag = False;
            respRawDescSeg[0] = pack(respDesc);
            descWriteProxy.descFragsPipeIn.enq(tuple2(respRawDescSeg, 0));
            isDispatchingReqReg <= True;
            $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware Send cmd queue response: ", fshow(respDesc));
        end
    endrule

    interface reqRawDescPipeIn = descReadProxy.rawDescPipeIn;
    interface respRawDescPipeOut = descWriteProxy.rawDescPipeOut;

    interface mrAndPgtManagerClt = toGPClientP(toPipeOut(mrAndPgtReqQ), toPipeInB0(mrAndPgtRespQ));
    interface qpcModifyClt = qpcUpdateCltInst.clt;

    interface setNetworkParamReqPipeOut = toPipeOut(setNetworkParamPipeOutQ);
    interface setRawPacketReceiveMetaReqOut = toGet(setRawPacketReceiveMetaReqQ);
    interface qpResetReqPipeOut = toPipeOut(qpResetReqPipeOutQ);
endmodule

interface DescriptorMux;
    interface Vector#(NUMERIC_TYPE_TWO, PipeInB0#(RingbufRawDescriptor)) descPipeInVec;
    interface PipeOut#(RingbufRawDescriptor) descPipeOut;
endinterface

module mkDescriptorMux(DescriptorMux);

    Vector#(NUMERIC_TYPE_TWO, PipeInAdapterB0#(RingbufRawDescriptor)) descPipeInQueueVec <- replicateM(mkPipeInAdapterB0);
    Vector#(NUMERIC_TYPE_TWO, PipeInB0#(RingbufRawDescriptor)) descPipeInVecInst = newVector;

    FIFOF#(RingbufRawDescriptor) descPipeOutQueue <- mkFIFOF;

    for (Integer idx = 0; idx < valueOf(NUMERIC_TYPE_TWO); idx = idx + 1) begin
        descPipeInVecInst[idx] = toPipeInB0(descPipeInQueueVec[idx]);
    end

    Reg#(Bit#(TLog#(NUMERIC_TYPE_TWO))) currentForwardChannelReg <- mkRegU;
    Reg#(Bool) isForwardingFirstDescReg <- mkReg(True);


    rule forwardFirstDescRule if (isForwardingFirstDescReg);
        let rawDescMaybe = tagged Invalid;
        
        if (descPipeInQueueVec[0].notEmpty) begin
            rawDescMaybe = tagged Valid descPipeInQueueVec[0].first;
            descPipeInQueueVec[0].deq;
            currentForwardChannelReg <= 0;
        end
        else if (descPipeInQueueVec[1].notEmpty) begin
            rawDescMaybe = tagged Valid descPipeInQueueVec[1].first;
            descPipeInQueueVec[1].deq;
            currentForwardChannelReg <= 1;
        end
        // else if (descPipeInQueueVec[2].notEmpty) begin
        //     rawDescMaybe = tagged Valid descPipeInQueueVec[2].first;
        //     descPipeInQueueVec[2].deq;
        //     currentForwardChannelReg <= 2;
        // end

        if (rawDescMaybe matches tagged Valid .rawDesc) begin
            RingbufDescCommonHead descHeader = unpack(truncate(rawDesc >> 240));

            immAssert(
                descHeader.valid,
                "desc should be valid",
                $format("desc=", fshow(descHeader))
            );
            if (descHeader.hasNextFrag) begin
                isForwardingFirstDescReg <= False;
            end

            $display(
                "time=%0t:", $time, toGreen(" mkDescriptorMux forwardFirstDescRule"),
                toBlue(", descHeader="), fshow(descHeader),
                toBlue(", rawDesc="), fshow(rawDesc)
            );
            descPipeOutQueue.enq(rawDesc);
        end
    endrule

    rule forwardOtherDesc if (!isForwardingFirstDescReg);
        let rawDesc = descPipeInQueueVec[currentForwardChannelReg].first;
        descPipeInQueueVec[currentForwardChannelReg].deq;

        RingbufDescCommonHead descHeader = unpack(truncate(rawDesc >> 240));
        immAssert(
            descHeader.valid,
            "desc should be valid",
            $format("desc=", fshow(descHeader))
        );
        if (!descHeader.hasNextFrag) begin
            isForwardingFirstDescReg <= True;
        end

        // $display(
        //     "time=%0t:", $time, toGreen(" mkDescriptorMux forwardOtherDesc"),
        //     toBlue(", descHeader="), fshow(descHeader),
        //     toBlue(", rawDesc="), fshow(rawDesc)
        // );

        descPipeOutQueue.enq(rawDesc);
    endrule

    interface descPipeInVec = descPipeInVecInst;
    interface descPipeOut = toPipeOut(descPipeOutQueue);
endmodule
