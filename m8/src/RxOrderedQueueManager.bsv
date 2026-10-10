// 这个包 RxOrderedQueueManager 是接收路径中的有序队列管理器。它位于 RxDmaPlacement 之后，负责处理接收侧的有序标志（flag）DMA 写入、DMA 退休、信用管理、完成通知和错误上报。核心思想是：每个 QP 维护一个有序队列，存放待发送的标志写入请求；只有当该 QP 的 DMA ACK 已经推进到某个 barrier PSN 之后，才允许发送对应的标志请求；发送时消耗信用并产生预期响应；收到响应后确认完成，最终产生上层可见的完成通知。
package RxOrderedQueueManager;
import Vector::*;
import FIFOF::*;
import RWire::*;
import CommonTypes::*;
import TxTypes::*;
import RxTypes::*;

Integer rxOrderedQueueDepth = 4;
Integer rxOrderedRetireQueueDepth = 8;
Integer rxOrderedIngressQueueDepth = 8;
Integer rxOrderedResponseQueueDepth = 4;
Integer rxOrderedCreditQueueDepth = 8;
Integer rxOrderedCompletionQueueDepth = 8;
Integer rxOrderedErrorQueueDepth = 16;
Integer rxOrderedFlagBytes = 4;
Bit#(64) rxInitialOrderedGrantLimit = 64'd4;

// 表示一个待发送的有序标志条目。
typedef struct {
    RxOrderedSeq orderedSeq;
    TxQpn qpn;
    TxPsn barrierPsn;
    Bit#(64) dmaAddr;
    Bit#(32) value;
} RxOrderedEntry deriving(Bits, Eq, FShow);

// 校验标志写入请求的访问权限和地址范围。
function Bool rxOrderedFlagAccess(RxQpConfig cfg, RxOrderedFlagIngress flag);
    Bit#(65) offset = zeroExtend(flag.flagAddr) - zeroExtend(cfg.virtualBase);
    Bit#(65) endOffset = offset + fromInteger(rxOrderedFlagBytes);
    Bit#(66) physical = zeroExtend(cfg.physicalBase) + zeroExtend(offset);
    return cfg.remoteWrite && cfg.rkey == flag.rkey
        && flag.flagAddr[1:0] == 0 && flag.flagAddr >= cfg.virtualBase
        && endOffset <= zeroExtend(cfg.regionBytes)
        && physical + fromInteger(rxOrderedFlagBytes) <= rxAddressLimit66();
endfunction

// 把虚拟地址转换成物理 DMA 地址。
function Bit#(64) rxOrderedFlagPhysical(RxQpConfig cfg,
        RxOrderedFlagIngress flag);
    return cfg.physicalBase + (flag.flagAddr - cfg.virtualBase);
endfunction

interface RxOrderedQueueManagerIfc;
    method Action configureEpoch(RxEpoch value);
    method Action configure(RxQpIndex index, RxQpConfig cfg);
    method Action start;
    method TxPsn dmaAckPsn(RxQpIndex index);
    method Bool faulted;
    interface PipeIn#(RxDmaRetire) retireIn;
    interface PipeIn#(RxOrderedFlagIngress) orderedFlagIn;
    interface PipeOut#(RxFlagDmaRequest) flagRequestOut;
    interface PipeIn#(RxFlagDmaResponse) flagResponseIn;
    interface PipeOut#(RxOrderedCredit) creditOut;
    interface PipeOut#(RxCompletion) completionOut;
    interface PipeOut#(RxError) errorOut;
endinterface

