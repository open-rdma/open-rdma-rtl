import json, html, os, pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent

def find_flow_root(start):
    for candidate in (start, *start.parents):
        if (candidate / 'shared/make/modules.mk').is_file():
            return candidate
    raise RuntimeError('无法定位 OpenRDMA-flow 根目录')

FLOW = find_flow_root(HERE)
INV_PATH = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else FLOW / '.archify/inventory.json'
OUT_HTML = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else FLOW / '.archify/ports.html'
OUT_HTML.parent.mkdir(parents=True, exist_ok=True)
INV = json.loads(INV_PATH.read_text(encoding='utf-8'))
BY_IFC = {m['interface']: dict(m) for m in INV['modules']}
ROWH, HEADER, PAD, GAP = 20, 44, 10, 14
FONT, TFONT, EFONT = 10, 9, 9.5

EXT = {
 'RX_EXT': ('Packet DMA / Flag DMA / Host',
            '外部消费者与 DMA 适配器',
            [('IN','dmaRequests','PipeIn','RxDmaWriteRequest'),
             ('IN','dmaPayloads','PipeIn','RxDmaPayloadBeat'),
             ('OUT','dmaCompletions','PipeOut','RxDmaCompletion'),
             ('IN','flagDmaRequest','PipeIn','RxFlagDmaRequest'),
             ('OUT','flagDmaResponse','PipeOut','RxFlagDmaResponse'),
             ('OUT','orderedFlagIn','PipeIn','RxOrderedFlagIngress'),
             ('IN','completion','PipeIn','RxCompletion'),
             ('IN','orderedCredit','PipeIn','RxOrderedCredit'),
             ('IN','feedback','PipeIn','RxFeedback'),
             ('IN','ecn','PipeIn','RxEcnEvent'),
             ('IN','txFeedback','PipeIn','RxTxFeedback'),
             ('IN','errors','PipeIn','RxError')]),
}

def esc(s): return html.escape(str(s), quote=True)
def w_of(t): return INV['types'].get(t.split('::')[-1])

def collect(ifc=None, spec=None, keep=None):
    if spec:
        rows = []
        for d, n, form, ty in spec:
            rows.append({'dir': d, 'name': n, 'form': form, 'payload': ty,
                         'bits': w_of(ty), 'lanes': 1})
    else:
        rows = [dict(p) for p in BY_IFC[ifc]['members']]
    if keep:
        rows = [r for r in rows if r['name'] in keep]
    return [r for r in rows if r['dir'] == 'IN'], [r for r in rows if r['dir'] == 'OUT']

def block(ifc, label, sub, x, top, width, spec=None, keep=None):
    ins, outs = collect(ifc, spec, keep)
    rows = ins + outs
    h = HEADER + max(len(rows), 1) * ROWH + PAD
    o = ['<g class="blk">',
         f'<rect x="{x}" y="{top}" width="{width}" height="{h}" rx="10"/>',
         f'<text class="bt" x="{x+13}" y="{top+19}">{esc(label)}</text>',
         f'<text class="bs" x="{x+13}" y="{top+33}">{esc(sub)}</text>',
         f'<line x1="{x}" y1="{top+HEADER-8}" x2="{x+width}" y2="{top+HEADER-8}" class="sep"/>']
    pos = {}
    for i, p in enumerate(rows):
        y = top + HEADER + i * ROWH + ROWH / 2
        n, t = p['name'], p['payload']
        if len(t) > 24: t = t[:23] + '\u2026'
        bits = f"{p['bits']}b" if p['bits'] is not None else '?'
        if p['lanes'] > 1: bits += f"\u00d7{p['lanes']}"
        left = p['dir'] == 'IN'
        pos[n] = ('L' if left else 'R', y)
        cx = x if left else x + width
        o.append(f'<circle cx="{cx}" cy="{y:.1f}" r="3" class="pin {"in" if left else "out"}"/>')
        o.append(f'<text class="pn" x="{x+11}" y="{y+3.4:.1f}">{esc(n)}</text>')
        o.append(f'<text class="pt" x="{x+width-11}" y="{y+3.4:.1f}" text-anchor="end">{esc(t)} <tspan class="pb">{esc(bits)}</tspan></text>')
    o.append('</g>')
    return '\n'.join(o), h, pos

