# OpenRDMA 论文第 3–6 章与 OpenRDMA-flow 实现一致性审查

- 审查对象：`reference/OpenRDMA_view.pdf`（OpenRDMA: A GPU-Native Multi-Path Reliable RDMA Transport Architecture）
- 代码基准：当前 `OpenRDMA-flow/` checkout（2026-11-05）
- 审查范围：仅 `OpenRDMA-flow/` 目录内的 RTL、integration、测试和文档；未检索目录外代码
- 审查方式：静态阅读 BSV RTL、cocotb 测试与仓库内报告，并按论文条目逐项对照；**本次未重新运行全量仿真、ns-3 联仿或综合**
- 结论边界：本报告区分“代码没有实现”“代码实现方式/字段不同”“论文的量化结果在当前树中不可复现”“当前树中一致”四种情况

---

## 0. 一页结论

**总体判定：第 3–5 章的核心数据通路在代码中有对应实现，但论文把多项尚未实现或仅部分实现的机制写成了已经落地的硬件设计；第 6 章的定性功能基本有代码支撑，定量结果在当前 `OpenRDMA-flow` 树中不可复现。**

最严重的不符集中在六处：

1. **GPU Doorbell 提交路径不完整**：代码只接受已经解码的 `DecodedGdrpSubmission`，没有 Doorbell 地址/QPN 解码、8 B 对齐检查、Slot 地址映射；只支持 `WRITE_RELAXED`（opcode `00`），不支持 `WRITE_ORDERED_FLAG`（`01`）和 `WRITE_RELAXED_THEN_FLAG`（`10`）；完全没有 Doorbell credit / grant page / CAS 反压。
2. **多路径不是论文写的 SRv6/EV Path Table**：代码没有 IPv6、SRv6、uSID、outer destination 或 Path Table；默认 `WIRE_LEGACY_PRIVATE` 只在四个本地通道间做 round-robin；实验性 `WIRE_MRC_IPV4_ECMP_NO_ICRC` 仅把 entropy 放进 UDP source port，且 RX 不解析该 profile。
3. **Ordered Flag 没有端到端 TX 实现**：M3 有 `TRAFFIC_ORDERED` 优先级入口，但该入口没有连接到 E2E，也没有 `WRITE_ORDERED_FLAG` 的 wire opcode/4 B Flag 请求生成；M8 的 Flag 队列通过 `RxTop.orderedFlagIn` 测试侧带注入，不是从网络协议包解析。
4. **第四章的硬件可靠性 profile 不存在**：代码只实现“软件协同恢复” profile（M9 + M10 + CPU `retx_runtime` + M11）；论文 §4.4 和 §5.4 的硬件 profile（NIC 本地 hole 推断、Grouped Timer、NIC retransmission scheduler、retry limit 状态机）没有实现。
5. **拥塞控制/ECN/probe 反馈闭环没有实现**：M3 不会在 IPv4 TOS 里写 ECN；RX 的 ECN 事件不进入 SACK/EV 回传；Path Probe 只有 `probeOut` 结构端口，没有 probe 报文、ACK/timeout、连续成功计数和 spare EV 替换后的受影响包重传；TX 也没有 congestion-control admission 接口。
6. **第 6 章的量化结果缺少当前树内的可复现证据**：`report/README.md` 明确说 active tree 中没有 ns-3 module、Unix-socket adapter、raw event archive 或 parser；当前 E2E 只有一条 1,500 B message A、单包丢包、无时间戳的测试；所有 cocotb BFM 使用 2 ns 时钟，而论文 Table 16 声称 2.5 ns；论文 §6.4.1 的 19-cycle 模型与仓库自己的 `report/README.md`（23/33 cycles）和实际 FIFO 结构矛盾；Yosys 综合数字在树内没有 `synth.log`/stat 证据，且本机环境没有 Yosys；论文称 RX top 生成 21,533 行 Verilog，当前产物是 21,077 行。

**一句话建议**：如果论文要按当前代码提交，应把第 3–5 章中未实现的部分明确移到“设计/未来工作”，并重做第 6 章为当前 check-out 可复现的实验；否则需要先补齐 Doorbell credit、ordered flag、SRv6/EV 闭环、ECN/probe 和硬件可靠性 profile。

---

## 1. 第 3 章 System Overview

| 论文条目 | 代码对应 | 判定 | 证据 |
|---|---|---|---|
| §3.1 Host/GPU 双层软件层，CPU/GPU 双路径提交；GPU 通过 MMIO-Write Doorbell | 只有统一的 `DecodedGdrpSubmission {qpn, token}` 输入，没有独立 CPU 提交路径，没有 MMIO/Doorbell address | **部分/不符** | `m0_doorbell_analysis/src/TxMvpTypes.bsv:20-25`；测试直接传入 `qpn`，见 `integrations/tx/cocotb/m0_chain_model.py:177` |
| §3.1 CPU 负责 QP、MR、Slot、path、credit 配置 | QP/MR/Slot/PGT 有配置端口；path 在 M3 配置；没有 credit 配置 | **部分不符** | `TxMvp.bsv:330-338, 363-469`；`MrcTxScheduler.bsv:345-352` |
| §3.2.1 Tx：Work Submission Processor 解码 Doorbell、Slot、WQE、PSN、WQE Record | M0 完成 Slot 查询、MR 检查、QP PSN 预留、PGT 翻译、burst 拆分；没有 Doorbell decode、WQE Record 写；WQE Record 实际在 E2E 的 `RetxWqeMonitor` 中按 M2 context 旁路注册 | **部分实现** | `TxMvp.bsv:28-73, 104-162, 188-258, 278-324`；`integrations/e2e/src/RetxWqeMonitor.bsv:32-60` |
| §3.2.1 Tx Data Fetch 从 GPU 内存 PCIe DMA Read | M1 `DmaEngine` 支持 8 个 outstanding slot、whole-chunk reorder、128 B completion；DMA 是抽象接口，不建模 PCIe | **语义实现/抽象** | `m1_dma_engine/src/DmaEngine.bsv:336-516, 532-735` |
| §3.2.1 Congestion Control 统一调度首发/重传、ECN 标记 | M3 没有 congestion-control 模块、没有注入许可、没有 ECN 标记；只有 EV 状态机和通道 buffer 反压 | **未实现** | `MrcTxScheduler.bsv:326-352` 无 CC 接口；`MrcHeaders.bsv:20-31` IPv4 TOS 固定 `8'h00` |
| §3.2.1 Assembly Unit 加协议头并填 ECN | M3 生成 Ethernet/IPv4/UDP/BTH/RETH；不生成 ECN | **部分实现** | `MrcHeaders.bsv:106-221` |
| §3.2.1 Multi-Path Tx Scheduler 基于 EV 的 per-packet spraying；control plane 预配置 SRv6 模板和 EV 表 | `EvPathManager` 有 4 profile × 8 EV、GOOD/SKIP/DENIED/ASSUMED_BAD，但只映射 entropy + 本地 channel；无 SRv6 模板/outer destination；legacy 默认 round-robin | **部分/不符** | `m3_mrc_tx_scheduler/src/EvPathManager.bsv:50-270`；`MrcTxTypes.bsv:44-70`；`README.md:62-65` |
| §3.2.2 Rx：Packet Buffer、Parser、RQ Bitmap、Ordered Queue、DMA Placement | M4–M8 均有对应实现，RxTop 串联 | **一致** | `integrations/rx/src/RxTop.bsv:69-90` |
| §3.2.2 Parser 提取 ECN，经 SACK 回传；提取 EV | 提取 IPv4 ECN 到 `RxEcnEvent`，但 RxFeedback 不携带 ECN/EV；没有 EV 字段；MQ/MRC header 不解析 | **部分/不符** | `m5_rx_packet_parser/src/RxPacketParser.bsv:150-213`；`shared/bsv/rx/RxTypes.bsv:138-161` |
| §3.2.3 Retx logic：WQE Record、Scoreboard Bitmap、SACK Retx Management Queue、Timer | M9 有 WQE Record/journal/snapshot，M10 生成 report，M11 执行 retry；Timer 在 CPU `retx_runtime`；M10 不是“单次 PCIe write” | **部分实现** | `m9_retx_state_manager/src/RetxStateManager.bsv:280-504`；`m10_retx_report_engine/src/RetxReportEngine.bsv:45-131`；`retx_runtime/runtime.py:14-19` |
| §3.3 FTile 层：4 × EMIB / 300G MAC/PCS/FEC / FHT，聚合 400 Gb/s | 只有 4 个 `EthPacket` 抽象通道；没有 MAC/PCS/FEC/EMIB/FHT、没有 100 Gb/s 链路模型 | **未实现（抽象模型）** | `MrcTxScheduler.bsv:339-343, 905-908`；`README.md:46-65` |
| §3.4 总结称已实现 EV 多路径、bitmap 可靠传输、选择性重传 | EV/bitmap 部分存在；SRv6 EV、on-wire 反馈、硬件重传不存在 | **过度概括** | 见第 2–3 节 |

