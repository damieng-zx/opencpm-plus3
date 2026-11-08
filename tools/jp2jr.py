#!/usr/bin/env python3
"""Find (and optionally fix) JP instructions that could be JR.

JR is two bytes, JP three.  sjasmplus does not relax jumps, so this tool
reads the assembled listing (build/bios.lst) for real addresses, finds every
unconditional or Z/NZ/C/NC JP whose target is within JR range, and maps it
back to the .zpa source line.

    python3 tools/jp2jr.py            # report candidates
    python3 tools/jp2jr.py --check    # same, but exit 1 if there are any
    python3 tools/jp2jr.py --fix      # rewrite them in src/**/*.zpa

The build runs --check after assembling, so a JP that could be JR fails it.

Shrinking code only ever shortens other jumps, so after --fix rebuild and
run again until nothing is left.

Left alone:
  * the BIOS jump table (fn_* entries are a fixed-size ABI);
  * a JP whose own label is patched as `label + n` (self-modifying code);
  * common-memory code before `ccp_run_prog`, whose addresses are pinned
    for RAMDISK.FID and the CCP (see the asserts in common.zpa);
  * a line marked `; keep jp`.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LST = os.path.join(ROOT, 'build', 'bios.lst')
SOURCES = {
    'bios.asm': 'src/bios/bios.zpa',
    'common.asm': 'src/bios/common.zpa',
    'screen.asm': 'src/bios/screen.zpa',
    'screen5.asm': 'src/bios/screen5.zpa',
    'keyboard.asm': 'src/bios/keyboard.zpa',
    'fdc765.asm': 'src/bios/fdc765.zpa',
    'bdos.asm': 'src/bdos/bdos.zpa',
}
# First address in common memory that nothing outside the image pins.
PIN_LABEL = 'ccp_run_prog'

LINE_RX = re.compile(r'^\s*\d+\+*\s+([0-9A-F]{4})\s((?:[0-9A-F]{2} )+(?:\.\.\.)?)?\s*(.*)$')
GLOBAL_RX = re.compile(r'^([A-Za-z_]\w*):')
LABEL_RX = re.compile(r'^(\.?[A-Za-z_][\w.]*):')
JP_RX = re.compile(r'^jp\s+(?:(z|nz|c|nc)\s*,\s*)?([.A-Za-z_][\w.]*)\s*$', re.I)
PATCH_RX = re.compile(r'\(\s*([.A-Za-z_][\w.]*)\s*\+\s*\d+\s*\)')


def code_of(text):
    return text.split(';', 1)[0].strip()


def norm(text):
    return re.sub(r'\s+', '', text.lower())


def parse_listing():
    """Return (jps, labels).  jps: dicts with file/addr/glob/text/label."""
    labels = {}
    jps = []
    stack = []
    cur = '?'
    glob = None
    last_label = None
    for raw in open(LST, encoding='utf-8', errors='replace'):
        if raw.startswith('# file opened:'):
            stack.append(cur)
            cur = raw.split(':', 1)[1].strip()
            continue
        if raw.startswith('# file closed:'):
            cur = stack.pop() if stack else '?'
            continue
        m = LINE_RX.match(raw.rstrip('\n'))
        if not m:
            continue
        addr = int(m.group(1), 16)
        nbytes = len(m.group(2).replace('...', '').split()) if m.group(2) else 0
        code = code_of(m.group(3))
        lm = LABEL_RX.match(code)
        if lm:
            name = lm.group(1)
            if not name.startswith('.'):
                glob = name
            full = (glob or '') + name if name.startswith('.') else name
            labels[full] = addr
            last_label = full
            code = code[lm.end():].strip()
        if not code:
            continue
        jm = JP_RX.match(code)
        if jm and nbytes == 3:
            jps.append(dict(file=cur, addr=addr, glob=glob, text=norm(code),
                            cond=jm.group(1), target=jm.group(2),
                            label=last_label))
        last_label = None
    return jps, labels


def patched_labels():
    names = set()
    for path in SOURCES.values():
        for line in open(os.path.join(ROOT, path), encoding='utf-8'):
            for m in PATCH_RX.finditer(code_of(line)):
                names.add(m.group(1))
    return names


def candidates():
    jps, labels = parse_listing()
    patched = patched_labels()
    pin = labels.get(PIN_LABEL)
    out = []
    for j in jps:
        if j['file'] not in SOURCES:
            continue
        if j['glob'] and j['glob'].startswith('fn_'):
            continue
        if j['label'] and j['label'].split('.')[-1] in {p.split('.')[-1] for p in patched}:
            continue
        if j['file'] == 'common.asm' and pin is not None and j['addr'] < pin:
            continue
        t = j['target']
        full = (j['glob'] or '') + t if t.startswith('.') else t
        if full not in labels:
            continue
        disp = labels[full] - (j['addr'] + 2)
        if -128 <= disp <= 127:
            out.append(j)
    return out


def source_index(path):
    """Map (glob, normalised jp text, ordinal) -> line index in a .zpa file."""
    lines = open(os.path.join(ROOT, path), encoding='utf-8').read().split('\n')
    idx = {}
    count = {}
    glob = None
    for i, line in enumerate(lines):
        code = code_of(line)
        gm = GLOBAL_RX.match(code)
        if gm:
            glob = gm.group(1)
        lm = LABEL_RX.match(code)
        if lm:
            code = code[lm.end():].strip()
        if JP_RX.match(code):
            key = (glob, norm(code))
            n = count.get(key, 0)
            count[key] = n + 1
            idx[key + (n,)] = i
    return lines, idx


def ordinals(jps_all):
    seen = {}
    for j in jps_all:
        key = (j['file'], j['glob'], j['text'])
        j['ord'] = seen.get(key, 0)
        seen[key] = j['ord'] + 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--fix', action='store_true', help='rewrite the sources')
    ap.add_argument('--check', action='store_true',
                    help='exit 1 if any JP could be JR (build gate)')
    args = ap.parse_args()

    jps_all, _ = parse_listing()
    ordinals(jps_all)
    by_addr = {(j['file'], j['addr']): j for j in jps_all}
    cands = [by_addr[(c['file'], c['addr'])] for c in candidates()]

    files = {}
    fixed = 0
    unmapped = []
    for c in cands:
        path = SOURCES[c['file']]
        if path not in files:
            files[path] = source_index(path)
        lines, idx = files[path]
        i = idx.get((c['glob'], c['text'], c['ord']))
        if i is None or 'keep jp' in lines[i]:
            if i is None:
                unmapped.append(c)
            continue
        print(f"{path}:{i + 1}: {code_of(lines[i])}")
        if args.fix:
            lines[i] = re.sub(r'\bjp(\s)', r'jr\1', lines[i], count=1)
            fixed += 1
    for c in unmapped:
        print(f"unmapped: {c['file']} {c['glob']} @{c['addr']:04X} {c['text']}",
              file=sys.stderr)
    if args.fix:
        for path, (lines, _) in files.items():
            with open(os.path.join(ROOT, path), 'w', encoding='utf-8', newline='') as fh:
                fh.write('\n'.join(lines))
        print(f'jp2jr: rewrote {fixed} jump(s)')
        return 0
    print(f'jp2jr: {len(cands)} JP instruction(s) could be JR')
    if args.check and cands:
        print('jp2jr: run `python3 tools/jp2jr.py --fix`, rebuild, and repeat '
              'until clean (or mark a line `; keep jp`)')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
