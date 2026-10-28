# TX 吞吐诊断：从 201.88 Gb/s 到 400 Gb/s

本文记录 2026-10-27 对 `paper-ji` 工作区 TX 数据通路的定位、修复与复测。归档结果仍以
`report/evaluation.tex` 和 `reference/evaluation-preview.pdf` 为准，本文不修改、不替换任何归档数值。

## 1. 单位与目标

- 目标 **400 Gb/s = 50 GB/s**，不是 400 GB/s。
- 网络侧是 4 条独立 100 Gb/s 链路；400 Gb/s 是 line-rate 上限，扣除 Ethernet/IP/UDP/BTH/RETH
  header、IFG 和 preamble 后的 payload goodput 必然更低。
- 本文的 400 Gb/s 指 **2 ns model cycle、无下游反压、aligned 1 KiB chunk、steady-state、
  按 TX payload handshake 计时** 的 cycle-model 速率；它不代表 FPGA Fmax、PCIe/GPU 或 MAC 实测。

## 2. 归档 E04 的现象

归档批次 `batch-2q374d`（来源：远端 `implementation` 分支的
`evaluation/evaluation-report.md`；本文只引用其数字，不在本地重建该批次）使用 4 QP、PMTU 4096、
每路径 200 ns、completion 每拍 1 beat。对应论文入口是 `report/evaluation.tex` 的 RQ1 与
Figure 2(a)：

| 配置 | TX effective（full window） | 说明 |
|---|---:|---|
| 128×1 KiB，无额外等待 | 201.88 Gb/s | 128-message 批次，含启动/排空 |
| 32×1 KiB，无额外等待 | 175.2 Gb/s | 同配置 32-message 批次（`evaluation.tex` RQ1） |
| 32×1 KiB，每 request 延迟 20 cycles | 104.11 Gb/s | 相对 175.2 = 0.59× |
| 32×1 KiB，每 request 延迟 100 cycles | 34.32 Gb/s | 相对 175.2 = 0.20× |

注意 20/100-cycle 行必须与同批次的 175.2 比较，不能与 128-message 的 201.88 比较。归档事件呈现固定
模式：一个 1 KiB message 只发出一个 DMA request，约 15 cycles 后回完整 completion，然后才取下一个
request。20/100-cycle 等待因此被**逐 request 串行累加**，而不是由 8 个 outstanding slot 并发隐藏。
该现象只能证明“上游供给限制吞吐”，不能归因于 M0 查表。

## 3. 代码层根因

### 3.1 实验 DMA 模型（决定等待如何缩放）

`integrations/tx/cocotb/m0_chain_bfm.py`（以及评测分支归档的 `tx_stream.py`）按 message 顺序：

1. 收 1 个 `DmaReadRequest`；
2. 立即按固定顺序回该 request 的全部 completion beat；
3. 再收下一个 request。

M1 明明有 8 个 outstanding slot，模型却始终只让 1 个 request 在途。这会造成：

- 人为等待被逐个 request 相加，而不是被并发掩盖；
- 归档数据无法区分 RTL 结构性气泡与 DMA latency。

但串行模型不是零延迟下 201.88 Gb/s 的原因：§5.5 的隔离实验显示，新 RTL 配合同一串行模型、
零延迟时仍可达 340.4 Gb/s（32-message full window）。因此归因应拆成两部分：

| 对照 | A | B | 比值 |
|---|---|---:|---:|
| RTL 效应（均串行、0 latency、32 msg full） | 旧 RTL 175.2 | 新 RTL 340.4 | 1.94× |
| 模型效应（均新 RTL、20 cycles） | 串行 129.0 | 并发 400.2 | 3.10× |

### 3.2 M1（`m1_dma_engine/src/DmaEngine.bsv`）

BSC `-show-schedule` 在修复前明确给出：

- `receiveCompletion` 阻塞 `dmaCompletionIn_enq`：completion FIFO 不能同拍入队和出队；
- `drainMiddleBeat` / `drainLastBeat` 阻塞 `orderedBeatOut_deq`：reorder 输出 FIFO 同样隔拍；
- tracker 的 `stageOrderedBeat` 阻塞 `orderedBeatIn_enq`。