---

## 2. 第 4 章 OpenRDMA Design

### 4.1 GPU-Visible Ordered Message Completion

| 论文条目 | 代码行为 | 判定 |
|---|---|---|
| `WRITE_RELAXED` / `WRITE_ORDERED_FLAG` 两种 Write 语义 | 只有 `WRITE_RELAXED` 的 TX 生成；没有 ordered flag wire opcode 或 4 B Flag 请求生成 | **不符** |
| Ordered Write 只发布 4 B Flag，不移动 payload | M8 有 4 B `value` 和 flag DMA 请求，但入口是 `RxOrderedFlagIngress` 测试带，不是网络包 | **仅 RX 侧部分实现** |
| Flag 可在前置 payload 之前到达时被保留，等 `dmaAckPsn >= barrierPsn` 再发布 | M8 每 QP FIFO depth 4，选择队首且 `dmaAck >= barrier` 才输出 Flag 请求 | **一致** |
| 同一 QP 的 Flag 与 payload 属于不同网络请求 | 无 TX 侧 Flag 包生成；E2E 不连接 ordered 入口 | **未实现** |
| 每 QP 的 Ordered Write FIFO 有固定容量，提交前必须持有 ordered credit | M8 有 depth 4 FIFO 和 absolute `orderedGrantLimit`，满时 fail-stop；TX 侧没有 credit 预留 | **RX 一致 / TX 缺失** |
| Flag DMA 完成后才产生 CPU CQE / GPU 观察 | M8 有 message-level `RxCompletion` 和 Flag DMA response/error；没有独立 Completion Management 或 CQE ring | **部分** |

**关键证据**

- M8 FIFO 深度和 credit：`m8_rx_ordered_queue/src/RxOrderedQueueManager.bsv:10, 18, 73, 260-273`
- Flag 侧带入口：`integrations/rx/src/RxTop.bsv:52-56, 216-225`
- M3 ordered 入口只在模块 TB 中驱动：`m3_mrc_tx_scheduler/tb/TestM3.bsv:43-44`；E2E 没有连接 `orderedDescriptorIn/orderedPayloadIn`（`integrations/e2e/src/E2eTop.bsv:139-160`）

**结论**：4.1 的接收侧“有序发布”机制基本存在，但发送侧 `WRITE_ORDERED_FLAG` 和端到端 Flag 通路不存在。

### 4.2 GPU-Initiated Work Submission and Resource Backpressure

| 论文条目 | 代码行为 | 判定 |
|---|---|---|
| 8 B Doorbell 字段：`seq[63:60]`、`op[59:58]`、`slot_id[57:40]`、`len_or_imm32[39:8]`、`flags[7:0]` | 字段切片完全一致 | **一致** |
| Doorbell 地址 `gpu_doorbell_base + (qpn << 3)`，QPN 从地址提取 | 没有地址、BAR base 或 QPN 解码；`DecodedGdrpSubmission` 直接携带 `qpn` | **不符** |
| 地址 8 B 对齐、BAR 范围检查 | 不存在 | **未实现** |
| `WRITE_RELAXED`（00）、`WRITE_ORDERED_FLAG`（01）、`WRITE_RELAXED_THEN_FLAG`（10） | 只允许 `opcode == 0`，其他值 `dynamicAssert` | **仅 1/3 实现** |
| 偶数 `slot_id` + 相邻 Flag Slot `slot_id + 1` | 没有 Slot pair，没有 Flag Slot 查询 | **未实现** |
| Slot 表有地址、key、最大长度、允许操作类型 | `PayloadSlot` 只有 `valid/allowWriteRelaxed/localLkey/localOffset/remoteBase/maxLen/remoteKey`；只有 relaxed 权限位 | **部分** |
| `MAX_SLOT` 为偶数且 `2 ≤ MAX_SLOT ≤ 2^18` | 物理表只有 16 项，`slotId < 16` 断言；18-bit 字段高 bits 必须为 0 | **配置受限** |
| Doorbell credit：GPU 写 Doorbell 前必须持有 credit | 没有任何 Doorbell credit 逻辑 | **未实现** |
| Grant page：GPU-readable absolute `grant_limit`，local head + CAS | 不存在 | **未实现** |
| Ordered credit：每个 Ordered Write 消耗一个，relaxed 不消耗 | RX M8 返回 `RxOrderedCredit`；TX 侧没有 ordered credit 计数/预留 | **仅接收侧** |
| reconfiguration 时停止新提交、等待 NIC 完成、重建 QP/Slot | 没有 stop/drain/rebuild 流程；配置端口可在运行中写入 | **未实现** |
| 无效地址/无效 key 被拒绝并报告错误 | M0 用 `dynamicAssert` fail-stop；没有错误报告通道 | **部分（fail-stop）** |

**结论**：4.2 的核心“最小 Doorbell + Slot 查表 + credit/grant 反压”只实现了前半部分；credit/grant 与地址解码完全没有落地，而这两项正是 4.2 的标题（Resource Backpressure）所在。

### 4.3 Out-of-Order Multipath Packet Execution

| 论文条目 | 代码行为 | 判定 |
|---|---|---|
| 使用 SRv6 表达确定性路径：outer IPv6 + uSID，inner endpoint | 没有 IPv6/SRv6；M3 只构建 Ethernet/IPv4/UDP/BTH/RETH | **不符** |
| 控制面按 destination 预配置 SRv6 path template 和 EV 映射表 | `MrcSourceProfileConfig` 是 4 个 traffic class 的 profile id，不是 per-destination；EV entry 只有 entropy/channel | **不符** |
| EV 映射到 `{SRv6 outer destination, local FTile port, TX channel}` | `MrcResolvedPath` 只有 `{profileId, entryIndex, generation, entropy, channel}` | **不符** |
| 每个 QP 维持 active EV 集 | EV 表按 profile 全局配置（4×8），不是 per-QP | **不符** |
| 相邻 PSN 可选不同 EV，实现 per-packet spraying | legacy 默认 `chooseChannel(roundRobin, eligibleMask)`；MRC 实验路径按 EV cursor 轮转 | **部分（多通道，非 SRv6 EV）** |
| EV 可作为路径健康索引，接收侧在 feedback 中回带 EV | RX 没有 EV 字段；`RxTxFeedback` 只有 `{qpn, psn, aeth}`；RxFeedback 只有 bitmap/ack | **未实现** |
| ECN 触发路径切换、丢包移除 EV、选 spare EV、重传受影响包 | `EvPathManager` 有 ECN/TRIM/ALWAYS_SKIP/TIMEOUT 的状态转移，但没有 ECN 入链、没有 spare 集、没有受影响包重传 | **仅状态机骨架** |

**关键证据**

