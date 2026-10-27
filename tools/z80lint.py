#!/usr/bin/env python3
"""
z80lint.py -- Z80 assembler linter for CP/M 3.1 / ZX Spectrum +3 project.

Proper instruction parser with effects table, replacing the old regex linter.

Checks:
  1. Stack balance (CFG): every RET must be reached with net push/pop depth
     of zero along all control-flow paths. The routine is split into basic
     blocks; a fixed-point solver assigns an entry depth to each block by
     propagating along jump/fall-through edges, and every RET is checked
     against the accumulated depth at that point. Labels reached with
     conflicting depths are reported as ambiguous. `ld sp, …` is treated as
     a stack rebase (depth resets to 0 from that point); `inc sp`/`dec sp`
     and `jp (hl/ix/iy)` mark the routine unanalysable and require
     `; lint-exempt: stack`.
  2. Register clobber: reads of registers known clobbered by a preceding CALL
     without intervening restore.
  3. Dead stores: writes between push/pop that are discarded by the pop.
  4. Clobber annotations: the declared Clobbers:/Out: set must cover the
     registers the routine (or its callees, by actual effect) leaves
     changed. Also flags Out: registers the body never writes (callers
     would read garbage believing it a result), and over-declared
     clobbers (info only — safe direction). SP is never tracked (CALL/RET
     contract) and F is not tracked (flags are assumed dead across CALL).
     Routines marked `; lint-exempt: stack` are skipped. Add
     `; lint: ignore` to the Clobbers: line to skip a routine.

Routine header format:
    ; routine_name - Description
    ;   In:       A = input
    ;   Out:      HL = result
    ;   Clobbers: AF, BC, DE
    ;
    ; A plain '; Stack: …' comment is treated as free-form documentation and
    ; has no effect on the linter. To disable the balance check on a routine
    ; that intentionally leaves SP non-zero (e.g. a jp-based shim), add:
    ;   ; lint-exempt: stack

Suppression:
    Add '; lint: ignore' to any line to suppress warnings on that line.

Usage:
  python3 tools/z80lint.py [--gate-annotations] [file.asm ...]
  (default: scans build/zpa/*.asm plus src/boot, src/fid and src/tools)

Exit code: 0 = clean, 1 = issues found.
  Check 4 (clobber annotations) is informational by default so an
  existing annotation backlog does not break the build gate.  Pass
  --gate-annotations to count its findings toward the exit code once
  the cleanup is done.
"""

import re
import sys
from pathlib import Path

# -------------------------------------------------------------------------
# Register constants
# -------------------------------------------------------------------------

SINGLES = {'a', 'b', 'c', 'd', 'e', 'h', 'l', 'i', 'r'}
PAIRS = {'bc', 'de', 'hl', 'sp', 'af', 'ix', 'iy'}
CONDITIONS = {'z', 'nz', 'c', 'nc', 'p', 'm', 'pe', 'po'}

PAIR_EXPAND = {
    'af': ('a', 'f'),
    'bc': ('b', 'c'),
    'de': ('d', 'e'),
    'hl': ('h', 'l'),
    'ix': ('ixh', 'ixl'),
    'iy': ('iyh', 'iyl'),
    'sp': ('sp',),
}

# For annotation parsing: map pair names to sub-registers we track
ANNOT_PAIR_MAP = {
    'AF': {'a', 'f'},
    'BC': {'b', 'c'},
    'DE': {'d', 'e'},
    'HL': {'h', 'l'},
    'IX': {'ixh', 'ixl'},
    'IY': {'iyh', 'iyl'},
    'SP': {'sp'},
}

# -------------------------------------------------------------------------
# Operand classifier
# -------------------------------------------------------------------------

class Op:
    """Classified operand."""
    __slots__ = ('kind', 'value', 'inner')
    # Kinds: 'reg8', 'reg16', 'indirect_pair', 'indexed', 'indirect_mem',
    #        'imm', 'cond', 'symbol', 'port_c', 'port_imm'

    def __init__(self, kind, value=None, inner=None):
        self.kind = kind
        self.value = value    # register name or condition code (lowercase)
        self.inner = inner    # for indexed: base pair

    def __repr__(self):
        if self.inner:
            return f"Op({self.kind}, {self.value}, {self.inner})"
        return f"Op({self.kind}, {self.value})"


# Regex patterns for operand classification
_RE_INDIRECT_PAIR = re.compile(r'^\((?:hl|bc|de|sp)\)$', re.I)
_RE_INDEXED = re.compile(r'^\((ix|iy)\s*[+\-]', re.I)
_RE_INDIRECT_MEM = re.compile(r'^\([^)]+\)$')
_RE_PORT_C = re.compile(r'^\(c\)$', re.I)


def classify_operand(s):
    """Classify a single operand string into an Op."""
    s = s.strip()
    low = s.lower()

    # Register pairs first (before checking singles, since 'c' is both)
    if low in PAIRS:
        return Op('reg16', low)

    # 8-bit registers
    if low in SINGLES:
        return Op('reg8', low)

    # IXH/IXL/IYH/IYL
    if low in ('ixh', 'ixl', 'iyh', 'iyl'):
        return Op('reg8', low)

    # (C) for I/O
    if _RE_PORT_C.match(low):
        return Op('port_c')

    # (HL), (BC), (DE), (SP) indirect
    if _RE_INDIRECT_PAIR.match(low):
        inner = low[1:-1]
        return Op('indirect_pair', inner)

    # (IX+d), (IY+d)
    m = _RE_INDEXED.match(low)
    if m:
        return Op('indexed', inner=m.group(1).lower())

    # Condition codes (excluding 'c' which is handled contextually)
    if low in CONDITIONS and low != 'c':
        return Op('cond', low)

    # (nn) - indirect memory
    if _RE_INDIRECT_MEM.match(s):
        return Op('indirect_mem')

    # Immediate/symbol
    return Op('imm')


def classify_operands(mnemonic, raw_operands):
    """
    Classify operand list, handling the condition code ambiguity for 'c'.
    For jp/jr/call/ret, first operand might be a condition code.
    """
    ops = []
    for i, raw in enumerate(raw_operands):
        op = classify_operand(raw)

        # Handle condition code disambiguation
        if i == 0 and mnemonic in ('jp', 'jr', 'call', 'ret'):
            low = raw.strip().lower()
            if low in CONDITIONS:
                ops.append(Op('cond', low))
                continue
            # 'c' as condition code: only if there is a second operand (target)
            if low == 'c' and len(raw_operands) > 1:
                ops.append(Op('cond', low))
                continue

        ops.append(op)
    return ops


# -------------------------------------------------------------------------
# Assembly line parser
# -------------------------------------------------------------------------

# Directives we skip (not instructions)
DIRECTIVES = {
    'org', 'equ', 'ds', 'dw', 'db', 'defs', 'defw', 'defb', 'defm',
    'phase', 'dephase', 'block', 'align', 'if', 'else', 'endif', 'ifdef',
    'ifndef', 'macro', 'endm', 'include', 'incbin', 'device', 'assert',
    'display', 'struct', 'ends', 'dup', 'edup', 'module', 'endmodule',
    'define', 'undefine', 'export', 'page', 'slot', 'size', 'lua',
    'endlua', 'end', 'output', 'outend', 'fpos', 'opt', 'byte', 'word',
    'savenex', 'savesna', 'savebin', 'savehob', 'emptytap', 'savetap',
    'shellexec', 'hex',
}