复现：`make -C m1_dma_engine test PYTHON=…` 会以 `-show-schedule` 编译，dump 位于
`m1_dma_engine/build/dma/verilog/mkDmaCompletionReorder.sched` 与
`mkDmaMessageTransferTracker.sched`；修复后这两个文件中上述 `Blocking rules` 已消失。

completion 携带 1024-bit data + keep；三处 `mkSizedFIFOF(2)` 的互斥把该数据热路径降到约半速。

### 3.3 M2（`m2_packet_assembly/src/PacketAssembly.bsv`）

- `payloadQ` 是 `mkSizedFIFOF(2)`，`emitPayload` 与 `payloadOut_deq` 互斥；
- 每个 message 结束后进入 `P_FLUSH` 再回 `P_IDLE`，在最后一次 request 已精确消费 EOP 后仍多占一拍；
- 每个 packet 先进入 `P_DESCRIPTOR` 状态再 `P_PAYLOAD`，1 KiB/4 KiB PMTU 下每 message 多一次状态往返。

### 3.4 M3（`m3_mrc_tx_scheduler/src/MrcTxScheduler.bsv`）

- 每通道 `frameQ` 是 `mkSizedFIFOF(2)`，`emitFrameWord` 与 `channelNOut_deq` 互斥，256-bit egress 隔拍；
- `firstPayloadQ` 等四个 ingress payload FIFO 与 `selectedPayloadQ` 存在同类互斥；
- `nextBeat` / `nextBeatValid` 在 `captureNextBeat` 写入、`emitFrameWord` 读取并清零，形成 BRAM
  预取与帧发射之间的写后读依赖，帧发射周期性多占一拍。

## 4. 修复

| 位置 | 修复 | 保留的语义 |
|---|---|---|
| M1 `completionQ`、reorder `orderedQ`、tracker `orderedQ` | 改为 `mkPipelineFIFOF` | 同拍 enq/deq；whole-chunk reorder、8-slot tag、generation 不变 |
| M1 两级 `retireQ` | 改为 `mkBypassFIFOF` | slot/message 回收时序不变 |
| M2 `payloadQ` | 改为 `mkPipelineFIFOF` | 反压与 keep 检查不变 |
| M2 message 结束 | 删除 `P_FLUSH`；最后一个 request 精确消费 EOP 后直接 `P_IDLE` | 最后 payload handshake 语义不变 |
| M2 首 descriptor | `startMessage` 直接组合生成并入队 descriptor，去掉首 packet 的 `P_DESCRIPTOR` 一拍 | 字段、PSN、opcode、地址不变 |
| M3 四通道 `frameQ` | 改为 `mkPipelineFIFOF` | `TxEgressEvent` 仍只在 EOF word 被 dequeue 后可见 |
| M3 ingress payload FIFO | 改为 `mkSizedBypassFIFOF(2)` | 保留 2 entry 容量与原有“满则停”语义 |
| M3 `selectedPayloadQ` | 改为 `mkSizedBypassFIFOF(8)` | 8-beat staging 覆盖稳态同拍 enq/deq；更长 packet 由 `storePayload` 每拍排空 |
| M3 `nextBeat`/`nextBeatValid` | 改为 `mkCReg(2, …)`，capture 写端口 0、emit 读端口 1 | 预取数据不变，仅解除写后读冲突 |
| TX DMA BFM | 改为全局 outstanding 队列 + 每 request 独立 `ready_cycle` | 仍逐字段比对、仍支持 reverse/interleaved completion |

DMA BFM 新增参数 `request_latency_cycles`、`prime_outstanding`、`completion_order` 和
`metrics`。`request_latency_cycles` 是每个 request 从发出到可回 completion 的独立延迟；
`prime_outstanding` 是预热时允许在途的 request 数。二者不改变 scoreboard。

## 5. 复测结果

工具链：BSC 2025.01、Verilator 5.048、cocotb 2.1.0.dev0，2 ns model cycle，`SIM=verilator`。

### 5.1 M0 独立 request 供给