- IPv4/UDP 头构造：`m3_mrc_tx_scheduler/src/MrcHeaders.bsv:20-42`
- MRC profile 头（仍是 IPv4/UDP，不是 IPv6/SRv6）：`MrcHeaders.bsv:170-213`
- EV 解析结果字段：`MrcTxTypes.bsv:63-70`
- README 明确“IPv6/SRv6 未实现，RX 不解析实验 wire”：`README.md:62-65`；`RX_README.md:5, 68`
- RX 固定 UDP source port `0xC1E8`，会拒绝 MRC ECMP entropy：`m5_rx_packet_parser/src/RxPacketParser.bsv:57-59, 159`

**额外注意**：论文 §4.3 说“每个数据包携带完成 direct placement 所需的地址和权限”。在默认 legacy profile 中，只有 FIRST/ONLY 带私有 RETH；MIDDLE/LAST 不带地址/key，接收侧靠 QP context + PSN 推导。MRC 实验 profile 每包带 METH/RETH，但 RX 不解析。该表述与默认实现不符。

### 4.4 Packet-Level Reliability Feedback

| 论文条目 | 代码行为 | 判定 |
|---|---|---|
| 每 QP 有 `ack_psn` + 16-bit receive bitmap + `ooo_count` | M6 有 `ackPsn`、`receiveBitmap`、`oooCount`；窗口 16 | **一致** |
| `ooo_count = popcount(bitmap)` | 用 `countOnes(merged)` 重新计算 | **一致** |
| 只有 `ooo_count` 超过可配置 reorder 阈值才进入 lazy SACK | 只要 `receiveBitmap != 0` 就返回 `RX_SACK`；没有阈值 | **不符** |
| SACK 可合并、按聚合定时器/周期性 refresh 发送 | 每个被接纳包立即产生 feedback；没有聚合定时器或 refresh | **未实现** |
| MPR（Maximum PSN Range）限制发送 PSN；接收窗口可滑动 | M6 固定窗口 16；没有独立 MPR 字段或 feedback 更新 | **部分/固定值** |
| duplicate/old/out-of-window 不改变状态，可再次返回 ACK/SACK | 有 duplicate/old/out-of-window 分支，duplicate 返回 snapshot，越窗 NAK/error | **一致** |
| 接收侧 NAK 指向可定位异常和 PSN | `RxFeedback.kind = RX_NACK` + `triggerPsn`；没有 reason code 字段 | **部分** |
| 发送侧硬件 Scoreboard 锁存 ACK/SACK，hole candidate 由 NIC 判断 | M9 只维护 journal 状态并生成 snapshot；hole 推断在 CPU `retx_runtime`；NIC 没有 hole candidate state | **仅在软件 profile** |
| post-hole SACK 计数阈值 | CPU `retx_runtime` 的 `SACK_THRESHOLD = 3` 实现 | **一致（CPU 侧）** |
| Grouped Timer：连续 PSN 成组、组满/WQE 末尾/超时关闭、expire 后重扫 Scoreboard、backoff、retry limit→error | 没有 Grouped Timer；`retx_runtime` 只有 per-QP deadline/backoff/`RETRY_LIMIT` | **未实现（NIC）** |
| 反馈丢失时 SACK refresh 周期重发 | 没有 | **未实现** |

**关键证据**

- `rxFeedbackSnapshot` 的 SACK 选择：`m6_rx_rq_bitmap/src/RxRqBitmapManager.bsv:33-38`
- bitmap 合并与 ack 推进：`RxRqBitmapManager.bsv:260-310`
- `SACK_THRESHOLD`、timeout、retry limit：`retx_runtime/runtime.py:14-19, 138-200, 203-255`

**结论**：4.4 的接收侧 bitmap 语义基本一致；发送侧“硬件完整闭环”和 lazy SACK/Grouped Timer 不影响“软件 profile”可用性，但论文把这些写成 NIC 硬件行为，与代码不符。

### 4.5 Software-Coordinated Recovery

| 论文条目 | 代码行为 | 判定 |
|---|---|---|
| NIC 报告事实，CPU 做恢复决策 | M9 提供 WQE Record/journal/snapshot，M10 生成 Report header + hole entries + notification，CPU `retx_runtime` 做 SACK-hole/NAK/timeout 策略 | **基本一致** |
| NIC 保留 WQE Record、SQ Scoreboard、精简 SACK queue，移除 retransmit 组装/Grouped Timer | M9/M10 保留记录和 report；没有 Grouped Timer | **基本一致** |
| NIC 把 report 通过“一次 PCIe write”推到 CPU memory | M10 只输出 `ReportHeader`/`HoleEntry`/`Notification` 结构端口；没有 host ring/DMA writer/CRC | **抽象/未实现** |
| CPU 从 NIC 读完整 ACK bitmap 和 WQE metadata | M9 snapshot 包含 `sack_bitmap`、`ackPsn`、hole entries 的 metadata | **一致** |
| CPU 用 post-hole SACK 阈值判断丢包 | `retx_runtime` `SACK_THRESHOLD = 3` | **一致** |
| CPU 生成 retry descriptor，保留原 QP/PSN，设置 `is_retry` | M11 `RetryEntry` → M9 admission → M3 `TRAFFIC_RETRY`；没有显式 `is_retry` 字段，用 traffic class 表达 | **语义一致/字段不同** |
| NIC 在发送前复查 QP state、MPR window、credit、CC permission、PSN 未被 ACK | M9 admission 只查 QP enabled/epoch 和 journal state==sent；没有 MPR、credit、CC 复查；M3 不复查 | **部分** |
| old generation retry 被拒绝 | M9 用 `qpEpoch` 和 record handle 检查 | **一致** |
| 重传从 WQE Record 的 DMA metadata 重建 DMA Read | M11 从 `RetxReplayStore` 取回 payload；E2E 不接 M0/M1，不做新的 GPU DMA Read | **结构不同** |
| 重传请求与主数据流解耦，主发送不等待 | M3 在 packet 边界插入 retry，E2E 测试断言主 message 的 commit 序列不被破坏 | **一致** |
| per-QP software timer | `retx_runtime` deadlines / `TIMEOUT_NS` | **一致** |

**关键证据**

- M10 report 输出端口：`m10_retx_report_engine/src/RetxReportEngine.bsv:45-131`
- M9 snapshot/hole entries：`RetxStateManager.bsv:396-438`
- M11 replay fetch：`m11_retx_retry_engine/src/RetxRetryEngine.bsv:84-136`
- replay store：`integrations/e2e/src/RetxReplayStore.bsv`；E2E README 说明 payload 从 replay store 取回：`integrations/e2e/README.md:105-119`

**结论**：4.5 的“CPU 决策 + NIC 执行”方向与代码一致；差异在于报告传输是结构端口而非单次 PCIe write，且恢复使用 replay store 而不是重新 DMA Read GPU 内存。

### 4.6 Congestion Control and Transmission Scheduling