def strip_comment(line):
    """Strip ; comment, respecting quoted strings."""
    result = []
    in_str = False
    q = None
    for ch in line:
        if not in_str and ch in ('"', "'"):
            in_str, q = True, ch
        elif in_str and ch == q:
            in_str = False
        elif not in_str and ch == ';':
            break
        result.append(ch)
    return ''.join(result).strip()


def split_operands(text):
    """Split operand string on commas, respecting parentheses."""
    ops = []
    depth = 0
    current = []
    for ch in text:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        elif ch == ',' and depth == 0:
            ops.append(''.join(current).strip())
            current = []
            continue
        current.append(ch)
    if current:
        s = ''.join(current).strip()
        if s:
            ops.append(s)
    return ops


def parse_line(raw):
    """
    Parse a single assembly line.
    Returns (label, mnemonic, operands_str, operands_list, is_directive, is_local)
    where label may be None, mnemonic may be None.
    """
    code = strip_comment(raw)
    if not code:
        return None, None, '', [], False, False

    label = None
    is_local = False

    # Check for label (with colon)
    m = re.match(r'^(\.?\w+)\s*:', code)
    if m:
        label = m.group(1)
        is_local = label.startswith('.')
        code = code[m.end():].strip()

    if not code:
        return label, None, '', [], False, is_local

    # Split mnemonic and operands
    parts = code.split(None, 1)
    mnemonic = parts[0].lower()

    # Handle sjasmplus label-without-colon followed by equ
    if len(parts) > 1 and parts[1].lower().startswith('equ'):
        return parts[0], 'equ', parts[1][3:].strip(), [], True, False

    if mnemonic in DIRECTIVES:
        return label, mnemonic, parts[1] if len(parts) > 1 else '', [], True, is_local

    operands_str = parts[1] if len(parts) > 1 else ''
    operands = split_operands(operands_str) if operands_str else []

    return label, mnemonic, operands_str, operands, False, is_local


# -------------------------------------------------------------------------
# Instruction effects resolver
# -------------------------------------------------------------------------

def _pair_regs(pair):
    """Expand pair name to set of sub-registers."""
    return set(PAIR_EXPAND.get(pair, (pair,)))


def get_effects(mnemonic, ops):
    """
    Given a mnemonic and classified operands, return (reads, writes).
    Both are sets of lowercase register names: a, b, c, d, e, h, l, f,
    sp, ixh, ixl, iyh, iyl, i, r.
    """
    reads = set()
    writes = set()

    def add_op_reads(op):
        """Add registers read by accessing this operand."""
        if op.kind == 'reg8':
            reads.add(op.value)
        elif op.kind == 'reg16':
            reads.update(_pair_regs(op.value))
        elif op.kind == 'indirect_pair':
            reads.update(_pair_regs(op.value))
        elif op.kind == 'indexed':
            reads.update(_pair_regs(op.inner))
        elif op.kind == 'port_c':
            reads.update(('b', 'c'))

    def add_dst_writes(op):
        """Add register writes for a destination operand."""
        if op.kind == 'reg8':
            writes.add(op.value)
        elif op.kind == 'reg16':
            writes.update(_pair_regs(op.value))
        elif op.kind in ('indirect_pair', 'indexed'):
            # Writing to memory: the address register is READ not written
            add_op_reads(op)

    # ---- LD variants ----
    if mnemonic == 'ld':
        if len(ops) == 2:
            dst, src = ops

            if dst.kind == 'reg8':
                # LD r, src
                writes.add(dst.value)
                add_op_reads(src)
            elif dst.kind in ('indirect_pair', 'indexed'):
                # LD (HL), src / LD (IX+d), src
                add_dst_writes(dst)
                add_op_reads(src)
            elif dst.kind == 'reg16':
                if dst.value == 'sp' and src.kind == 'reg16':
                    # LD SP, HL/IX/IY
                    add_op_reads(src)
                    writes.add('sp')
                elif src.kind == 'indirect_mem':
                    # LD pair, (nn) - writes both sub-registers
                    writes.update(_pair_regs(dst.value))
                else:
                    # LD pair, nn / LD pair, pair
                    writes.update(_pair_regs(dst.value))
                    add_op_reads(src)
            elif dst.kind == 'indirect_mem':
                # LD (nn), A / LD (nn), pair
                add_op_reads(src)
        return reads, writes

    # ---- ALU: ADD/ADC/SUB/SBC ----
    if mnemonic in ('add', 'adc', 'sub', 'sbc'):
        if len(ops) == 2 and ops[0].kind == 'reg16':
            # 16-bit: ADD HL,pair / ADC HL,pair / SBC HL,pair
            pair_dst = ops[0].value
            reads.update(_pair_regs(pair_dst))
            add_op_reads(ops[1])
            writes.update(_pair_regs(pair_dst))
            writes.add('f')
            if mnemonic in ('adc', 'sbc'):
                reads.add('f')
            return reads, writes

        # 8-bit ALU
        if len(ops) == 2:
            # ADD A, x / ADC A, x / SBC A, x
            reads.add('a')
            add_op_reads(ops[1])
        elif len(ops) == 1:
            # SUB x (implicit A)
            reads.add('a')
            add_op_reads(ops[0])
        writes.add('a')
        writes.add('f')
        if mnemonic in ('adc', 'sbc'):
            reads.add('f')
        return reads, writes

    # ---- Logic: AND/OR/XOR/CP ----
    if mnemonic in ('and', 'or', 'xor', 'cp'):
        if len(ops) >= 1:
            src = ops[-1]
            if mnemonic == 'xor' and src.kind == 'reg8' and src.value == 'a':
                # XOR A: sets A=0, does NOT meaningfully read A
                writes.add('a')
                writes.add('f')
                return reads, writes
            if mnemonic == 'or' and src.kind == 'reg8' and src.value == 'a':
                # OR A: tests A, writes F only (A value unchanged)
                reads.add('a')
                writes.add('f')
                return reads, writes
            if mnemonic == 'cp':
                # CP x: reads A, reads x, writes F only
                reads.add('a')
                add_op_reads(src)
                writes.add('f')
                return reads, writes
            # AND/OR/XOR general
            reads.add('a')
            add_op_reads(src)
            writes.add('a')
            writes.add('f')
        return reads, writes

    # ---- INC/DEC ----
    if mnemonic in ('inc', 'dec'):
        if len(ops) == 1:
            op = ops[0]
            if op.kind == 'reg16':
                # INC/DEC pair: NO flags affected
                reads.update(_pair_regs(op.value))
                writes.update(_pair_regs(op.value))
            elif op.kind == 'reg8':
                # INC/DEC r: flags affected
                reads.add(op.value)
                writes.add(op.value)
                writes.add('f')
            elif op.kind in ('indirect_pair', 'indexed'):
                # INC/DEC (HL) / (IX+d): reads address, writes flags
                add_op_reads(op)
                writes.add('f')
        return reads, writes

    # ---- PUSH/POP ----
    if mnemonic == 'push':
        if ops and ops[0].kind == 'reg16':
            reads.update(_pair_regs(ops[0].value))
        return reads, writes

    if mnemonic == 'pop':
        if ops and ops[0].kind == 'reg16':
            writes.update(_pair_regs(ops[0].value))
        return reads, writes

    # ---- Rotate accumulator ----
    if mnemonic in ('rlca', 'rrca', 'rla', 'rra'):
        reads.add('a')
        writes.update(('a', 'f'))
        if mnemonic in ('rla', 'rra'):
            reads.add('f')
        return reads, writes

    # ---- Rotate/shift CB prefix: RLC/RRC/RL/RR/SLA/SRA/SRL ----
    if mnemonic in ('rlc', 'rrc', 'rl', 'rr', 'sla', 'sra', 'srl'):
        if ops:
            op = ops[-1]
            if op.kind == 'reg8':
                reads.add(op.value)
                writes.add(op.value)
            else:
                add_op_reads(op)
            writes.add('f')
            if mnemonic in ('rl', 'rr'):
                reads.add('f')
        return reads, writes

    # ---- BIT/SET/RES ----
    if mnemonic == 'bit':
        if len(ops) >= 2:
            add_op_reads(ops[-1])
            writes.add('f')
        return reads, writes

    if mnemonic in ('set', 'res'):
        if len(ops) >= 2:
            op = ops[-1]
            if op.kind == 'reg8':
                reads.add(op.value)
                writes.add(op.value)
            else:
                add_op_reads(op)
        return reads, writes

    # ---- Block operations ----
    if mnemonic in ('ldi', 'ldd'):
        reads.update(('b', 'c', 'd', 'e', 'h', 'l'))
        writes.update(('b', 'c', 'd', 'e', 'h', 'l', 'f'))
        return reads, writes

    if mnemonic in ('ldir', 'lddr'):
        reads.update(('b', 'c', 'd', 'e', 'h', 'l'))
        writes.update(('b', 'c', 'd', 'e', 'h', 'l', 'f'))
        return reads, writes

    if mnemonic in ('cpi', 'cpd'):
        reads.update(('a', 'b', 'c', 'h', 'l'))
        writes.update(('b', 'c', 'h', 'l', 'f'))
        return reads, writes

    if mnemonic in ('cpir', 'cpdr'):
        reads.update(('a', 'b', 'c', 'h', 'l'))
        writes.update(('b', 'c', 'h', 'l', 'f'))
        return reads, writes

    # ---- Exchange ----
    if mnemonic == 'ex':
        if len(ops) == 2:
            a, b = ops
            if a.kind == 'reg16' and b.kind == 'reg16':
                if a.value == 'de' and b.value == 'hl':
                    reads.update(('d', 'e', 'h', 'l'))
                    writes.update(('d', 'e', 'h', 'l'))
                elif a.value == 'af':
                    # EX AF, AF'
                    reads.update(('a', 'f'))
                    writes.update(('a', 'f'))
            elif a.kind == 'indirect_pair' and a.value == 'sp':
                # EX (SP), HL / IX / IY
                reads.add('sp')
                if b.kind == 'reg16':
                    reads.update(_pair_regs(b.value))
                    writes.update(_pair_regs(b.value))
        return reads, writes

    if mnemonic == 'exx':
        reads.update(('b', 'c', 'd', 'e', 'h', 'l'))
        writes.update(('b', 'c', 'd', 'e', 'h', 'l'))
        return reads, writes

    # ---- I/O ----
    if mnemonic == 'in':
        if len(ops) == 2:
            dst, src = ops
            if src.kind == 'port_c':
                reads.update(('b', 'c'))
            if dst.kind == 'reg8':
                writes.add(dst.value)
            writes.add('f')
        return reads, writes

    if mnemonic == 'out':
        if len(ops) == 2:
            dst, src = ops
            if dst.kind == 'port_c':
                reads.update(('b', 'c'))
            add_op_reads(src)
        return reads, writes

    if mnemonic in ('ini', 'ind', 'inir', 'indr'):
        reads.update(('b', 'c', 'h', 'l'))
        writes.update(('b', 'h', 'l', 'f'))
        return reads, writes

    if mnemonic in ('outi', 'outd', 'otir', 'otdr'):
        reads.update(('b', 'c', 'h', 'l'))
        writes.update(('b', 'h', 'l', 'f'))
        return reads, writes

    # ---- Control flow ----
    if mnemonic in ('jp', 'jr'):
        if ops and ops[0].kind == 'indirect_pair' and ops[0].value == 'hl':
            reads.update(('h', 'l'))
        if ops and ops[0].kind == 'cond':
            reads.add('f')
        return reads, writes

    if mnemonic == 'call':
        if ops and ops[0].kind == 'cond':
            reads.add('f')
        reads.add('sp')
        writes.add('sp')
        return reads, writes

    if mnemonic in ('ret', 'reti', 'retn'):
        reads.add('sp')
        writes.add('sp')
        if ops and ops[0].kind == 'cond':
            reads.add('f')
        return reads, writes

    if mnemonic == 'djnz':
        reads.add('b')
        writes.update(('b', 'f'))
        return reads, writes

    if mnemonic == 'rst':
        reads.add('sp')
        writes.add('sp')
        return reads, writes

    # ---- Misc ----
    if mnemonic == 'daa':
        reads.update(('a', 'f'))
        writes.update(('a', 'f'))
        return reads, writes

    if mnemonic == 'cpl':
        reads.add('a')
        writes.update(('a', 'f'))
        return reads, writes

    if mnemonic == 'neg':
        reads.add('a')
        writes.update(('a', 'f'))
        return reads, writes

    if mnemonic == 'scf':
        writes.add('f')
        return reads, writes

    if mnemonic == 'ccf':
        reads.add('f')
        writes.add('f')
        return reads, writes

    if mnemonic in ('nop', 'halt', 'ei', 'di'):
        return reads, writes

    if mnemonic == 'im':
        return reads, writes

    # Unknown instruction: return empty sets (safe default)
    return reads, writes