`m0_doorbell_analysis` 新增 `sustained_single_chunk_request_rate_exceeds_400_gbps`：
128 个 1 KiB submission、PMTU 4096、单 chunk、无下游反压，排除首尾各 16 个 request 后测得

- **819.20 Gb/s**（5 cycles/request；1 KiB 在 2 ns 周期下 5 拍正好是 819.2 Gb/s）。

结论：M0 的 12-cycle 查表是启动延迟，不是 201.88 Gb/s 的稳态瓶颈。

### 5.2 M1 独立 payload 供给

`m1_dma_engine` 新增 `sustained_payload_rate_hides_bounded_request_latency`：
128 个 1 KiB message、8 outstanding、completion 每拍 1 beat，排除首尾各 128 beat：

| request latency | M1 steady payload |
|---:|---:|
| 0 cycle | 455.573 Gb/s |
| 20 cycles | 455.573 Gb/s |
| 100 cycles | 265.700 Gb/s |

0 与 20 cycles 完全相同，说明 8-slot BDP 足以完全隐藏 20-cycle 延迟。

### 5.3 M0→M3 端到端

`integrations/tx` 新增 `sustained_m0_to_m3_rate_hides_bounded_dma_latency`：
128×1 KiB、4 QP、PMTU 4096、4 通道、无出口停顿。`steady` 排除首尾各 16 个 frame；
`full-window` 与归档 E04 边界一致（首个 submission 接受到最后 frame EOF）。

| request latency | submission | DMA request | TxCommit | frame EOF（steady） | full-window |
|---:|---:|---:|---:|---:|---:|
| 0 cycle | 517.447 | 455.111 | 454.049 | **441.680 Gb/s** | **400.220 Gb/s** |
| 20 cycles | 517.447 | 455.111 | 454.049 | **441.680 Gb/s** | **400.220 Gb/s** |
| 100 cycles | 277.744 | 247.847 | 247.847 | 247.689 Gb/s | 226.377 Gb/s |

0/20 cycles 的 frame EOF 周期间隔直方图为 `{9: 96, 10: 28, 11: 3}`，加权平均
`(9×96 + 10×28 + 11×3) / 127 = 9.27` 拍，与 441.68 Gb/s 对应。DMA request 直方图
`{5: 7, 38: 1, 9: 115, 10: 4}` 还包含启动阶段，不能直接用作稳态均值。归档 128-message
full-window 201.88 Gb/s 对应约 20.3 拍/message；新 RTL 为 400.22 Gb/s，约 **1.98×**。
该倍数同时包含 RTL 修复与 DMA 模型修复，拆分见 §5.5。

### 5.4 为什么 100-cycle 只有 247.69 Gb/s

8 个 outstanding slot 的 BDP 上限为

```
rate ≈ N × 1024 B / (L + S) × 8 bit / 2 ns
```

其中 `N = 8`，`L = 100 cycles`，`S` 是单 slot 的完成/排空/回收服务时间。由 247.689 Gb/s 反推：

```
每 8 个 chunk 的周期数 = 8 × 1024 × 8 / 247.689e9 / 2e-9 = 132.3
S ≈ 132.3 - 100 = 32.3 cycles
```

因此 247.69 Gb/s 是 8-slot reorder 的容量上界，不是 RTL 死锁或 M0 查表问题。要在此延迟下达到
400 Gb/s，需要约 `400/248 × 8 ≈ 13` 个 outstanding slot；当前 `DmaSlot = Bit#(3)` 与 8 组
per-slot rule 是硬边界。验收阈值已按该上界修正为 ≥240 Gb/s，保留 3% 余量；本轮不扩展 slot 位宽。
扩展 tag/slot 还需要复制全部 per-slot 规则并重新验证 BSC 展开与面积/时序，不能仅按 13 槽估算收益。

### 5.5 模型与 RTL 的隔离

同一串行 DMA 模型（`serial_dma=True`，32×1 KiB，full-window）与新 RTL 的对照：

