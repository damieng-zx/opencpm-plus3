#!/usr/bin/env python3
"""
zpa.py — Z80 Pinned-register Annotator

Processes .zpa (or .asm) files with ZPA annotations:
  - Parses @proc/@param/@var/@out/@clobbers/@end declaration blocks
  - Substitutes %varname with pinned registers throughout the proc body
  - Expands  call proc(%arg, ...)         into move instructions + call
  - Expands  call proc(%arg) → %out       with output capture
  - Type-checks arguments against callee param declarations
  - Cross-checks call sites across all source files
  - Detects overlapping register assignments in @param/@var (Feature 2)
  - Auto push/pop via 'preserving' clause (Feature 3)
  - Warns when callee clobbers a register holding an active %var (Feature 1+3)
  - Supports 'flag' type for variables in the F register (Feature 4)

Syntax
------

  Proc declaration (structured comment block, immediately before the label):

    ; @proc name
    ; @param %name:type  reg   — incoming parameter, pinned to register
    ; @var   %name:type  reg   — local variable, pinned to register
    ; @out   reg [reg…]        — return register(s) or flags
    ; @clobbers reg,…          — registers this proc clobbers (for callers)
    ; @end

  Extern declaration (proc body is raw Z80, not in this file):

    ; @extern name
    ; @param  %name:type  reg
    ; @out    hl
    ; @clobbers af,bc,de,hl
    ; @end

  Extended call:

    call procname(%arg1, %arg2)
    call procname(%arg1, %arg2) → %outvar
    call procname(%arg1) -> %outvar       (ASCII arrow also accepted)

  Auto push/pop (preserving clause):

    call procname(%arg1) preserving %var1, %var2

    Emits push/pop for each named %var whose register overlaps the callee's
    @clobbers set. Warns if an active %var is clobbered but not preserved.

  Variable reference (any non-comment operand position):

    ld a, %drive      →  ld a, b          (if %drive pinned to b)
    ld %pos, 0        →  ld bc, 0         (if %pos pinned to bc)
    inc %pos          →  inc bc

  Suppression:

    Add '; zpa: ignore' to a call line to suppress clobber warnings.

Types: u8 / i8 / flag  (8-bit)   u16 / i16  (16-bit)
       'flag' type is for variables pinned to the F register (carry, zero, etc.)
"""

import sys
import re
from pathlib import Path
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Register sets
# ---------------------------------------------------------------------------

REG8  = {'a', 'b', 'c', 'd', 'e', 'h', 'l', 'i', 'r',
          'ixh', 'ixl', 'iyh', 'iyl'}
REG16 = {'af', 'bc', 'de', 'hl', 'ix', 'iy', 'sp'}
FLAGS = {'carry', 'zero', 'sign', 'pv', 'pe', 'po', 'nc', 'nz', 'ns'}

def reg_width(reg: str) -> int:
    r = reg.lower()
    if r in REG8:  return 8
    if r in REG16: return 16
    return 0  # flags / unknown

def type_width(t: str) -> int:
    t = t.lower()
    if t in ('u8',  'i8', 'flag'):  return 8
    if t in ('u16', 'i16'):         return 16
    return 0

# ---------------------------------------------------------------------------
# Register overlap detection
# ---------------------------------------------------------------------------

REG_PARTS = {
    'a': frozenset({'a'}), 'b': frozenset({'b'}), 'c': frozenset({'c'}),
    'd': frozenset({'d'}), 'e': frozenset({'e'}), 'h': frozenset({'h'}),
    'l': frozenset({'l'}), 'f': frozenset({'f'}), 'i': frozenset({'i'}),
    'r': frozenset({'r'}), 'sp': frozenset({'sp'}),
    'ixh': frozenset({'ixh'}), 'ixl': frozenset({'ixl'}),
    'iyh': frozenset({'iyh'}), 'iyl': frozenset({'iyl'}),
    'af': frozenset({'a', 'f'}), 'bc': frozenset({'b', 'c'}),
    'de': frozenset({'d', 'e'}), 'hl': frozenset({'h', 'l'}),
    'ix': frozenset({'ixh', 'ixl'}), 'iy': frozenset({'iyh', 'iyl'}),
}

