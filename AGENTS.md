<!-- bmad:context -->
<!-- Verified 2026-10-12 against be588c8. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## OpenRDMA-flow

RDMA 数据通路的分模块自持树：TX 为 `m0`–`m3`（GDRP 提交 → DMA → 分片 → 四通道调度/封装），
RX 为 `m4`–`m8`（Packet Buffer → Parser → RQ bitmap → DMA Placement → Ordered Queue）。
RTL 用 Bluespec SystemVerilog（`bsc`），验证用 cocotb 2 + verilator/icarus。每个模块目录可单独
拷走使用；只有 `integration/`（TX）与 `rx_integration/`（RX）做跨模块连接。模块文档在
`README.md` / `RX_README.md`，验证记录在 `RX_VALIDATION.md`。

## Where things are

- TX 端到端与跨模块粘合：`integration/`；RX 端：`rx_integration/`。
- `integration/` 用 `bsc -p` 从 `../m0/src`…`../m3/src` 解析类型，必须与 `m0`–`m3` 同级目录才能编译。
- `reference/` 是不参与 active build 的归档（旧 RX MVP 快照、实验安排），不要在其中改 RTL 或跑测试。

## Running and verifying

- 跑 cocotb 套件必须显式传 `PYTHON=<cocotb 2 解释器>`（本机路径记录在 `RX_VALIDATION.md`）；默认 `python3` 不在该环境，会失败。
- 单模块/集成：`make -C mX test PYTHON=…`；默认 `SIM=verilator`，negative 套件只支持 `SIM=icarus`。
- `integration/` 和 `rx_integration/` 的 `compile`/`verilog`/`test` 会先跑 `preflight`（`cmp` 门禁）。

## Conventions that differ from defaults

- 共享类型包每个目录各持一份字节一致的副本（`CommonTypes.bsv`×4、`TxTypes.bsv`×3，RX unit 另持 `RxTypes.bsv` 与 python 镜像）：增改类型必须整树同步，只改一份会让 `bsc -p` 的包选择变成顺序相关、静默出错。
- 分片与 wire header 分离：M2 只产出 `PacketDescriptor`（PSN、每包 VA/rkey/MSN、packetIndex）与 payload beat，Ethernet/IPv4/UDP/BTH/RETH 全部在 `m3/src/MrcHeaders.bsv` 生成；不要在 M2 序列化头部。
- 默认 wire profile 是 `WIRE_LEGACY_PRIVATE`；`WIRE_MRC_IPV4_ECMP_NO_ICRC` 是实验路径，未与任何标准实现互操作。

## Known pitfalls

- `TxCommit`（packet 已进 per-channel buffer）不是上线、不是 ACK；`TxEgressEvent` 也不等于 MAC 上线时刻或 RTT 起点。
- 未实现、不要据此声称合规：ICRC、IPv6/SRv6、WriteImm、TSETH、on-wire SACK/NACK/Probe，以及 RX 侧对实验 wire 的解析。

<!-- /bmad:context -->
