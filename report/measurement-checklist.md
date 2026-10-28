# FCCM Evaluation 补测清单

本清单定义 `evaluation.tex` draft 模式中的四组 planned measurements。它只规定如何测，不提供或暗示
结果。任何数据进入论文正文前，必须满足相应的 provenance、flow status 和复现门槛。

## 1. 通用 run manifest

每次实验生成唯一 `run_id`，并同时保存 machine-readable manifest、raw data 和 aggregate summary。

必填字段：

| 类别 | 字段 |
|---|---|
| Source | git commit、dirty status、submodule/生成契约状态、experiment script hash |
| Toolchain | BSC、Verilator/Icarus、cocotb、Python、ns-3、Quartus/Yosys 的完整版本 |
| Build | top、wire profile、clock period/constraint、parameter set、simulator、compile flags |
| Workload | payload、PMTU、QP、lane/path、window、burst、DMA latency、backpressure、loss/skew |
| Randomness | master seed、derived seed 列表、每个 seed 的 run ID |
| Timing | warm-up、measurement interval、drain policy、event endpoints |
| Artifacts | raw trace、JUnit、CSV/JSON、log、waveform（若开启）、report、plot-script hash |
| Outcome | PASS/FAIL/EXPECTED_FATAL/BLOCKED；不能只依赖 JUnit `<failure>` 标签 |

所有 aggregate CSV/JSON 必须包含 `run_id`、配置键和单位。图表从 aggregate 文件确定性生成，不能手工
抄写数值。

## 2. P-XMODEL：cross-model closure

### 目标

恢复或重建外部 ns-3 harness 后，证明同一输入 trace 在 Python reference model、BSV/Verilator 和
network co-simulation 中保持一致。它回答“网络模型改变 arrival order 时，是否仍保留 RTL 选择的
packet production timing”，不回答物理 FPGA 性能。

### 输入矩阵

- payload：64 B、1 KiB、4 KiB、16 KiB；
- PMTU：256、512、1024、2048、4096 B；
- active QPs：1、2、4；
- path：1、2、4；delay 为 equal、单路径 +200/+500/+1000/+2000 ns；
- end-to-end RX closure 仅使用 `WIRE_LEGACY_PRIVATE`；`WIRE_MRC_IPV4_ECMP_NO_ICRC` 仅做 TX byte/timing/network 子矩阵，RX 标为 `N/A/BLOCKED`；
- deterministic reorder、duplicate、drop trace；closed-loop 未接通前，drop case 记录 network-dropped、missing PSN 和 RX/message terminal `INCOMPLETE/TIMEOUT`，只对实际到达的 duplicate/out-of-window packet 使用 `rejected`；
- packet spraying；fixed-per-QP 仅作为 archived baseline，恢复其 QPN-to-path、ready/backpressure 语义后才能重新比较。

### 比较项

1. request ID、QPN、PSN、packet index/count；
2. frame byte stream、payload length、channel/path、injection timestamp；
3. arrival event 的 path、timestamp 和 order；
4. RX accept/duplicate/out-of-window、DMA request、retire、CQE/Flag event；
5. packet/frame/event count 和 terminal state。

### 晋级门槛

- deterministic case 的 frame bytes、IDs、path 和 event order必须 exact match；
- timestamp 仅在共享时钟边界上比较，容差和原因必须写入 manifest；
- adapter、config、raw trace、parser 和 summary script 全部归档；
- 当前 preview 的 `20 per-path captures` 只有在以上 artifact 恢复后才能替换为 current reproducible result。

建议输出：`xmodel-events.csv`、`xmodel-summary.json`、一张按时间对齐的 TX injection / network arrival /
RX decision timeline。

## 3. P-CYCLE：数据通路 cycle breakdown

### 目标

补充“数据运行周期”：报告 semantic event 之间的 model cycles、initiation interval、stall 和 occupancy，
而不是用整个 cocotb testcase 的 `sim_time` 推断 datapath latency。

### TX event 定义

