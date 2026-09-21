# OpenRDMA 近期工作与实验安排

### 证据链 1：GPU 轻量提交

**近期工作：**

整理现有 M0–M3 TX fast path，并补充 Doorbell Credit/Grant，使 `8-byte intent → Slot/MR/QP/PGT 查询 → PSN/DMA → Packetization → TX` 链路完整。

**配套实验：**

硬件侧使用 **BSV cycle-accurate simulation**，测试单请求和连续请求，得到 Doorbell 到内部 request、first packet 的周期，并测试高提交速率下 Credit backpressure。软件侧建立 **CPU Proxy、Full-WQE GPU-side、OpenRDMA 8-byte Intent** 三种控制路径模型，比较 GPU 侧需要执行的控制操作。

**需要拿到的数据/图：**

- control bytes / request
- memory operations / request
- atomic operations / request
- Doorbell → request latency
- Doorbell → first packet latency
- pipeline initiation interval
- maximum sustainable request rate
- Credit/FIFO occupancy

最终建议形成 **1 张 Submission Rate/Latency 图 + 1 张三种 submission control-path 开销对比图或小表**。

**支撑证据：**

证明 OpenRDMA 不需要 GPU 在 fast path 构造完整 WQE，8-byte intent 能减少 GPU 侧控制工作，同时通过 Credit 保证资源使用有界。

---

### 证据链 2：Multipath 与乱序可靠传输

**近期工作：**

补 M4 RX Packet Parse 和 M5 RQ Bitmap，并逐步连接 WQE Record/Scoreboard，使接收端能够记录乱序 packet、推进 `ack_psn` 并产生基础 ACK/SACK feedback。

**配套实验：**

硬件侧使用 **BSV** 验证顺序、乱序、duplicate 和窗口边界情况下 RQ Bitmap 与 `ack_psn` 是否正确。软件侧开发 **packet-level discrete-event Simulator**，模拟 1/2/4 条路径以及不同 bandwidth、delay、loss 和 reordering，比较 Single Path、简单回退式 recovery 和 selective recovery。

**需要拿到的数据/图：**

- aggregate goodput
- flow completion time
- 1/2/4 path utilization
- reorder depth
- RQ Bitmap occupancy
- retransmitted bytes / packets
- duplicate traffic
- recovery latency

重点形成两张图：

> **Path Count / Path Skew → Goodput**

以及：

> **Reordering / Loss Rate → Retransmission Overhead**

**支撑证据：**

证明 multipath 可以获得并行链路收益；同时由于 receiver 保存 sparse arrival state，正常的跨路径乱序不会直接被当成 packet loss，从而避免大量不必要的重传。

---

### 证据链 3：GPU-visible Ordered Completion

**近期工作：**

重点补 M6 RX DMA Placement、M7 DMA Completion Merge/Ordered Retire 和 M8 Ordered Queue/Flag Manager，把：

```text
packet receive
→ ack_psn
→ DMA completion
→ dma_ack_psn
→ barrier
→ Flag publication
```

整条链跑通。

**配套实验：**

硬件侧用 **BSV** 人为制造 Flag 提前到达、network reordering、DMA completion reordering 和两者同时乱序，验证 Flag 不会提前发布。软件侧再做多 QP simulation，比较当前 Global Retire 和理想 Per-QP Retire，在 DMA straggler 下观察 HOL blocking。

**需要拿到的数据/图：**

- `ack_psn` progression
- `dma_ack_psn` progression
- Flag arrival cycle
- Flag publication cycle
- Flag pending latency
- premature Flag count
- P50/P99 completion latency
- Ordered Queue occupancy
- HOL blocked request 数量

其中最重要的 correctness 数据是：

> **premature Flag = 0**

最终建议形成一张非常直观的：

> **Packet Arrival → DMA Completion → `dma_ack_psn` → Flag Publication 时序图**

再形成一张：

> **DMA disorder / straggler → Completion Latency**

如果做 Global vs Per-QP retire，再作为一个小图放在这一节。

