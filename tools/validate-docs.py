from pathlib import Path
import collections, hashlib, re

# Markdown links and table shapes.
mds = [Path('SPEC.md'), *Path('docs').rglob('*.md'), Path('packages/sm83-lean/README.md')]
links = 0
for p in mds:
    text = p.read_text()
    for m in re.finditer(r'(?<!!)\[[^\]]+\]\(([^)]+)\)', text):
        dest = m.group(1).split('#', 1)[0]
        if not dest or '://' in dest or dest.startswith('mailto:'):
            continue
        links += 1
        assert (p.parent / dest).resolve().exists(), (p, dest)
sep = re.compile(r'^\s*\|(?:\s*:?-+:?\s*\|)+\s*$')
tables = 0
for p in mds:
    lines = p.read_text().splitlines()
    i = 0
    while i + 1 < len(lines):
        if lines[i].lstrip().startswith('|') and sep.match(lines[i + 1]):
            tables += 1
            cols = lines[i].count('|')
            j = i + 2
            while j < len(lines) and lines[j].lstrip().startswith('|'):
                assert lines[j].count('|') == cols, (p, j + 1)
                j += 1
            i = j
        else:
            i += 1

# Recorded source hashes.
memory = Path('docs/research/codebase-memory.md').read_text()
hashes = re.findall(r'^\| `([^`]+)` \| `([0-9a-f]{64})` \|$', memory, re.M)
for p, expected in hashes:
    assert hashlib.sha256(Path(p).read_bytes()).hexdigest() == expected, p

# Source cardinalities.
moves = sum(bool(re.match(r'\s*move\s', l)) for l in Path('pokered/data/moves/moves.asm').read_text().splitlines())
base = len(list(Path('pokered/data/pokemon/base_stats').glob('*.asm')))
includes = sum('INCLUDE "data/pokemon/base_stats/' in l for l in Path('pokered/data/pokemon/base_stats.asm').read_text().splitlines())
dex = sum(bool(re.match(r'\s*db\s+(?:DEX_\w+|0)\s*(?:;.*)?$', l)) for l in Path('pokered/data/pokemon/dex_order.asm').read_text().splitlines())
trainer_count = sum(bool(re.match(r'\s*move_choices(?:\s|$)', l)) for l in Path('pokered/data/trainers/move_choices.asm').read_text().splitlines())
effect_ids = sum(bool(re.match(r'\s*const(?:_skip)?(?:\s|$)', l)) for l in Path('pokered/constants/move_effect_constants.asm').read_text().splitlines())
effect_ptr_count = sum(bool(re.match(r'\s*dw\s+\w+', l)) for l in Path('pokered/data/moves/effects_pointers.asm').read_text().splitlines())
item_ptr_count = sum(bool(re.match(r'\s*dw\s+\w+', l)) for l in Path('pokered/engine/items/item_effects.asm').read_text().split('ItemUseBall:', 1)[0].splitlines())
assert (moves, base, includes, dex, trainer_count, effect_ids, effect_ptr_count, item_ptr_count) == (165, 151, 150, 190, 47, 87, 86, 83)

# Literal percent expressions and move accuracy expansion.
prob = Path('docs/reference/probability-thresholds.md').read_text()
literal = set()
for p in ['pokered/engine/battle/core.asm', 'pokered/engine/battle/effects.asm', 'pokered/engine/battle/trainer_ai.asm']:
    for m in re.finditer(r'\b\d+ percent(?:\s*[+-]\s*\d+)?', Path(p).read_text()):
        literal.add(re.sub(r'\s+', ' ', m.group()))
head = prob.split('## Move-record accuracy bytes', 1)[0]
prows = {m.group(1): int(m.group(2)) for m in re.finditer(r'\| `([^`]*percent[^`]*)` \| (\d+) \|', head)}
assert literal == set(prows)
for expr, expected in prows.items():
    m = re.fullmatch(r'(\d+) percent(?: ([+-]) (\d+))?', expr)
    actual = int(m.group(1)) * 255 // 100
    if m.group(2):
        actual += int(m.group(3)) * (1 if m.group(2) == '+' else -1)
    assert actual == expected, expr
accuracies = collections.Counter()
for line in Path('pokered/data/moves/moves.asm').read_text().splitlines():
    m = re.match(r'\s*move\s+\w+,\s*\w+,\s*\d+,\s*\w+,\s*(\d+),\s*\d+', line)
    if m:
        accuracies[int(m.group(1))] += 1