# -------------------------------------------------------------------------
# Routine / header parsing
# -------------------------------------------------------------------------

ROUTINE_LABEL_RE = re.compile(r'^([A-Za-z_]\w*)\s*:')
CLOBBER_RE = re.compile(r';\s*clobbers?[:\s]\s*(.+)', re.I)
OUT_RE = re.compile(r';\s*out[:\s]\s*(.+)', re.I)
STACK_RE = re.compile(r';\s*lint-exempt\s*:\s*stack\b', re.I)


def contiguous_comment_block(lines):
    """
    Trailing run of non-blank comment lines.  Annotation blocks (In/Out/
    Clobbers) sit directly above the label; stopping at blank lines keeps
    file-header prose far above a data label from being parsed as that
    label's annotations.
    """
    out = []
    for line in reversed(lines):
        if not line.strip().startswith(';'):
            break
        out.append(line)
    out.reverse()
    return out


def parse_annotation_regs(text):
    """Parse register list from annotation: 'AF, BC, DE' -> {'a','f','b','c','d','e'}"""
    regs = set()
    for part in text.replace(',', ' ').split():
        part = re.sub(r'\(.*?\)', '', part)  # strip parenthetical notes
        part = re.sub(r'=.*', '', part)       # strip "= value" descriptions
        part = part.strip().upper()
        if part in ANNOT_PAIR_MAP:
            regs.update(ANNOT_PAIR_MAP[part])
        elif part in ('A', 'B', 'C', 'D', 'E', 'H', 'L', 'F'):
            regs.add(part.lower())
        elif part in ('IX', 'IY'):
            regs.update(ANNOT_PAIR_MAP.get(part, set()))
        elif part == 'SP':
            regs.add('sp')
        elif part in ('Z', 'NZ', 'NC', 'CARRY', 'ZERO', 'FLAG', 'FLAGS'):
            regs.add('f')  # Flag conditions mean F is an output
    # Also check the raw text for flag-related keywords
    upper = text.upper()
    if any(w in upper for w in ('Z =', 'NZ =', 'CARRY', 'Z FLAG', 'NZ FLAG', 'Z SET', 'NZ SET')):
        regs.add('f')
    return regs