module mkRxOrderedQueueManager(RxOrderedQueueManagerIfc);
    // 运行与配置状态：保存运行状态、epoch、各 QP 配置、DMA ACK、信用限额、上一个屏障 PSN。
    Reg#(Bool) running <- mkReg(False);
    Reg#(Bool) failed <- mkReg(False);
    Reg#(Bool) epochConfigured <- mkReg(False);
    Reg#(RxEpoch) currentEpoch <- mkReg(0);
    Vector#(RxQpCount, Reg#(RxQpConfig)) cfgs <- replicateM(mkReg(unpack(0)));
    Vector#(RxQpCount, Reg#(TxPsn)) dmaAck <- replicateM(mkReg(0));
    Vector#(RxQpCount, Reg#(Bit#(64))) grantLimit <- replicateM(mkReg(rxInitialOrderedGrantLimit));
    Vector#(RxQpCount, Reg#(Bool)) lastBarrierValid <- replicateM(mkReg(False));
    Vector#(RxQpCount, Reg#(TxPsn)) lastBarrier <- replicateM(mkReg(0));
    // 队列：每个 QP 一个有序队列，以及退休、入口、响应、信用、完成、错误队列。
    Vector#(RxQpCount, FIFOF#(RxOrderedEntry)) orderedQ <- replicateM(mkSizedFIFOF(rxOrderedQueueDepth));
    FIFOF#(RxDmaRetire) retireQ <- mkSizedFIFOF(rxOrderedRetireQueueDepth);
    FIFOF#(RxOrderedFlagIngress) ingressQ <- mkSizedFIFOF(rxOrderedIngressQueueDepth);
    FIFOF#(RxFlagDmaResponse) flagResponseQ <- mkSizedFIFOF(rxOrderedResponseQueueDepth);
    FIFOF#(RxOrderedCredit) creditQ <- mkSizedFIFOF(rxOrderedCreditQueueDepth);
    FIFOF#(RxCompletion) completionQ <- mkSizedFIFOF(rxOrderedCompletionQueueDepth);
    FIFOF#(RxError) errorQ <- mkSizedFIFOF(rxOrderedErrorQueueDepth);

    // 全局序号与选择状态：维护退休期望序号、下一个有序序号、轮询游标、当前选中的标志条目、未完成标志响应等。
    Reg#(RxGlobalSeq) expectedRetire <- mkReg(0);
    Reg#(RxOrderedSeq) nextOrderedSeq <- mkReg(0);
    Reg#(RxQpIndex) selectionCursor <- mkReg(0);
    Reg#(Bool) selectedValid <- mkReg(False);
    Reg#(RxQpIndex) selectedQp <- mkReg(0);
    Reg#(RxOrderedEntry) selectedEntry <- mkReg(unpack(0));
    Reg#(Bool) flagOutstanding <- mkReg(False);
    Reg#(RxOrderedSeq) expectedFlagResponse <- mkReg(0);
    RWire#(RxQpIndex) dequeueQp <- mkRWire;

    // 当 flagRequestOut.deq 被调用时，通过 dequeueQp 通知对应 QP 的有序队列出队。
    for (Integer i = 0; i < valueOf(RxQpCount); i = i + 1) begin
        rule dequeueAcceptedFlag(dequeueQp.wget matches tagged Valid .qp
                &&& qp == fromInteger(i));
            orderedQ[i].deq;
        endrule
    end

    // 处理来自 DMA 的退休信号。
    rule processRetire(running && !failed);
        let retired = retireQ.first;
        retireQ.deq;
        if (!retired.success || retired.globalSeq != expectedRetire) begin
            errorQ.enq(RxError{qpn:retired.qpn, psn:retired.psn,
                code:RX_ORDERED_BAD_RETIRE});
            failed <= True;
        end
        else begin
            expectedRetire <= expectedRetire + 1;
            if (retired.ackValid)
                dmaAck[retired.qp] <= retired.ackPsnAfterMerge;
            if (retired.messageComplete)
                completionQ.enq(RxCompletion{qpn:retired.qpn,
                    lastPsn:retired.messageLastPsn,
                    bytes:retired.messageBytes, success:True});
        end
    endrule

    // 计算下一个标志的匹配与顺序信息：对入口队列队首的标志请求，计算它匹配的 QP、是否满足顺序条件、是否有访问权限。
    let nextFlag = ingressQ.first;
    Bit#(RxQpCount) nextFlagMatchMask = 0;
    Bit#(RxQpCount) nextFlagOrderMask = 0;
    Bool nextFlagHasAccess = False;
    for (Integer i = 0; i < valueOf(RxQpCount); i = i + 1) begin
        Bool qpMatches = cfgs[i].valid && cfgs[i].qpn == nextFlag.qpn;
        Bool qpOrdered = !lastBarrierValid[i]
            || rxPsnAtOrAfter(nextFlag.barrierPsn, lastBarrier[i]);
        nextFlagMatchMask[i] = pack(qpMatches);
        nextFlagOrderMask[i] = pack(qpOrdered);
        if (qpMatches && qpOrdered && rxOrderedFlagAccess(cfgs[i], nextFlag))
            nextFlagHasAccess = True;
    end
    Bit#(3) nextFlagMatchCount = zeroExtend(pack(countOnes(nextFlagMatchMask)));

    // 如果标志请求匹配的 QP 数不为 1，或没有访问权限，则拒绝。
    rule rejectInvalidFlag(running && !failed && ingressQ.notEmpty
            && (nextFlagMatchCount != 1 || !nextFlagHasAccess));
        ingressQ.deq;
        errorQ.enq(RxError{qpn:nextFlag.qpn, psn:nextFlag.barrierPsn,
            code:RX_ORDERED_BAD_FLAG});
        failed <= True;
    endrule

    for (Integer i = 0; i < valueOf(RxQpCount); i = i + 1) begin
        // 若标志请求合法且对应 QP 有序队列不满，则接纳，分配 orderedSeq，更新该 QP 的 lastBarrier，递增 nextOrderedSeq；
        rule admitOrderedFlag(running && !failed && ingressQ.notEmpty
                && nextFlagMatchCount == 1 && cfgs[i].valid
                && cfgs[i].qpn == nextFlag.qpn
                && nextFlagOrderMask[i] == 1
                && rxOrderedFlagAccess(cfgs[i], nextFlag)
                && orderedQ[i].notFull);
            ingressQ.deq;
            orderedQ[i].enq(RxOrderedEntry{orderedSeq:nextOrderedSeq,
                qpn:nextFlag.qpn, barrierPsn:nextFlag.barrierPsn,
                dmaAddr:rxOrderedFlagPhysical(cfgs[i], nextFlag),
                value:nextFlag.value});
            lastBarrier[i] <= nextFlag.barrierPsn;
            lastBarrierValid[i] <= True;
            nextOrderedSeq <= nextOrderedSeq + 1;
        endrule
        // 若队列满，则拒绝并报 RX_ORDERED_QUEUE_FULL。
        rule rejectOrderedOverflow(running && !failed && ingressQ.notEmpty
                && nextFlagMatchCount == 1 && cfgs[i].valid
                && cfgs[i].qpn == nextFlag.qpn
                && nextFlagOrderMask[i] == 1
                && rxOrderedFlagAccess(cfgs[i], nextFlag)
                && !orderedQ[i].notFull);
            ingressQ.deq;
            errorQ.enq(RxError{qpn:nextFlag.qpn, psn:nextFlag.barrierPsn,
                code:RX_ORDERED_QUEUE_FULL});
            failed <= True;
        endrule
    end

    // 轮询选择下一个可发送的标志条目。
    for (Integer i = 0; i < valueOf(RxQpCount); i = i + 1) begin
        rule selectEligibleFlag(running && !failed && !selectedValid
                && !flagOutstanding && selectionCursor == fromInteger(i)
                && orderedQ[i].notEmpty
                && rxPsnAtOrAfter(dmaAck[i], orderedQ[i].first.barrierPsn));
            selectedEntry <= orderedQ[i].first;
            selectedQp <= fromInteger(i);
            selectedValid <= True;
            selectionCursor <= fromInteger((i + 1) % valueOf(RxQpCount));
        endrule
        rule skipEmptyQp(running && !failed && !selectedValid
                && !flagOutstanding && selectionCursor == fromInteger(i)
                && !orderedQ[i].notEmpty);
            selectionCursor <= fromInteger((i + 1) % valueOf(RxQpCount));
        endrule
        rule skipBlockedQp(running && !failed && !selectedValid
                && !flagOutstanding && selectionCursor == fromInteger(i)
                && orderedQ[i].notEmpty
                && !rxPsnAtOrAfter(dmaAck[i], orderedQ[i].first.barrierPsn));
            selectionCursor <= fromInteger((i + 1) % valueOf(RxQpCount));
        endrule
    end

    // 处理标志 DMA 响应。
    rule consumeFlagResponse(running && !failed && flagOutstanding);
        let response = flagResponseQ.first;
        flagResponseQ.deq;
        if (response.orderedSeq != expectedFlagResponse
                || response.epoch != currentEpoch || !response.success) begin
            errorQ.enq(RxError{qpn:selectedEntry.qpn,
                psn:selectedEntry.barrierPsn,
                code:response.success ? RX_FLAG_DMA_BAD_RESPONSE : RX_FLAG_DMA_FAILED});
            failed <= True;
        end
        else begin
            flagOutstanding <= False;
        end
    endrule

    // 当没有未完成标志请求却收到响应时，视为陈旧响应。
    rule rejectStaleFlagResponse(running && !failed && !flagOutstanding);
        let response = flagResponseQ.first;
        flagResponseQ.deq;
        errorQ.enq(RxError{qpn:0, psn:0, code:RX_FLAG_DMA_BAD_RESPONSE});
        failed <= True;
    endrule

    // 提供 epoch 配置、QP 配置、启动、查询 DMA ACK 和故障标志。
    method Action configureEpoch(RxEpoch value) if (!running);
        currentEpoch <= value;
        epochConfigured <= True;
    endmethod
    method Action configure(RxQpIndex index, RxQpConfig cfg) if (!running);
        cfgs[index] <= cfg;
        dmaAck[index] <= cfg.initialPsn - 1;
        grantLimit[index] <= rxInitialOrderedGrantLimit;
        lastBarrierValid[index] <= False;
        lastBarrier[index] <= 0;
    endmethod
    method Action start if (!running && epochConfigured);
        running <= True;
    endmethod
    method TxPsn dmaAckPsn(RxQpIndex index) = dmaAck[index];
    method Bool faulted = failed;
    // 接口 retireIn：接收 DMA 退休，只有运行、未故障且队列不满时允许。
    interface retireIn = interface PipeIn;
        method Action enq(RxDmaRetire value) if (running && !failed && retireQ.notFull);
            retireQ.enq(value);
        endmethod
        method Bit#(1) notFull = pack(running && !failed && retireQ.notFull);
    endinterface;
    // 接口 orderedFlagIn：接收有序标志写入请求。
    interface orderedFlagIn = interface PipeIn;
        method Action enq(RxOrderedFlagIngress value)
                if (running && !failed && ingressQ.notFull);
            ingressQ.enq(value);
        endmethod
        method Bit#(1) notFull = pack(running && !failed && ingressQ.notFull);
    endinterface;
    // 接口 flagRequestOut：输出标志 DMA 请求。只有运行、未故障、选择有效且队列不满时允许。
    interface flagRequestOut = interface PipeOut;
        method RxFlagDmaRequest first if (running && !failed && selectedValid
                && creditQ.notFull);
            return RxFlagDmaRequest{orderedSeq:selectedEntry.orderedSeq,
                epoch:currentEpoch, qpn:selectedEntry.qpn, barrierPsn:selectedEntry.barrierPsn,
                addr:selectedEntry.dmaAddr, value:selectedEntry.value};
        endmethod
        method Action deq if (running && !failed && selectedValid
                && creditQ.notFull);
            dequeueQp.wset(selectedQp);
            let nextGrant = grantLimit[selectedQp] + 1;
            grantLimit[selectedQp] <= nextGrant;
            creditQ.enq(RxOrderedCredit{qpn:selectedEntry.qpn,
                orderedGrantLimit:nextGrant});
            expectedFlagResponse <= selectedEntry.orderedSeq;
            flagOutstanding <= True;
            selectedValid <= False;
        endmethod
        method Bit#(1) notEmpty = pack(running && !failed && selectedValid
            && creditQ.notFull);
    endinterface;
    interface flagResponseIn = toPipeIn(flagResponseQ);
    interface creditOut = toPipeOut(creditQ);
    interface completionOut = toPipeOut(completionQ);
    interface errorOut = toPipeOut(errorQ);
endmodule
endpackage