section = prob.split('## Move-record accuracy bytes', 1)[1].split('## Mechanics call sites', 1)[0]
doc_acc = {int(a): (int(b), int(c)) for a, b, c in re.findall(r'^\| (\d+) \| (\d+) \| (\d+) \|$', section, re.M)}
assert doc_acc == {n: (n * 255 // 100, count) for n, count in accuracies.items()}
assert sum(accuracies.values()) == 165

# Stat ratio rows.
ratios = []
for line in Path('pokered/data/battle/stat_modifiers.asm').read_text().splitlines():
    m = re.match(r'\s*db\s+(\d+),\s*(\d+)', line)
    if m:
        ratios.append((len(ratios) + 1, int(m.group(1)), int(m.group(2))))
stat_head = Path('docs/reference/stat-modifier-flow.md').read_text().split('| Effect |', 1)[0]
doc_ratios = [tuple(map(int, m)) for m in re.findall(r'^\| (\d+) \| (\d+) \| (\d+) \|$', stat_head, re.M)]
assert ratios == doc_ratios

# Trainer layers/action table.
layers = []
for line in Path('pokered/data/trainers/move_choices.asm').read_text().splitlines():
    m = re.match(r'\s*move_choices\s*([^;]*?)\s*;\s*(\w+)', line)
    if m:
        layers.append((m.group(2), tuple(int(x) for x in re.findall(r'\d+', m.group(1)))))
actions = []
for line in Path('pokered/data/trainers/ai_pointers.asm').read_text().splitlines():
    m = re.match(r'\s*dbw\s+(\d+),\s*(\w+)\s*;\s*(\w+)', line)
    if m:
        actions.append((m.group(3), int(m.group(1)), m.group(2)))
trainer_doc = []
for m in re.finditer(r'^\| `\$([0-9A-F]{2})` \| `(\w+)` \| ([^|]+?) \| (\d+) \| `(\w+)` \|$', Path('docs/reference/trainer-ai-dispatch.md').read_text(), re.M):
    raw = m.group(3).strip()
    ls = () if raw == '—' else tuple(int(x) for x in re.findall(r'\d+', raw))
    trainer_doc.append((int(m.group(1), 16), m.group(2), ls, int(m.group(4)), m.group(5)))
trainer_expected = []
for i, ((name, ls), (name2, count, routine)) in enumerate(zip(layers, actions), 1):
    assert name == name2
    trainer_expected.append((i, name, ls, count, routine))
assert trainer_doc == trainer_expected

# Item pointer table.
item_src = []
for line in Path('pokered/engine/items/item_effects.asm').read_text().split('ItemUseBall:', 1)[0].splitlines():
    m = re.match(r'\s*dw\s+(\w+)\s*;\s*(\w+)', line)
    if m:
        item_src.append((len(item_src) + 1, m.group(2), m.group(1)))
item_doc = []
for line in Path('docs/reference/item-dispatch.md').read_text().splitlines():
    fields = [x.strip() for x in line.split('|')]
    if len(fields) < 6:
        continue
    mid = re.fullmatch(r'`\$([0-9A-F]{2})`', fields[1])
    mptr = re.fullmatch(r'`(\w+)`', fields[3])
    mconst = re.search(r'`(\w+)`', fields[2])
    if mid and mptr and mconst:
        item_doc.append((int(mid.group(1), 16), mconst.group(1), mptr.group(1)))
assert item_src == item_doc

# Effect IDs/pointers.
effect_names = []
for line in Path('pokered/constants/move_effect_constants.asm').read_text().splitlines():
    m = re.match(r'\s*const\s+(\w+)', line)
    if m:
        effect_names.append(m.group(1))
    elif re.match(r'\s*const_skip(?:\s|$)', line):
        effect_names.append('unused')
effect_ptrs = []
for line in Path('pokered/data/moves/effects_pointers.asm').read_text().splitlines():
    m = re.match(r'\s*dw\s+(\w+)', line)
    if m:
        effect_ptrs.append(m.group(1))
effect_expected = [(i, n, '—' if i == 0 else effect_ptrs[i - 1]) for i, n in enumerate(effect_names)]
effect_doc = []
for line in Path('docs/reference/effect-dispatch.md').read_text().splitlines():
    fields = [x.strip() for x in line.split('|')]
    if len(fields) < 6:
        continue
    mid = re.fullmatch(r'`\$([0-9A-F]{2})`', fields[1])
    mptr = re.fullmatch(r'(?:`(\w+)`|(—))', fields[3])
    mname = re.fullmatch(r'(?:`(\w+)`|(unused))', fields[2])
    if mid and mptr and mname:
        effect_doc.append((int(mid.group(1), 16), mname.group(1) or mname.group(2), mptr.group(1) or mptr.group(2)))
assert effect_expected == effect_doc

# Six effect phase arrays.
phase_specs = {
    'ResidualEffects1': ('pokered/data/battle/residual_effects_1.asm', 'ResidualEffects1:'),
    'SpecialEffectsCont': ('pokered/data/battle/special_effects.asm', 'SpecialEffectsCont:'),
    'SetDamageEffects': ('pokered/data/battle/set_damage_effects.asm', 'SetDamageEffects:'),
    'ResidualEffects2': ('pokered/data/battle/residual_effects_2.asm', 'ResidualEffects2:'),
    'AlwaysHappenSideEffects': ('pokered/data/battle/always_happen_effects.asm', 'AlwaysHappenSideEffects:'),
    'SpecialEffects': ('pokered/data/battle/special_effects.asm', 'SpecialEffects:'),
}
effect_md = Path('docs/reference/effect-dispatch.md').read_text()
for name, (path, label) in phase_specs.items():
    source = []
    for line in Path(path).read_text().split(label, 1)[1].splitlines():
        m = re.match(r'\s*db\s+([A-Z0-9_]+|-1)', line)
        if not m:
            continue
        if m.group(1) == '-1':
            break
        source.append(m.group(1))
    m = re.search(rf'### `{name}`.*?```text\n(.*?)\n```', effect_md, re.S)
    assert m, name
    documented = [x.strip() for x in m.group(1).splitlines() if x.strip()]
    assert source == documented, name

print(f'PASS: {len(mds)} Markdown files, {links} local links, {tables} tables, {len(hashes)} hashes')
print('PASS: cardinalities, probabilities/move accuracy, stat ratios, trainer/item/effect dispatch, six effect arrays')