class Routine:
    """Represents a parsed routine with header annotations."""
    __slots__ = ('name', 'filepath', 'start_lineno', 'lines',
                 'stack_exempt', 'clobber_ignore', 'clobbers', 'out_regs')

    def __init__(self, name, filepath, start_lineno):
        self.name = name
        self.filepath = filepath
        self.start_lineno = start_lineno
        self.lines = []           # [(lineno, raw_text), ...]
        self.stack_exempt = False
        self.clobber_ignore = False
        self.clobbers = set()     # register names from Clobbers:
        self.out_regs = set()     # register names from Out:


def parse_file(filepath):
    """Parse a .asm file into a list of Routine objects."""
    try:
        with open(filepath, errors='replace') as f:
            raw = f.readlines()
    except OSError as e:
        print(f"ERROR: cannot open {filepath}: {e}", file=sys.stderr)
        return []

    routines = []
    current = None
    pending_cmts = []  # comment lines buffered before next label

    for lineno, line in enumerate(raw, 1):
        stripped = line.strip()

        # Blank or comment-only
        if not stripped or stripped.startswith(';'):
            if current is None:
                pending_cmts.append(line)
            else:
                current.lines.append((lineno, line))
                if STACK_RE.search(line):
                    current.stack_exempt = True
            continue

        # Non-local label: new routine
        m = ROUTINE_LABEL_RE.match(stripped)
        if m and not stripped.startswith('.'):
            if current is not None:
                routines.append(current)

            name = m.group(1)
            cur = Routine(name, filepath, lineno)

            # Scan header comment block
            header_lines = pending_cmts
            # Also grab trailing comments from previous routine
            if current is not None:
                tail = []
                for _, raw_line in reversed(current.lines):
                    s = raw_line.strip()
                    if not s or s.startswith(';'):
                        tail.append(raw_line)
                    else:
                        break
                header_lines = list(reversed(tail)) + pending_cmts

            # Only the contiguous comment block directly above the label
            # carries annotations; anything above a blank line is prose
            # (e.g. the file header) and must not attach to this label.
            anno_lines = contiguous_comment_block(header_lines)

            in_out_block = False
            for hline in header_lines:
                if STACK_RE.search(hline):
                    cur.stack_exempt = True
            for hline in anno_lines:
                mc = CLOBBER_RE.search(hline)
                if mc:
                    cur.clobbers |= parse_annotation_regs(mc.group(1))
                    if 'lint: ignore' in hline.lower():
                        cur.clobber_ignore = True
                    in_out_block = False
                mo = OUT_RE.search(hline)
                if mo:
                    cur.out_regs |= parse_annotation_regs(mo.group(1))
                    in_out_block = True
                elif in_out_block and hline.strip().startswith(';'):
                    # Continuation of Out: block — look for register/flag refs
                    extra = parse_annotation_regs(hline.lstrip('; '))
                    cur.out_regs |= extra
                    # Stop if we hit another annotation keyword
                    if any(kw in hline.upper() for kw in ('IN:', 'CLOBBERS:', 'STACK:')):
                        in_out_block = False

            cur.lines.append((lineno, line))
            pending_cmts = []
            current = cur
            continue

        # Ordinary line
        pending_cmts = []
        if current is not None:
            if not current.clobbers:
                mc = CLOBBER_RE.search(line)
                if mc:
                    current.clobbers = parse_annotation_regs(mc.group(1))
            if not current.out_regs:
                mo = OUT_RE.search(line)
                if mo:
                    current.out_regs = parse_annotation_regs(mo.group(1))
            if STACK_RE.search(line):
                current.stack_exempt = True
            current.lines.append((lineno, line))

    if current is not None:
        routines.append(current)

    return routines


# -------------------------------------------------------------------------
# Parse instruction from line (shared helper)
# -------------------------------------------------------------------------

def parse_instruction(raw):
    """
    Parse a raw line into (mnemonic, classified_ops, raw_ops) or
    (None, None, None) if not an instruction.
    """
    label, mnemonic, operands_str, operands_raw, is_directive, is_local = parse_line(raw)
    if mnemonic is None or is_directive:
        return None, None, None
    ops = classify_operands(mnemonic, operands_raw)
    return mnemonic, ops, operands_raw


# -------------------------------------------------------------------------
# Check 1: CFG-based stack balance via basic-block analysis
# -------------------------------------------------------------------------

class _Block:
    __slots__ = ('idx', 'entries', 'net_delta', 'successors',
                 'last_insn', 'unanalyzable', 'sp_rebased')

    def __init__(self, idx, entries):
        self.idx = idx
        self.entries = entries          # list of (lineno, raw, label, is_local, mnemonic, ops, raw_ops)
        self.net_delta = 0
        self.successors = []            # list of block indices
        self.last_insn = None           # entry tuple of the final real instruction
        self.unanalyzable = []          # [(lineno, reason), ...]
        self.sp_rebased = False         # True if block executes `ld sp, ...`


def _cfg_sp_manip(mnemonic, ops):
    """Return a reason string if the instruction mutates SP in an untrackable way.
    `ld sp, ...` is handled separately: it rebases the stack rather than shifting
    by an unknown delta, so the CFG analyser treats it as resetting the running
    depth to zero instead of bailing out."""
    if mnemonic in ('inc', 'dec') and ops:
        if ops[0].kind == 'reg16' and ops[0].value == 'sp':
            return f'{mnemonic} sp'
    return None


def _cfg_is_ld_sp(mnemonic, ops):
    if mnemonic != 'ld' or len(ops) < 2:
        return False
    return ops[0].kind == 'reg16' and ops[0].value == 'sp'


def _cfg_is_indirect_jp(raw_ops):
    if not raw_ops:
        return False
    t = raw_ops[0].strip().lower()
    return t in ('(hl)', '(ix)', '(iy)')


def _cfg_is_terminator(mnemonic):
    return mnemonic in ('ret', 'reti', 'retn', 'jp', 'jr', 'djnz')


def _cfg_target_label(raw_ops, has_cond):
    if not raw_ops:
        return None
    if has_cond and len(raw_ops) >= 2:
        return raw_ops[1].strip()
    return raw_ops[0].strip()


def _cfg_entries(routine):
    """Extract (lineno, raw, label, is_local, mnemonic, ops, raw_ops) per non-blank line."""
    out = []
    for lineno, raw in routine.lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith(';'):
            continue
        label, mnemonic, _, raw_ops, is_directive, is_local = parse_line(raw)
        if mnemonic is None and label is None:
            continue
        if is_directive:
            continue
        ops = classify_operands(mnemonic, raw_ops) if mnemonic is not None else None
        out.append((lineno, raw, label, is_local, mnemonic, ops, raw_ops))
    return out


def _cfg_build_blocks(entries):
    if not entries:
        return []
    starts = {0}
    for i, (_, _, label, _, mnemonic, _, _) in enumerate(entries):
        if i > 0 and label is not None:
            starts.add(i)
        if mnemonic and _cfg_is_terminator(mnemonic):
            if i + 1 < len(entries):
                starts.add(i + 1)
    sl = sorted(starts)
    blocks = []
    for k, s in enumerate(sl):
        end = sl[k + 1] if k + 1 < len(sl) else len(entries)
        blocks.append(_Block(idx=len(blocks), entries=entries[s:end]))
    return blocks


def _cfg_analyze_block(b):
    delta = 0
    last = None
    for entry in b.entries:
        lineno, _, _, _, mnemonic, ops, _ = entry
        if mnemonic is None:
            continue
        reason = _cfg_sp_manip(mnemonic, ops)
        if reason:
            b.unanalyzable.append((lineno, reason))
        # EX (SP), xx: swaps top-of-stack content, depth unchanged
        if (mnemonic == 'ex' and len(ops) == 2
                and ops[0].kind == 'indirect_pair' and ops[0].value == 'sp'):
            last = entry
            continue
        # LD SP, ... rebases the stack: discard prior depth and restart from 0.
        if _cfg_is_ld_sp(mnemonic, ops):
            delta = 0
            b.sp_rebased = True
            last = entry
            continue
        if mnemonic == 'push':
            delta += 1
        elif mnemonic == 'pop':
            delta -= 1
        last = entry
    b.net_delta = delta
    b.last_insn = last