| 论文条目 | 代码行为 | 判定 |
|---|---|---|
| 不使用 per-path cwnd/AIMD，拥塞时切换路径 | 没有 cwnd/AIMD；EV 状态机有 SKIP/ASSUMED_BAD | **部分** |
| 典型 MRC 部署约 100 条 EV 路径 | 只有 4 profile × 8 = 32 个 EV entry | **规模不符** |
| ECN 标记由 receiver Packet Parser 提取，经 SACK echo EV | Parser 提取 ECN 到独立 `RxEcnEvent`；SACK/feedback 不携带 EV/ECN | **未闭环** |
| 收到 ECN SACK 后：识别 EV、移除、换 spare、重传受影响包 | `EvPathManager` 能在 `EV_FB_ECN` 下把 EV 置 SKIP；没有 SACK/EV 关联，没有 spare 集，没有受影响包重传 | **仅部分状态转移** |
| Path Probe：MRC 周期发送 probe；peer echo；超时内 ACK 则 success counter++；连续成功 3 次恢复 | `EvPathManager` 只产生 `MrcProbeRequest`；没有 probe 报文/ACK/timeout/success counter；`EV_FB_PROBE_GOOD` 一次就恢复 | **未实现** |
| probe rate limiter：每路径每毫秒最多 1 个 | 只有 `probeIntervalCycles`（默认 4096），不是 1 ms，也不是独立 rate limiter | **不符** |
| Send Engine 轮询 4 个 FTile 通道，跳过满 FIFO；retry > first；同优先级 round-robin | M3 有 4 个 encoder、每通道 2 个 outstanding、`chooseChannel` round-robin；source 优先级 control > ordered > retry > first；有 `maxHighBurst` 防饥饿 | **部分一致** |
| EV 选择和地址生成 | 只选 channel/entropy；没有 SRv6 地址生成 | **部分** |
| 选择后启动 DMA transfer | DMA 在 M1 早已完成，M3 没有 DMA 接口 | **顺序不同（与 §5.2 一致，与 §4.6 不一致）** |
| 反压链 FTile FIFO → Send Engine → WQE queue → GPU credit | 有 per-channel buffer 满则停；没有 WQE queue/GPU credit | **部分** |
| ACK/SACK/NAK feedback 是最高优先级输入 | `control` 入口优先级最高，但 E2E 没有驱动 control；RX 也不产生 on-wire ACK/SACK/NAK | **未闭环** |

**关键证据**

- EV feedback 类型：`MrcTxTypes.bsv:9-20`
- EV 状态转移：`EvPathManager.bsv:119-164`
- Probe 输出：`EvPathManager.bsv:166-196, 269`
- 通道仲裁与 source 优先级：`MrcTxScheduler.bsv:287-303, 400, 443-445, 490, 550-704`
- E2E 只接 first/retry：`E2eTop.bsv:139-160`

**论文内部矛盾**：§4.6 第 (4) 步说 Send Engine 在 EV selection/channel arbitration 之后“initiate DMA transfer”；但 §5.2 Table 6 的顺序是 PGT/DMA Read → Segmentation → EV/Path Table → Packet assembly。代码遵循 §5.2（DMA 在 M0/M1，M3 只做组包和通道选择）。这不是代码违背全部论文，而是论文自身两处顺序描述不一致。

### 4.7 Chapter Summary

§4.7 称三条原则之一是“hardware handles steady-state fast path — ordering, submission, multipath forwarding, and routine loss recovery”，但 §4.5 又把 loss detection/timeout/retry decision 交给 CPU，代码也采用后者。建议论文统一为“hardware 处理首传/有序发布/bitmap 事实，software 处理恢复决策”，否则与 §4.5 和代码同时矛盾。

---

## 3. 第 5 章 Protocol and Hardware Design

### 5.1 Submission Interface and Admission Pipeline

| 论文条目 | 代码 | 判定 |
|---|---|---|
| Table 1 四阶段：Configuration、GPU payload/credit、Doorbell decode/request、Admission/WQE Parse | 只有 Configuration、Slot lookup/MR check/QP reserve/PGT、DMA burst；没有 credit、没有 Doorbell decode | **2/4 阶段** |
| Table 2 CPU runtime 只做配置/恢复；GPU 做 payload/credit/Doorbell；NIC front-end 做 QPN/Slot/request | M0 的输入已经是 `DecodedGdrpSubmission`，QPN 是输入；没有 GPU credit | **部分不符** |
| 5.1.2：payload writes → ordered credit → Doorbell credit → 8 B store | 没有 credit；payload 使用抽象 M1 DMA | **未实现** |
| Table 3 Doorbell credit / ordered credit 的容量和 grant 条件 | 只有 M8 的 RX ordered credit；没有 Doorbell credit/grant page | **仅接收侧** |
| 5.1.3：`gpu_doorbell_addr = base + (qpn << 3)`；QPN 从地址提取 | 没有地址；QPN 直接输入 | **不符** |
| Table 4：64-bit Doorbell 字段 | 字段切片一致：`token[63:60]/[59:58]/[57:40]/[39:8]/[7:0]` | **一致** |
| Table 5：00 relaxed、01 ordered flag、10 combined、11 reserved；credit 0/1/1 | 只有 00；01/10/11 全部断言失败；没有 flag/combined 请求 | **仅 00** |
| Slot 表 18-bit 平坦索引、MAX_SLOT 偶数 | 物理 16 项，高 14 bit 必须 0 | **配置受限** |
| 组合操作读取 `slot_id` 和 `slot_id+1` | 没有 | **未实现** |
| Admission：BAR range、8 B 对齐、QPN、flags、opcode、slot range/valid、kind/capability/key/length/owner | 有 flags/opcode/slot/valid/allowWriteRelaxed/length/地址溢出；没有 BAR/对齐、没有远程 key 校验、没有 owner_qpn | **部分** |
| 通过检查后才分配 PSN 并进入 WQE Parse | M0 QP reserve 分配 PSN，但没有独立的 WQE Parse/WQE Record 绑定 | **结构不同** |

**结论**：5.1 的“64-bit Doorbell 格式”与代码一致，但整个提交/准入流水线在 RTL 中从“decoded submission”开始，论文描述的前半段（地址解码、credit、grant、ordered ops、Slot pair）没有代码。

### 5.2 TX Datapath and Multipath Packetization

| 论文条目 | 代码 | 判定 |
|---|---|---|
| Table 6 五阶段：PSN/WQE Record、PGT/DMA、Segmentation、EV/Channel、Assembly | PSN 在 M0 QP reserve；PGT/M0 + DMA/M1；Segmentation/M2；EV/Channel/M3；Header/M3 | **阶段映射基本一致** |
| WQE Record 由 WQE Parse 绑定，记录 start_psn/psn_count/DMA metadata | M9 有 `Rec`；E2E 由 `RetxWqeMonitor` 从 M2 context 注册，不是 M0/WQE Parse | **结构不同** |
| Record release 由 packet-level ACK 决定，不能由本地 DMA Read 完成提前释放 | M9 journal 在 ACK/SACK 上转为 terminal，record 只在 cumulative ACK 覆盖整个范围时 complete；若全部包只被 SACK 选择性确认而 cumulative 未推进，record 不会释放 | **部分/边界不符** |
| PSN range 由 WQE Parse 集中分配，Segmentation 不用 per-QP global counter | M0 QP table 维护 `nextPsn`；M2 消费 `startPsn/psnCount` | **一致** |
| 每个包 isfirst/islast；单包两者都置位 | M2 `PacketDescriptor` 有 `isFirst/isLast`；但 legacy/MRC wire 用 BTH opcode `0x06/07/08/09` 或 `C6/C7/C8/CA` 表示位置，没有独立 isfirst/islast 字段 | **语义一致/线格式不同** |
| Table 7：QPN、PSN、opcode、isfirst/islast、remote placement、ECN | QPN/PSN/opcode/placement 有；ECN 无；legacy RETH 只在 FIRST/ONLY | **部分/不符** |
| 四个 Payload TX Engine 每通道一个，并行组包 | 4 个 `mkChannelEncapsulator`；但 M3 同一时刻只有一个全局 `active` packet，靠 per-channel buffer 流水 | **部分一致** |
| 每个通道的 state 独立；共享状态由 front-end 检查 | QP/window/scoreboard 没有在 M3 检查 | **部分不符** |
| FTile FIFO 反压时后续包可换通道，已绑定包不换 | `freeMask` + `activeChannel`；进行中的包保持通道 | **一致** |
| EV/Path Table 查询得到 SRv6 outer destination、FTile port、channel | 只有 entropy/channel；没有 outer destination/port | **不符** |
| Table 8 优先级：ACK/SACK/NAK > Ordered > Retry > First | 代码 control > ordered > retry > first；control 没有被 E2E 驱动，RX 也没有 on-wire feedback | **部分** |
| Ordered TX Engine：`WRITE_RELAXED_THEN_FLAG` 一个 Doorbell 产生两个请求 | M3 有 ordered 输入和独立 FIFO；没有 Doorbell 产生逻辑，没有 Flag opcode/4 B 请求 | **未实现** |
| 统一 send gate：QP active、PSN 在 MPR、CC grant、FTile FIFO、EV 可用 | 只有通道 FIFO/EV 可用；M0 有 QP/MR 检查但不是 M3 gate；没有 MPR/CC | **部分** |
| 重传优先但保留首发最小服务比例 | `maxHighBurst=4` + `forceFirst` | **一致** |
| 三类边界：FTile FIFO、Doorbell credit、CC | 只有 FIFO；credit/CC 缺失 | **1/3** |