| Event | 准确定义 | 不能解释为 |
|---|---|---|
| `t_m0_submission_admit` | M0 submission 完成 ready/enable handshake | GPU MMIO 完成 |
| `t_integration_request_admit` | TX integration request 完成 ready/enable handshake | M0 submission；两种起点不得合并成同一分布 |
| `t_dma_req_first/last` | 第一/最后一个 abstract DMA read request handshake | PCIe TLP 上线 |
| `t_dma_cpl_first/last` | 第一/最后一个 abstract DMA completion 被 M1 接收 | 真实 PCIe latency |
| `t_m2_desc_first/last` | M2 descriptor handshake | frame 上线 |
| `t_commit_enqueue_first/last` | packet 进入 M3 buffer 时，内部 `TxCommit` 被写入 `commitQ`；需要内部 instrumentation | exported notification handshake |
| `t_channel_eof_deq_first/last` | channel 内 EOF word 从 `frameQ` dequeue，并在源点生成 egress event；需要内部 instrumentation | wire EOF、RTT |
| `t_commit_notify_first/last` | exported `TxCommit` handshake，已包含 notification queue/consumer wait | 精确 buffer-admission 时刻 |
| `t_egress_notify_first/last` | exported `TxEgressEvent` handshake，已包含 per-channel/top-level queue、merge 与 consumer wait | 精确 EOF dequeue、MAC 上线、RTT |

报告：first-packet latency、latest-EOF latency、cycles/packet、cycles/message、steady initiation interval、
M1 tag occupancy、M2/M3 FIFO high-watermark、每 source/channel wait 和 stall-reason cycles。datapath stage cost
使用内部 source point；notification cost 单独报告 source→exported-handshake queue delay。observer 必须 always-ready，
并另设 backpressure case 验证 notification queue 行为。

### RX event 定义

| Event | 准确定义 |
|---|---|
| `t_sof` | M4 首 beat handshake |
| `t_parse` | M5 parsed-packet handshake |
| `t_admit_rx` | M6 admitted-packet handshake |
| `t_dma_req_rx` | M7 abstract DMA descriptor handshake |
| `t_dma_cpl_rx` | abstract DMA completion 被 M7 接收 |
| `t_retire` | M7 retire 被 M8 接收 |
| `t_cqe` | CQE output handshake |
| `t_flag_req/resp/credit` | Ordered Flag request、abstract response、credit handshake |

报告：SOF→parse/admit/DMA request、completion→retire、retire→CQE/Flag，以及 M4 slot、M6 bitmap/window、
M7 outstanding DMA、M8 pending Flag 的 occupancy/high-watermark。

### 参数矩阵

- payload：64 B、1 KiB、4 KiB、16 KiB；
- PMTU：256、512、1024、2048、4096 B；
- active QPs：1、2、4；
- DMA wait：0、20、100 model cycles；
- output backpressure：0、20、100 cycles，以及 deterministic burst pattern；
- receive order：in-order、reverse within window、duplicate、window boundary；
- 每个 deterministic case 报 exact cycle；randomized case 报 P50/P95/P99/max 和 seed 数。

### 晋级门槛

- event 必须来自 handshake，不得以 packet index、queue non-empty 或 testcase end 代替；
- ns 换算必须写成 `model cycles converted at the configured model clock`；
- 只有成功 post-route 后，才可单独给出按 achieved clock 换算的实现估计；仍不能称 wire latency。

## 4. P-SCALE：steady-state、scale 与 robustness

### finite-batch 与 steady-state 分离

现有结果继续标为 deterministic finite batch。新增 steady-state 测量必须定义：

1. offered-load ramp；
2. warm-up interval（不计结果）；
3. fixed measurement interval；
4. drain interval（不计 throughput）；
5. saturation 判定和 queue-growth 判定；
6. stochastic case 的固定 seed 集合及 95% confidence interval。

### 参数矩阵