def _cfg_compute_successors(blocks, label_to_block):
    for bi, b in enumerate(blocks):
        next_bi = bi + 1 if bi + 1 < len(blocks) else None
        li = b.last_insn
        if li is None:
            if next_bi is not None:
                b.successors.append(next_bi)
            continue

        lineno, _, _, _, mn, ops, raw_ops = li

        if mn in ('ret', 'reti', 'retn'):
            cond = bool(ops and ops[0].kind == 'cond')
            if cond and next_bi is not None:
                b.successors.append(next_bi)
            continue

        if mn in ('jp', 'jr'):
            if _cfg_is_indirect_jp(raw_ops):
                b.unanalyzable.append((lineno, 'indirect jump'))
                continue
            cond = bool(ops and ops[0].kind == 'cond')
            target = _cfg_target_label(raw_ops, cond)
            if target is not None:
                target_bi = label_to_block.get(target)
                if target_bi is not None:
                    b.successors.append(target_bi)
                # Unknown target: external exit (no internal edge)
            if cond and next_bi is not None:
                b.successors.append(next_bi)
            continue

        if mn == 'djnz':
            target = _cfg_target_label(raw_ops, False)
            if target is not None:
                target_bi = label_to_block.get(target)
                if target_bi is not None:
                    b.successors.append(target_bi)
            if next_bi is not None:
                b.successors.append(next_bi)
            continue

        # Non-terminator tail (e.g. block ended because next line has a label)
        if next_bi is not None:
            b.successors.append(next_bi)


def _cfg_block_label(b):
    for (_, _, lbl, _, _, _, _) in b.entries:
        if lbl:
            return lbl
    return f'block@{b.entries[0][0]}' if b.entries else f'block#{b.idx}'


def check_stack_balance_cfg(routine):
    """
    CFG-based stack balance: solve entry-depth per basic block via fixed-point,
    then check each RET sees depth 0. Unanalyzable SP manipulations or indirect
    jumps in a non-exempt routine are reported as needing explicit exemption.
    """
    if routine.stack_exempt:
        return []

    entries = _cfg_entries(routine)
    blocks = _cfg_build_blocks(entries)
    if not blocks:
        return []

    # Map each label to the block it heads. Only the first entry of a block
    # can bear a label under our splitting rule.
    label_to_block = {}
    for bi, b in enumerate(blocks):
        if not b.entries:
            continue
        first_label = b.entries[0][2]
        if first_label:
            label_to_block[first_label] = bi
    label_to_block.setdefault(routine.name, 0)

    for b in blocks:
        _cfg_analyze_block(b)
    _cfg_compute_successors(blocks, label_to_block)

    issues = []

    # Any SP manipulation / indirect jump means the routine is outside the
    # analyser's reach — require explicit exemption rather than guess.
    un = [(ln, r) for b in blocks for (ln, r) in b.unanalyzable]
    if un:
        reasons = sorted(set(r for _, r in un))
        first_ln = min(ln for ln, _ in un)
        issues.append({
            'kind': 'needs_exempt',
            'lineno': first_ln,
            'reason': ', '.join(reasons),
        })
        return issues

    # Fixed-point entry-depth solver.
    entry_depth = {0: 0}
    worklist = [0]
    while worklist:
        bi = worklist.pop()
        b = blocks[bi]
        # A block containing `ld sp, ...` rebases the stack; its exit depth
        # reflects only what happened after the rebase.
        base = 0 if b.sp_rebased else entry_depth[bi]
        exit_d = base + b.net_delta
        for succ in blocks[bi].successors:
            if succ not in entry_depth:
                entry_depth[succ] = exit_d
                worklist.append(succ)
            elif entry_depth[succ] != exit_d:
                succ_label = _cfg_block_label(blocks[succ])
                pred_li = blocks[bi].last_insn
                pred_ln = pred_li[0] if pred_li else blocks[bi].entries[0][0]
                issues.append({
                    'kind': 'ambiguous',
                    'lineno': pred_ln,
                    'label': succ_label,
                    'existing': entry_depth[succ],
                    'arriving': exit_d,
                })

    # Check every block that exits via RET.
    for bi, b in enumerate(blocks):
        if bi not in entry_depth or b.last_insn is None:
            continue
        lineno, raw, _, _, mn, _, _ = b.last_insn
        if mn not in ('ret', 'reti', 'retn'):
            continue
        if 'lint: ignore' in raw.lower():
            continue
        base = 0 if b.sp_rebased else entry_depth[bi]
        depth = base + b.net_delta
        if depth != 0:
            issues.append({
                'kind': 'ret',
                'lineno': lineno,
                'depth': depth,
                'entry_depth': base,
                'code': strip_comment(raw.strip()),
            })

    return issues


# -------------------------------------------------------------------------
# Check 2: Register clobber after CALL
# -------------------------------------------------------------------------

CALL_TARGET_RE = re.compile(
    r'^\s*call\s+(?:(?:z|nz|c|nc|p|m|pe|po)\s*,\s*)?(\w+)', re.I
)


def check_clobbers_in_file(filepath, all_lines, routine_map):
    """
    For each CALL with a known clobber set, scan forward in the basic block
    for reads of clobbered registers without intervening writes.
    Out registers are excluded from the clobber set.
    """
    issues = []

    for i, line in enumerate(all_lines):
        m = CALL_TARGET_RE.search(line)
        if not m:
            continue
        target = m.group(1)
        if target not in routine_map:
            continue

        r = routine_map[target]
        # Effective clobbers = declared clobbers minus Out registers
        clobbered = r.clobbers - r.out_regs
        if not clobbered:
            continue

        call_lineno = i + 1
        restored = set()

        for j in range(i + 1, min(i + 25, len(all_lines))):
            fwd_raw = all_lines[j]
            fwd = fwd_raw.strip()
            if not fwd or fwd.startswith(';'):
                continue

            mnemonic, ops, _ = parse_instruction(fwd_raw)
            if mnemonic is None:
                # Could be a public label => end of basic block
                if ROUTINE_LABEL_RE.match(fwd) and not fwd.startswith('.'):
                    break
                continue

            # Get writes from this instruction to track restores
            _, inst_writes = get_effects(mnemonic, ops)

            # A PUSH is a save, not a use: `push af` after a call that
            # clobbers A is exactly how callers preserve the value.
            if mnemonic == 'push':
                continue

            # Check for reads of still-clobbered registers BEFORE updating
            # restored set (the write on THIS line restores for FUTURE lines)
            inst_reads, _ = get_effects(mnemonic, ops)
            for reg in (clobbered - restored) & inst_reads:
                # Skip if line has lint: ignore suppression
                if 'lint: ignore' in fwd_raw.lower():
                    continue
                issues.append({
                    'file': filepath,
                    'call_line': call_lineno,
                    'use_line': j + 1,
                    'target': target,
                    'register': reg,
                    'code': fwd,
                })

            restored.update(inst_writes)

            # End of basic block
            if mnemonic in ('jp', 'jr') and (not ops or ops[0].kind != 'cond'):
                break
            if mnemonic in ('ret', 'reti', 'retn'):
                break
            if CALL_TARGET_RE.match(fwd):
                break
            if ROUTINE_LABEL_RE.match(fwd) and not fwd.startswith('.'):
                break

    return issues