def build(cols, edges, top=150):
    blocks, poss, hs = [], [], []
    for c in cols:
        b, h, pos = block(c.get('ifc'), c['label'], c['sub'], c['x'], top, c['width'],
                          c.get('spec'), c.get('keep'))
        blocks.append(b); hs.append(h); poss.append(pos)
    maxh = max(hs)
    maxlane = max([e.get('lane', 0) for e in edges] + [0])
    bus0 = top + maxh + 34
    paths, labels = [], []
    over_lane = [0]
    label_rects = []
    grp = {}
    for e in edges:
        si, sp, di, dp = e['si'], e['sp'], e['di'], e['dp']
        s_side, sy = poss[si][sp]
        d_side, dy = poss[di][dp]
        sl = cols[si]['x'] + (cols[si]['width'] if s_side == 'R' else 0)
        dl = cols[di]['x'] + (0 if d_side == 'L' else cols[di]['width'])
        cls = 'e ' + e.get('kind', 'fwd')
        if e.get('kind', 'fwd') == 'fwd' and (di - si > 1 or e.get('force_over')):
            lane = over_lane[0]; over_lane[0] += 1
            oy = top - 26 - lane * 18
            d = (f'M {sl} {sy:.1f} L {sl+16} {sy:.1f} L {sl+16} {oy:.1f} '
                 f'L {dl-16} {oy:.1f} L {dl-16} {dy:.1f} L {dl} {dy:.1f}')
            paths.append(f'<path class="e fwd" d="{d}"/>')
            if e.get('label'):
                lw = len(e['label']) * 5.8; lcx = (sl+16+dl-16)/2
                labels.append(f'<text class="el" x="{lcx:.1f}" y="{oy-5:.1f}" '
                              f'text-anchor="middle">{esc(e["label"])}</text>')
                label_rects.append((e['label'], lcx-lw/2, oy-14, lw, 13))
            continue
        if e.get('kind') == 'back':
            lane = e.get('lane', 0)
            by = bus0 + lane * 19
            ax = cols[di]['x'] - 22 - lane * 16
            d = (f'M {sl} {sy:.1f} L {sl+16} {sy:.1f} L {sl+16} {by:.1f} '
                 f'L {ax} {by:.1f} L {ax} {dy:.1f} L {dl} {dy:.1f}')
            lx, ly = (sl + 16 + ax) / 2, by - 5
        else:
            gx = (sl + dl) / 2
            d = f'M {sl} {sy:.1f} L {gx} {sy:.1f} L {gx} {dy:.1f} L {dl} {dy:.1f}'
            k = (si, di); n = grp.get(k, 0); grp[k] = n + 1
            lx, ly = gx, (sy + dy) / 2 - 5 + ((n % 3) - 1) * 13
        paths.append(f'<path class="{cls}" d="{d}"/>')
        if e.get('label'):
            lw = len(e['label']) * 5.8
            labels.append(f'<text class="el" x="{lx:.1f}" y="{ly:.1f}" text-anchor="middle">{esc(e["label"])}</text>')
            label_rects.append((e['label'], lx-lw/2, ly-9, lw, 13))
    rects = [(cols[i]['label'], cols[i]['x'], top, cols[i]['width'], hs[i]) for i in range(len(cols))]
    bad = []
    for (t, lx, ly, lw, lh) in label_rects:
        for (bn, bx, by, bw, bh) in rects:
            if lx < bx + bw and lx + lw > bx and ly < by + bh and ly + lh > by:
                bad.append((t, bn, round(lx), round(ly)))
    ll = []
    for i in range(len(label_rects)):
        for j in range(i + 1, len(label_rects)):
            a, b = label_rects[i], label_rects[j]
            if a[1] < b[1] + b[3] and a[1] + a[3] > b[1] and a[2] < b[2] + b[4] and a[2] + a[4] > b[2]:
                ll.append((a[0], b[0]))
    if bad:
        print('  LABEL/BOX COLLISIONS:')
        for b in sorted(set(bad)): print('   ', b)
    else:
        print('  label/box collisions: none')
    if ll:
        print('  LABEL/LABEL COLLISIONS:')
        for b in sorted(set(ll)): print('   ', b)
    else:
        print('  label/label collisions: none')
    W = max(c['x'] + c['width'] for c in cols) + 30
    H = bus0 + maxlane * 19 + 46
    svg = (f'<svg viewBox="0 0 {W:.0f} {H:.0f}" width="{W:.0f}" height="{H:.0f}" '
           f'xmlns="http://www.w3.org/2000/svg">' + '\n'.join(blocks) + '\n'
           + '\n'.join(paths) + '\n' + '\n'.join(labels) + '</svg>')
    return svg, W, H

