# OpenRDMA-flow RX

RX 使用 M4–M8 五个 unit，由 `integrations/rx/` 连接。各 unit 保留私有 RTL、TB 和测试，但从根级 `shared/` 引用唯一 Common/Tx/Rx 类型与公共 cocotb 基础设施。unit 可在仓库内独立构建，不再支持脱离仓库复制。

> 这是功能 MVP，不等于 400G production 实现。当前 RX 只解析 `WIRE_LEGACY_PRIVATE`，尚不支持实验性的 `WIRE_MRC_IPV4_ECMP_NO_ICRC`、ICRC/FCS、真实 PCIe posted-write drain、GPU cache 可见性、散页 GPU MR、Quartus P&R 或板级 FTile 联调。

## 目录结构

```text
OpenRDMA-flow/
├── shared/bsv/{common,tx,rx}/
├── shared/python/openrdma_flow_tb/rx/
├── m4_rx_packet_buffer/
├── m5_rx_packet_parser/
├── m6_rx_rq_bitmap/
├── m7_rx_dma_placement/
├── m8_rx_ordered_queue/
└── integrations/rx/       RxTop + current TX M2/M3 → RX loopback
```

每个 unit 的 `src/` 只保存模块私有 RTL，`tb/` 与 `cocotb/tests/` 保留本地；Makefile 通过 `shared/make/modules.mk` 和 `bsv-cocotb.mk` 获得路径与通用规则。

## 数据通路

```text
RxWireBeat[4]
  -> Packet Buffer（16 slot/lane，beat-addressed storage）
  -> Packet Parser（4 decoder，Ethernet/IPv4/UDP/BTH/RETH）
  -> RQ Bitmap Manager（4 QP × 16 PSN，atomic receive commit）
  -> DMA Placement（4 packet DMA lane）
  -> per-lane completion FIFO
  -> single Ordered Retire（globalSeq）
  -> DMA watermark / CQE / Ordered Flag Queue
```

| unit | production module | 已实现语义 |
|---|---|---|
| `m4_rx_packet_buffer` | `mkRxPortBuffer` ×4 / `mkRxPacketBuffer` | 四 lane 独立 frame buffer；slot generation；SOF/EOF、prefix BE、最大 4138B 检查；payload read 与显式 release |
| `m5_rx_packet_parser` | `mkRxFrameDecoder` ×4 / `mkRxPacketParser` | legacy Ethernet/IPv4/UDP/BTH/RETH；WRITE FIRST/MIDDLE/LAST/ONLY；AETH feedback；IPv4 checksum/长度/地址校验；ECN CE |
| `m6_rx_rq_bitmap` | `mkRxRqBitmapManager` | 4 QP × 16-entry bitmap；duplicate/window/PSN wrap；FIRST 前 pending continuation；MR/segment admission；ACK/SACK/NAK；`globalSeq` |
| `m7_rx_dma_placement` | `mkRxDmaLane` ×4 / `mkRxDmaPlacement` | descriptor handshake 后读取 payload；alignment；completion identity；跨 lane 按 `globalSeq` ordered retire |
| `m8_rx_ordered_queue` | `mkRxOrderedQueueManager` | 推进 `dmaAckPsn`；完整消息 CQE；per-QP Ordered Flag FIFO；MR/rkey/alignment/barrier 检查；absolute credit |

`integrations/rx/src/RxTop.bsv` 实例化五个 unit，并连接 Buffer → Parser → RQ → DMA → Ordered Queue，同时合并 release/error 流和 sticky fault。`integrations/rx/` 不持有 `CommonTypes.bsv`、`TxTypes.bsv` 或 `RxTypes.bsv` 副本。

## receive 与 DMA 双水位

- `RxFeedback.ackPsn`：最高连续、已完成 admission 和 receive bitmap commit 的 PSN；packet 接收后即可推进，不等待 DMA。
- `dmaAckPsn(qp)`：最高连续、对应记录已通过 `globalSeq` Ordered Retire 的 PSN；用于 Ordered Flag barrier。

`RxFeedback.sackBase = ackPsn + 1`，`sackBitmap[i]` 只表示 receive commit，不表示 DMA completion。duplicate 和 reject 不分配 `globalSeq`，也不产生 DMA。