### 5.3 RX Datapath and Direct Placement

| 论文条目 | 代码 | 判定 |
|---|---|---|
| 四 lane receive buffer/parser，out-of-order 汇聚 | M4/M5 ×4，M6 合并 ingress | **一致** |
| Parser 提取 QPN/PSN/opcode/boundary/placement/EV/ECN | 提取 legacy 头部、QPN/PSN/opcode、first/last、addr/rkey、ECN；没有 EV，不能解析 MRC profile | **部分/不符** |
| ACK/SACK/NAK 直接进入 feedback queue，不进入 payload path | M5 routeAck 只发 feedback/release；M6 产生 RxFeedback | **一致（但 feedback 是内部事件）** |
| 数据包先更新 bitmap，再 DMA，保证证据先于 DMA | M6 先 commit bitmap/admitted，然后 M7 DMA | **一致** |
| RQ Bitmap 产生 ACK/SACK/NAK，ACK 不等 DMA | `rxFeedbackSnapshot` 在 bitmap merge 后产生；ack_psn 不等待 DMA | **一致** |
| Four-way DDP，每包独立写最终地址 | M7 每包产生独立 `RxDmaWriteRequest`；但 legacy MIDDLE/LAST 无 RETH，依赖 first 包建立的 QP context | **部分/默认 profile 不符** |
| DMA lane 输出 FIFO 保留本 lane 完成顺序，携带 global_seq | M7 每 lane 一个 outstanding，completion FIFO，globalSeq | **一致** |
| Single Ordered Retire：global_seq == retire_head 才出队，更新 dma_ack_psn | M7 `retireHead` + lane head 比较；M8 在 retire 时更新 dmaAck | **一致** |
| 四 Parser 同周期可能访问同一 QP bitmap，需要 banking/arbitration | M6 通过 inputQ/ingressQ 单点串行化，没有 bank、没有 QPN 低位 banking | **实现方式不同** |
| Parsing budget 24/32 cycles | M6 每周期处理一个 candidate，结构上可行；没有专门预算检查 | **架构上可满足** |
| 边界 flag 由 packet header 携带 | legacy 用 opcode；MRC 用 opcode | **线格式不同** |

### 5.4 Reliability and Recovery Engines

| 论文条目 | 代码 | 判定 |
|---|---|---|
| 支持 hardware recovery profile 和 software-coordinated profile 两种 | 只有 software-coordinated profile（M9/M10/CPU runtime/M11）；硬件 profile 没有 | **仅一半** |
| Table 12：硬件 profile 的 NIC bitmap、NIC hole judgment、NIC grouped timer、NIC retransmission scheduler | NIC 没有 hole judgment/grouped timer/retransmission scheduler；这些在 Python CPU | **未实现** |
| ACK/SACK/NAK 三种反馈，ACK 累积、SACK selective、NAK pinpoint | `RxFeedback` 有 ACK/SACK/NACK；NAK 无 reason code；都是内部事件，不是 wire 包 | **部分** |
| ACK/SACK 不等待 DMA | 一致 | **一致** |
| SACK refresh / duplicate feedback 不产生副作用 | 无 refresh；duplicate 产生 feedback snapshot | **部分** |
| 发送侧 SQ Scoreboard 维护每个 outstanding PSN | M9 是 per-packet journal，不是 bitmap；可生成 bitmap snapshot | **语义近似/结构不同** |
| SACK hole candidate 条件、scan_end、post-hole count | CPU runtime 实现；NIC 不实现 | **仅 CPU** |
| retransmit_pending flag、发送前二次 Scoreboard check、late ACK 取消 | M11 一次只处理一个请求；M9 admission 检查 state==2；没有 per-PSN pending flag，也没有发送前二次检查 | **部分** |
| SACK work queue、Grouped Timeout、统一 retransmission path | feedback FIFO + CPU；没有 Grouped Timeout；统一路径存在（M11→M3） | **部分** |
| 软件 profile：NIC 提供 accepted-request report、CPU 决策、NIC 执行 | 一致（报告为结构端口，replay store 取 payload） | **基本一致** |
| 软件 profile：发送前检查 QP state、MPR、credit、CC、PSN 未 ACK | 只检查 QP/epoch + journal state | **部分** |

### 5.5 Ordered Completion Protocol and Hardware

| 论文条目 | 代码 | 判定 |
|---|---|---|
| per-lane completion FIFO + global_seq + single ordered retire | M7 有 | **一致** |
| per-QP `dma_ack_psn` 在 DMA 完成且 global retire 后推进 | M8 `processRetire` 时更新 | **一致** |
| Flag 到达可先于 payload；Flag 元数据进入 per-QP FIFO；payload 不进 FIFO | M8 有 FIFO 和 `RxOrderedFlagIngress`；但 Flag 是测试侧带，不是从 parser/网络包解析 | **结构相符/入口不符** |
| 只有 `barrier_psn <= dma_ack_psn` 且 Flag DMA path ready 才发布 | M8 选择队首且 `rxPsnAtOrAfter(dmaAck, barrier)`；`creditQ.notFull` 作为 ready | **一致** |
| Flag 请求被接受后 dequeue 并返回 absolute credit | M8 `flagRequestOut.deq` 时 `grantLimit++` 并入 creditQ | **一致** |
| DMA error/Flag error 停止 retirement/release，需 host stop/drain/reset | M8 fail-stop；RxTop sticky fault | **一致（无 host stop/drain）** |
| CPU CQE path：Completion Management 写 request identity/status/result 到 CQ ring | `RxCompletion` 只有 `{qpn,lastPsn,bytes,success}`，没有 request identity/CQ ring | **部分/不符** |
| GPU Flag path：Ordered Queue 直接写 preconfigured GPU memory | `RxFlagDmaRequest{addr,value}` 输出给外部 adapter；没有实际 GPU memory/visibility 模型 | **抽象实现** |
| Flag 与 payload 共享 DMA-write 基础设施 | 结构端口层面是独立的 flag request/response；没有共享 DMA 模型 | **部分** |

### 5.6 Resource, Lifecycle, and Timing