# ------------------------------ RX ------------------------------
x, COLS = 30, []
def add(label, sub, w, ifc=None, keep=None, spec=None):
    global x
    COLS.append(dict(label=label, sub=sub, width=w, x=x, ifc=ifc, keep=keep, spec=spec)); x += w + 160

add('FTile / MAC RX', '外部线路侧', 170, None,
    spec=[('OUT','ports','PipeOut','RxWireBeat')])
add('M4 · RxPacketBuffer', 'm4_rx_packet_buffer/src/RxPacketBuffer.bsv:220', 260, 'RxPacketBufferIfc',
    keep=['ports','frames','readRequests','readResponses','releases','errors'])
add('M5 · RxPacketParser', 'm5_rx_packet_parser/src/RxPacketParser.bsv:237', 260, 'RxPacketParserIfc',
    keep=['frames','packets','feedbackOut','ecnOut','releases','errorOut'])
add('M6 · RxRqBitmapManager', 'm6_rx_rq_bitmap/src/RxRqBitmapManager.bsv:43', 260, 'RxRqBitmapManagerIfc',
    keep=['packets','admitted','releases','feedbackOut','errorOut'])
add('M7 · RxDmaPlacement', 'm7_rx_dma_placement/src/RxDmaPlacement.bsv:215', 270, 'RxDmaPlacementIfc',
    keep=['admitted','requests','payloads','completions','readRequests','readResponses','releases','retireOut','errors'])
add('M8 · RxOrderedQueueManager', 'm8_rx_ordered_queue/src/RxOrderedQueueManager.bsv:42', 270, 'RxOrderedQueueManagerIfc',
    keep=['retireIn','orderedFlagIn','flagRequestOut','flagResponseIn','creditOut','completionOut','errorOut'])
add(EXT['RX_EXT'][0], EXT['RX_EXT'][1], 285, spec=EXT['RX_EXT'][2])

