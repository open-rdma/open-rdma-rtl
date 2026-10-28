package E2eTop;

import Connectable :: *;

import CommonTypes :: *;
import MrcTxScheduler :: *;
import MrcTxTypes :: *;
import PacketAssembly :: *;
import RetxM3Bridge :: *;
import RetxReplayStore :: *;
import RetxTop :: *;
import RetxTxTap :: *;
import RetxTypes :: *;
import RetxWqeMonitor :: *;
import RxFeedbackTap :: *;
import RxTop :: *;
import RxTypes :: *;
import TxTypes :: *;

// 完整 TX-RX-Retx 数据通路：
//
//   context/payload -> M2 -> tap -> M3 -> wire -> RxTop (M4-M8)
//                              ^                    |
//                              |              feedback tap
//                        M11 -> bridge             |
//                              ^                 M9/M10
//                              |                    |
//                        replay store <---- packet tap
//
// CPU 通过 retx host ABI（snapshot/report/notification/retry/result）观察并
// 驱动重传；正常报文只走 M2->M3->RxTop，重传报文走 M11->bridge->M3 的
// TRAFFIC_RETRY 入口，由 M3 在 packet 边界插入主数据流。
interface E2eTopIfc;
    // TX ingress / egress
    interface PipeIn#(MessageContext) txContextIn;
    interface PipeIn#(MessagePayloadBeat) txPayloadIn;
    interface PipeIn#(MrcTxCfgReq) txConfigIn;
    interface PipeOut#(CfgResp) txConfigOut;
    interface PipeIn#(MrcSourceProfileConfig) txSourceRouteConfigIn;
    interface PipeOut#(EthPacket) txChannel0Out;
    interface PipeOut#(EthPacket) txChannel1Out;
    interface PipeOut#(EthPacket) txChannel2Out;
    interface PipeOut#(EthPacket) txChannel3Out;
    interface PipeOut#(TxCommit) txCommitOut;
    interface PipeOut#(TxEgressEvent) txEgressOut;

    // RX
    method Action configureEpoch(RxEpoch value);
    method Action configureNetwork(RxNetworkConfig cfg);
    method Action configureQp(RxQpIndex index, RxQpConfig cfg);
    method Action configureQp0(RxQpConfig cfg);
    method Action start;
    interface PipeIn#(RxWireBeat) rxLane0;
    interface PipeIn#(RxWireBeat) rxLane1;
    interface PipeIn#(RxWireBeat) rxLane2;
    interface PipeIn#(RxWireBeat) rxLane3;
    interface PipeOut#(RxDmaWriteRequest) rxDmaRequest0;
    interface PipeOut#(RxDmaWriteRequest) rxDmaRequest1;
    interface PipeOut#(RxDmaWriteRequest) rxDmaRequest2;
    interface PipeOut#(RxDmaWriteRequest) rxDmaRequest3;
    interface PipeOut#(RxDmaPayloadBeat) rxDmaPayload0;
    interface PipeOut#(RxDmaPayloadBeat) rxDmaPayload1;
    interface PipeOut#(RxDmaPayloadBeat) rxDmaPayload2;
    interface PipeOut#(RxDmaPayloadBeat) rxDmaPayload3;
    interface PipeIn#(RxDmaCompletion) rxDmaCompletion0;
    interface PipeIn#(RxDmaCompletion) rxDmaCompletion1;
    interface PipeIn#(RxDmaCompletion) rxDmaCompletion2;
    interface PipeIn#(RxDmaCompletion) rxDmaCompletion3;
    interface PipeOut#(RxCompletion) rxCompletionOut;
    interface PipeOut#(RxError) rxErrorsOut;
    interface PipeOut#(RxFeedback) rxFeedbackObsOut;
    interface PipeOut#(RxTxFeedback) rxTxFeedbackOut;
    interface PipeOut#(RxEcnEvent) rxEcnOut;
    interface PipeOut#(RxOrderedCredit) rxOrderedCreditOut;

    // Retx host ABI
    method Action configureRetx(Bit#(32) hostSession, Bit#(32) nicSession);
    method Action configureRetxQpAt(Bit#(2) idx, RetxQpConfigHw cfg);
    method Action configureRetxQp0(RetxQpConfigHw cfg);
    method Action setRetxEpoch(Bit#(16) epoch);
    interface PipeIn#(RetxSnapshotReqHw) retxSnapshotReqIn;
    interface PipeOut#(RetxReportHeader) retxReportHeaderOut;
    interface PipeOut#(RetxHoleEntry) retxReportEntryOut;
    interface PipeOut#(RetxNotificationHw) retxNotificationOut;
    interface PipeIn#(RetxOnDemandReqHw) retxOnDemandIn;
    interface PipeOut#(RetxOnDemandReqHw) retxOnDemandOut;
    interface PipeIn#(RetxRetryEntry) retxRetryIn;
    interface PipeOut#(RetxRetryResultHw) retxResultOut;
    interface PipeOut#(RetxRecordTerminateHw) retxReleaseOut;
endinterface

(* synthesize *)
module mkE2eTop(E2eTopIfc);
    PacketAssemblyEngineIfc m2 <- mkPacketAssemblyEngine;
    FourChannelTxSchedulerIfc m3 <- mkFourChannelTxScheduler;
    RxTopIfc rx <- mkRxTop;
    RetxTopIfc retx <- mkRetxTop;
    RetxWqeMonitorIfc monitor <- mkRetxWqeMonitor;
    RetxTxTapIfc tap <- mkRetxTxTap;
    RetxReplayStoreIfc replay <- mkRetxReplayStore;
    RxFeedbackTapIfc feedbackTap <- mkRxFeedbackTap;
    RetxM3BridgeIfc bridge <- mkRetxM3Bridge;

    // TX 主链路：context 旁路登记 WQE，M2 之后逐 packet 预留并捕获 replay。
    mkConnection(monitor.contextOut, m2.contextIn);
    mkConnection(m2.descriptorOut, tap.descriptorIn);
    mkConnection(m2.payloadOut, tap.payloadIn);
    mkConnection(tap.descriptorOut, m3.firstDescriptorIn);
    mkConnection(tap.payloadOut, m3.firstPayloadIn);
    mkConnection(monitor.recordOut, tap.recordIn);
    mkConnection(monitor.wqeRegisterOut, retx.wqeRegisterIn);
    mkConnection(retx.wqeRegisterRespOut, monitor.wqeRegisterRespIn);
    mkConnection(tap.reserveOut, retx.packetReserveIn);
    mkConnection(retx.packetGrantOut, tap.grantIn);
    mkConnection(tap.sentOut, retx.sentEventIn);
    mkConnection(tap.replayWriteOut, replay.writeIn);

    // 重传链路：M11 -> M3 retry ingress；fetch 由 replay store 提供。
    mkConnection(retx.m3DescOut, bridge.retxDescriptorIn);
    mkConnection(retx.m3BeatOut, bridge.retxBeatIn);
    mkConnection(bridge.descriptorOut, m3.retryDescriptorIn);
    mkConnection(bridge.payloadOut, m3.retryPayloadIn);
    mkConnection(retx.fetchReqOut, replay.fetchReqIn);
    mkConnection(replay.fetchBeatOut, retx.fetchBeatIn);

    // RX 本地 feedback 同时驱动 M9 scoreboard 与 CPU 观测端口。
    mkConnection(rx.feedback, feedbackTap.feedbackIn);
    mkConnection(feedbackTap.retxOut, retx.feedbackIn);

    interface txContextIn = monitor.contextIn;
    interface txPayloadIn = m2.payloadIn;
    interface txConfigIn = m3.configServer.request;
    interface txConfigOut = m3.configServer.response;
    interface txSourceRouteConfigIn = m3.sourceRouteConfigIn;
    interface txChannel0Out = m3.channel0Out;
    interface txChannel1Out = m3.channel1Out;
    interface txChannel2Out = m3.channel2Out;
    interface txChannel3Out = m3.channel3Out;
    interface txCommitOut = m3.txCommitOut;
    interface txEgressOut = m3.txEgressOut;

    method Action configureEpoch(RxEpoch value) = rx.configureEpoch(value);
    method Action configureNetwork(RxNetworkConfig cfg) = rx.configureNetwork(cfg);
    method Action configureQp(RxQpIndex index, RxQpConfig cfg) = rx.configureQp(index, cfg);
    method Action configureQp0(RxQpConfig cfg) = rx.configureQp(0, cfg);
    method Action start = rx.start;
    interface rxLane0 = rx.ports[0];
    interface rxLane1 = rx.ports[1];
    interface rxLane2 = rx.ports[2];
    interface rxLane3 = rx.ports[3];
    interface rxDmaRequest0 = rx.dmaRequests[0];
    interface rxDmaRequest1 = rx.dmaRequests[1];
    interface rxDmaRequest2 = rx.dmaRequests[2];
    interface rxDmaRequest3 = rx.dmaRequests[3];
    interface rxDmaPayload0 = rx.dmaPayloads[0];
    interface rxDmaPayload1 = rx.dmaPayloads[1];
    interface rxDmaPayload2 = rx.dmaPayloads[2];
    interface rxDmaPayload3 = rx.dmaPayloads[3];
    interface rxDmaCompletion0 = rx.dmaCompletions[0];
    interface rxDmaCompletion1 = rx.dmaCompletions[1];
    interface rxDmaCompletion2 = rx.dmaCompletions[2];
    interface rxDmaCompletion3 = rx.dmaCompletions[3];
    interface rxCompletionOut = rx.completion;
    interface rxErrorsOut = rx.errors;
    interface rxFeedbackObsOut = feedbackTap.observeOut;
    interface rxTxFeedbackOut = rx.txFeedback;
    interface rxEcnOut = rx.ecn;
    interface rxOrderedCreditOut = rx.orderedCredit;

    method Action configureRetx(Bit#(32) hostSession, Bit#(32) nicSession);
        retx.configure(hostSession, nicSession);
    endmethod
    method Action configureRetxQpAt(Bit#(2) idx, RetxQpConfigHw cfg);
        retx.configureQpAt(idx, cfg);
    endmethod
    method Action configureRetxQp0(RetxQpConfigHw cfg);
        retx.configureQpAt(0, cfg);
    endmethod
    method Action setRetxEpoch(Bit#(16) epoch);
        monitor.setEpoch(epoch);
        tap.setEpoch(epoch);
        feedbackTap.setEpoch(epoch);
    endmethod
    interface retxSnapshotReqIn = retx.snapshotReqIn;
    interface retxReportHeaderOut = retx.reportHeaderOut;
    interface retxReportEntryOut = retx.reportEntryOut;
    interface retxNotificationOut = retx.notificationOut;
    interface retxOnDemandIn = retx.onDemandIn;
    interface retxOnDemandOut = retx.onDemandOut;
    interface retxRetryIn = retx.retryIn;
    interface retxResultOut = retx.resultOut;
    interface retxReleaseOut = retx.releaseOut;
endmodule

endpackage