- QP：1、2、4（参数化扩展完成后再增加）；
- receive window：当前 16；8/32/64 只有 RTL 真正参数化后才可测；
- burst：1 到首次 failure 后至少两个点；
- path skew：0、200、500、1000、2000 ns；
- loss：0、单包、burst；closed-loop 未接通前报告 network drop、missing PSN、message/retirement `INCOMPLETE/TIMEOUT` 和后续实际到达包的 secondary window decision，不能报告 recovery goodput；
- message/PMTU：覆盖单包、边界 small-tail 和 multi-packet；
- policy：packet spraying；fixed per QP 仅在 archived baseline 的映射与 backpressure 语义恢复后加入；byte-aware/message-aware 只有实现后才加入。

### 指标

- payload goodput，明确与 line/wire rate 的区别；
- per-message completion P50/P95/P99/max；
- accepted/rejected/duplicate/out-of-window packet 数；
- retransmitted bytes 和 recovery time（仅 closed loop 完成后）；
- per-path packet/byte distribution、Jain fairness；
- queue/window occupancy、stall reason、failure mode；
- saturation offered load 和 convergence time。

### RX boundary 专项

对每个 skew 点穷举 burst length，至少保存：largest tested pass、smallest tested fail、实际最大 window occupancy、
缺失 PSN、window base、arrival order。不能把两个 marker 推导成通用 capacity 公式，也不能把 +200 ns 的非单调
现象推广为“增加 delay 提高容量”。

## 5. P-SUBMIT：GPU-ready 到首个 on-NIC payload

### 目标

验证正文中的 code-derived cycle model：从 `DecodedGdrpSubmission` 可见，到首个外部 `DmaReadRequest`
handshake，再到 M1 `payloadOut` 的首个和完整 1-KiB chunk。

### 结构基线

当前 RTL 的串行下界：

- M0 Slot/MR/QP/PGT 查询与 burst split：12 cycles；
- M0 adapter + context/chunk synchronizer：3 cycles；
- M1 normalizer + scheduler + reorder installation：3 cycles；
- exported DMA-request handshake：1 cycle；
- 合计：19 cycles；
- 首 payload：`C_req + R + K + 3`；
- 完整 chunk：`C_req + R + 2K + 2`；
- 4-KiB-aligned 1-KiB chunk：K=8，首 beat `R+30`，完整 chunk `R+37`。

这些数字假设 no stall、一周期表查询、one completion beat per cycle、下游 always-ready；不是
post-route 或实测值。

### cocotb 验证

在以下事件打 timestamp，并保存 per-case CSV：

1. submission accepted into `submissionQ`；
2. first `DmaReadRequest` handshake；
3. first and last `DmaCompletionBeat` handshake；
4. first and last `DmaPayloadBeat` handshake at `payloadOut`。

至少覆盖：

- payload 64 B、1 KiB、4 KiB；
- PMTU 256/512/1024/2048/4096；
- 4-KiB aligned 与 unaligned physical address；
- no backpressure 与 M1/M2 backpressure；
- completion in issue order 与 reverse-order batches。

如果实测 cycle 与 12/19 不一致，先定位是额外 FIFO hop、Bluespec rule conflict、completion batching，
还是 downstream stall；不要为了匹配模型修改测量点。

### 与 IBGDA 同平台测量

在同一 GPU、NIC、PCIe link、payload 和 fence scope 下测量：

- `mini-gda` inline 与 non-inline；
- `GDAKI` inline；
- `NVSHMEM` internal/public。

记录：

- issue（WQE construction + dbrec + doorbell）；
- put+completion；
- first payload arrival at NIC（若 NIC counter/timestamp 可得）；
- p50、p99、run count、SM clock、GPU/NIC 型号、PCIe generation。

IBGDA 的 kSM-cycle 只用于展示 SM-clock 依赖；OpenRDMA 的 12/19 是 NIC RTL cycles。两者必须先换算成 ns，
不得直接相减。正文中的 0.70/4.03/5.31/11.10 µs 来自公开 p50，不是本仓库实测；本仓库若要主张同平台优势，
必须重新测量同一 pair。

### 晋级门槛

