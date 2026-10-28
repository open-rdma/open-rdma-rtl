# FCCM Evaluation LaTeX 交付说明

本目录新增一套可独立编译、也可被主论文 `\input` 的英文 Evaluation 章节。正文保留
`reference/evaluation-preview.pdf` 中已有的数值和图，不运行新的 RTL、ns-3 或综合实验，也不填造
resource、Fmax、power、tail latency 等尚未取得的数据。

## 文件

| 文件 | 用途 |
|---|---|
| `evaluation.tex` | 英文正文，从 `\section{Evaluation}` 开始；不包含 document environment |
| `evaluation-standalone.tex` | `IEEEtran` conference 单栏独立 wrapper |
| `evaluation-standalone.pdf` | 由上述 wrapper 编译的 7 页单栏 final 预览 |
| `evaluation.bib` | 本章实际使用的最小 bibliography |
| `figures/eval-preview-fig*.pdf` | 从 preview 精确裁出的 vector 图 |
| `measurement-checklist.md` | `P-XMODEL`、`P-CYCLE`、`P-SUBMIT`、`P-SCALE`、`P-SYNTH` 补测协议 |
| `tx-throughput-diagnosis.md` | TX 从 201.88 Gb/s 到 400 Gb/s 的根因、RTL 修复、复测数据与 8-slot BDP 边界 |

已有的 `software-retransmission-final-report.md` 未被本次工作修改。仓库上层
`paper/sections/06_evaluation.tex` 和 `06_evaluation_2.tex` 中包含尚未实测的硬件平台、预测值和预期
结果，本次没有复用或修改这些内容。

## 编译

从本目录执行 final 版本：

```bash
latexmk -pdf -bibtex \
  -interaction=nonstopmode \
  -halt-on-error \
  -file-line-error \
  -outdir=../build/report-evaluation \
  evaluation-standalone.tex
```

展开 planned measurement 模板的 draft 版本：

```bash
latexmk -pdf -bibtex \
  -interaction=nonstopmode \
  -halt-on-error \
  -file-line-error \
  -jobname=evaluation-planned \
  -usepretex='\def\EVALDRAFT{1}' \
  -outdir=../build/report-evaluation \
  evaluation-standalone.tex
```

final PDF 不显示空数据表；只有 `EVALDRAFT` 的值严格为 `1` 时，draft PDF 才会显示
`PLANNED MEASUREMENT -- NO DATA`。未定义或定义为 `0` 都保持 final 模式。

## 接入主论文

主论文需要加载 `amsmath`、`graphicx`、`booktabs`、`array`、`multirow`、`float`、`cite` 和 `microtype`。若从
`open-rdma-design/` 根目录编译，可在 `\input` 前设置：

```latex
\newcommand{\EvalFigureRoot}{OpenRDMA-flow/report/figures}
\input{OpenRDMA-flow/report/evaluation}
```

正文不自行创建 bibliography。主论文的 `paper/bibliography/references.bib` 已包含
`mrc-srv6-paper`，因此不能把两个 `.bib` 不去重地同时交给 BibTeX（会触发 repeated entry）。接入时沿用
主 bibliography 中的该 key，只合入 `evaluation.bib` 中缺失的 CXL-over-Ethernet、ns-3、Verilator、
GPU-initiated communication 和 NVSHMEM 条目；或者先合并并按 citation key 去重。

如主论文希望查看 planned 模板，在 `\input` 前定义：

```latex
\def\EVALDRAFT{1}
\newcommand{\EvalPlanned}[1]{#1}
```

final 投稿版本不应定义该宏。

## Figure provenance

唯一源文件：`reference/evaluation-preview.pdf`

- SHA-256：`958f065edd52a99686a53a51086d36220db4ff2c4801434f3a16606f305b3802`
- 物理页数：7
- Page size：595.28 × 841.89 pt（A4）
- 裁剪流程：`pdfseparate` 提取单页，再用 `pdfcrop --bbox` 裁 plot artwork；不栅格化、不重绘、不从像素重新估数。

| 输出文件 | 源 PDF 页 | bbox（left bottom right top，pt） | SHA-256 |
|---|---:|---|---|
| `eval-preview-fig1-tx-latency.pdf` | 3 | `55 595 540 790` | `2ce67352fcb2d234ca227354feab0ba7c3ec4ec592e13b8ed5e7b080f5d2b6d5` |
| `eval-preview-fig2-tx-rate.pdf` | 3 | `55 350 540 545` | `147af56332b36ea6ba11ae04aa4fa6521931d20abab90b682da1852a5ec4fce4` |
| `eval-preview-fig3-path-policy.pdf` | 4 | `55 515 540 795` | `fa241c34bad08eca10c1ca92472303897ba5e1ad5313e33078f69ab2c07f8a87` |
| `eval-preview-fig4-rx-skew.pdf` | 5 | `55 595 540 795` | `2a026351e55f461780b50fce4cf5f935791c587947f2b9f484e816335d598163` |
| `eval-preview-fig5-ordered-completion.pdf` | 6 | `55 585 540 795` | `f6c95f3dab11859232332f579664ca21ccd5b4dc1ffc308d1ed02abcb8a52871` |

Caption 在 `evaluation.tex` 中重新排版，因此裁剪图不包含原 caption。

## Evidence ledger