Ordered Flag 仍通过 post-parser 语义入口 `RxOrderedFlagIngress` 注入。只有 `dmaAckPsn` 在 24-bit serial number 空间达到 `barrierPsn` 后，队首才能输出 `RxFlagDmaRequest`；外部 adapter 实际接受请求时才返回 absolute `RxOrderedCredit`。

## current TX 兼容边界

`integrations/rx/tb/TestTxRxLoopback.bsv` 直接引用同级 current TX：

```text
../../m2_packet_assembly/src/PacketAssembly.bsv
  -> ../../m3_mrc_tx_scheduler/src/MrcTxScheduler.bsv
  -> wire reinjection
  -> RxTop
```

loopback 显式设置 `WIRE_LEGACY_PRIVATE` 和 `MrcSourceProfileConfig.mrcMask=0`，并持续排空 `TxEgressEvent`。旧 `mvp/rx/upstream` 不再参与 active build；原快照和 2026-09-13 验证记录只保存在 `reference/rx-mvp-legacy/` 供追溯。

当前 legacy wire 使用 opcode `0x06/0x07/0x08/0x09`，FIRST/ONLY 带私有顺序 RETH。RX 尚不解析 current TX 的 `OP_MRC_WRITE_*`、METH、标准序 RETH 或 EV entropy profile。

## 共享唯一来源与 preflight

RX 相关唯一来源为：

- `shared/bsv/common/CommonTypes.bsv`；
- `shared/bsv/tx/TxTypes.bsv`；
- `shared/bsv/rx/RxTypes.bsv`；
- `shared/python/openrdma_flow_tb/rx/` 与 `openrdma_flow_tb.cocotb_bsv`。

根级 `make preflight` 检查 package 唯一性、禁止模块镜像、Python import origin、Retx manifest 和 legacy archive checksum。`integrations/rx` 不再维护 `cmp` 副本清单。

## 构建与测试

cocotb 2 需要显式解释器：

```bash
PYTHON=/home/mmhh/miniconda3/envs/cocotb2/bin/python

# 单个 unit
make -C m4_rx_packet_buffer test SIM=verilator PYTHON=$PYTHON
make -C m6_rx_rq_bitmap test-long SIM=icarus PYTHON=$PYTHON

# RX 全矩阵（在 OpenRDMA-flow 根目录执行）
make preflight
make compile-rx
make verilog-rx
make test-rx SIM=icarus PYTHON=$PYTHON
make test-rx SIM=verilator PYTHON=$PYTHON
make test-rx-long SIM=icarus PYTHON=$PYTHON
make production-rx-verilog
```

short matrix 包含 M4 6 例、M5 3 例、M6 8 例、M7 5 例、M8 9 例、RxTop 5 例和 current TX→RX loopback 1 例，共 37 例。long matrix 在 M6 增加固定 seed `0x52444D41` 的 reorder/lane-mix 场景，共 38 例。实际执行结果见 `RX_VALIDATION.md`。

## DMA adapter 契约

每个唯一 packet 输出一个 `RxDmaWriteRequest` 和若干连续 `RxDmaPayloadBeat`，输入一个回显 `globalSeq/lane/epoch` 的 `RxDmaCompletion`。adapter 可拆分内部 PCIe transaction，但 `success` 必须表示 payload 已达到 Ordered Flag 所需的 ordered placement completion point；不能把 descriptor 入队或普通 posted write 发出当作完成。

## 已知限制

- Packet Buffer 仍是 beat-addressed `RegFile` 功能存储，尚未替换为 banked BRAM/URAM primitive。
- RQ state owner 每次只提交一个 candidate，pending resolver 与 ingress 调度尚未优化到四 lane line-rate。
- 每个 DMA lane 只有一个 packet outstanding。
- ACK/SACK/NAK 目前是 NIC 内部事件，尚未编码成网络控制包。
- Ordered Queue 使用固定 cursor 的 per-QP round-robin。
- sticky fault 需要 reset 建立新 epoch；尚无在线 stop/drain/reconfigure。
- 尚未验证 Quartus P&R、真实 FTile/PCIe/GPU、ICRC/FCS、标准 RoCE/MRC 互操作、IOMMU/ATS 或形式验证。
