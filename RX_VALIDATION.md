# RX 扁平化迁移后验证记录

日期：2026-09-27。

## 验证范围

本记录描述迁移到 `OpenRDMA-flow/` 顶层的 RX active tree：

- 五个与 TX `m0`–`m3` 同级的自持 RX unit；
- `integrations/rx/src/RxTop.bsv`；
- current TX M2/M3 → RX legacy loopback；
- RX 共享 BSV/Python 副本门禁；
- `mkRxTop` production Verilog。

迁移前 2026-09-13 的 fixed-upstream 验证记录已归档到 `reference/rx-mvp-legacy/VALIDATION.md`，不能作为本树结果使用。

## 工具环境

- B-Lang BSC：2025.01.1（可执行文件位于 `/home/mmhh/bsc-2025.01.1-ubuntu-24.04/bin/bsc`）
- Icarus Verilog：12.0 stable
- Verilator：5.048
- Python：3.13.13（`/home/mmhh/miniconda3/envs/cocotb2/bin/python`）
- cocotb：2.1.0.dev0+ra1888346

## 结构与门禁

执行：

```bash
make -C OpenRDMA-flow preflight
make -C OpenRDMA-flow compile-rx \
    PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
make -C OpenRDMA-flow verilog-rx \
    PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
```

结果：通过。

`preflight` 已确认：

- RX M4–M8 的 `CommonTypes.bsv`、`TxTypes.bsv` 与 current TX M2 canonical copy 一致；
- current TX M2/M3 的上述共享 package 一致；
- 五份 `RxTypes.bsv` byte-identical；
- 本记录执行时，unit/集成目录中的 RX Python mirror、wire model、BFM helper 和 `cocotb_bsv` 副本一致；
- 2026-10-23 重构后，上述副本已收敛到 `shared/python/openrdma_flow_tb`，由 import-origin 门禁替代 `cmp`。

删除旧 `mvp/rx` 并去掉 `OpenRDMA-flow/rx` 中间层后，已再次执行 preflight、compile、verilog、两个 simulator short matrix、Icarus long 和 production elaboration；active Makefile、runner、BSV 和 Python 文件中未发现旧层级、`mvp/cocotb`、legacy `upstream` 或 reference archive 路径依赖。

历史 archive 的 snapshot manifest 也独立通过：

```bash
cd OpenRDMA-flow/reference/rx-mvp-legacy/upstream
sha256sum -c BASELINE.sha256
```

四个文件均为 `OK`；该结果只证明 archive 完整，不表示 active RX 使用旧 snapshot。

## Icarus short matrix

执行：

```bash
make -C OpenRDMA-flow test-rx SIM=icarus \
    PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
```

| target | PASS | FAIL | SKIP |
|---|---:|---:|---:|
| `m4` | 6 | 0 | 0 |
| `m5` | 3 | 0 | 0 |
| `m6` | 8 | 0 | 1（long-only） |
| `m7` | 5 | 0 | 0 |
| `m8` | 9 | 0 | 0 |
| `rx_top` | 5 | 0 | 0 |
| `tx_rx_loopback` | 1 | 0 | 0 |
| **合计** | **37** | **0** | **1** |

## Verilator short matrix

执行：

```bash
make -C OpenRDMA-flow test-rx SIM=verilator \
    PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
```

结果与 Icarus short 一致：**37 PASS，0 FAIL，1 个 RX M6 long-only SKIP**。

## Icarus long matrix

执行：

```bash
make -C OpenRDMA-flow test-rx-long SIM=icarus \
    PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
```

| target | PASS | FAIL | SKIP |
|---|---:|---:|---:|
| `m4` | 6 | 0 | 0 |
| `m5` | 3 | 0 | 0 |
| `m6` | 9 | 0 | 0 |
| `m7` | 5 | 0 | 0 |
| `m8` | 9 | 0 | 0 |
| `rx_top` | 5 | 0 | 0 |
| `tx_rx_loopback` | 1 | 0 | 0 |
| **合计** | **38** | **0** | **0** |

RX M6 的第 9 例使用固定 seed `0x52444D41`，覆盖 FIRST/MIDDLE/LAST reorder、lane mix 和连续 `globalSeq`。

## current TX M2/M3 防回归

loopback 已从旧 snapshot 切换到 current TX，因此额外执行：

```bash
make -C OpenRDMA-flow/m2_packet_assembly test SIM=verilator \
    PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
make -C OpenRDMA-flow/m3_mrc_tx_scheduler test SIM=verilator \
    PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
```

结果：

- current TX M2 short：9 PASS，0 FAIL；
- current TX M3 short：19 PASS，0 FAIL。

RX loopback 本身验证 current `MessageContext`、显式 `WIRE_LEGACY_PRIVATE`、`MrcSourceProfileConfig.mrcMask=0`、三个 `TxCommit`、三个 `TxEgressEvent`、三帧逆序重注入、逐 byte DMA payload 和最终 500-byte CQE；Icarus 与 Verilator 均通过。

## Production Verilog

执行：

```bash
make -C OpenRDMA-flow production-rx-verilog \
    PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python
```

结果：成功生成：

```text
OpenRDMA-flow/integrations/rx/build/production/verilog/mkRxTop.v
```

生成文件为 21,058 行；无 BSC compilation 或 elaboration error。

## 警告与既有问题

BSC 仍报告原 RX 实现已有的 rule urgency/action shadowing warning；Verilator 仍报告 BSC primitive 中的 width/case warning。上述 warning 未升级为 error，双 simulator 结果一致。

该记录中的 `CommonTypes.bsv (m0 vs m1) diverged` 是 2026-09-27 的历史状态，后续提交已经归一化。2026-10-23 重构进一步删除全部模块副本，当前权威为 `shared/bsv/common/CommonTypes.bsv`，根级 `make preflight` 验证 active package 唯一性。