_PUSH_PAIR = {
    'a': 'af', 'f': 'af',
    'b': 'bc', 'c': 'bc',
    'd': 'de', 'e': 'de',
    'h': 'hl', 'l': 'hl',
    'ixh': 'ix', 'ixl': 'ix',
    'iyh': 'iy', 'iyl': 'iy',
}

_PUSH_ORDER = ['af', 'bc', 'de', 'hl', 'ix', 'iy']

def _reg_parts(reg: str) -> frozenset:
    return REG_PARTS.get(reg.lower(), frozenset())

def _regs_overlap(r1: str, r2: str) -> bool:
    return bool(_reg_parts(r1) & _reg_parts(r2))

def _push_pair_for(reg: str):
    r = reg.lower()
    if r in REG16:
        return r
    return _PUSH_PAIR.get(r)

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Var:
    name: str   # e.g. %fcb
    type: str   # u8 / u16
    reg:  str   # pinned register (lowercase)

@dataclass
class ProcDecl:
    name:     str
    extern:   bool = False
    params:   list = field(default_factory=list)   # list[Var]
    vars_:    list = field(default_factory=list)   # list[Var]
    out_regs: list = field(default_factory=list)   # e.g. ['hl', 'carry']
    clobbers: list = field(default_factory=list)   # e.g. ['af', 'bc', 'de', 'hl']
    source:   str  = ''
    line:     int  = 0

# ---------------------------------------------------------------------------
# Declaration parser
# ---------------------------------------------------------------------------

DECL_RE  = re.compile(r';\s*@(proc|extern|param|var|out|clobbers|end)\b(.*)', re.I)
VAR_RE   = re.compile(r'(%\w+)\s*:\s*(\w+)\s+(\w+)')

def _split_rest(rest: str) -> str:
    """Strip inline comment from @-directive argument string."""
    return rest.split(';')[0].strip()

def parse_var_line(rest: str) -> 'Var | None':
    m = VAR_RE.match(_split_rest(rest))
    if not m:
        return None
    return Var(m.group(1), m.group(2).lower(), m.group(3).lower())

def parse_proc_block(lines: list[tuple[int, str]], source: str) -> 'ProcDecl | None':
    """
    Parse a @proc…@end (or @extern…@end) comment block.
    lines: list of (lineno, text) — raw source lines for the block.
    Returns ProcDecl or None.
    """
    decl = None
    for lineno, text in lines:
        m = DECL_RE.match(text.strip())
        if not m:
            continue
        directive = m.group(1).lower()
        rest      = m.group(2)

        if directive == 'proc':
            name = _split_rest(rest).split()[0] if _split_rest(rest) else ''
            decl = ProcDecl(name=name, extern=False, source=source, line=lineno)
        elif directive == 'extern':
            name = _split_rest(rest).split()[0] if _split_rest(rest) else ''
            decl = ProcDecl(name=name, extern=True, source=source, line=lineno)
        elif decl is None:
            continue
        elif directive == 'param':
            v = parse_var_line(rest)
            if v:
                decl.params.append(v)
        elif directive == 'var':
            v = parse_var_line(rest)
            if v:
                decl.vars_.append(v)
        elif directive == 'out':
            decl.out_regs += [
                r.strip().rstrip(',').lower()
                for r in _split_rest(rest).split()
                if r.strip().rstrip(',')
            ]
        elif directive == 'clobbers':
            decl.clobbers += [
                r.strip().rstrip(',').lower()
                for r in _split_rest(rest).split()
                if r.strip().rstrip(',')
            ]
        elif directive == 'end':
            return decl
    return decl  # unterminated block — return anyway

# ---------------------------------------------------------------------------
# Cross-pair move emitter
# ---------------------------------------------------------------------------