E = [
 dict(si=0, sp='ports',       di=1, dp='ports',        label='ports 290b×4'),
 dict(si=1, sp='frames',      di=2, dp='frames',       label='frames 803b×4'),
 dict(si=2, sp='packets',     di=3, dp='packets',      label='packets 217b×4'),
 dict(si=3, sp='admitted',    di=4, dp='admitted',     label='admitted 291b×4'),
 dict(si=4, sp='retireOut',   di=5, dp='retireIn',     label='retireOut 190b'),
 dict(si=4, sp='requests',    di=6, dp='dmaRequests',  label='requests 207b×4'),
 dict(si=4, sp='payloads',    di=6, dp='dmaPayloads',  label='payloads 370b×4'),
 dict(si=6, sp='dmaCompletions', di=4, dp='completions', label='completions 83b×4', kind='back', lane=0),
 dict(si=5, sp='flagRequestOut', di=6, dp='flagDmaRequest', label='flagReq 224b'),
 dict(si=6, sp='flagDmaResponse', di=5, dp='flagResponseIn', label='flagResp 81b', kind='back', lane=1),
 dict(si=6, sp='orderedFlagIn',  di=5, dp='orderedFlagIn',   label='flagIn 176b', kind='back', lane=2),
 dict(si=4, sp='readRequests',  di=1, dp='readRequests',  label='readReq 22b×4', kind='back', lane=3),
 dict(si=1, sp='readResponses', di=4, dp='readResponses', label='readResp 535b×4', kind='back', lane=4),
 dict(si=2, sp='releases',      di=1, dp='releases',      label='releases 14b×4 (M5)', kind='back', lane=5),
 dict(si=3, sp='releases',      di=1, dp='releases',      label='releases 14b×4 (M6)', kind='back', lane=6),
 dict(si=4, sp='releases',      di=1, dp='releases',      label='releases 14b×4 (M7)', kind='back', lane=7),
 dict(si=5, sp='completionOut', di=6, dp='completion',    label='completion 74b'),
 dict(si=5, sp='creditOut',     di=6, dp='orderedCredit', label='credit 88b'),
 dict(si=2, sp='feedbackOut',   di=6, dp='txFeedback',    label='txFeedback 80b', kind='back', lane=8),
 dict(si=3, sp='feedbackOut',   di=6, dp='feedback',      label='feedback 169b', kind='back', lane=9),
 dict(si=2, sp='ecnOut',        di=6, dp='ecn',           label='ecn 52b', kind='back', lane=10),
 dict(si=5, sp='errorOut',      di=6, dp='errors',        label='error 53b (M8)', kind='back', lane=11),
 dict(si=2, sp='errorOut',      di=6, dp='errors',        label='error 53b (M5)', kind='back', lane=12),
]
rx_svg, rw, rh = build(COLS, E)


# ------------------------------ TX ------------------------------
x, TCOLS = 30, []
def tadd(label, sub, w, ifc=None, keep=None, spec=None):
    global x
    TCOLS.append(dict(label=label, sub=sub, width=w, x=x, ifc=ifc, keep=keep, spec=spec)); x += w + 145

tadd('GDRP / Host', '外部提交', 175, None,
     spec=[('OUT', 'submission', 'PipeOut', 'DecodedGdrpSubmission')])
tadd('M0 · TxMvp', 'm0_doorbell_analysis/src/TxMvp.bsv:330', 275, 'TxMvpIfc')
tadd('Integration · M0MessageAdapter', 'integrations/tx/src/M0MessageAdapter.bsv:31', 230, 'M0MessageAdapterIfc')
tadd('Integration · Context/Chunk Sync', 'integrations/tx/src/DmaPhaseAIntegration.bsv:33', 250,
     'ContextChunkSynchronizerIfc')
tadd('M1 · DmaEngine', 'm1_dma_engine/src/DmaEngine.bsv:741', 255, 'DmaEngineIfc')
tadd('M1 · DmaPayloadCompactor', 'm1_dma_engine/src/DmaPayloadCompactor.bsv:17', 245, 'DmaPayloadCompactorIfc')
tadd('M2 · PacketAssembly', 'm2_packet_assembly/src/PacketAssembly.bsv:213', 245, 'PacketAssemblyEngineIfc')
tadd('M3 · FourChannelTxScheduler', 'm3_mrc_tx_scheduler/src/MrcTxScheduler.bsv:324', 300, 'FourChannelTxSchedulerIfc')
tadd('Integration · Done/Commit Tracker', 'DmaPhaseAIntegration.bsv:222 / :255', 255, None,
     spec=[('IN',  'lifecycleIn',  'PipeIn',  'TxMessageLifecycle'),
           ('IN',  'expectedIn',   'PipeIn',  'DmaMessageDone'),
           ('IN',  'actualIn',     'PipeIn',  'DmaMessageDone'),
           ('OUT', 'checkedOut',   'PipeOut', 'DmaMessageDone'),
           ('IN',  'commitIn',     'PipeIn',  'TxCommit'),
           ('OUT', 'commitOut',    'PipeOut', 'TxCommit'),
           ('OUT', 'releaseOut',   'PipeOut', 'TxRequestId')])
