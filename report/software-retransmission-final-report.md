# OpenRDMA 软件协同重传 — 实现与联合测试报告

- 日期：2026-10-22
- 分支：`paper-ji`
- 状态：功能仿真 MVP（非生产部署版本）

## 1. 结论摘要

本次交付实现了软件协同重传的**功能仿真 MVP**：

- 冻结了 solution architecture 与 ABI v1：`_bmad-output/planning-artifacts/architecture/architecture-software-retransmission-2026-10-21/`
- 新增自持单元：`retx_contract`、`m9`、`m10`、`m11`、`retx_runtime`、`retx_integration`
- 新增联合顶层 `retx_integration/src/RetxTop.bsv`，把 m9 事实、m10 Report、m11 Retry 串成闭环
- 全部新增单元测试通过；m0–m8、TX integration、RX integration、TX→RX loopback 回归通过
- preflight 可在编译前拦截 RetxTypes/CommonTypes 漂移，篡改测试验证为 exit 2

## 2. 环境

| 项 | 版本 |
| --- | --- |
| Bluespec Compiler | 2025.01.1 build 65e3a87a |
| Verilator | 5.048 rev v5.048-56-gc233a3905 |
| Icarus Verilog | 12.0 stable（negative 约定） |
| Python | 3.13.13 |
| cocotb | 2.1.0.dev0+ra1888346 |

所有 cocotb 命令显式使用 `PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python`，默认 `SIM=verilator`。

## 3. 实现模块

| 模块 | 实现内容 |
| --- | --- |
| `retx_contract` | ABI v1 schema、确定性生成 BSV/Python codec、golden vectors、manifest；CRC-32/ISO-HDLC；Report/Retry/Result/Notification/Negotiation/RingCredit |
| `m9` | 4 QP × 16 PSN Scoreboard、WQE Record、packet journal、SACK/ACK 更新、immutable snapshot、Admission grant、release 事件 |
| `m10` | snapshot → Report header + hole entries、per-QP generation、Notification、On-demand echo |
| `m11` | Retry Entry → Admission Request、grant/deny、fetch request/beat → M3 descriptor/beat、ACCEPTED/SENT/terminal Result |
| `retx_runtime` | Report cache、post-hole SACK、NAK、Per-QP timeout、pending 去重、backoff、batch 组装 |
| `retx_integration` | `RetxTop` 连接 m9/m10/m11；preflight；联合闭环测试 |

## 4. 测试结果

### 4.1 新增单元

| 套件 | 结果 |
| --- | --- |
| `retx_contract` | 6 PASS / 0 FAIL |
| `m9` | 3 PASS / 0 FAIL |
| `m10` | 2 PASS / 0 FAIL |
| `m11` | 2 PASS / 0 FAIL |
| `retx_runtime` | 5 PASS / 0 FAIL |
| `retx_integration`（m9→m10→runtime→m11 闭环） | 1 PASS / 0 FAIL |
| preflight 篡改检测 | 注入 1 字节后 exit 2；恢复后 OK |

### 4.2 既有 m0–m8 与集成回归

| 套件 | 结果 |
| --- | --- |
| m0 | 10 PASS / 0 FAIL |
| m1 DMA | 13 PASS / 0 FAIL |
| m1 compactor | 2 PASS / 0 FAIL |
| m2 | 9 PASS / 0 FAIL |
| m3 | 19 PASS / 0 FAIL |
| m4 / m5 / m6 / m7 / m8 | 6 / 3 / 8 / 5 / 9 PASS，0 FAIL |
| rx_integration + TX→RX loopback | 5 + 1 PASS，0 FAIL |
| integration（DMA→M2→M3） | 5 PASS / 0 FAIL |
| integration（M0→frame 全链路） | 6 PASS / 0 FAIL |

> 为使 TX integration preflight 通过，按 architecture AD-2/AD-3 将 `m1/src/CommonTypes.bsv` 一次性归一化为 `m0/src/CommonTypes.bsv`（原差异为注释/空白）。

## 5. FR / Story 覆盖

| 范围 | 状态 |
| --- | --- |
| FR1 wire/RX 语义不变 | 既有回归通过；未新增独立 differential harness |
| FR2–FR6 Report/Scoreboard/Record/On-demand | m9/m10 功能子集 + 单测；缺失 overflow/reset 全矩阵 |
| FR7–FR10 CPU cache/policy/deadline/request | Python reference runtime + 单测 |
| FR11–FR14 Admission/fetch/Result | m11 功能子集 + 单测；CC/credit provider 为 mock seam |
| FR15 QP Epoch 隔离 | 类型与接口支持；reset 全流程未实现 |
| FR16 正常/恢复解耦 | m11 单请求模型；未做并发流量 stress |
| FR17–FR19 可观测/故障/resilience | ABI negotiation schema 已定义；运行时实现与故障矩阵未完成 |

## 6. 已知限制（必须如实告知）

1. **m10 输出的 Report header 未计算 CRC**；CRC 应在 abstract host transaction 边界由 codec 填充。当前联合测试以 `check_crc=False` 验证结构，未实现端到端 CRC 写入硬件。
2. **m9 为功能子集**：Record completion 按 `psnBase+packetCount-1` 判定，未实现逐 PSN remaining 精确计数、64-entry 容量满测试、snapshot 并发重试全矩阵。
3. **m11 一次只处理一个 active request**；未实现 8 context、Result ring 16 深、retry limit terminal、fetch ID ABA 全流程。
4. **retx_runtime 为 reference 实现**：不是生产 C/C++ 驱动；deadline/scan 预算为简化实现；Report hole metadata 由测试注入。
5. **未实现**：真实 PCIe DMA/MSI-X、cache coherence、production CC/credit/pacing、on-wire SACK/NACK、MRC RX、ICRC、IPv6、WriteImm、TSETH、CPU restart/NIC reset 全矩阵、trace/counter 全链路、独立 differential harness（Story 1.4）。
6. **未运行**：negative expected-fatal 新套件、long/random 新套件、Quartus/yosys 物理综合。

## 7. 建议下一步

1. 补齐 m10 CRC 与 abstract transaction writer，使 Report 字节端到端可由 host codec 直接接收。
2. 将 m9 Record completion 改为逐 PSN journal 计数，补容量/并发 ACK/reset 测试。
3. 扩展 m11 为 8 context、16-slot Result ring，并接入 m9 Admission 全检查顺序。
4. 实现 `retx_integration` 的 full-loop fault matrix（overflow、CPU restart、NIC reset、stale epoch）与 Story 1.4 differential harness。
5. 运行新单元 long/random 与 negative 套件，并把结果追加到本报告。