# Explicit 16-bit register-pair copies (no direct Z80 instruction exists)
_PAIR_MOVES: dict[tuple[str,str], list[str]] = {
    ('hl', 'bc'): ['ld h, b', 'ld l, c'],
    ('hl', 'de'): ['ld h, d', 'ld l, e'],
    ('de', 'hl'): ['ld d, h', 'ld e, l'],
    ('de', 'bc'): ['ld d, b', 'ld e, c'],
    ('bc', 'hl'): ['ld b, h', 'ld c, l'],
    ('bc', 'de'): ['ld b, d', 'ld c, e'],
}

def emit_move(dst: str, src: str, indent: str,
              source: str, lineno: int) -> list[str]:
    """
    Emit Z80 instruction(s) to copy src → dst.
    Returns a (possibly empty) list of assembly lines.
    """
    d, s = dst.lower(), src.lower()
    if d == s:
        return []  # already in the right place — no-op

    dw, sw = reg_width(d), reg_width(s)

    if dw == 8 and sw == 8:
        return [f"{indent}ld {d}, {s}"]

    if dw == 16 and sw == 16:
        key = (d, s)
        if key in _PAIR_MOVES:
            return [f"{indent}{ins}" for ins in _PAIR_MOVES[key]]
        # fallback for ix/iy / af / sp moves
        return [f"{indent}push {s}", f"{indent}pop {d}"]

    _error(source, lineno,
           f"incompatible move: {s} ({sw}-bit) → {d} ({dw}-bit)")
    return [f"{indent}; ZPA ERROR: cannot move {s} → {d}"]

# ---------------------------------------------------------------------------
# Call expander
# ---------------------------------------------------------------------------

# call procname(arg, …)  [→ %var | -> %var]
_CALL_ZPA = re.compile(
    r'^(\s*)call\s+(\w+)\s*\(([^)]*)\)\s*'
    r'(?:[→\-]>?\s*(%\w+))?\s*'
    r'(?:preserving\s+(.+?))?\s*'
    r'(?:;.*)?$'
)