tadd('外部接口 · Ethernet / DMA', '线路侧与 DMA 适配器', 245, None,
     spec=[('IN',  'channel0Out',    'PipeIn',  'EthPacket'),
           ('IN',  'channel1Out',    'PipeIn',  'EthPacket'),
           ('IN',  'channel2Out',    'PipeIn',  'EthPacket'),
           ('IN',  'channel3Out',    'PipeIn',  'EthPacket'),
           ('IN',  'dmaReadReqOut',  'PipeIn',  'DmaReadRequest'),
           ('OUT', 'dmaCompletionIn','PipeOut', 'DmaCompletionBeat')])

TE = [
 dict(si=0, sp='submission',      di=1, dp='submissionIn',  label='submissionIn 88b'),
 dict(si=1, sp='dmaReadReqOut',   di=2, dp='requestIn',     label='dmaReadReqOut 334b'),
 dict(si=2, sp='chunkOut',        di=3, dp='chunkIn',       label='chunkOut 130b'),
 dict(si=2, sp='contextOut',      di=3, dp='contextIn',     label='contextOut 272b'),
 dict(si=3, sp='chunkOut',        di=4, dp='chunkIn',       label='chunkOut 130b'),
 dict(si=3, sp='contextOut',      di=6, dp='contextIn',     label='contextOut 272b'),
 dict(si=4, sp='payloadOut',      di=5, dp='payloadIn',     label='payloadOut 1202b'),
 dict(si=5, sp='payloadOut',      di=6, dp='payloadIn',     label='payloadOut 1195b'),
 dict(si=6, sp='descriptorOut',   di=7, dp='firstDescriptorIn', label='descriptorOut 334b'),
 dict(si=6, sp='payloadOut',      di=7, dp='firstPayloadIn',    label='payloadOut 1194b'),
 dict(si=7, sp='channel0Out',     di=9, dp='channel0Out',   label='channel0Out 382b', kind='over'),
 dict(si=7, sp='channel1Out',     di=9, dp='channel1Out',   label='channel1Out 382b', kind='over'),
 dict(si=7, sp='channel2Out',     di=9, dp='channel2Out',   label='channel2Out 382b', kind='over'),
 dict(si=7, sp='channel3Out',     di=9, dp='channel3Out',   label='channel3Out 382b', kind='over'),
 dict(si=7, sp='txCommitOut',     di=8, dp='commitIn',      label='txCommitOut 85b'),
 dict(si=3, sp='lifecycleOut',    di=8, dp='lifecycleIn',   label='lifecycleOut 57b'),
 dict(si=4, sp='dmaReadReqOut',   di=9, dp='dmaReadReqOut', label='dmaReadReqOut 157b', kind='over'),
 dict(si=9, sp='dmaCompletionIn', di=4, dp='dmaCompletionIn', label='dmaCompletionIn 1233b', kind='back', lane=0),
 dict(si=8, sp='releaseOut',      di=3, dp='lifecycleReleaseIn', label='releaseOut 16b', kind='back', lane=1),
 dict(si=4, sp='messageDoneOut',  di=8, dp='actualIn',      label='messageDoneOut 65b', kind='back', lane=2),
 dict(si=8, sp='checkedOut',      di=9, dp='channel0Out',   label='checkedOut 65b', kind='back', lane=3),
]
# 'over' edges are forced onto the top bus regardless of distance
for e in TE:
    if e.get('kind') == 'over':
        e['kind'] = None; e.pop('kind')
tx_svg, tw, th = build(TCOLS, TE, top=210)

