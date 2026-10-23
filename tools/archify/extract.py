import json, os, re, pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent

def find_flow_root(start):
    for candidate in (start, *start.parents):
        if (candidate / 'shared/make/modules.mk').is_file():
            return candidate
    raise RuntimeError('无法定位 OpenRDMA-flow 根目录')

FLOW = pathlib.Path(os.environ.get('OPENRDMA_FLOW_ROOT', find_flow_root(HERE)))
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else FLOW / '.archify/inventory.json'
registry = (FLOW / 'shared/make/modules.mk').read_text(encoding='utf-8')
module_names = [m.group(1).strip() for m in re.finditer(r'^M\d+_DIR_NAME := (.+)$', registry, re.M)]
source_dirs = [*(FLOW / name / 'src' for name in module_names),
               *(FLOW / 'integrations' / name / 'src' for name in ('tx', 'rx', 'retx')),
               FLOW / 'shared/bsv/common', FLOW / 'shared/bsv/tx', FLOW / 'shared/bsv/rx',
               FLOW / 'shared/generated/retx/bsv']
files = sorted(path for directory in source_dirs if directory.is_dir() for path in directory.glob('*.bsv'))
OUT.parent.mkdir(parents=True, exist_ok=True)
DERIV = r'(?:\s*deriving\s*\([^)]*\))?'
GENERIC = {'PipeIn', 'PipeOut', 'ServerP', 'ClientP'}
CONST, ALIAS, STRUCT, ENUMS = {}, {}, {}, {}

def nocmt(t):
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)
    return re.sub(r'//[^\n]*', '', t)

for p in files:
    t = nocmt(p.read_text(encoding='utf-8', errors='replace'))
    for m in re.finditer(r'typedef\s+(\d+)\s+(\w+)\s*;', t):
        CONST.setdefault(m.group(2), int(m.group(1)))
    for m in re.finditer(r'typedef\s+Bit#\((\d+)\)\s+(\w+)\s*;', t):
        ALIAS.setdefault(m.group(2), f'Bit#({m.group(1)})')
    for m in re.finditer(r'typedef\s+Bool\s+(\w+)\s*;', t):
        ALIAS.setdefault(m.group(1), 'Bool')
    for m in re.finditer(r'typedef\s+(UInt|Int)#\((\d+)\)\s+(\w+)\s*;', t):
        ALIAS.setdefault(m.group(3), f'{m.group(1)}#({m.group(2)})')
    for m in re.finditer(r'typedef\s+struct\s*\{(.*?)\}\s*(\w+)\s*' + DERIV + r'\s*;', t, re.S):
        STRUCT.setdefault(m.group(2), [
            (fm.group(2), fm.group(1).strip())
            for fm in re.finditer(r'([A-Za-z_][\w#()\[\], ]*?)\s+(\w+)\s*;', m.group(1))
            if not fm.group(1).strip().startswith('Vector')
        ])
    for m in re.finditer(r'typedef\s+enum\s*\{(.*?)\}\s*(\w+)\s*' + DERIV + r'\s*;', t, re.S):
        n = sum(1 for v in re.split(r',', re.sub(r'//.*', '', m.group(1))) if v.strip())
        ENUMS.setdefault(m.group(2), max(n, 1))

def width(t, seen=frozenset()):
    t = (t or '').strip()
    if not t: return None
    t = t.split('::')[-1].strip()                 # drop Pkg:: qualifier
    if t in GENERIC or t in seen: return None
    m = re.match(r'Bit#\((\d+)\)$', t)
    if m: return int(m.group(1))
    if t == 'Bool': return 1
    m = re.match(r'ActionValue$', t)
    if m: return 0
    m = re.match(r'(?:UInt|Int)#\((\d+)\)$', t)
    if m: return int(m.group(1))
    if t in ENUMS: return max(1, (ENUMS[t]-1).bit_length())
    if t in ALIAS: return width(ALIAS[t], seen | {t})
    if t in STRUCT:
        tot = 0
        for _, ft in STRUCT[t]:
            w = width(ft, seen | {t})
            if w is None: return None
            tot += w
        return tot or None
    return None

ARGS = r'\((.*)\)'
def arg_types(s):
    s = s.strip()
    if not s: return []
    tps = []
    for a in re.split(r',(?![^()]*\))', s):
        a = a.strip()
        m = re.match(r'(.+?)\s+\w+$', a)
        tps.append((m.group(1) if m else a).strip())
    return tps

