# OpenRDMA-flow

OpenRDMA-flow 是 RDMA TX、RX 与软件协同重传的模块化 BSV/cocotb 树。每个模块仍可在仓库内独立构建，但公共类型和测试基础设施由根级 `shared/` 唯一提供，不再支持把单个模块目录脱离仓库复制运行。

```text
OpenRDMA-flow/
├── shared/                    公共 BSV、Python、Make、Retx contract/generated 与门禁
├── m0_doorbell_analysis/      TxMvp：GDRP submission、表查询、PGT 翻译、DMA chunk
├── m1_dma_engine/             DmaEngine + DmaPayloadCompactor
├── m2_packet_assembly/        message → PMTU packet descriptor + payload
├── m3_mrc_tx_scheduler/       四通道调度、EV 管理与 wire encapsulation
├── m4_rx_packet_buffer/       RX frame slot 与 payload storage
├── m5_rx_packet_parser/       legacy Ethernet/IPv4/UDP/BTH/RETH parser
├── m6_rx_rq_bitmap/           PSN window、bitmap、ACK/SACK/NAK
├── m7_rx_dma_placement/       packet DMA 与 ordered retire
├── m8_rx_ordered_queue/       DMA watermark、CQE、Ordered Flag
├── m9_retx_state_manager/     Retx Scoreboard、Record、snapshot、admission
├── m10_retx_report_engine/    Retx Report 与 notification
├── m11_retx_retry_engine/     Retry admission、fetch 与抽象 M3 seam
├── integrations/{tx,rx,retx,e2e}/
├── retx_runtime/              Python reference policy
├── tools/archify/             纳入版本控制的架构提取工具
└── reference/rx-mvp-legacy/   只读历史归档，不参与 active build
```

目录物理映射只维护在 `shared/make/modules.mk`。所有 module Makefile 复用 `shared/make/bsv-cocotb.mk` 和 `openrdma_flow_tb.sim.runner`。

## 运行测试

cocotb 必须显式指定安装了 Cocotb 2 的解释器；默认 `SIM=verilator`，negative 套件使用 Icarus。

| 套件 | 命令 | 内容 |
|---|---|---|
| 全树静态门禁 | `make preflight` | package 唯一性、Python import origin、Retx manifest、归档 checksum |
| 全部 short | `make test-all PYTHON=/path/to/python` | M0–M11、四套 integration、contract/runtime |
| 全部 long | `make test-long PYTHON=/path/to/python` | 全部已有 long；Retx contract/runtime/M9–M11/Retx seam 当前为显式 short alias |
| negative | `make test-negative PYTHON=/path/to/python` | M1 与 TX integration expected-fatal |
| 单模块 | `make -C m2_packet_assembly test PYTHON=...` | 模块独立入口 |
| TX integration | `make -C integrations/tx test` | DmaPhaseA + M0 chain |
| RX integration | `make -C integrations/rx test` | RxTop + TX→RX loopback |
| Retx seam | `make -C integrations/retx test` | M9/M10/M11 seam；保留为模块级 seam 测试 |
| 完整数据链路 | `make -C integrations/e2e test` | M2/M3 + M4–M8 + M9–M11 + replay store + CPU runtime 的重传闭环 |
| Retx contract | `make -C shared/contracts/retx test` | BSV/Python ABI golden |
| RX production | `make production-rx-verilog` | `mkRxTop` production Verilog |

## 两条 wire profile

M3 支持两条互不相同的报文路径，靠 `MessageContext.wireProfile` / `PacketDescriptor.wireProfile`
选择，M2 只负责分片和每包 placement 元数据，真正序列化头部的只有 M3：

| profile | 内容 | 状态 |
|---|---|---|
| `WIRE_LEGACY_PRIVATE` | 私有 Ethernet/IPv4/UDP/BTH，仅 First/Only 带私有序 RETH，固定 UDP source | 默认，`M0→M3` 链路与全部既有测试走这条 |
| `WIRE_MRC_IPV4_ECMP_NO_ICRC` | MRC normal Write `C6/C7/C8/CA`，每包带 METH 和标准序 `VA｜r_key｜dmalen` RETH，UDP source port 承载 ECMP entropy，Last/Only 设置 BTH.AR，含 0–3 字节 RDMA pad | 实验路径，尚未与任何标准实现互操作 |

M3 侧的 EV 控制面（`EvPathManager`）随 MRC profile 一起提供：4 个 profile × 8 个 EV entry、
`GOOD/SKIP/DENIED/ASSUMED_BAD` 状态、ECN/SKIP/ALWAYS_SKIP/timeout/probe 归一化反馈、
local/peer port 位图和 sideband `ProbeRequest`。traffic class → EV profile 的映射由
`MrcSourceProfileConfig` 配置，descriptor 自带的 `wireProfile/evProfileId` 必须与之匹配；M3 还会检查
profile、opcode/packet position、PMTU 分片和 message range（均用 assertion fail-stop）。

