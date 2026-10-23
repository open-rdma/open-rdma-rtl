<!-- bmad:context -->
<!-- Verified 2026-10-23. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## OpenRDMA-flow

RDMA 数据通路的模块化 BSV/cocotb 树：TX 为 M0–M3，RX 为 M4–M8，软件协同重传 MVP 为 M9–M11。模块在仓库内可独立构建，但公共类型、Python model/BFM、runner 和 Make 规则由根级 `shared/` 唯一提供，不能再把单个模块目录脱离仓库复制运行。

## Where things are

- M0–M11 的目录物理映射只维护在 `shared/make/modules.mk`；目录统一为 `m编号_职责名`，其中 M0 是 `m0_doorbell_analysis`。
- 公共 BSV：`shared/bsv/{common,tx,rx}`；Retx 生成 BSV：`shared/generated/retx/bsv`。
- 公共 cocotb：`shared/python/openrdma_flow_tb`；production Retx codec：`shared/generated/retx/python/openrdma_flow`。
- 跨模块连接：`integrations/tx`、`integrations/rx`、`integrations/retx`。
- Retx schema/generator/test：`shared/contracts/retx`；host reference policy：`retx_runtime`。
- `reference/rx-mvp-legacy/` 是只读归档，不得进入 BSC path、Python import 或 active 门禁。

## Running and verifying

- cocotb 必须显式传 `PYTHON=<cocotb 2 解释器>`；默认 `SIM=verilator`，negative 套件使用 Icarus。
- 改动前先跑 `make preflight`；它检查共享 package 唯一性、Python import origin、Retx manifest 和归档 checksum。
- 全量 short：`make test-all PYTHON=…`；long：`make test-long PYTHON=…`；negative：`make test-negative PYTHON=…`。
- 单模块示例：`make -C m2_packet_assembly test PYTHON=…`；集成示例：`make -C integrations/tx test PYTHON=…`。
- `make generate-retx` 是唯一允许更新 Retx 生成物的入口；普通 build 只校验，`make clean` 不删除生成物。

## Conventions that differ from defaults

- active tree 中 `CommonTypes`、`TxTypes`、`RxTypes`、`RetxTypes` 各只能有一个 package 定义；禁止恢复模块内镜像或依赖 `bsc -p` 顺序。
- Python 公共代码使用 `openrdma_flow_tb.*`，production Retx codec 使用 `openrdma_flow.retx.codec`；禁止测试自行注入 sibling 路径。
- 分片与 wire header 分离：M2 只产出语义 `PacketDescriptor` 与 payload，Ethernet/IPv4/UDP/BTH/RETH 只在 M3 `MrcHeaders.bsv` 生成。
- 默认 wire profile 是 `WIRE_LEGACY_PRIVATE`；`WIRE_MRC_IPV4_ECMP_NO_ICRC` 是 TX-only 实验路径。
- 物理目录变化必须先更新 `shared/make/modules.mk`，构建脚本和 Archify 不得重新散写 sibling 路径。

## Known pitfalls

- `TxCommit` 是 packet 进入 M3 per-channel buffer，不是上线或 ACK；`TxEgressEvent` 也不是 MAC 上线时刻或 RTT 起点。
- `integrations/retx` 当前只连接 M9/M10/M11 seam，尚未真实连接 M3、M6 或 Python runtime，不得称为完整重传闭环。
- Retx contract/runtime、M9–M11 与 Retx seam 的 long target 当前是显式 short alias，不代表新增 randomized long coverage。
- 未实现、不得声称合规：ICRC、IPv6/SRv6、WriteImm、TSETH、on-wire SACK/NACK/Probe，以及 RX 侧实验 wire 解析。

<!-- /bmad:context -->