| 论文条目 | 代码 | 判定 |
|---|---|---|
| 4 × 100GE、400 MHz、1024 bit/cycle、4 KiB 32 cycles / 3 KiB 24 cycles | M3 每通道 256 bit/cycle ×4 = 1024 bit/cycle；4 KiB/128 B=32，3 KiB=24 | **架构一致** |
| 数据通路模块 ×4 并行，协议状态集中/分 bank | Parser/DMA lane/encoder ×4；M1/M2 单实例；RQ/QP/Scoreboard 无 banking | **部分** |
| RQ Bitmap/QP Context/Scoreboard 用 banking，独立吞吐 | M6/M9 单点串行；没有 bank | **不符** |
| WQE Record 单 BRAM reverse lookup | M9 `Reg#(Vector#(64, Rec))` + 线性 `findRecByHandle`；不是 BRAM | **结构不同** |
| Ordered Retire/Queue 集中 | M7/M8 集中 | **一致** |
| Global Slot Table 2..2^18、QP context/credit/queue 随 QP 数、RQ bitmap QP×MPR、WQE/Scoreboard 消息数×PSN 窗口、Grouped Timer 按组 | Slot 16；QP 4；RQ 4×16；WQE 64；Grouped Timer 不存在 | **部分** |
| 四 Parser 同拍访问同一 QP bitmap 的 port contention 缓解：work queue、banking、arbitration | 只有 ingress 队列串行化，没有 banking/arbitration | **部分** |
| 生命周期 RESET→CONFIGURE→RUN→STOP→DRAIN→RESET；STOP 阻止新提交，DRAIN 排空，RESET 清计数 | 只有 configure/start；fault 后 sticky，必须 reset；没有 stop/drain/reconfigure | **未实现** |
| 错误 epoch/code、GPU 停止提交、CPU drain/terminate、不支持 hot-fix | RX 有 epoch/error code/sticky fault；M0 用断言；没有统一 lifecycle | **部分** |
| 400 MHz timing closure，报告 frequency/slack/BRAM/CDC/debug | 树内没有 SDC/Quartus/Yosys timing 报告 | **未提供** |

---

## 4. 第 6 章 Evaluation

### 4.1 方法与配置

| 论文 | 当前树 | 判定 |
|---|---|---|
| TX/RX Verilator + ns-3 联仿 | active tree 没有 ns-3 module/adapter/raw trace/parser；`report/README.md` 明确说不能从当前 checkout 一键复现 | **不可复现** |
| 2.5 ns model cycle | 所有 cocotb BFM 使用 2 ns | **不符** |
| BSC 2023.01 | 本机/仓库报告使用 BSC 2025.01.1 | **不符（版本）** |
| Verilator 5.048；cocotb 2.1.0.dev0 | 本机一致 | **一致** |
| 4 QP、4 RX lane、16-packet window、16 payload slot/lane、4 Ordered Queue entry/QP、PMTU 256..4096 | `RxQpCount=4`、`RxLaneCount=4`、`RxWindowSize=16`、`RxPayloadSlots=16`、`rxOrderedQueueDepth=4`、PMTU 5 档 | **一致** |
| 4 × 100 Gb/s p2p、200 ns、100-packet queue | 没有网络模型/速率限制；RTL frame 输出可超过 400 Gb/s（当前测试 441.68 Gb/s steady） | **未实现** |
| 按 1,024 messages、4,068 B payload、4 QP | 当前 throughput 测试是 128×1 KiB；没有 4,068 B/1,024-message/2,048-message 批次 | **测试配置不符** |
| fixed-per-QP policy 用 QPN 低 2 bit | 没有该 policy 的 RTL 支持；只有 `channelEnable` 掩码或 round-robin | **未实现** |
| Table 17：TX short 67 pass | 当前 short 测试计数正好 67 | **一致** |
| Table 17：RX short 37 pass, 3 skip / long 38 pass, 2 skip | 当前 RX 短套件 38 项中 1 个 long-only skip（37 pass/1 skip）；long 38 项无 skip | **部分不符（skip 数）** |
| Table 17：Online reference 11/11 frames；Five-mode timing consistency 37 checks | 当前树没有对应 harness/result artifact | **不可复现** |
| Table 17：Reversed DMA completion 3,2,1,0 → retire 0,1,2,3 | M7 有测试 `test_four_dma_lanes_reverse_completion_ordered_retire` | **一致** |
| Table 17：Ordered Queue capacity 1/2/4 credits，第五个被拒 | M8 有 overflow/credit 测试 | **一致** |

### 4.2 高聚合吞吐（§6.2）

- **代码能支持的量级**：`integrations/tx/cocotb/tests/test_m0_chain.py:339-408` 的 `sustained_m0_to_m3_rate_hides_bounded_dma_latency` 在 128×1 KiB、4 QP、PMTU 4096、2 ns 模型下断言 frame EOF steady ≥ 400 Gb/s；仓库报告记录 0/20-cycle 延迟下 steady 441.68 Gb/s、full-window 400.22 Gb/s（`report/tx-throughput-diagnosis.md:136-143`）。
- **论文的 380.9 Gb/s、387.7 Gb/s serialized、367.8→380.9、2,048×1 KiB 326.0、reverse 359.9** 依赖 ns-3 的 framing/serialization 和 1,024-message 批次；当前树没有这些实验脚本或原始数据。
- **判定**：数量级和趋势（达到约 400 Gb/s、reverse 略低、小 payload 较低）与 RTL 能力不矛盾，但**不能用当前 checkout 复现论文数字**。

### 4.3 少量 QP 的多路径增益（§6.3）

- 当前 M3 的 legacy 默认是 `chooseChannel(roundRobin, eligibleMask)`，确实能实现 per-packet 四通道轮转（`MrcTxScheduler.bsv:287-303, 443-445`）。
- 论文的 fixed-per-QP baseline（QPN 低两位映射通道）在当前 RTL 中没有实现；M3 只有 `channelEnable` 掩码，不能在同一运行中把 4 个 QP 分别固定到 4 个通道。
- 论文的 3.51×（16 KiB、1 QP）、323.5 Gb/s、4 KiB 4 QP 211.8 vs 164.2 等数字没有当前树内 harness/archive；且与 `reference/evaluation-preview.pdf` 的 2.48× / 26.4% 结果不是同一组数值。**不可复现，且与仓库归档结果不一致**。

### 4.4 Request-to-Packet Latency（§6.4）

- **§6.4.1 19-cycle budget 与代码不符**：
  - 论文 Table 18：M0 12 + M0 adapter 3 + M1 3 + exported handshake 1 = 19。
  - 当前 M0 有 12 个 rule firing，但每个 table query 之间是 `mkConnection` 包装的 `mkSizedFIFOF`，每次 request/response 各有一个 Pipe hop。仓库自己的 `report/README.md:108-121` 与 `report/evaluation.tex:181-232` 从同一 RTL 推出 **M0 23 cycles（12 rules + 11 hops）**，加上 adapter/synchronizer/M1 10 cycles，到外部 DMA request 共 **33 cycles**。
  - 因此论文的 19 cycles 至少漏掉了 M0 的 11 个 Pipe hop 以及 adapter/synchronizer 的多个 hop；**与代码结构、仓库自身评估不一致**。
- **§6.4.2 first SOF latency**：当前 `M0ChainScenarioMetrics` 只记录 `submission_accept_ps`、`dma_request_issue_ps`、`tx_commit_ps`、`frame_eof_ps`（`integrations/tx/cocotb/m0_chain_bfm.py:78-87`）；没有 first-SOF 时间戳。论文的 127.5/145/382.5 ns 等“first packet starts”数字无法由现有 instrumentation 直接产生。
- **formula 结构**：`C_first = C_req + R + K + 3`、`C_chunk = C_req + R + 2K + 2` 与 M1 whole-chunk reorder（`DmaEngine.bsv:351, 388-506`）一致；但 `C_req=19` 与代码不符。

### 4.5 Receive Progress Under Path Skew（§6.5）

- **可通过代码参数解释的部分**：1 KiB PMTU 下每 message 为 996 B + 28 B（`shared/bsv/tx/TxTypes.bsv:182-187`），即每 message 2 个 PSN；`RxWindowSize=16`（`shared/bsv/rx/RxTypes.bsv:8`）。因此 8 个 message = 16 PSN，正好填满窗口；第 9 个 message 的首包会越窗。这与论文“8 pass / 9 boundary”在数值上一致。
- **不可复现的部分**：当前树没有 ns-3，也没有 5 个 path-delay profile、1/2/4 QP 的 skew sweep、15 个 short-burst 测试或 `RX_OUT_OF_WINDOW` 的采样统计脚本。论文的 0.354 µs / 1.280 µs、9 pass/10 fail 等具体数值没有当前 artifact。
- **结论**：机制和窗口边界可解释，具体结果不可复现。

