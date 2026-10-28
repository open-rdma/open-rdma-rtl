# integrations/e2e — 完整 TX-RX-Retx 数据链路

本目录把 `M2/M3`、`RxTop (M4–M8)`、`M9/M10/M11`、replay store 和 CPU 侧
`retx_runtime` 策略连接成一条可仿真的完整数据链路。它不同于 `integrations/retx`：
后者只验证 M9/M10/M11 的 seam，本目录才真正把重传插回 M3 主数据流。

```text
context/payload -> M2 -> TX tap -> M3 -> wire model -> RxTop (M4-M8)
                           ^                              |
                           |                       RX feedback tap
                     M11 -> bridge                       |
                           ^                          M9/M10
                           |                            |
                     replay store <-------- packet tap / sentEvent
```

## 组件

| 文件 | 作用 |
|---|---|
| `src/E2eTop.bsv` | 顶层：连接 M2、M3、RxTop、RetxTop 与四个 integration 局部模块 |
| `src/RetxWqeMonitor.bsv` | 旁路 MessageContext，向 M9 注册 WQE，并按 message 顺序返回 recordHandle |
| `src/RetxTxTap.bsv` | 逐 packet `packetReserve`、`sentEvent`，捕获 payload 到 replay store |
| `src/RetxReplayStore.bsv` | 64 slot × 32 × 128 B 的 packet payload snapshot；供 M11 fetch |
| `src/RxFeedbackTap.bsv` | 把 RX ACK/SACK/NAK 同时送入 M9 scoreboard 和 CPU 观测端口 |
| `src/RetxM3Bridge.bsv` | M11 内部 descriptor/beat → TX 公共类型，固定 `TRAFFIC_RETRY` |
| `cocotb/e2e_cpu.py` | CPU：codec + `retx_runtime` 的 report 摄取与 SACK-hole 重传决策 |

## 数据流

1. **正常路径**：`context/payload -> M2 -> M3 -> 四通道 frame -> RxTop -> DMA -> CQE`。
   TX tap 只观察和登记，不修改 first-traffic descriptor/payload。
2. **丢包发现**：wire model 丢弃一个 frame；RX 仍然接收后续 packet，M6 产生 SACK。
3. **CPU 监控**：RxFeedbackTap 把 feedback 送入 M9；CPU 取 snapshot，M10 生成
   ReportHeader + HoleEntry + Notification。
4. **重传决策**：CPU 用 `openrdma_flow.retx.codec` 校验 ABI，用 `retx_runtime` 的
   SACK-hole 阈值策略生成 `RetryEntry`，写回 NIC。
5. **重传执行**：M11 经 M9 admission，按 replayHandle 从 replay store 取回 payload，
   发出 `M3Desc/M3Beat`；bridge 将其送进 M3 的 `retryDescriptorIn/retryPayloadIn`。
6. **链路分配**：M3 在 packet 边界优先服务 retry，但每个 packet 一旦开始就完整发送；
   主 message 的 packet 序列不丢失、不乱序，retry 只占用一个 packet slot。
7. **恢复**：RX 收到重传 packet 后推进 cumulative ACK，ordered retire 放行，CPU 下一条
   report 的 hole 清零。

## 测试

```bash
make -C integrations/e2e test PYTHON=<cocotb2 python>
# 或从根目录
make test-e2e PYTHON=<cocotb2 python>
```

| 用例 | 内容 |
|---|---|
| `test_normal_tx_rx_path` | 无丢包：只走 TX→RX，CQE/DMA 数据正确，CPU report 无 hole、无 retry |
| `test_cpu_driven_retry_keeps_main_dataflow` | 丢 1 个 packet：CPU report→RetryEntry→M11→M3 retry→RX 恢复；断言 retry commit 严格落在主 message 首尾 commit 之间，两条 message 的 DMA/CQE 均正确 |

## 边界

- 丢包由测试侧 wire model 注入；ICRC/CRC 未实现，不能检测 payload 位翻转。
- M10 输出 report 的字段值（struct 端口）；host ABI 的字节序列化和 CRC 由 CPU 侧
  `openrdma_flow.retx.codec` 在事务边界完成，E2E 不对 NIC DMA 写 host ring 建模。
- M9 的 64 个 journal/record slot 在 ACK 后只产生 release 事件，尚未回收复用。
- M9 的 16-PSN window 由 CPU/RX feedback 推进；TX tap 在 reserve 被拒时 fail-stop，
  因此 E2E 场景保持 in-flight ≤16 packet。
- CPU runtime 最多管理 4 个 active QP context；单次 E2E 场景受上述 journal 数量限制。
- E2E 从 M2 接入 TX；M0/M1 前端由 `integrations/tx` 的 M0 chain 单独覆盖。
- 未实现：IPv6/SRv6、WriteImm、TSETH、on-wire SACK/NACK/Probe、MRC experimental profile
  在 RX 侧的解析。