**本轮明确未实现**（不要据此声称互操作或合规）：RoCE **ICRC**、IPv6 Structured EV、SRv6、
WriteImm（`C9/CB` + ImmDt + RQMSN）、TSETH、on-wire 的 Reliability SACK/NACK/Probe/Port Status
报文、以及 RX 侧对新实验 wire 的解析。OCP 文档自身的 UDP dport 4791/4971 冲突未在本仓库裁决，
实验路径固定使用 4791。

## 两个完成点

| 信号 | 含义 |
|---|---|
| `TxCommit` | packet 已完整写入 M3 的 per-channel buffer（buffer admission），**不是**上线、不是 ACK |
| `TxEgressEvent` | 该 frame 的 EOF word 已从 channel buffer 取走（真实 EOF 握手），携带 EV profile/index/generation/entropy |

integration 的 request-ID 生命周期仍以 `TxCommit` 回收；`TxEgressEvent` 是纯可观测流，四个
通道的 BFM 与 integration TB 在后台持续排空它（它带反压）。它也不等于 MAC 上线时刻或 RTT 起点。

## 共享源码与生成契约

| 唯一来源 | 消费者 |
|---|---|
| `shared/bsv/common/CommonTypes.bsv` | M0–M11 与 integration |
| `shared/bsv/tx/TxTypes.bsv` | M1–M8、TX/RX integration |
| `shared/bsv/rx/RxTypes.bsv` | M4–M8、RX integration |
| `shared/generated/retx/bsv/RetxTypes.bsv` | M9–M11、Retx integration |
| `shared/python/openrdma_flow_tb/` | 全部 cocotb model/BFM/runner |
| `shared/generated/retx/python/openrdma_flow/retx/codec.py` | contract、M10、Retx integration、runtime |

`shared/contracts/retx/schema.py` 是 Retx ABI 手写权威。普通 build 只运行确定性 `--check`；只有 `make generate-retx` 更新提交入库的生成物。`make clean` 不删除生成契约。

`preflight` 不再比较副本，而是拒绝 active tree 中重新出现同名共享 package、Python mirror、旧目录或漂移生成物。`reference/rx-mvp-legacy/` 明确排除。

## 完整 TX-RX-Retx 数据链路

`integrations/e2e` 把三段数据路径接到一起：

```text
context/payload -> M2 -> TX tap -> M3 -> wire -> RxTop (M4-M8)
                           ^                      |
                           |                RX feedback tap
                     M11 -> bridge                 |
                           ^                    M9/M10
                           |                      |
                     replay store <---- packet tap
```

- 正常报文只走 `M2 -> M3 -> RxTop -> DMA/CQE`；`TxCommit`/`TxEgressEvent` 与单独
  TX integration 的含义一致。
- TX tap 在 M2 输出处向 M9 注册 WQE、逐 packet `packetReserve`、发 `sentEvent`，并把
  payload beat 写入 replay store。重传时 M11 从 replay store 取回同一 packet 的
  descriptor/payload，经 `TRAFFIC_RETRY` 入口交给 M3。
- RX feedback 同时驱动 M9 scoreboard 和 host 观测端口；CPU 通过
  `snapshot -> report/notification -> RetryEntry -> result` host ABI 参与决策。
- M3 的 retry 仲裁在 packet 边界插入重传，main first-traffic 的 packet 序列保持完整；
  E2E 测试会断言 retry commit 严格落在主 message 的首尾 commit 之间。

当前 E2E MVP 的边界：wire model 在测试侧注入 frame loss（ICRC/CRC 未实现，无法检测
payload 位翻转）；M9 的 64 个 journal slot 在 ACK 后只产生 release 事件、尚未回收复用；
CPU runtime 最多管理 4 个 active QP context；E2E 从 M2 接入 TX，M0/M1 前端的完整链路仍由
`integrations/tx` 的 M0 chain 单独覆盖。

## 交付边界

模块保持源码职责隔离和仓库内独立 `make -C`，但依赖同仓库 `shared/`。如需可搬运单模块包，应后续提供显式 export/bundle target，而不是恢复长期复制。

Retx 的 ABI、M9/M10/M11 功能子集和 `integrations/retx` seam 仍然保留；`integrations/e2e`
是当前唯一把 M2/M3、M4–M8、M9–M11、replay store 与 `retx_runtime` CPU 策略连成可执行
数据链路的入口。不要在 product 结论中把 E2E wire model 的丢包注入误称为 ICRC/CRC 检测。