### 4.6 Loss Recovery and Retransmission Cost（§6.6）

**一致的方面：**

- E2E 确实实现了本地的 SACK-driven retry、CPU report/decision、M11 单请求、M3 retry 插回主数据流（`integrations/e2e/cocotb/tests/test_e2e.py:424-577`）。
- 论文的 wire 字节账与当前 legacy 头/PMTU 代码精确吻合：
  - 2500 B A + 900 B B，256 B PMTU：A 为 11 包（首包 228 B + 10×244 B），B 为 4 包（228 + 3×244）；首包头 70 B、后续头 54 B；总 payload 3,400 B + header 842 B = **4,242 B**。
  - 单包重传增加 244 + 54 = **298 B**；两个相邻丢包 **596 B**；三个 spread **894 B**。
  - 这些数值与论文 §6.6 的 4,242 B / 298 B / 596 B / 894 B **完全一致**，说明论文的 wire-cost 部分使用了同一套 legacy 头和 PMTU 规则。
- E2E 测试确实在 message B 的前两个 packet commit 之后插入 retry，再完成 B 的剩余 packet，验证 retry 不破坏主数据流顺序（`test_e2e.py:505-560`）。

**不一致/不可复现的方面：**

- 当前 E2E 常量是 `MSG_A_LEN = 1500`、`MSG_B_LEN = 900`、`PMTU = 0`、`DROP_PACKET_INDEX = 1`（`test_e2e.py:59-67`）；论文使用 2500 B A、连续 drop 1–7、burst 2、spread 3，当前测试没有这些变体。
- 当前 `poll_report` 立即轮询 snapshot（循环 8 次、每次发 snapshot request），没有论文所说的“按固定间隔轮询”的 CPU policy（`test_e2e.py:362-393`）；`retx_runtime` 有 `ONDEMAND_INTERVAL_NS`，但 E2E CPU 路径没有模拟这个间隔。
- 当前测试不记录 drop-to-CQE、SACK readiness、report generation、retry commit、retry-to-CQE 的时间戳；论文的 598/582/568/… ns、76–96 ns、236–306 ns、34 ns、160–164 ns 没有当前树内测量代码或原始数据。
- 论文的 “first-frame-to-CQE 616–634 ns” 和 “interleaving +142 ns” 也没有当前 instrumentation。

**结论**：wire 成本和 retry 机制与代码一致；具体 latency 数字不可复现，测试矩阵也不足。

### 4.7 Ordered Completion and Blocking Cost（§6.7）

- **功能层面一致**：M7/M8 支持 reverse DMA completion（3,2,1,0）按 global_seq 退休为 0,1,2,3；M8 支持 per-QP Ordered FIFO、barrier、credit、queue overflow fail-stop。对应测试在 `m7_rx_dma_placement/cocotb/tests/m7/test_dma_placement.py:150-203` 和 `m8_rx_ordered_queue/cocotb/tests/m8/test_ordered_queue.py:97-330`。
- **不可复现**：当前测试只做功能等待，没有记录“Flag enqueue-to-acceptance”“retirement accepted/ready/credit/response”时间；论文的 10/50/210 ns、202/208/210/212/214 ns、34/1034 ns 没有当前测量代码或归档日志。结构上 2 ns cycle 下这些量级是可能的，但不是当前 checkout 的现有结果。

### 4.8 Implementation Evidence（§6.8）

- 论文称 Yosys 综合四通道 TX scheduler 得到 **261,337 generic cells、38,512 DFF、56,899 MUX、4 BRAM2**。
  - 当前生成的 `m3_mrc_tx_scheduler/build/standalone-verilog/mkFourChannelTxScheduler.v` 确实有 **4 个 BRAM2 实例**（约 4410/4449/4488/4527 行），这一点一致。
  - 但树内没有 `synth.log`、`stat` 输出或 netlist 资源报告；本机环境也没有可用的 Yosys（项目文档明确“yosys 本机未安装”），因此 cell/DFF/MUX 数字**无法核验**。
- 论文称 RX top 生成 **21,533 行** production Verilog；当前四个 `mkRxTop.v` 产物均为 **21,077 行**（`integrations/rx/build/production/verilog/mkRxTop.v` 等）。这是明确的数量差异（可能由 BSC 版本/生成选项导致，但当前树不是 21,533）。
- 论文没有给出 Fmax/slack/BRAM 利用率等 §5.6 要求的 timing closure 数据；§6.8 只有 generic cell 计数，不能支撑“timing closed”。

---

## 5. 不一致清单（按严重度）

### A. 严重：论文描述了但代码没有的机制

1. Doorbell 地址/QPN 解码、BAR/8 B 对齐检查（§4.2, §5.1.3/§5.1.4）
2. Doorbell credit、grant page、local head + CAS（§4.2, §5.1.2）
3. `WRITE_ORDERED_FLAG` / `WRITE_RELAXED_THEN_FLAG` 及 Slot pair（§4.1, §5.1, §5.2）
4. TX 侧 4 B Ordered Flag 请求生成与端到端 Flag 网络请求（§4.1, §5.2, §5.5）
5. SRv6/IPv6/uSID、outer destination、Path Table、per-QP EV set（§4.3, §5.2）
6. RX 解析 EV/MRC profile，以及 SACK 回带 EV/ECN（§4.3, §4.6, §5.3）
7. ECN 路径切换的 SACK echo → EV 移除 → spare 替换 → 受影响包重传（§4.6）
8. Path Probe 报文、ACK/timeout、连续成功计数、1/ms rate limiter（§4.6）
9. Congestion-control interface / 注入许可 / ECN 标记（§3.2.1, §5.2）
10. 硬件可靠性 profile：NIC hole inference、Grouped Timer、NIC retransmission scheduler、retry limit 状态机（§4.4, §5.4）
11. 统一生命周期 RESET→CONFIGURE→RUN→STOP→DRAIN→RESET，以及 stop/drain/reconfigure（§5.6）
12. FTile/MAC/PCS/FEC/EMIB/FHT 物理层（§3.3）

### B. 中等：实现结构/字段与论文不同

1. M0 从 `DecodedGdrpSubmission` 开始，而不是从 Doorbell 地址/8 B 存储开始。
2. Slot 表实际只有 16 项，`slot_id` 高 14 bit 必须为 0。
3. M9 用 per-packet journal 而非 SQ Scoreboard bitmap；record 只在 cumulative ACK 覆盖时 complete。
4. M10 输出结构端口，不是单次 PCIe write；没有 host ring/CRC/interrupt。
5. 重传 payload 来自 `RetxReplayStore`（64 slot），不是重新 DMA Read GPU 内存；M9 record 的 DMA metadata 未用于重建 DMA Read。
6. M8 的 Flag 入口是顶层 `RxTop.orderedFlagIn` 测试侧带，不是从 parser/网络包解析。
7. legacy wire 只有 FIRST/ONLY 带 RETH，MIDDLE/LAST 依赖 QP context；不是每包独立携带地址/key。
8. legacy/MRC wire 用 BTH opcode 表示 first/middle/last/only，没有显式 isfirst/islast 字段。
9. M6 所有 out-of-order 情况立即 SACK；没有 lazy SACK 阈值、没有 refresh timer、没有独立 MPR 更新。
10. M3 的 control 优先级入口在 E2E 中未驱动；RX 也不产生 on-wire ACK/SACK/NAK。
11. M6/M9 没有 banking/多 port 共享状态；与 §5.6 的 banked design 不同。
12. `RxCompletion` 没有 request identity，也没有 CQ ring/Completion Management 模块。
13. 论文 §4.6 的 Send Engine “先选 EV 再启动 DMA”与代码（DMA 在 M0/M1 已完成）以及论文 §5.2 Table 6 的顺序都不完全一致。

### C. 轻微/参数差异