# -------------------------------------------------------------------------
# Check 3: Dead stores in push/pop pairs
# -------------------------------------------------------------------------

def check_dead_stores(routine):
    """
    Detect writes to a sub-register between push and matching pop that are
    never read before the pop discards them.
    Skip PUSH AF (too many false positives).
    """
    issues = []

    # Build instruction list
    insns = []
    for lineno, raw in routine.lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith(';'):
            continue
        mnemonic, ops, raw_ops = parse_instruction(raw)
        if mnemonic is None:
            # Could be a label-only line
            label, _, _, _, _, is_local = parse_line(raw)
            if label:
                insns.append((lineno, 'label', None, None, is_local))
            continue
        insns.append((lineno, mnemonic, ops, raw_ops, False))

    for i, (push_ln, mn, push_ops, _, _) in enumerate(insns):
        if mn != 'push' or not push_ops:
            continue
        if push_ops[0].kind != 'reg16':
            continue

        pair = push_ops[0].value
        if pair in ('ix', 'iy', 'sp'):
            continue
        # Skip AF: too many intentional save/restore patterns
        if pair == 'af':
            continue

        sub_regs = set(PAIR_EXPAND[pair])
        written = {}  # reg -> write_lineno

        depth = 1
        for j in range(i + 1, len(insns)):
            ln, jmn, jops, _, is_label = insns[j]

            if is_label or jmn == 'label':
                continue

            # Nested push/pop tracking
            if jmn == 'push' and jops and jops[0].kind == 'reg16' and jops[0].value == pair:
                depth += 1
                continue
            if jmn == 'pop' and jops and jops[0].kind == 'reg16' and jops[0].value == pair:
                depth -= 1
                if depth == 0:
                    # Matching pop found: report unread writes
                    for reg, wln in written.items():
                        # Check if the write line has lint: ignore
                        write_raw = routine.lines[wln - routine.lines[0][0]] if wln - routine.lines[0][0] < len(routine.lines) else ('', '')
                        if isinstance(write_raw, tuple) and len(write_raw) == 2:
                            write_raw = write_raw[1]
                        if 'lint: ignore' in str(write_raw).lower():
                            continue
                        issues.append({
                            'push_lineno': push_ln,
                            'write_lineno': wln,
                            'pop_lineno': ln,
                            'register': reg,
                            'pair': pair,
                        })
                    break
                continue
            # Different pair popped: interleaved stacks, abort
            if jmn == 'pop':
                break

            # Unconditional branch or ret: cannot track linearly
            if jmn in ('ret', 'reti', 'retn'):
                break
            if jmn in ('jp', 'jr') and jops and jops[0].kind != 'cond':
                break

            # CALL: clear written set (callee may have read the values)
            if jmn == 'call':
                written.clear()
                continue

            # Get instruction effects
            inst_reads, inst_writes = get_effects(jmn, jops)

            # Check reads first: any read of a written reg clears the dead flag
            for reg in list(written.keys()):
                if reg in inst_reads:
                    del written[reg]

            # Track writes to sub-registers
            for reg in sub_regs & inst_writes:
                if reg not in inst_reads:
                    # Pure write: potentially dead
                    written[reg] = ln

    return issues


# -------------------------------------------------------------------------
# Check 4: Clobber annotation verification (declared vs actual effects)
# -------------------------------------------------------------------------

def compute_direct_writes(lines):
    """
    Net register writes and preserved registers over a sequence of routine
    body lines.

    A `pop` with no matching push is a data load (real write).  A `pop`
    with a matching push makes the register's final value equal to what it
    held at the matching `push`:
      - if the register held the caller's value (no write recorded), the
        pop restores it — the pair is "preserved";
      - if the routine had written it before the push (e.g. a result
        carried across a bank switch), the write survives the pop.
    Writes made between a push and its matching pop are always destroyed
    by the pop.  The same pairing logic covers EXX/EXX and EX AF,AF'
    swaps: a balanced swap pair preserves the swapped registers.

    SP is always excluded (CALL/RET contract); F is excluded (flags are
    assumed dead across CALL by convention).

      In:       lines — [(lineno, raw_text), ...]
      Out:      (writes, preserved) — sets of sub-register names left
                changed at RET, and sub-registers provably preserved by
                balanced push/pop or swap pairs
      Clobbers: none
    """
    writes = set()
    preserved = set()
    push_stack = {}      # pair -> [snapshot sets]
    load_pairs = set()   # pairs with an unmatched pop (data load)
    swap_depth = {'exx': 0, 'afx': 0}
    swap_seen = {'exx': False, 'afx': False}

    for lineno, raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith(';'):
            continue
        mnemonic, ops, raw_ops = parse_instruction(raw)
        if mnemonic is None:
            continue

        if mnemonic == 'push' and ops and ops[0].kind == 'reg16':
            pair = ops[0].value
            snap = writes & _pair_regs(pair)
            push_stack.setdefault(pair, []).append(snap)
            writes -= _pair_regs(pair)
            continue

        if mnemonic == 'pop' and ops and ops[0].kind == 'reg16':
            pair = ops[0].value
            stack = push_stack.get(pair)
            if stack:
                snap = stack.pop()
                writes -= _pair_regs(pair)
                writes |= snap
            else:
                writes |= _pair_regs(pair)   # data load: real write
                load_pairs.add(pair)
            continue

        if mnemonic == 'exx':
            swap_seen['exx'] = True
            if swap_depth['exx'] == 0:
                writes |= {'b', 'c', 'd', 'e', 'h', 'l'}
                swap_depth['exx'] = 1
            else:
                writes -= {'b', 'c', 'd', 'e', 'h', 'l'}
                swap_depth['exx'] = 0
            continue

        if (mnemonic == 'ex' and len(ops) == 2
                and ops[0].kind == 'reg16' and ops[0].value == 'af'):
            swap_seen['afx'] = True
            if swap_depth['afx'] == 0:
                writes |= {'a', 'f'}
                swap_depth['afx'] = 1
            else:
                writes -= {'a', 'f'}
                swap_depth['afx'] = 0
            continue

        if (mnemonic == 'ex' and len(ops) == 2
                and ops[0].kind == 'indirect_pair' and ops[0].value == 'sp'
                and ops[1].kind == 'reg16'):
            writes |= _pair_regs(ops[1].value)   # HL/IX/IY becomes stack junk
            continue

        _, inst_writes = get_effects(mnemonic, ops)
        writes |= inst_writes

    writes.discard('sp')
    writes.discard('f')

    # Balanced push/pop pairs (no leftover pushes, no data-load pop):
    # the popped value is the caller's, so the register is preserved.
    for pair, stack in push_stack.items():
        if not stack and pair not in load_pairs:
            preserved |= _pair_regs(pair)
    # Balanced swap pairs restore the swapped-in registers.
    if swap_seen['exx'] and swap_depth['exx'] == 0:
        preserved |= {'b', 'c', 'd', 'e', 'h', 'l'}
    if swap_seen['afx'] and swap_depth['afx'] == 0:
        preserved |= {'a', 'f'}
    preserved.discard('sp')
    preserved.discard('f')

    return writes, preserved


def regs_to_pairs(subregs):
    """Render a sub-register set as conventional names: {'b','c'} -> 'BC',
    a partial pair like {'a'} -> 'A'."""
    remaining = set(subregs)
    names = []
    for pair, subs in ANNOT_PAIR_MAP.items():
        if subs and subs <= remaining:
            names.append(pair)
            remaining -= subs
    for reg in sorted(remaining):
        names.append(reg.upper())
    return ', '.join(names)