**支撑证据：**

证明可靠收到 packet 和 GPU 可以安全消费数据是两个不同的完成边界。OpenRDMA 可以允许 network 和 DMA 乱序执行，但只有 payload placement 和 ordering dependency 真正完成以后才发布 GPU-visible Flag。

---

### 证据链 4：HW/SW Recovery Tradeoff

**近期工作：**

补 M9 的 WQE Record、SQ Scoreboard 和 Retry Interface。BSV 第一阶段先做到 ACK/SACK 状态更新、PSN→request metadata 查询和 retry request 重新进入 TX，不急着实现完整 Grouped Timer 和复杂 retransmission policy。

**配套实验：**

硬件侧用 **BSV** 验证 Scoreboard/WQE Record/retry datapath，并在条件允许时对 Full-HW 与 HW/SW 两种配置做 Quartus 综合。软件侧建立 **Full Hardware Recovery 和 Software-Coordinated Recovery** 两个模型，扫描 software recovery latency、loss rate、QP 和 window depth。

**需要拿到的数据/图：**

- recovery latency
- goodput
- flow completion time
- outstanding missing packets
- retransmission queue depth
- CPU/NIC report traffic
- reliability state bits
- BRAM/M20K usage estimate
- Full-HW 与 HW/SW 的资源差异

重点形成：

> **Software Recovery Latency → Goodput**

不同曲线对应不同 loss rate。

再形成：

> **Hardware Resource ↔ Recovery Latency tradeoff**

**支撑证据：**

不是证明“软件恢复一定更好”，而是找到一个边界：在低 loss 情况下，可以用一定的软件恢复延迟换取 FPGA 状态和复杂控制逻辑的减少；当 loss 或软件响应延迟增加到一定程度后，性能开始明显下降。

---

### 证据链 5：FPGA 实现可行性

**近期工作：**

在 M0–M9 核心链路稳定后进行整体综合。近期暂时不把 Path Probe、完整 ECN、复杂 Grouped Timer 等作为必须实现项，优先保证论文核心 datapath 完整。

**配套实验：**

使用 **Quartus Synthesis + P&R + Timing Analysis**。选择几个代表性 QP/window 配置，同时对主要模块分别统计资源和关键时序。

**需要拿到的数据/图：**

- ALM/LUT
- FF/Register
- M20K/BRAM
- Fmax
- Worst Slack
- critical-path delay
- 各模块 pipeline latency
- initiation interval
- QP 数增加时资源增长
- Window depth 增加时 BRAM 增长

最终论文至少需要一张 **FPGA Implementation Results 表**，包含：

```text
Submission
TX Datapath
RX/Reliability
Ordered Completion
Total
```

对应各自的 ALM/LUT、FF、BRAM、Fmax。

如果数据够，再增加：

> **QP / Window Size → FPGA Resource Usage**

作为 scalability 图。

**支撑证据：**

证明前面的协议和架构不仅是 software simulation 中成立，核心 datapath 已经具有 BSV 实现，并且资源占用和时序具有实际 FPGA 落地可行性。

---

## 近期整体推进

近期可以把工作归成两条并行线：

**硬件侧：**

> M0–M3 整理 → M4–M5 RX/Reliability → M6–M8 Ordered Completion → M9 Retry State → Quartus

**实验侧：**

> Submission Model → Multipath/Recovery Simulator → Ordered Completion Scale-out → HW/SW Recovery Sweep → Resource/Timing 汇总

最终希望不是单独得到很多零碎波形，而是拿到几组能直接放论文的核心结果：

> **① Submission overhead 图**

> **② Multipath goodput 图**

> **③ Reordering/Loss → Retransmission overhead 图**

> **④ Ordered Completion 时序 + latency 图**

> **⑤ HW/SW Recovery tradeoff 图**

> **⑥ FPGA Resource/Fmax 表**

这样近期每一项开发任务，都能够直接对应论文中的一条证据链，后面写 Evaluation 时基本不用重新组织逻辑。
