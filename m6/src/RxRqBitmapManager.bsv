//这个包 RxRqBitmapManager 是接收路径中的RQ（Request Queue）位图管理器。它位于 RxPacketParser 之后，负责把解析出来的数据包按 QP（Queue Pair）归属、做接收窗口和 PSN 检查、维护接收位图、处理乱序/重复/超时/越窗等情况，并产生 ACK/NACK 反馈、允许包（admitted）输出、缓冲区释放请求和错误上报。它还支持“先暂存后解析”的 pending 机制，以应对乱序到达和上下文尚未建立的情况。
package RxRqBitmapManager;
import Vector::*;
import FIFOF::*;
import RegFile::*;
import CommonTypes::*;
import TxTypes::*;
import RxTypes::*;

Integer rxRqInputQueueDepth = 4;
Integer rxRqIngressQueueDepth = 8;
Integer rxRqRouteQueueDepth = 32;
Integer rxRqLaneQueueDepth = 4;
Integer rxRqReleaseQueueDepth = 8;
Integer rxRqFeedbackQueueDepth = 32;
Integer rxRqErrorQueueDepth = 16;
Integer rxPendingMaxAge = valueOf(RxWindowSize) - 1;

// 描述一个 QP 的接收侧状态
typedef struct {
    TxPsn ackPsn;
    Bit#(RxWindowSize) receiveBitmap;
    Bit#(7) oooCount;
    Bool contextValid;
    TxPsn startPsn;
    TxPsn lastPsn;
    Bit#(64) remoteAddr;
    Bit#(32) rkey;
    TxLength messageBytes;
} RxRqState deriving(Bits, Eq, FShow);

// 根据当前 QP 状态生成一份反馈快照
function RxFeedback rxFeedbackSnapshot(RxQpConfig cfg, RxRqState state,
        TxPsn triggerPsn, Bool nak);
    return RxFeedback{qpn:cfg.qpn,
        kind:nak ? RX_NACK : (state.receiveBitmap != 0 ? RX_SACK : RX_ACK),
        ackPsn:state.ackPsn, sackBase:state.ackPsn + 1,
        sackBitmap:zeroExtend(state.receiveBitmap), oooCount:state.oooCount,
        triggerPsn:triggerPsn};
endfunction

// 定义 RQ 位图管理器对外接口
interface RxRqBitmapManagerIfc;
    method Action configure(RxQpIndex index, RxQpConfig cfg);
    method Action start;
    method RxReceiveProgress progress(RxQpIndex index);
    method RxGlobalSeq nextGlobalSeq;
    method Bool faulted;
    interface Vector#(RxLaneCount, PipeIn#(RxParsedPacket)) packets;
    interface Vector#(RxLaneCount, PipeOut#(RxAdmittedPacket)) admitted;
    interface Vector#(RxLaneCount, PipeOut#(RxBufferRelease)) releases;
    interface PipeOut#(RxFeedback) feedbackOut;
    interface PipeOut#(RxError) errorOut;
endinterface

