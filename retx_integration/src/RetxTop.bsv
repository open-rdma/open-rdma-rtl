package RetxTop;

import RetxTypes::*;
import CommonTypes::*;
import Connectable::*;
import RetxStateManager::*;
import RetxReportEngine::*;
import RetxRetryEngine::*;

// Feature composition: m9 facts -> m10 Report -> host runtime; runtime -> m11;
// m11 Admission -> m9; replay fetch beats -> m11 -> M3 descriptor/beats.
interface RetxTopIfc;
    method Action configure(Bit#(32) hostSession, Bit#(32) nicSession);
    method Action configureQpAt(Bit#(2) idx, RetxQpConfigHw cfg);
    method Action resetQp(Bit#(24) qpn);
    interface PipeIn#(RetxWqeRegisterHw) wqeRegisterIn;
    interface PipeOut#(RetxWqeRegisterRespHw) wqeRegisterRespOut;
    interface PipeIn#(RetxPacketReserveHw) packetReserveIn;
    interface PipeOut#(RetxPacketGrantHw) packetGrantOut;
    interface PipeIn#(RetxSentEventHw) sentEventIn;
    interface PipeIn#(RetxFeedbackEventHw) feedbackIn;
    interface PipeIn#(RetxSnapshotReqHw) snapshotReqIn;
    interface PipeOut#(RetxReportHeader) reportHeaderOut;
    interface PipeOut#(RetxHoleEntry) reportEntryOut;
    interface PipeOut#(RetxNotificationHw) notificationOut;
    interface PipeIn#(RetxOnDemandReqHw) onDemandIn;
    interface PipeOut#(RetxOnDemandReqHw) onDemandOut;
    interface PipeIn#(RetxRetryEntry) retryIn;
    interface PipeIn#(RetxFetchBeatHw) fetchBeatIn;
    interface PipeOut#(RetxFetchReqHw) fetchReqOut;
    interface PipeOut#(RetxM3DescHw) m3DescOut;
    interface PipeOut#(RetxM3BeatHw) m3BeatOut;
    interface PipeOut#(RetxRetryResultHw) resultOut;
    interface PipeOut#(RetxRecordTerminateHw) releaseOut;
endinterface

(* synthesize *)
module mkRetxTop(RetxTopIfc);
    RetxStateManagerIfc state <- mkRetxStateManager;
    RetxReportEngineIfc report <- mkRetxReportEngine;
    RetxRetryEngineIfc retry <- mkRetxRetryEngine;

    mkConnection(state.snapshotHdrOut, report.snapshotIn);
    mkConnection(state.snapshotEntryOut, report.entryIn);
    mkConnection(retry.admissionReqOut, state.admissionReqIn);
    mkConnection(state.admissionGrantOut, retry.admissionGrantIn);

    method Action configure(Bit#(32) hostS, Bit#(32) nicS);
        report.configure(nicS, hostS);
        retry.configure(hostS, nicS);
    endmethod
    method Action configureQpAt(Bit#(2) idx, RetxQpConfigHw cfg) = state.configureQpAt(idx, cfg);
    method Action resetQp(Bit#(24) qpn) = state.resetQp(qpn);

    interface wqeRegisterIn = state.wqeRegisterIn;
    interface wqeRegisterRespOut = state.wqeRegisterRespOut;
    interface packetReserveIn = state.packetReserveIn;
    interface packetGrantOut = state.packetGrantOut;
    interface sentEventIn = state.sentEventIn;
    interface feedbackIn = state.feedbackIn;
    interface snapshotReqIn = state.snapshotReqIn;
    interface reportHeaderOut = report.reportHeaderOut;
    interface reportEntryOut = report.reportEntryOut;
    interface notificationOut = report.notificationOut;
    interface onDemandIn = report.onDemandIn;
    interface onDemandOut = report.onDemandOut;
    interface retryIn = retry.retryIn;
    interface fetchBeatIn = retry.fetchBeatIn;
    interface fetchReqOut = retry.fetchReqOut;
    interface m3DescOut = retry.m3DescOut;
    interface m3BeatOut = retry.m3BeatOut;
    interface resultOut = retry.resultOut;
    interface releaseOut = state.releaseOut;
endmodule

endpackage