defs = {}
for p in files:
    lines = p.read_text(encoding='utf-8', errors='replace').splitlines()
    i = 0
    while i < len(lines):
        if re.match(r'interface\s+\w+\s*(#\(.*?\))?\s*;\s*$', lines[i]):
            name = re.match(r'interface\s+(\w+)', lines[i]).group(1)
            mem, j = [], i + 1
            while j < len(lines) and 'endinterface' not in nocmt(lines[j]):
                mem.append((j + 1, lines[j])); j += 1
            defs.setdefault(name, {'file': str(p.relative_to(FLOW)), 'line': i + 1, 'members': []})
            for lineno, bl in mem:
                s = nocmt(bl).strip()
                if not s: continue
                mm = re.match(r'interface\s+([\w:]+#\(.+?\)|[\w:]+)\s+(\w+)\s*;\s*$', s)
                if mm and '=' not in s:
                    defs[name]['members'].append({'line': lineno, 'name': mm.group(2),
                                                  'raw': mm.group(1), 'kind': 'ifc'}); continue
                mm = re.match(r'method\s+ActionValue#\((.+?)\)\s+(\w+)\s*' + ARGS + r'\s*;', s)
                if mm:
                    defs[name]['members'].append({'line': lineno, 'name': mm.group(2), 'kind': 'av',
                                                  'raw': mm.group(1).strip(), 'args': arg_types(mm.group(3))}); continue
                mm = re.match(r'method\s+Action\s+(\w+)\s*' + ARGS + r'\s*;', s)
                if mm:
                    defs[name]['members'].append({'line': lineno, 'name': mm.group(1), 'kind': 'act',
                                                  'raw': '', 'args': arg_types(mm.group(2))}); continue
                mm = re.match(r'method\s+([\w#\(\)]+)\s+(\w+)\s*' + ARGS + r'\s*;', s)
                if mm:
                    defs[name]['members'].append({'line': lineno, 'name': mm.group(2), 'kind': 'ret',
                                                  'raw': mm.group(1).strip(), 'args': arg_types(mm.group(3))})
            i = j + 1
        else:
            i += 1

def resolve(m):
    raw = (m.get('raw') or '').strip()
    vec = 1
    vm = re.match(r'Vector#\(\s*(\w+)\s*,\s*(.+?)\)$', raw)
    if vm:
        c = vm.group(1)
        vec = int(c) if c.isdigit() else (CONST.get(c) or 1)
        raw = vm.group(2).strip()
    pm = re.match(r'(PipeIn|PipeOut)#\((.+)\)$', raw)
    if pm:
        kind, payload = pm.group(1), pm.group(2).strip()
        w = width(payload)
        return {'form': kind, 'lanes': vec, 'payload': payload, 'bits': w,
                'bus_bits': (w * vec if w is not None else None),
                'dir': 'IN' if kind == 'PipeIn' else 'OUT', 'args': []}
    sm = re.match(r'(ServerP|ClientP)#\((.+)\)$', raw)
    if sm:
        parts = [x.strip() for x in re.split(r',(?![^()]*\))', sm.group(2))]
        ws = [width(x) for x in parts]
        return {'form': sm.group(1), 'lanes': vec, 'payload': ' + '.join(parts),
                'bits': sum(x for x in ws if x), 'bus_bits': sum(x for x in ws if x),
                'dir': 'BIDIR', 'args': []}
    if m['kind'] == 'act':
        tps = m.get('args') or []
        ws = [width(x) for x in tps]
        return {'form': 'Action', 'lanes': vec, 'payload': ', '.join(tps) or '(void)',
                'bits': sum(x for x in ws if x), 'bus_bits': sum(x for x in ws if x),
                'dir': 'IN', 'args': tps}
    if m['kind'] == 'av':
        return {'form': 'ActionValue', 'lanes': vec, 'payload': raw,
                'bits': width(raw), 'bus_bits': width(raw), 'dir': 'OUT', 'args': m.get('args') or []}
    return {'form': 'method', 'lanes': vec, 'payload': raw, 'bits': width(raw),
            'bus_bits': width(raw), 'dir': 'OUT', 'args': m.get('args') or []}

mods = []
for name, d in sorted(defs.items()):
    if name in GENERIC: continue
    ms = [{k: v for k, v in {**mem, **resolve(mem)}.items() if k != 'kind'} for mem in d['members']]
    if not ms: continue
    mods.append({'interface': name, 'file': d['file'], 'line': d['line'], 'members': ms})

inv = {'types': {}, 'modules': mods}
for k in list(ALIAS) + list(STRUCT) + list(ENUMS):
    w = width(k)
    if w: inv['types'][k] = w
OUT.write_text(json.dumps(inv, ensure_ascii=False, indent=2))

print(f"interfaces={len(mods)}  members={sum(len(m['members']) for m in mods)}  named_types={len(inv['types'])}")
for mo in mods:
    bad = [m['name'] for m in mo['members'] if m['bits'] is None]
    flag = f"  UNRESOLVED={bad}" if bad else ""
    print(f"  {mo['interface']:30s} {mo['file']}:{mo['line']:<4d} members={len(mo['members']):3d}{flag}")