| 配置 | 0 cycle | 20 cycles | 100 cycles |
|---|---:|---:|---:|
| 归档旧 RTL，串行（32 msg，full） | 175.2 | 104.11 | 34.32 |
| 新 RTL，串行（32 msg，full） | **340.447** | 129.008 | 36.653 |
| 新 RTL，并发（128 msg，full） | 400.220 | **400.220** | 226.377 |
| 新 RTL，并发（128 msg，steady） | 441.680 | 441.680 | 247.689 |

- **RTL 效应**：同一串行模型、零延迟，175.2 → 340.4 Gb/s（1.94×）。因此零延迟下的 201.88 Gb/s
  主要来自 §3.2–§3.4 的 FIFO 互斥，而不是 DMA 模型。
- **模型效应**：同一新 RTL、20 cycles，串行 129.0 vs 并发 400.2 Gb/s（3.1×）。因此 20-cycle 下
  的 104.11 Gb/s 是“逐 request 累加等待”，不是 RTL 无法隐藏该延迟。
- 未运行“旧 RTL + 新并发模型”组合（迁移前的完整旧树不可直接构建）；旧 RTL 一侧只用归档同批次
  数字对照，且批次规模已在表中标明。

### 5.6 其它消息尺寸

64 messages、4 QP、PMTU 4096、并发、零延迟，steady 排除首尾各 8 个 frame：

| 消息大小 | frame EOF（steady） | 说明 |
|---:|---:|---|
| 64 B | 56.224 Gb/s | 每 message 固定开销占主导，1 KiB 级门限不适用 |
| 4 KiB | 419.092 Gb/s | 达到 400 Gb/s |
| 16 KiB | **465.051 Gb/s** | 达到 400 Gb/s；归档同配置为 124.9 Gb/s（批次边界不同） |

64 B 的速率由 message 速率而非 payload 带宽决定；不能据此声称小消息也达到 400 Gb/s。path-policy、
RX 与重传闭环未在本轮复测。

## 6. 证据边界

- 所有数值来自 Verilator cycle model；2 ns 不是 achieved FPGA clock。
- ns-3 网络、MAC 上线、PCIe/GPU、ICRC/FCS、ACK 驱动重传均不在本复测范围。
- 归档 `report/evaluation.tex` 的 E04 数值保持不变；本文只解释其 DMA 模型和 FIFO 调度原因。
- 模型/RTL 隔离只做了“新 RTL + 串行模型”与“新 RTL + 并发模型”两组；未运行“旧 RTL + 新并发模型”。
  §5.5 的 RTL 效应使用同批次串行行对照，模型效应使用同 RTL 的行对照。
- 尺寸复测只覆盖 64 B/1 KiB/4 KiB/16 KiB、4 QP、零延迟；32/128-message、path-policy、RX 和重传闭环
  未全部重跑。64 B 受 message 速率限制，不声称达到 400 Gb/s。
- 未扩大 M1 outstanding slot：100-cycle 行按 8-slot BDP 上界验收（≥240 Gb/s），不把容量限制
  误归因于 M0；若要在此延迟下达到 400 Gb/s，需要单独扩展 tag/slot 位宽与 per-slot rule。
- 仍存在的结构性气泡：M1 `forwardRegistration`/`forwardDone` 被 `!payloadDeqReq` 门控，每 message
  至少多一拍；M3 只有一个全局 `active`，同一时刻只填充一个 channel 的 BRAM。两者在 4–16 KiB
  复测中未把速率压到 400 Gb/s 以下，但仍是后续可优化点。

## 7. 复现

```bash
PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
make preflight PYTHON="$PYTHON"
make -C m0_doorbell_analysis test PYTHON="$PYTHON"
make -C m1_dma_engine test PYTHON="$PYTHON"
make -C m2_packet_assembly test PYTHON="$PYTHON"
make -C m3_mrc_tx_scheduler test PYTHON="$PYTHON"
make -C integrations/tx test-m0chain PYTHON="$PYTHON"
```

吞吐用例会打印 `M0 稳态 DMA request`、`M1 稳态 payload`、`M0→M3 稳态`、串行 DMA 基线、
消息尺寸扫描与周期间隔直方图；阈值断言失败时保留完整信息，便于区分数据错误与 BDP 容量限制。
negative 套件：`make test-negative SIM=icarus PYTHON="$PYTHON"`。