def expand_call(line: str,
                var_map: dict,
                proc_db: dict,
                source: str, lineno: int) -> 'list[str] | None':
    """
    Expand an extended call line.  Returns list of output lines, or None if
    this line is not an extended call.

    Supports: call procname(args) [→ %outvar] [preserving %var1, %var2]
    The preserving clause auto-generates push/pop around the call for any
    named %var whose register overlaps the callee's @clobbers set.
    """
    m = _CALL_ZPA.match(line)
    if not m:
        return None

    indent   = m.group(1)
    procname = m.group(2)
    args_raw = m.group(3).strip()
    out_var  = m.group(4)
    pres_raw = m.group(5)

    # ── Resolve callee ──────────────────────────────────────────────────────
    if procname not in proc_db:
        _error(source, lineno,
               f"call to unknown proc '{procname}' — add @proc or @extern block")
        return [line]

    callee = proc_db[procname]
    args   = [a.strip() for a in args_raw.split(',') if a.strip()] \
             if args_raw else []

    if len(args) != len(callee.params):
        _error(source, lineno,
               f"call {procname}: {len(args)} arg(s) given, "
               f"{len(callee.params)} declared")
        return [line]

    # ── Build effective clobber set (expanded to sub-registers) ──────────────
    callee_clobbers = set()
    for cr in callee.clobbers:
        callee_clobbers.update(_reg_parts(cr))

    # ── Parse preserving clause ─────────────────────────────────────────────
    preserve_vars: list[str] = []
    if pres_raw:
        for p in pres_raw.split(','):
            p = p.strip()
            if p.startswith('%'):
                if p not in var_map:
                    _error(source, lineno,
                           f"undeclared variable '{p}' in preserving clause")
                else:
                    preserve_vars.append(p)

    # Determine register pairs to push/pop
    pairs_to_push: set[str] = set()
    for pv in preserve_vars:
        _, pv_reg = var_map[pv]
        pv_parts = _reg_parts(pv_reg)
        if pv_parts & callee_clobbers:
            pair = _push_pair_for(pv_reg)
            if pair:
                pairs_to_push.add(pair)

    # ── Check output/preserve conflict ──────────────────────────────────────
    if out_var and out_var in var_map:
        _, out_reg = var_map[out_var]
        ret_reg = next((r for r in callee.out_regs if r not in FLAGS), None)
        if ret_reg:
            for pv in preserve_vars:
                if pv not in var_map:
                    continue
                _, pv_reg = var_map[pv]
                if _regs_overlap(out_reg, pv_reg):
                    _error(source, lineno,
                           f"call {procname}: output → {out_var} "
                           f"({out_reg}) conflicts with preserving "
                           f"{pv} ({pv_reg})")

    # ── Warn about clobbered active vars not in preserving clause ───────────
    if var_map and 'zpa: ignore' not in line.lower():
        for vname, (vtype, vreg) in var_map.items():
            if vname in preserve_vars:
                continue
            if vname == out_var:
                continue
            if _reg_parts(vreg) & callee_clobbers:
                _warn(source, lineno,
                      f"call {procname} clobbers {vreg} where {vname} lives "
                      f"— add 'preserving {vname}' to save/restore")

    # ── Build annotation ────────────────────────────────────────────────────
    annot = f"call {procname}({args_raw})"
    if preserve_vars:
        annot += f" preserving {', '.join(preserve_vars)}"
    out_lines = [f"{indent}; {annot}"]

    # ── Emit pushes ─────────────────────────────────────────────────────────
    push_order = [p for p in _PUSH_ORDER if p in pairs_to_push]
    for pair in push_order:
        out_lines.append(f"{indent}push {pair}")

    # ── Marshal each argument ───────────────────────────────────────────────
    for arg, param in zip(args, callee.params):
        if arg.startswith('%'):
            if arg not in var_map:
                _error(source, lineno, f"undeclared variable '{arg}'")
                out_lines.append(f"{indent}; ZPA ERROR: undeclared {arg}")
                continue
            arg_type, arg_reg = var_map[arg]
        else:
            arg_reg  = arg.lower()
            w        = reg_width(arg_reg)
            arg_type = 'u16' if w == 16 else 'u8'

        at, pt = type_width(arg_type), type_width(param.type)
        if at and pt and at != pt:
            _error(source, lineno,
                   f"call {procname}: arg '{arg}' is {arg_type} but "
                   f"param '{param.name}' expects {param.type}")

        out_lines.extend(emit_move(param.reg, arg_reg, indent, source, lineno))

    out_lines.append(f"{indent}call {procname}")

    # ── Capture output variable ─────────────────────────────────────────────
    if out_var:
        if out_var not in var_map:
            _error(source, lineno, f"undeclared output variable '{out_var}'")
        else:
            out_type, out_reg = var_map[out_var]
            ret_reg = next((r for r in callee.out_regs if r not in FLAGS), None)
            if ret_reg:
                out_lines.extend(
                    emit_move(out_reg, ret_reg, indent, source, lineno))
            else:
                _error(source, lineno,
                       f"call {procname}: '→ {out_var}' used but proc has "
                       f"no register in @out")

    # ── Emit pops (reverse order) ───────────────────────────────────────────
    for pair in reversed(push_order):
        out_lines.append(f"{indent}pop {pair}")

    return out_lines

# ---------------------------------------------------------------------------
# Variable substitution
# ---------------------------------------------------------------------------

_VARREF = re.compile(r'%\w+')

def substitute_vars(text: str, var_map: dict,
                    source: str, lineno: int) -> str:
    """Replace every %varname in text with its pinned register."""
    def _rep(m: re.Match) -> str:
        name = m.group(0)
        if name not in var_map:
            _error(source, lineno, f"undeclared variable '{name}'")
            return name
        return var_map[name][1]   # the register string
    return _VARREF.sub(_rep, text)

# ---------------------------------------------------------------------------
# Error tracking
# ---------------------------------------------------------------------------

_errors: list[str] = []
_warnings: list[str] = []

def _error(source: str, lineno: int, msg: str) -> None:
    entry = f"{source}:{lineno}: ERROR: {msg}"
    _errors.append(entry)
    print(entry, file=sys.stderr)