def _routine_last_insn(routine):
    """Return (lineno, mnemonic, ops, raw_ops) of the last real instruction."""
    last = None
    for lineno, raw in routine.lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith(';'):
            continue
        mnemonic, ops, raw_ops = parse_instruction(raw)
        if mnemonic is None:
            continue
        last = (lineno, mnemonic, ops, raw_ops)
    return last


def _routine_has_instructions(routine):
    for lineno, raw in routine.lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith(';'):
            continue
        mnemonic, ops, raw_ops = parse_instruction(raw)
        if mnemonic is not None:
            return True
    return False


def check_clobber_annotations(routine_list, routine_map):
    """
    Verify declared Clobbers:/Out: sets against actual register effects.

    For every annotated routine:
      missing  — a register the routine (or its callees, by actual effect)
                 leaves changed but which is declared in neither
                 Clobbers: nor Out:.  Callers reading it read garbage.
      out_dead — an Out: register the body never writes (callers trust
                 it as a result; check 2 wrongly exempts it too).
      unused   — a declared Clobbers: register that neither the body nor
                 any callee actually changes (over-declaration; safe).

    Only ACTUAL effects propagate through calls: a callee's declared
    Clobbers: set is ignored for propagation since it may restore
    registers before returning.  Registers push/pop-protected around a
    call site are not propagated from that call.  Control flow reaching
    the next routine (unconditional tail jp/jr to a routine label, or
    fall-through) merges that routine's effects too.

    Flag F is not tracked (flags are assumed dead across CALL); SP is
    never tracked (CALL/RET contract).  Routines that are stack-exempt
    (never return / shim) or suppressed with `; lint: ignore` on the
    Clobbers: line are skipped.

      In:       routine_list — every parsed Routine (duplicates allowed)
                routine_map  — name -> Routine for call resolution
      Out:      dict with keys missing/out_dead/unused/unannotated/skipped
      Clobbers: none
    """
    # Order routines per file for fall-through successor edges.
    by_file = {}
    for r in routine_list:
        by_file.setdefault(r.filepath, []).append(r)
    next_in_file = {}
    for fp, rs in by_file.items():
        for a, b in zip(rs, rs[1:]):
            next_in_file[id(a)] = b
    obj_by_id = {id(r): r for r in routine_list}

    direct = {}
    preserved = {}
    eff = {}
    calls = {}       # rid -> [(callee rid, protected subregs at call site)]
    succs = {}       # rid -> rid of control-flow successor routine
    jumps = set()    # (rid, target rid) — any jp/jr to a routine label
    indirect_exit = set()   # rids with a terminal indirect jump
    referenced = set()   # routine names reached by call or tail jp

    # Pass 1: structural successors.  An unconditional tail jp/jr to a
    # known routine, or fall-through into the next routine in the file,
    # means that routine's code executes as part of this one.
    for r in routine_list:
        if not r.lines:
            continue
        rid = id(r)
        last = _routine_last_insn(r)
        succ = None
        if last:
            _, mn, ops, raw_ops = last
            if (mn in ('jp', 'jr') and ops
                    and ops[0].kind not in ('cond', 'indirect_pair')
                    and raw_ops):
                tgt = routine_map.get(raw_ops[0].strip())
                if tgt is not None and tgt.lines and tgt is not r:
                    succ = id(tgt)
            elif mn in ('ret', 'reti', 'retn', 'djnz'):
                succ = None
            elif mn in ('jp', 'jr') and ops and ops[0].kind == 'indirect_pair':
                succ = None
                indirect_exit.add(rid)
            else:
                nxt = next_in_file.get(rid)
                if nxt is not None and nxt.lines:
                    succ = id(nxt)
        else:
            # Label-only routine (stubs sharing a tail): falls through
            # into the next routine.
            nxt = next_in_file.get(rid)
            if nxt is not None and nxt.lines:
                succ = id(nxt)
        succs[rid] = succ

    # Pass 2: per-routine facts.
    for r in routine_list:
        if not r.lines:
            continue
        rid = id(r)

        # Chain-folded body: instructions of this routine plus its
        # structural successor chain, so push/pop pairing across a tail
        # jump or fall-through is honoured.  (Only for effect tracking;
        # call sites below stay per-routine.)
        chain_lines = list(r.lines)
        seen = {rid}
        cur = succs.get(rid)
        while cur is not None and cur not in seen:
            seen.add(cur)
            s_routine = obj_by_id[cur]
            chain_lines.extend(s_routine.lines)
            cur = succs.get(cur)
        direct[rid], preserved[rid] = compute_direct_writes(chain_lines)
        eff[rid] = set(direct[rid])

        # Walk the body: call sites (with push-protected regs) + targets.
        depth = {}
        tgts = []
        for _, raw in r.lines:
            stripped = raw.strip()
            if not stripped or stripped.startswith(';'):
                continue
            mnemonic, ops, raw_ops = parse_instruction(raw)
            if mnemonic is None:
                continue
            if mnemonic == 'push' and ops and ops[0].kind == 'reg16':
                pair = ops[0].value
                depth[pair] = depth.get(pair, 0) + 1
            elif mnemonic == 'pop' and ops and ops[0].kind == 'reg16':
                pair = ops[0].value
                depth[pair] = max(0, depth.get(pair, 0) - 1)
            elif mnemonic == 'call':
                m = CALL_TARGET_RE.search(raw)
                if m:
                    tgt = routine_map.get(m.group(1))
                    if tgt is not None and tgt.lines:
                        prot = set()
                        for pair, d in depth.items():
                            if d > 0:
                                prot |= _pair_regs(pair)
                        tgts.append((id(tgt), prot))
                        referenced.add(tgt.name)
            elif mnemonic in ('jp', 'jr') and ops and raw_ops:
                tgt_name = raw_ops[0].strip()
                if ops[0].kind == 'cond':
                    if len(raw_ops) > 1:
                        tgt_name = raw_ops[1].strip()
                    else:
                        tgt_name = None
                elif ops[0].kind == 'indirect_pair':
                    tgt_name = None
                if tgt_name:
                    referenced.add(tgt_name)
                    tgt = routine_map.get(tgt_name)
                    if tgt is not None and tgt.lines and tgt is not r:
                        jumps.add((rid, id(tgt)))
        calls[rid] = tgts

    # Fixpoint: propagate actual callee/successor/jump-target effects,
    # and propagate opaqueness past indirect jumps.
    changed = True
    while changed:
        changed = False
        for rid, tgts in calls.items():
            for tid, prot in tgts:
                if tid == rid:
                    continue
                incoming = eff[tid] - prot
                if not incoming <= eff[rid]:
                    eff[rid] |= incoming
                    changed = True
                if tid in indirect_exit and rid not in indirect_exit:
                    indirect_exit.add(rid)
                    changed = True
        for rid, succ in succs.items():
            if succ is None or succ == rid:
                continue
            if not eff[succ] <= eff[rid]:
                eff[rid] |= eff[succ]
                changed = True
        for src, dst in jumps:
            if not eff[dst] <= eff[src]:
                eff[src] |= eff[dst]
                changed = True

    # Routines that are the structural successor of another routine are
    # shared tails: their Out: annotations document the exit state the
    # jumpers produce, not what the tail itself computes.
    shared_tails = {s for s in succs.values() if s is not None}

    issues = {'missing': [], 'out_dead': [], 'out_note': [], 'unused': [],
              'unannotated': [], 'skipped': []}

    for r in routine_list:
        if not r.lines:
            continue
        rid = id(r)
        if r.stack_exempt:
            issues['skipped'].append(r)
            continue
        if r.clobber_ignore:
            continue
        declared = set(r.clobbers)
        out_regs = {x for x in r.out_regs if x != 'f'}
        if not declared and not out_regs:
            # Only contract-relevant routines matter: reachable by a
            # CALL or tail JP and containing actual instructions.
            if _routine_has_instructions(r) and r.name in referenced:
                issues['unannotated'].append(r)
            continue

        protected = declared | out_regs
        miss = eff[rid] - protected
        if miss:
            body = regs_to_pairs(miss & direct[rid])
            callees = regs_to_pairs(miss - direct[rid])
            parts = []
            if body:
                parts.append(f"{body} (body)")
            if callees:
                parts.append(f"{callees} (callees)")
            issues['missing'].append({'routine': r, 'regs': '; '.join(parts)})

        unused = {reg for reg in (declared - eff[rid]) if reg != 'f'}
        if unused:
            issues['unused'].append(
                {'routine': r, 'regs': regs_to_pairs(unused)})

        # Out registers neither the body, its successor chain, nor any
        # callee actually produces.
        dead_out = out_regs - direct[rid] - eff[rid] - preserved[rid]
        if dead_out:
            entry = {'routine': r, 'regs': regs_to_pairs(dead_out)}
            if rid in shared_tails or rid in indirect_exit:
                # Shared tail (Out produced by the jumpers) or the chain
                # disappears into an indirect jump/dispatch table —
                # reported for information, not as a contract failure.
                issues['out_note'].append(entry)
            else:
                issues['out_dead'].append(entry)

    return issues


# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------

def main():
    argv = sys.argv[1:]
    gate_anno = '--gate-annotations' in argv
    args = [a for a in argv if not a.startswith('--')]

    if not args:
        # Prefer the ZPA-expanded output (authoritative) if present; fall back
        # to src/*.asm for projects that still have hand-written asm.
        files = []
        zpa_out = Path('build/zpa')
        if zpa_out.exists():
            files.extend(sorted(str(f) for f in zpa_out.glob('*.asm')))
        else:
            for d in ['src/bios', 'src/bdos', 'src/ccp']:
                p = Path(d)
                if p.exists():
                    files.extend(sorted(str(f) for f in p.glob('*.asm')))

        # Hand-written sources outside the ZPA pipeline: boot chain, FID and
        # the CP/M utilities.  These used to escape the linter entirely.
        for d in ['src/boot', 'src/fid', 'src/tools']:
            p = Path(d)
            if p.exists():
                files.extend(sorted(str(f) for f in p.glob('*.asm')))
    else:
        files = args

    if not files:
        print("No source files found.", file=sys.stderr)
        return 1

    # Parse all files
    all_routines = {}
    file_routines = {}

    for fp in files:
        routines = parse_file(fp)
        file_routines[fp] = routines
        for r in routines:
            all_routines[r.name] = r

    total = 0

    # ---- Check 1: Stack balance ----
    print("=== Stack Balance ===")
    stack_count = 0
    for fp in files:
        for routine in file_routines.get(fp, []):
            for iss in check_stack_balance_cfg(routine):
                k = iss['kind']
                if k == 'ret':
                    d = iss['depth']
                    sign = '+' if d > 0 else ''
                    print(f"  STACK  {fp}:{iss['lineno']}: "
                          f"{routine.name}: ret with depth {sign}{d} "
                          f"(entry depth {iss['entry_depth']:+d}, "
                          f"{abs(d)} word{'s' if abs(d) != 1 else ''} "
                          f"{'too many pushes' if d > 0 else 'too many pops'})"
                          f"  [{iss['code']}]")
                elif k == 'ambiguous':
                    print(f"  STACK  {fp}:{iss['lineno']}: "
                          f"{routine.name}: label {iss['label']} reached "
                          f"with conflicting stack depths "
                          f"{iss['existing']:+d} vs {iss['arriving']:+d}")
                elif k == 'needs_exempt':
                    print(f"  STACK  {fp}:{iss['lineno']}: "
                          f"{routine.name}: contains {iss['reason']} — "
                          f"add '; lint-exempt: stack'")
                stack_count += 1
    if stack_count == 0:
        print("  OK -- all routines balanced.")
    total += stack_count

    print()

    # ---- Check 2: Register clobber ----
    print("=== Register Clobber After CALL ===")
    clob_count = 0
    for fp in files:
        try:
            with open(fp, errors='replace') as f:
                lines = f.readlines()
        except OSError:
            continue
        # Build per-file routine map: same-file definitions take priority
        local_routines = {r.name: r for r in file_routines.get(fp, [])}
        merged = {**all_routines, **local_routines}
        for iss in check_clobbers_in_file(fp, lines, merged):
            print(f"  CLOBBER {iss['file']}:{iss['call_line']}: "
                  f"call {iss['target']} clobbers {iss['register']}, "
                  f"but line {iss['use_line']} reads it: {iss['code'].strip()}")
            clob_count += 1
    if clob_count == 0:
        print("  OK -- no clobber issues.")
    total += clob_count

    print()

    # ---- Check 3: Dead stores ----
    print("=== Dead Stores (push/write/pop without read) ===")
    dead_count = 0
    for fp in files:
        for routine in file_routines.get(fp, []):
            for iss in check_dead_stores(routine):
                print(f"  DEAD   {fp}:{iss['write_lineno']}: "
                      f"{routine.name}: write to {iss['register']} at line "
                      f"{iss['write_lineno']} is discarded by pop {iss['pair']} "
                      f"at line {iss['pop_lineno']} "
                      f"(pushed at line {iss['push_lineno']})")
                dead_count += 1
    if dead_count == 0:
        print("  OK -- no dead stores found.")
    total += dead_count

    print()

    # ---- Check 4: Clobber annotations ----
    print("=== Clobber Annotations (declared vs actual) ===")
    anno_count = 0
    routine_list = [r for rs in file_routines.values() for r in rs]
    issues = check_clobber_annotations(routine_list, all_routines)
    for iss in issues['missing']:
        r = iss['routine']
        print(f"  ANNO   {r.filepath}:{r.start_lineno}: {r.name}: "
              f"returns with {iss['regs']} changed, not in Clobbers/Out")
        anno_count += 1
    for iss in issues['out_dead']:
        r = iss['routine']
        print(f"  OUT    {r.filepath}:{r.start_lineno}: {r.name}: "
              f"declares Out {iss['regs']} but never produces it")
        anno_count += 1
    for iss in issues['out_note']:
        r = iss['routine']
        print(f"  note   {r.filepath}:{r.start_lineno}: {r.name}: "
              f"declares Out {iss['regs']} never produced here "
              f"(shared tail or indirect dispatch)")
    for iss in issues['unused']:
        r = iss['routine']
        print(f"  note   {r.filepath}:{r.start_lineno}: {r.name}: "
              f"declares {iss['regs']} clobbered but never changed")
    if issues['skipped']:
        print(f"  note: {len(issues['skipped'])} routine(s) skipped "
              f"(lint-exempt: stack)")
    if issues['unannotated']:
        names = sorted(r.name for r in issues['unannotated'])
        shown = ', '.join(names[:15]) + ('...' if len(names) > 15 else '')
        print(f"  note: {len(names)} routine(s) have no Clobbers/Out "
              f"annotation (not verified): {shown}")
    if anno_count == 0:
        print("  OK -- declared clobber sets match actual effects.")
    elif gate_anno:
        total += anno_count
    else:
        print(f"  note: {anno_count} finding(s) not gating the build; "
              f"pass --gate-annotations to enforce")

    print()
    if total:
        print(f"{total} issue(s) found.")
    else:
        print("All checks passed.")

    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