# ------------------------------ page ------------------------------
page = f'''<!DOCTYPE html><html lang="zh-CN" data-theme="dark"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>OpenRDMA-flow 接口全景图</title>
<style>
 html[data-theme=dark]{{--bg:#020617;--panel:rgba(7,27,43,.75);--bd:#1d3350;--tx:#e3f6ff;--soft:#a7cad9;--mut:#6f8fa3;--pin:#22d3ee;--po:#34d399;--edge:#4a9cbd;--back:#d97706}}
 html[data-theme=light]{{--bg:#f4f5f7;--panel:#fff;--bd:#e2e8f0;--tx:#0f172a;--soft:#475569;--mut:#7b8fa1;--pin:#0891b2;--po:#059669;--edge:#5f93a8;--back:#b45309}}
 *{{box-sizing:border-box}}body{{margin:0;padding:26px;background:var(--bg);color:var(--tx);
  font:13px/1.55 "JetBrains Mono",ui-monospace,Menlo,Consolas,"PingFang SC","Microsoft YaHei",monospace}}
 h1{{font-size:21px;margin:0 0 6px}} .lede{{color:var(--soft);margin:0 0 20px;max-width:110ch}}
 .card{{background:var(--panel);border:1px solid var(--bd);border-radius:14px;padding:15px 17px;margin-bottom:24px;overflow-x:auto}}
 h2{{font-size:15px;margin:0 0 4px}} .meta{{color:var(--mut);font-size:11.5px;margin:0 0 12px}}
 .meta code,.lede code{{background:rgba(127,127,127,.16);border-radius:4px;padding:1px 5px}}
 svg{{display:block}} rect{{fill:none}}
 .blk rect{{fill:var(--panel);stroke:var(--bd);stroke-width:1.4}} .blk .sep{{stroke:var(--bd);opacity:.55}}
 .bt{{fill:var(--tx);font-size:12px;font-weight:700}} .bs{{fill:var(--mut);font-size:9px}}
 .pn{{fill:var(--tx);font-size:{FONT}px}} .pt{{fill:var(--soft);font-size:{TFONT}px}} .pb{{fill:var(--pin);font-size:{TFONT}px}}
 .pin.in{{fill:var(--pin)}} .pin.out{{fill:var(--po)}}
 .e{{fill:none;stroke:var(--edge);stroke-width:1.6;stroke-linejoin:round}} .e.back{{stroke:var(--back);stroke-dasharray:5 3}}
 .el{{fill:var(--tx);font-size:{EFONT}px;paint-order:stroke;stroke:var(--panel);stroke-width:4px;stroke-linejoin:round}}
 .lg{{display:flex;gap:18px;color:var(--mut);font-size:11.5px;margin-top:10px;flex-wrap:wrap}}
 .sw{{display:inline-block;width:16px;height:3px;vertical-align:3px;margin-right:6px}}
</style></head><body>
<h1>OpenRDMA-flow 接口全景图</h1>
<p class="lede">按 BSV 源码逐接口生成。每个模块列出其接口声明中的<strong>全部</strong>端口：方向、负载类型与位宽。
<code>b</code> 为单路位宽，<code>×N</code> 为 <code>Vector#(N,…)</code> 路数，总线位宽为两者乘积。
连线取自模块接口与集成顶层 <code>mkConnection</code>。图形较宽，可在卡片内横向滚动。</p>
<div class="card"><h2>TX · M0–M3 发送路径接口</h2>
<p class="meta">模块端口见各 <code>*Ifc</code> 声明；seam 依据 integrations/tx/src/DmaPhaseAIntegration.bsv:341-354 与 integrations/tx/tb/TestM0Chain.bsv:59-61。</p>
{tx_svg}
<div class="lg"><span><span class="sw" style="background:var(--edge)"></span>前向连接</span>
<span><span class="sw" style="background:var(--back)"></span>回向连接（DMA completion / release / done）</span>
<span><span class="sw" style="background:var(--pin)"></span>输入端口</span>
<span><span class="sw" style="background:var(--po)"></span>输出端口</span></div></div>
<div class="card"><h2>RX · M4–M8 接收路径接口</h2>
<p class="meta">模块端口见各 <code>*Ifc</code> 声明；seam 连接依据 integrations/rx/src/RxTop.bsv:86-118。</p>
{rx_svg}
<div class="lg"><span><span class="sw" style="background:var(--edge)"></span>前向连接</span>
<span><span class="sw" style="background:var(--back)"></span>回向连接（读回环 / release / error / completion）</span>
<span><span class="sw" style="background:var(--pin)"></span>输入端口</span>
<span><span class="sw" style="background:var(--po)"></span>输出端口</span></div></div>
</body></html>'''
OUT_HTML.write_text(page, encoding='utf-8')
print('TX canvas', tw, 'x', th, '| RX canvas', rw, 'x', rh, '| page', len(page))
