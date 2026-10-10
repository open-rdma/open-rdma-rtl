# RX MVP 历史归档

本目录保存迁移前 `open-rdma-design/mvp/rx` 的历史材料，仅用于追溯，不参与 `OpenRDMA-flow` 的 active build、BSC path、cocotb import 或验证门禁。

- `RX_README.md`：旧目录架构与固定 legacy TX snapshot 的说明。
- `VALIDATION.md`：2026-09-13 针对旧目录和旧 `upstream/` 的验证记录。
- `upstream/`：旧 `CommonTypes`、`TxTypes`、`PacketAssembly`、`MrcTxScheduler` 快照及 SHA-256 manifest。
- `agent/`：旧 RX 设计/实现/审阅角色材料，其中路径均按旧目录理解。
- `tb/TestRx.bsv`：未进入原 regression target matrix 的 compatibility elaboration wrapper。

当前实现是 `../../m4/` 至 `../../m8/` 五个顶层 RX unit 与 `../../rx_integration/`，详细说明见 `../../RX_README.md`。它使用 current TX M2/M3 的 `WIRE_LEGACY_PRIVATE` 路径；不要把本归档目录加入任何 Makefile 或 simulator search path。