1. 论文 §4.6 “~100 EV 路径” vs 代码 4 profile × 8 = 32 个 EV entry。
2. 论文 §4.6 probe 间隔 1/ms vs 代码 `probeIntervalCycles` 默认 4096 cycles。
3. 论文 §6.1 2.5 ns vs 当前所有 BFM 2 ns。
4. 论文 Table 16 BSC 2023.01 vs 当前报告/环境 BSC 2025.01.1。
5. 论文 §6.1 RX skip 数（3/2）vs 当前 short/long 的 1/0。
6. 论文 §6.8 RX 21,533 行 vs 当前 21,077 行。
7. 论文中 `WQE Record` 由 WQE Parse 绑定，代码由 `RetxWqeMonitor` 从 M2 context 旁路注册。

### D. 当前树中一致/可支撑的部分

1. 64-bit Doorbell 字段切片（`TxMvp.bsv:30-37`）。
2. Slot/MR/QP/PGT 查表、地址溢出检查、16 MiB 长度限制、1 KiB/4 KiB-safe burst split（`TxMvp.bsv:43-73, 111-136, 188-258, 278-324`）。
3. M2 分片、first/continuation payload limit、PSN 使用（`TxTypes.bsv:182-187`；`PacketAssembly.bsv`）。
4. M3 四通道 encoder、round-robin legacy 通道选择、control/ordered/retry/first 优先级、`maxHighBurst` 防饥饿、MRC IPv4/UDP/BTH/METH/RETH 头与 pad（`MrcTxScheduler.bsv`、`MrcHeaders.bsv`）。
5. M6 16-bit bitmap、duplicate/old/out-of-window、`ack_psn` 在 bitmap commit 后前进、`ooo_count=popcount`（`RxRqBitmapManager.bsv`）。
6. M7 四 lane、global_seq、single ordered retire、reverse completion 按 global_seq 退休（`RxDmaPlacement.bsv`）。
7. M8 per-QP Ordered FIFO depth 4、barrier=`dmaAckPsn`、absolute credit、queue-full fail-stop（`RxOrderedQueueManager.bsv`）。
8. M9 WQE Record/journal、snapshot、admission；M10 report/notification；M11 单请求 retry/fetch/result（`m9`–`m11`）。
9. CPU 侧 `SACK_THRESHOLD=3`、per-QP timeout、retry limit 3、backoff（`retx_runtime/runtime.py:14-19, 138-255, 330-375`）。
10. E2E 的 TX→RX→Retx 数据链路和 retry 在主 message 边界插入（`integrations/e2e`，`test_e2e.py:424-577`）。
11. 论文 §6.6 的 4,242 B/298 B/596 B/894 B wire 账与当前 legacy 头/PMTU 代码精确一致。
12. 论文 §6.5 的 1 KiB→2 PSN/message、16 PSN window 可解释 8 pass/9 boundary。
13. 论文 Table 17 的 TX short 67 pass 与当前测试计数一致；reverse DMA/queue capacity 有功能测试。
14. 论文 §6.8 的四 BRAM2 实例与当前 M3 生成 Verilog 一致。

---

## 6. 建议

### 6.1 如果论文按当前代码提交

1. **把第 3–5 章分成“已实现”与“设计目标”两部分**，至少把以下内容标为未实现/未来工作：Doorbell credit/grant、地址解码、`WRITE_ORDERED_FLAG`/combined、SRv6/Path Table、EV feedback/probe、ECN 路径切换、硬件可靠性 profile、Grouped Timer、生命周期 stop/drain、FTile MAC/FEC。
2. **第 6 章只保留当前 tree 能复现的结果**：
   - 要么恢复并归档 ns-3 联仿 harness、raw trace、run manifest；
   - 要么把吞吐/多路径/skew 结果替换为当前 RTL-only 测试可产生的数字，并明确“无网络模型”。
3. **修正 §6.4.1 的 19-cycle 模型**：至少与 `report/README.md` 的 23/33-cycle 推导统一；若要声称 19，需要说明哪些 Pipe hop 被旁路/融合，而当前 RTL 并没有这些旁路。
4. **修正 §6.8**：给出可核验的 Yosys/Quartus 命令、版本、日志与资源报告；或删除具体 cell 数，只保留“已生成 Verilog/有 4 个 BRAM2”的可验证事实；RX 行数以实际产物为准（当前 21,077）。
5. **统一时钟/工具链**：Table 16 的 2.5 ns 与所有 BFM 的 2 ns 二选一；BSC 版本与 run manifest 对齐。
6. **补齐第 6 章测试矩阵**：至少把 E2E 的 A 改为 2500 B、加入 drop 1–7/burst/spread、加入固定间隔 polling，并记录 drop-to-CQE/SACK readiness/retry commit/CQE 时间戳；否则不要报告这些具体 latency。

### 6.2 如果论文要维持现有强声明

需要实现的关键路径（按依赖顺序）：

1. 在 M0 前增加 Doorbell 地址解码/8 B 对齐/BAR 检查和 Slot 地址映射。
2. 增加 Doorbell credit/grant page（或至少把 M8 的 absolute credit 模式扩展到 TX 侧），并把 `WRITE_ORDERED_FLAG`/`WRITE_RELAXED_THEN_FLAG` 接到 M2/M3/RX 的端到端 Flag 通路。
3. 在 M3 实现 Path Table（EV → outer destination/local port/channel）和 SRv6 封装；在 M5 实现对应解封装；打通 EV/ECN feedback。
4. 在 M3/M5/M6 之间打通 ECN 标记 → SACK EV echo → EV skip/spare → 受影响包重传；实现 probe 报文和成功计数。
5. 在 NIC 实现硬件 reliability profile（hole inference、Grouped Timer、retransmission scheduler、retry limit），或明确论文只支持 software-coordinated profile。
6. 实现统一 lifecycle 和 stop/drain/reconfigure；补 timing/SDC/综合报告。
7. 为第 6 章建立可复现的 ns-3/网络模型与 run manifest，或删除不可复现的数值。

---

## 7. 审查结论

- **第 3 章**：模块划分和 TX/RX 主数据流有对应实现；但 CPU/GPU 双提交、credit、FTile 物理层、congestion control 被写成既有能力，代码没有。
- **第 4 章**：4.1 的 RX Flag 队列、4.4 的 bitmap 语义、4.5 的软件协同恢复方向与代码基本一致；4.2 的 credit/grant、4.3 的 SRv6/EV、4.6 的 ECN/probe 闭环、4.4 的硬件可靠性 profile 与代码不符。4.7 与 4.5 自相矛盾。
- **第 5 章**：5.1 的 Doorbell 字段格式、5.2 的 TX 阶段划分、5.3 的 bitmap/DDP/ordered retire、5.5 的 per-QP Flag 队列/credit、5.6 的 1024-bit/4-channel 预算有代码对应；5.1 的 admission/credit/ordered ops、5.2 的 Path Table/ordered TX、5.4 的硬件 profile、5.6 的 lifecycle/timing 没有实现或不可验证。
- **第 6 章**：功能测试、wire 字节账、窗口边界、reverse retirement 等定性/参数性结论有代码支撑；所有关键定量结果（380.9 Gb/s、3.51×、508–598 ns、620/682 ns、19 cycles、261,337 cells）在当前 `OpenRDMA-flow` 中**没有可复现的 harness 或归档证据**，部分数字与仓库自身报告（33 cycles、2.48×、21,077 行）直接冲突。

因此，当前代码不能被认为是论文第 3–5 章所描述的“完整架构”的实现，也不能复现第 6 章的完整实验矩阵；它更适合被描述为 **M0–M11 的功能性 MVP**：TX 主路径、RX bitmap/DDP/ordered retire 和软件协同重传闭环可运行，而 GPU 提交反压、SRv6/EV 多路径控制面、ordered flag TX、ECN/probe 拥塞控制、硬件可靠性 profile 和物理 FTile 层仍需实现或明确降级为设计。