- code-derived cycle 表可以进入 final，但必须保留 “lower bound / no stall / one-cycle lookup” 限定；
- 硬件对比只有同平台、同 fence、同 payload、同测量端点时才可进入结果表；
- 不能把 GPU SM cycles 与 NIC cycles 直接比较；
- 不能把 2 ns model clock、target constraint 或 IBGDA SM clock 当作 achieved NIC Fmax。

## 6. P-SYNTH：resource、timing 与 power

### 前置条件

1. 明确 target FPGA part 和 tool version；
2. production top 或受控 pin-reduction wrapper，不能直接暴露数千个 debug/top-level pins；
3. 完整 clock/reset/CDC 与 SDC；
4. 明确是否包含 PCIe、MAC/FTile、memory controller 和 shell；
5. 参数固定：QP/window/record/buffer depth、wire profile、lane/channel 数。

### 结果分层

| Evidence stage | 可报告 | 不可报告 |
|---|---|---|
| Logical inventory | declared entry bits/bytes | LUT/ALM、BRAM packing、Fmax |
| Analysis & Synthesis | estimated ALM/LUT/FF/RAM/DSP、flow status | placed resource、timing closure |
| Fitter success | placed resource、pin/clock utilization | Fmax（若未运行 timing sweep） |
| TimeQuest success | target frequency、WNS/TNS、critical path | measured board stability |
| Board measurement | sustained throughput、latency、rail/wall power | 未测的 GPU/application speedup |

### 必填列

`component/config`、`core-only or shell-inclusive`、`flow stage/status`、ALM/LUT、FF/register、
BRAM/M20K/URAM、DSP、target clock、WNS/TNS、post-route Fmax（若真的 sweep）、tool/part/run ID。

至少分别报告 M0/M1/M2/M3、M4–M8、M9–M11、TX/RX/Retx integrations 和 full top（若存在）。
parameter scaling 只有同一 wrapper、constraint 和 tool version 下才可比较。

### 历史 M1 artifact

现有 M1 artifact 的 Fitter 因 pin demand 257% 失败，无 TimeQuest/Fmax，因此只能登记为 failed-fit diagnostic，
不能填入 final resource table。重新测量必须使用受控 wrapper，并完整执行 Analysis & Synthesis、Fitter、TimeQuest。

### Power

- `report_power` 只能称 estimated power，并记录 activity input；
- measured power 必须说明 board rail 或 wall、仪器、idle/load、采样区间、payload/packet size 与速率；
- 建议同时报告 W、Gb/s/W 和 J/Gbit；不能把 interface width × clock 当作 achieved throughput。

## 7. Closed-loop recovery：当前 BLOCKED

只有在 `integrations/retx` 真实连接 M3、M6 和 host/runtime 后，才允许测量并声称：

1. feedback/snapshot → M10 report；
2. host policy decision；
3. retry request → M9 admission；
4. M11 fetch → M3 egress；
5. RX eventual acceptance/completion。

届时记录 recovery latency breakdown、software response time、retransmitted packets/bytes、retry reason、retry limit、
queue pressure 和 terminal outcome。在此之前，M9–M11 单元/seam pass 只能证明 functional subset，不能证明
end-to-end loss recovery。

## 8. 论文结果晋级检查

任何 planned row 进入 `evaluation.tex` final 模式前，逐项确认：

- [ ] 同一 commit/run ID 下可定位 raw data、manifest 和生成脚本；
- [ ] measurement endpoint 与信号语义写清；
- [ ] model、synthesis、post-route、board-measured 标签正确；
- [ ] GPU SM cycles 与 NIC RTL cycles 未直接相减，均先换算为 ns；
- [ ] finite-batch 与 steady-state 不混用；
- [ ] deterministic 与 stochastic 统计口径正确；
- [ ] physical throughput 不由 interface width × clock 推导；
- [ ] resource 不由 logical bits 或 failed fit 外推；
- [ ] Fmax 不由 model period、target constraint 或 synthesis operating frequency替代；
- [ ] power estimate 与 physical measurement 分开；
- [ ] negative result 和 limitation 保留，不只报告最好点；
- [ ] Figure/Table caption 自包含地给出 payload、PMTU、QP、path、delay、run/seed 数。