def _warn(source: str, lineno: int, msg: str) -> None:
    entry = f"{source}:{lineno}: WARNING: {msg}"
    _warnings.append(entry)
    print(entry, file=sys.stderr)

def _check_var_conflicts(decl: 'ProcDecl') -> None:
    all_vars = decl.params + decl.vars_
    for i in range(len(all_vars)):
        for j in range(i + 1, len(all_vars)):
            v1, v2 = all_vars[i], all_vars[j]
            if _regs_overlap(v1.reg, v2.reg):
                overlap = _reg_parts(v1.reg) & _reg_parts(v2.reg)
                _error(decl.source, decl.line,
                       f"@proc {decl.name}: {v1.name} ({v1.reg}) and "
                       f"{v2.name} ({v2.reg}) share register(s) "
                       f"{', '.join(sorted(overlap))}")

# ---------------------------------------------------------------------------
# First pass — collect all proc declarations
# ---------------------------------------------------------------------------

def scan_procs(paths: list[Path]) -> dict[str, ProcDecl]:
    """
    Scan every source file for @proc/@extern…@end blocks.
    Returns a dict of proc_name → ProcDecl.
    """
    db: dict[str, ProcDecl] = {}
    for path in paths:
        text  = path.read_text(encoding='utf-8')
        lines = list(enumerate(text.splitlines(), 1))
        i = 0
        while i < len(lines):
            lineno, raw = lines[i]
            m = DECL_RE.match(raw.strip())
            if m and m.group(1).lower() in ('proc', 'extern'):
                # Collect lines until @end
                block: list[tuple[int, str]] = []
                j = i
                while j < len(lines):
                    block.append(lines[j])
                    dm = DECL_RE.match(lines[j][1].strip())
                    if dm and dm.group(1).lower() == 'end':
                        break
                    j += 1
                decl = parse_proc_block(block, str(path))
                if decl and decl.name:
                    if decl.name in db:
                        prev = db[decl.name]
                        is_redecl = prev.extern == decl.extern
                        if is_redecl:
                            print(
                                f"WARNING: '{decl.name}' declared in both "
                                f"{prev.source}:{prev.line} and "
                                f"{path}:{lineno}",
                                file=sys.stderr)
                    # Real proc (@proc) wins over forward decl (@extern)
                    if decl.name not in db or not decl.extern:
                        db[decl.name] = decl
                        _check_var_conflicts(decl)
                i = j + 1
            else:
                i += 1
    return db

# ---------------------------------------------------------------------------
# Second pass — process a single file
# ---------------------------------------------------------------------------

