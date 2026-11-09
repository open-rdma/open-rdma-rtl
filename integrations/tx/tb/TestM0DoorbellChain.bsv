// TestM0DoorbellChain: raw Doorbell -> M0 -> M3 test wrapper.

import CommonTypes :: *;
import Connectable :: *;
import DmaPhaseAIntegration :: *;
import DmaTypes :: *;
import DoorbellIngress :: *;
import M0MessageAdapter :: *;
import MrcTxTypes :: *;
import TxTypes :: *;
import TxMvpTypes :: *;

interface TestM0DoorbellChain;
    interface PipeIn#(GdrpDoorbellWrite) submissionPipeIn;

    interface PipeIn#(SlotCfgReq) slotCfgReqPipeIn;
    interface PipeOut#(TxCfgResp) slotCfgRespPipeOut;
    interface PipeIn#(QpCfgReq) qpCfgReqPipeIn;
    interface PipeOut#(TxCfgResp) qpCfgRespPipeOut;
    interface PipeIn#(MrCfgReq) mrCfgReqPipeIn;
    interface PipeOut#(TxCfgResp) mrCfgRespPipeOut;
    interface PipeIn#(PgtCfgReq) pgtCfgReqPipeIn;
    interface PipeOut#(TxCfgResp) pgtCfgRespPipeOut;

    interface PipeOut#(DmaReadRequest) dmaReadReqPipeOut;
    interface PipeIn#(DmaCompletionBeat) dmaCompletionPipeIn;

    interface PipeOut#(EthPacket) channel0PipeOut;
    interface PipeOut#(EthPacket) channel1PipeOut;
    interface PipeOut#(EthPacket) channel2PipeOut;
    interface PipeOut#(EthPacket) channel3PipeOut;
    interface PipeOut#(TxCommit) txCommitPipeOut;
    interface PipeOut#(TxEgressEvent) txEgressPipeOut;
    interface PipeOut#(DmaMessageDone) dmaMessageDonePipeOut;
    interface PipeIn#(MrcSourceProfileConfig) sourceRouteConfigPipeIn;
    interface PipeIn#(MrcEvEntryConfig) evEntryConfigPipeIn;
    interface PipeIn#(MrcEvPolicyConfig) evPolicyConfigPipeIn;
    interface PipeIn#(MrcPortStatusUpdate) portStatusPipeIn;
    interface PipeIn#(MrcPathFeedback) pathFeedbackPipeIn;
    interface PipeOut#(MrcProbeRequest) probePipeOut;
    interface PipeOut#(MrcNoPathEvent) noPathPipeOut;

    interface PipeIn#(MrcTxCfgReq) configPipeIn;
    interface PipeOut#(CfgResp) configRespPipeOut;
endinterface

(* synthesize *)
module mkTestM0DoorbellChain(TestM0DoorbellChain);
    DoorbellTxMvpIfc m0 <- mkDoorbellTxMvp(64'h0000_0000_0000_1000);
    let glue <- mkM0MessageAdapter;
    let chain <- mkDmaPhaseAIntegration;

    mkConnection(m0.dmaReadReqOut, glue.requestIn);
    mkConnection(glue.chunkOut, chain.chunkIn);
    mkConnection(glue.contextOut, chain.contextIn);

    interface submissionPipeIn = m0.doorbellIn;

    interface slotCfgReqPipeIn = m0.slotConfig.request;
    interface slotCfgRespPipeOut = m0.slotConfig.response;
    interface qpCfgReqPipeIn = m0.qpConfig.request;
    interface qpCfgRespPipeOut = m0.qpConfig.response;
    interface mrCfgReqPipeIn = m0.mrConfig.request;
    interface mrCfgRespPipeOut = m0.mrConfig.response;
    interface pgtCfgReqPipeIn = m0.pgtConfig.request;
    interface pgtCfgRespPipeOut = m0.pgtConfig.response;

    interface dmaReadReqPipeOut = chain.dmaReadReqOut;
    interface dmaCompletionPipeIn = chain.dmaCompletionIn;

    interface channel0PipeOut = chain.channel0Out;
    interface channel1PipeOut = chain.channel1Out;
    interface channel2PipeOut = chain.channel2Out;
    interface channel3PipeOut = chain.channel3Out;
    interface txCommitPipeOut = chain.txCommitOut;
    interface txEgressPipeOut = chain.txEgressOut;
    interface dmaMessageDonePipeOut = chain.dmaMessageDoneOut;
    interface sourceRouteConfigPipeIn = chain.sourceRouteConfigIn;
    interface evEntryConfigPipeIn = chain.evEntryConfigIn;
    interface evPolicyConfigPipeIn = chain.evPolicyConfigIn;
    interface portStatusPipeIn = chain.portStatusIn;
    interface pathFeedbackPipeIn = chain.pathFeedbackIn;
    interface probePipeOut = chain.probeOut;
    interface noPathPipeOut = chain.noPathOut;

    interface configPipeIn = chain.configServer.request;
    interface configRespPipeOut = chain.configServer.response;
endmodule