module mkRxRqBitmapManager(RxRqBitmapManagerIfc);
    Reg#(Bool) running <- mkReg(False);
    Reg#(Bool) failed <- mkReg(False);
    Vector#(RxQpCount, Reg#(RxQpConfig)) cfgs <- replicateM(mkReg(unpack(0)));
    Vector#(RxQpCount, Reg#(RxRqState)) states <- replicateM(mkReg(unpack(0)));
    Vector#(RxQpCount, Reg#(Bit#(RxWindowSize))) pendingValid <- replicateM(mkReg(0));
    RegFile#(RxPendingIndex, RxParsedPacket) pendingPackets <- mkRegFileFull;
    RegFile#(RxPendingIndex, RxPendingAge) pendingAge <- mkRegFileFull;
    Vector#(RxLaneCount, FIFOF#(RxParsedPacket)) inputQ <- replicateM(mkSizedFIFOF(rxRqInputQueueDepth));
    FIFOF#(RxParsedPacket) ingressQ <- mkSizedFIFOF(rxRqIngressQueueDepth);
    FIFOF#(RxAdmittedPacket) admittedRouteQ <- mkSizedFIFOF(rxRqRouteQueueDepth);
    FIFOF#(RxBufferRelease) releaseRouteQ <- mkSizedFIFOF(rxRqRouteQueueDepth);
    Vector#(RxLaneCount, FIFOF#(RxAdmittedPacket)) admittedQ <- replicateM(mkSizedFIFOF(rxRqLaneQueueDepth));
    Vector#(RxLaneCount, FIFOF#(RxBufferRelease)) releaseQ <- replicateM(mkSizedFIFOF(rxRqReleaseQueueDepth));
    FIFOF#(RxFeedback) feedbackQ <- mkSizedFIFOF(rxRqFeedbackQueueDepth);
    FIFOF#(RxError) errorQ <- mkSizedFIFOF(rxRqErrorQueueDepth);
    Reg#(RxGlobalSeq) globalSeq <- mkReg(0);
    Reg#(RxLaneId) ingressCursor <- mkReg(0);
    Reg#(RxQpIndex) pendingScanQp <- mkReg(0);
    Reg#(RxWindowIndex) pendingScanIndex <- mkReg(0);
    Reg#(Bool) resolvePhase <- mkReg(False);
    Bool pendingExists = False;
    for (Integer i = 0; i < valueOf(RxQpCount); i = i + 1)
        pendingExists = pendingExists || pendingValid[i] != 0;

    // 入口合并规则：从各个 lane 的输入队列中挑选一个 ready 的 lane，把它的第一个包放入 ingressQ
    function Bit#(RxLaneCount) ingressReadyMask();
        Bit#(RxLaneCount) ready = 0;
        for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1)
            ready[i] = pack(inputQ[i].notEmpty);
        return ready;
    endfunction
    let selectedIngressLane = rxPickReadyLane(ingressReadyMask(), ingressCursor);
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1) begin
        rule mergeIngressLane(!resolvePhase && isValid(selectedIngressLane)
                && fromMaybe(0, selectedIngressLane) == fromInteger(i));
            ingressQ.enq(inputQ[i].first);
            inputQ[i].deq;
            ingressCursor <= fromInteger((i + 1) % valueOf(RxLaneCount));
        endrule
    end

    // 扫描暂存区，看有没有包现在可以重新进入正常处理流程。
    rule resolvePending(running && !failed && resolvePhase && pendingExists);
        let scanState = states[pendingScanQp];
        RxWindowIndex scanIndex = pendingScanIndex;
        let pendingPacket = pendingPackets.sub({pendingScanQp, scanIndex});
        let age = pendingAge.sub({pendingScanQp, scanIndex});
        TxPsn packetIndex = pendingPacket.psn - scanState.startPsn;
        Bool belongs = scanState.contextValid && packetIndex[23] == 0
            && rxPsnAtOrAfter(scanState.lastPsn, pendingPacket.psn);
        Bool starts = !scanState.contextValid && pendingPacket.first
            && pendingPacket.psn == scanState.ackPsn + 1;
        Bool validPending = pendingValid[pendingScanQp][scanIndex] == 1;
        if (validPending && (belongs || starts)) begin
            Bit#(RxWindowSize) bits = pendingValid[pendingScanQp];
            bits[scanIndex] = 0;
            pendingValid[pendingScanQp] <= bits;
            ingressQ.enq(pendingPacket);
        end
        else if (validPending && age == fromInteger(rxPendingMaxAge)) begin
            Bit#(RxWindowSize) bits = pendingValid[pendingScanQp];
            bits[scanIndex] = 0;
            pendingValid[pendingScanQp] <= bits;
            releaseRouteQ.enq(RxBufferRelease{tag:pendingPacket.payloadTag});
            feedbackQ.enq(rxFeedbackSnapshot(cfgs[pendingScanQp], scanState,
                pendingPacket.psn, True));
            errorQ.enq(RxError{qpn:pendingPacket.qpn, psn:pendingPacket.psn,
                code:RX_PENDING_TIMEOUT});
        end
        else if (validPending)
            pendingAge.upd({pendingScanQp, scanIndex}, age + 1);
        pendingScanIndex <= pendingScanIndex + 1;
        if (pendingScanIndex == fromInteger(rxPendingMaxAge))
            pendingScanQp <= pendingScanQp + 1;
        resolvePhase <= False;
    endrule

    // 当没有新包要处理、但暂存区有包时，进入解析阶段。
    rule advanceIdleToResolve(running && !failed && !resolvePhase
            && pendingExists && !ingressQ.notEmpty);
        resolvePhase <= True;
    endrule

    // 模块核心，处理 ingressQ 中的包：检查 QP、PSN、窗口、位图、上下文等，决定是直接 admit、暂存 pending、还是丢弃并反馈错误。
    rule processCandidate(running && !failed && !resolvePhase
            && ingressQ.notEmpty);
        let packet = ingressQ.first;
        ingressQ.deq;
        // QP 匹配：根据包的 QPN 在 4 个 QP 配置中查找匹配。
        Bit#(3) matchCount = 0;
        RxQpIndex qp = 0;
        for (Integer i = 0; i < valueOf(RxQpCount); i = i + 1) begin
            if (cfgs[i].valid && cfgs[i].qpn == packet.qpn) begin
                matchCount = matchCount + 1;
                qp = fromInteger(i);
            end
        end

            // 匹配失败时释放缓冲区、报 RX_UNKNOWN_QP，并置故障标志。
            if (matchCount != 1) begin
                releaseRouteQ.enq(RxBufferRelease{tag:packet.payloadTag});
                errorQ.enq(RxError{qpn:packet.qpn, psn:packet.psn, code:RX_UNKNOWN_QP});
                failed <= True;
            end
            else begin
                let cfg = cfgs[qp];
                let state = states[qp];
                // 计算该包相对当前窗口的位置，判断是否为旧包、是否在窗口内、是否已提交重复、是否暂存重复。
                TxPsn nextPsn = state.ackPsn + 1;
                TxPsn windowOffset = packet.psn - nextPsn;
                Bool oldPacket = rxPsnBefore(packet.psn, nextPsn);
                Bool inWindow = rxPsnInWindow(state.ackPsn, packet.psn);
                RxWindowIndex ringIndex = truncate(packet.psn);
                RxWindowIndex bitmapIndex = truncate(windowOffset);
                Bool committedDuplicate = inWindow
                    && state.receiveBitmap[bitmapIndex] == 1;
                Bool pendingDuplicate = inWindow && pendingValid[qp][ringIndex] == 1;
                let existingPending = pendingPackets.sub({qp, ringIndex});
                Bool replacePending = pendingDuplicate && packet.first;

                // 重复/旧包/越窗处理
                if (replacePending) begin
                    releaseRouteQ.enq(RxBufferRelease{
                        tag:existingPending.payloadTag});
                    pendingPackets.upd({qp, ringIndex}, packet);
                    pendingAge.upd({qp, ringIndex}, 0);
                end
                else if (oldPacket || committedDuplicate || pendingDuplicate) begin
                    releaseRouteQ.enq(RxBufferRelease{tag:packet.payloadTag});
                    feedbackQ.enq(rxFeedbackSnapshot(cfg, state, packet.psn, False));
                end
                else if (!inWindow) begin
                    releaseRouteQ.enq(RxBufferRelease{tag:packet.payloadTag});
                    feedbackQ.enq(rxFeedbackSnapshot(cfg, state, packet.psn, True));
                    errorQ.enq(RxError{qpn:packet.qpn, psn:packet.psn,
                        code:RX_OUT_OF_WINDOW});
                end
                else begin
                    // 正常接纳流程
                    Bool establishing = !state.contextValid && packet.first
                        && packet.psn == nextPsn;
                    TxPsn contextStart = establishing ? packet.psn : state.startPsn;
                    Bit#(64) contextAddr = establishing ? packet.remoteAddr : state.remoteAddr;
                    Bit#(32) contextRkey = establishing ? packet.rkey : state.rkey;
                    TxLength contextBytes = establishing ? packet.messageBytes : state.messageBytes;
                    TxPsn contextLast = state.lastPsn;
                    if (establishing) begin
                        TxPsnCount packetCount = packetCountForMessage(contextBytes,
                            cfg.pmtu);
                        contextLast = contextStart + zeroExtend(packetCount) - 1;
                    end
                    TxPsn packetIndex = packet.psn - contextStart;
                    Bool belongs = (state.contextValid || establishing)
                        && packetIndex[23] == 0
                        && rxPsnAtOrAfter(contextLast, packet.psn);

                    if (!belongs) begin
                        pendingPackets.upd({qp, ringIndex}, packet);
                        pendingAge.upd({qp, ringIndex}, 0);
                        Bit#(RxWindowSize) bits = pendingValid[qp];
                        bits[ringIndex] = 1;
                        pendingValid[qp] <= bits;
                    end
                    else begin
                        // 校验远端写权限、rkey、地址范围、物理地址范围，以及该包的首尾标志和负载长度是否符合预期。
                        Bit#(38) messageOffset = packetIndex == 0 ? 0
                            : zeroExtend(firstPayloadLimit(cfg.pmtu))
                                + (zeroExtend(packetIndex) - 1)
                                    * zeroExtend(contPayloadLimit(cfg.pmtu));
                        Bit#(38) packetLimit = zeroExtend(packetIndex == 0
                            ? firstPayloadLimit(cfg.pmtu) : contPayloadLimit(cfg.pmtu));
                        Bit#(38) messageWide = zeroExtend(contextBytes);
                        Bit#(38) remaining = messageOffset < messageWide
                            ? messageWide - messageOffset : 0;
                        Bit#(38) expectedBytes = remaining < packetLimit
                            ? remaining : packetLimit;
                        Bool expectedLast = messageOffset + expectedBytes == messageWide;
                        Bit#(65) regionEnd = zeroExtend(cfg.virtualBase)
                            + zeroExtend(cfg.regionBytes);
                        Bit#(65) messageEnd = zeroExtend(contextAddr)
                            + zeroExtend(contextBytes);
                        Bit#(65) mrOffset = zeroExtend(contextAddr)
                            - zeroExtend(cfg.virtualBase);
                        Bit#(66) physicalMessageStart = zeroExtend(cfg.physicalBase)
                            + zeroExtend(mrOffset);
                        Bit#(66) physicalMessageEnd = physicalMessageStart
                            + zeroExtend(contextBytes);
                        Bit#(66) physical = physicalMessageStart
                            + zeroExtend(messageOffset);
                        Bool access = txPmtuBytes(cfg.pmtu) != 0 && cfg.remoteWrite
                            && cfg.rkey == contextRkey && contextBytes != 0
                            && contextAddr >= cfg.virtualBase
                            && messageEnd <= regionEnd
                            && messageEnd <= rxAddressLimit65()
                            && physicalMessageEnd
                                <= rxAddressLimit66();
                        Bool segment = packet.first == (packetIndex == 0)
                            && packet.last == expectedLast
                            && (!packet.first || (packet.remoteAddr == contextAddr
                                && packet.rkey == contextRkey
                                && packet.messageBytes == contextBytes))
                            && expectedBytes != 0
                            && zeroExtend(packet.payloadBytes) == expectedBytes;

                        // 校验失败处理：释放缓冲区、报错、置故障。
                        if (!access || !segment) begin
                            releaseRouteQ.enq(RxBufferRelease{tag:packet.payloadTag});
                            errorQ.enq(RxError{qpn:packet.qpn, psn:packet.psn,
                                code:access ? RX_BAD_SEGMENT : RX_ACCESS_DENIED});
                            failed <= True;
                        end
                        else begin
                            // 合并位图、推进 ACK、生成允许包
                            RxRqState nextState = state;
                            if (establishing) begin
                                nextState.contextValid = True;
                                nextState.startPsn = contextStart;
                                nextState.lastPsn = contextLast;
                                nextState.remoteAddr = contextAddr;
                                nextState.rkey = contextRkey;
                                nextState.messageBytes = contextBytes;
                            end
                            Bit#(16) merged = state.receiveBitmap;
                            merged[bitmapIndex] = 1;
                            TxPsn mergedAck = state.ackPsn;
    for (Integer i = 0; i < valueOf(RxWindowSize); i = i + 1) begin
                                if (merged[0] == 1) begin
                                    merged = merged >> 1;
                                    mergedAck = mergedAck + 1;
                                end
                            end
                            nextState.ackPsn = mergedAck;
                            nextState.receiveBitmap = merged;
                            Bit#(5) mergedCount = pack(countOnes(merged));
                            nextState.oooCount = zeroExtend(mergedCount);
                            Bool ackValid = mergedAck != state.ackPsn;
                            Bool messageComplete = ackValid
                                && rxPsnAtOrAfter(mergedAck, contextLast);
                            if (messageComplete)
                                nextState.contextValid = False;
                            states[qp] <= nextState;

                            let admittedPacket = RxAdmittedPacket{
                                globalSeq:globalSeq, payloadTag:packet.payloadTag,
                                lane:packet.lane, qp:qp, qpn:packet.qpn, psn:packet.psn,
                                dmaAddr:truncate(physical), payloadStart:packet.payloadStart,
                                payloadBytes:packet.payloadBytes, messageBytes:contextBytes,
                                first:packet.first, last:packet.last, ackValid:ackValid,
                                ackPsnAfterMerge:mergedAck,
                                messageComplete:messageComplete,
                                messageLastPsn:contextLast};
                            admittedRouteQ.enq(admittedPacket);
                            feedbackQ.enq(rxFeedbackSnapshot(cfg, nextState,
                                packet.psn, False));
                            globalSeq <= globalSeq + 1;
                        end
                    end
                end
            end
        resolvePhase <= pendingExists;  // 如果处理完后仍有暂存包，则下一周期进入解析阶段。


    endrule

    // 把中间路由队列中的允许包和释放请求按 lane 分发到对应的输出队列。注意，这里没有对 lane 进行检查，因为输入队列已经保证了 lane 的正确性。
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1) begin
        rule routeAdmitted(admittedRouteQ.notEmpty
                && admittedRouteQ.first.lane == fromInteger(i));
            admittedQ[i].enq(admittedRouteQ.first);
            admittedRouteQ.deq;
        endrule
        rule routeRelease(releaseRouteQ.notEmpty
                && releaseRouteQ.first.tag.lane == fromInteger(i));
            releaseQ[i].enq(releaseRouteQ.first);
            releaseRouteQ.deq;
        endrule
    end

    // 接口绑定
    Vector#(RxLaneCount, PipeIn#(RxParsedPacket)) packetInputs;
    Vector#(RxLaneCount, PipeOut#(RxAdmittedPacket)) admittedOutputs;
    Vector#(RxLaneCount, PipeOut#(RxBufferRelease)) releaseOutputs;
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1) begin
        packetInputs[i] = interface PipeIn;
            method Action enq(RxParsedPacket packet)
                    if (running && !failed && inputQ[i].notFull);
                inputQ[i].enq(packet);
            endmethod
            method Bit#(1) notFull = pack(running && !failed
                && inputQ[i].notFull);
        endinterface;
        admittedOutputs[i] = toPipeOut(admittedQ[i]);
        releaseOutputs[i] = toPipeOut(releaseQ[i]);
    end

    method Action configure(RxQpIndex index, RxQpConfig cfg) if (!running);
        cfgs[index] <= cfg;
        RxRqState stateInit = unpack(0);
        stateInit.ackPsn = cfg.initialPsn - 1;
        states[index] <= stateInit;
        pendingValid[index] <= 0;
    endmethod
    method Action start if (!running);
        running <= True;
    endmethod
    method RxReceiveProgress progress(RxQpIndex index);
        let state = states[index];
        return RxReceiveProgress{ackPsn:state.ackPsn,
            receiveBitmap:state.receiveBitmap, oooCount:state.oooCount};
    endmethod
    method RxGlobalSeq nextGlobalSeq = globalSeq;
    method Bool faulted = failed;
    interface packets = packetInputs;
    interface admitted = admittedOutputs;
    interface releases = releaseOutputs;
    interface feedbackOut = toPipeOut(feedbackQ);
    interface errorOut = toPipeOut(errorQ);
endmodule
endpackage