def process_file(path: Path, proc_db: dict[str, ProcDecl]) -> list[str]:
    """
    Process one source file.  Returns list of output lines (no trailing \\n).
    """
    source = str(path)
    lines  = list(enumerate(path.read_text(encoding='utf-8').splitlines(), 1))

    output:  list[str]             = []
    var_map: dict[str, tuple[str,str]] = {}  # %name → (type, reg)
    i = 0

    while i < len(lines):
        lineno, raw = lines[i]
        stripped    = raw.strip()

        # ── @proc / @extern block start ─────────────────────────────────────
        m = DECL_RE.match(stripped)
        if m and m.group(1).lower() in ('proc', 'extern'):
            block: list[tuple[int, str]] = []
            j = i
            while j < len(lines):
                block.append(lines[j])
                dm = DECL_RE.match(lines[j][1].strip())
                if dm and dm.group(1).lower() == 'end':
                    break
                j += 1

            decl = parse_proc_block(block, source)
            if decl:
                # Build var_map for this proc scope
                var_map = {
                    v.name: (v.type, v.reg)
                    for v in decl.params + decl.vars_
                }
                # Emit as plain (non-@) informational comments
                kind = 'extern' if decl.extern else 'proc'
                output.append(f"; ── {kind} {decl.name}")
                for v in decl.params:
                    output.append(f";    param {v.name}:{v.type} = {v.reg}")
                for v in decl.vars_:
                    output.append(f";    var   {v.name}:{v.type} = {v.reg}")
                if decl.out_regs:
                    output.append(f";    out   {' '.join(decl.out_regs)}")
                if decl.clobbers:
                    output.append(f";    clobbers {','.join(decl.clobbers)}")

            i = j + 1
            continue

        # ── Standalone @end (closes current proc scope) ──────────────────────
        if m and m.group(1).lower() == 'end':
            var_map = {}
            i += 1
            continue

        # ── Other stray @-directives — skip silently ─────────────────────────
        if m:
            i += 1
            continue

        # ── Extended call: call proc(args…) ──────────────────────────────────
        if re.match(r'\s*call\s+\w+\s*\(', raw):
            # Substitute %vars in args, but NOT in the preserving clause
            pres_m = re.search(r'\bpreserving\b', raw, re.I)
            if pres_m:
                pre = raw[:pres_m.start()]
                post = raw[pres_m.start():]
                subst = substitute_vars(pre, var_map, source, lineno) \
                        + post if var_map and '%' in pre else raw
            else:
                subst = substitute_vars(raw, var_map, source, lineno) \
                        if var_map and '%' in raw else raw
            expanded = expand_call(subst, var_map, proc_db, source, lineno)
            if expanded is not None:
                output.extend(expanded)
                i += 1
                continue

        # ── %varname substitution in regular code lines ───────────────────────
        if var_map and '%' in raw and not stripped.startswith(';'):
            code, sep, comment = raw.partition(';')
            raw = substitute_vars(code, var_map, source, lineno) \
                  + (sep + comment if sep else '')

        output.append(raw)
        i += 1

    return output

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(
        description='ZPA Phase 1 — Z80 Pinned-register Annotator')
    ap.add_argument('files', nargs='+',
                    help='Source .zpa/.asm files or directories to scan recursively')
    ap.add_argument('-o', '--outdir', default='build/zpa',
                    help='Output directory (default: build/zpa)')
    ap.add_argument('--db', action='store_true',
                    help='Print the proc declaration database and exit')
    args = ap.parse_args()

    # Expand directories so the build scripts do not need a hard-coded list
    # of .zpa files (new modules are picked up automatically).
    expanded = []
    for name in args.files:
        p = Path(name)
        if p.is_dir():
            expanded.extend(sorted(p.rglob('*.zpa')))
        else:
            expanded.append(p)
    paths = expanded
    if not paths:
        print("ERROR: no .zpa/.asm sources found", file=sys.stderr)
        sys.exit(1)

    missing = [p for p in paths if not p.exists()]
    if missing:
        for p in missing:
            print(f"ERROR: file not found: {p}", file=sys.stderr)
        sys.exit(1)

    proc_db = scan_procs(paths)

    # ── --db mode: just dump the database ─────────────────────────────────
    if args.db:
        for name, decl in sorted(proc_db.items()):
            kind = 'extern' if decl.extern else 'proc'
            print(f"{kind} {name}  [{decl.source}:{decl.line}]")
            for v in decl.params:
                print(f"  param {v.name}:{v.type} = {v.reg}")
            for v in decl.vars_:
                print(f"  var   {v.name}:{v.type} = {v.reg}")
            if decl.out_regs:
                print(f"  out   {' '.join(decl.out_regs)}")
            if decl.clobbers:
                print(f"  clobbers {','.join(decl.clobbers)}")
        return

    # ── Normal mode: process each file ────────────────────────────────────
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    print(f"zpa: {len(proc_db)} proc(s) in database", file=sys.stderr)

    for path in paths:
        out_lines = process_file(path, proc_db)
        out_path  = outdir / path.with_suffix('.asm').name
        out_path.write_text('\n'.join(out_lines) + '\n', encoding='utf-8')
        print(f"zpa: {path} → {out_path}", file=sys.stderr)

    if _warnings:
        print(f"\nzpa: {len(_warnings)} warning(s)", file=sys.stderr)
    if _errors:
        print(f"\nzpa: {len(_errors)} error(s) — build aborted", file=sys.stderr)
        sys.exit(1)
    else:
        print("zpa: OK", file=sys.stderr)


if __name__ == '__main__':
    main()