| 类别 | 本章如何处理 | 可以声称 | 不可以声称 |
|---|---|---|---|
| Archived co-simulation | preview 中 TX Verilator + ns-3 + RX Verilator 的数值和图 | 指定 batch 下的 model-level timing、finite-batch rate、sampled boundary | 当前 checkout 可一键复现、steady-state NIC throughput |
| Active M0–M8 tree | 用当前 README/RTL 校准信号和模块语义 | 模块化 BSV implementation、abstract DMA/wire interfaces | 真实 PCIe/GPU/MAC、MRC RX、ICRC/FCS |
| M9–M11 Retx seam | 只映射到 planned closed-loop 工作 | 当前为 M9/M10/M11 functional seam | 已接 M3/M6/runtime、完整 loss recovery |
| Logical state | 重排 preview Table 3 | 列出结构的 315.73 KiB logical entry data | full design BRAM/ALM、placed resource savings |
| Code-derived submission cycles | 从 `TxMvp.bsv`、`DmaEngine.bsv` 的 rule/FIFO 串行路径推导 12/19 cycles | 该 RTL 组织、无 stall、一周期表查询下的结构性下界 | 实测 GPU/PCIe latency、post-route Fmax、完整端到端加速 |
| IBGDA comparison | 使用 arXiv:2610.01380 的 p50 测量作为外部锚点，按 2 GHz 换算 kSM cycles | 同一 H200/CX-7 平台上的 GPU-side issue/completion 量级 | 把 GPU SM cycles 与 NIC RTL cycles直接相减、声称同平台优劣势 |
| Historical M1 synthesis | 只记录排除理由，不进入正文结果表 | 曾有 standalone Analysis & Synthesis artifact | full-NIC resource、Fmax、timing closure |
| Planned measurements | 仅在 draft 和 checklist 中出现 | measurement protocol 已定义 | 任何结果值 |

### Code-derived submission cycle model

正文的 12/19-cycle 结果来自当前 active RTL 的串行 rule/FIFO 路径，而不是 cocotb 实测：

- M0：Slot、MR、QP、PGT 四组查询/join 加 burst split = 12 cycles；
- M0 adapter + context/chunk synchronizer = 3 cycles；
- M1 normalizer + scheduler + reorder installation = 3 cycles；
- exported DMA-request handshake = 1 cycle；
- 合计 = 19 cycles；
- 首 payload = `C_req + R + K + 3`；
- 完整 1-KiB chunk = `C_req + R + 2K + 2`，K=8 时为 `R+37`。

来源路径：`m0_doorbell_analysis/src/TxMvp.bsv`、`m0_doorbell_analysis/src/TxTables.bsv`、
`integrations/tx/src/M0MessageAdapter.bsv`、`integrations/tx/src/DmaPhaseAIntegration.bsv`、
`m1_dma_engine/src/DmaEngine.bsv`。模型假设 no stall、one-cycle register lookup、one completion beat
per cycle 和 downstream always-ready；target BRAM 可能增加 M0 周期，因此这是结构性下界。
不计入：GPU fence、credit CAS、8-B Doorbell store、PCIe transport、address/QPN extraction 与
Doorbell field decode（正文记为 `D_decode`）。

IBGDA 对比数据来自 `arXiv:2610.01380` 的 p50 测量：`mini-gda` issue 0.70 µs / put+completion 4.03 µs，
GDAKI 1.60/6.02 µs，NVSHMEM internal 4.26/9.18 µs，NVSHMEM public 5.31/11.10 µs；平台为
H200 + ConnectX-7 200-Gb/s IB。正文中的 kSM-cycle 列是按 2.0 GHz SM clock 的换算，不是原作者报告值。
这些是 GPU-side issue/completion，不是 NIC 内部 cycle；不能与 12/19 NIC cycles 直接相减。

### 外部 ns-3 artifact 边界

active tree 中没有找到 preview 所用的 ns-3 module、Unix-socket adapter、raw event archive 或 parser。
因此正文把它称为 `archived experiment batch`。要升级为可复现实验，至少需要归档：commit、tool version、
三进程命令、network config、raw request/frame/event trace、parser version、seed 和 aggregate manifest。

### 历史 M1 综合结果为何排除

`m1_dma_engine/build/quartus-synth/` 中的历史 artifact 给出 standalone Analysis & Synthesis estimate，
但 Fitter 因 2,812 pins / 1,096 available（257%）失败，也没有 TimeQuest/Fmax。它不能代表 M0–M11、
TX/RX integration 或完整 NIC，因此正文只要求未来补做受控 wrapper + SDC + Fitter + TimeQuest，
不引用该 artifact 的 ALM/register 数值。

### Test artifact 边界

散落的 JUnit XML 并非同一 commit、同一 run ID 的原子 full-tree run。JUnit 的 `sim_time` 和 wall time
包含 reset、配置、等待与多事务，不能当作 datapath latency。negative expected-fatal case 的 XML 会记录
failure，必须由外层 expected-fatal driver 判断预期结果，不能混入普通 PASS 计数。

## 写作边界

- `TxCommit`：packet 完整进入 M3 per-channel buffer；不是 MAC 上线、ACK 或 RTT 边界。
- `TxEgressEvent`：EOF word 从 channel buffer 被消费；仍不是 MAC 上线或远端接收。
- 2 ns 是 model cycle，不是 achieved FPGA clock。
- 12/19 cycles 是从当前 functional RTL 的串行 rule/FIFO 路径推导的下界；它们不是 cocotb 实测 latency，也不是 post-route timing。
- IBGDA 的 0.70/4.03/5.31/11.10 µs 是公开 p50 测量；kSM-cycle 列是按 2 GHz 假设换算，不能与 NIC cycles 直接相减。
- fixed-per-QP 是 implementation-level baseline，不是 commercial RNIC/RoCE baseline。
- Fig. 4 是 sampled pass/fail boundary，不是 receive capacity 公式。
- Ordered Queue retirement 是 injected RTL input，不是 GPU-memory completion。
- `WIRE_MRC_IPV4_ECMP_NO_ICRC` 仍是 TX-only 实验路径；SRv6、ICRC、MRC RX 未实现。
- final 版本不得出现 `TBD`、假数据、空曲线或未经测量的 application speedup。
