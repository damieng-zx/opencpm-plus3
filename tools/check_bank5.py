#!/usr/bin/env python3
"""Check the paging discipline of the bank-5 screen code.

Screen routines that only ever run with the screen paged in (mode 2: banks
4,5,6,3) live in bank 5 itself, at SCREEN5_BASE (src/bios/screen5.zpa).
In system mode (4,7,6,3) the same addresses hold the C: RAM disk in bank 7,
so two mistakes are fatal and silent:

  1. Bank-4 or common code reaching a bank-5 label while bank 5 is not
     mapped: a call or jump runs RAM-disk bytes, a load or store reads or
     corrupts the RAM disk.
  2. Bank-5 code calling something that switches banks (anything that
     reaches `write_1ffd`, such as `_page_out`): the return address is then
     in unmapped bank 5.  Bank-5 code may still *jump* to `_page_out` as its
     last act; that returns to the bank-4 caller.

The check reads the assembled listing (build/bios.lst), so it sees real
addresses:

  * Rule 1 - in bank 4 and common memory, any line naming a bank-5 label
    (call, jp, jr, ld, dw, ...) must follow a `call _page_in` in the same
    routine, with no `call _page_out` in between.  A line that is paged in
    by other means can be marked `; paged`.
  * Rule 2 - in bank 5, the target of every `call` must not reach
    `write_1ffd`.  Reachability follows call/jp/jr/djnz edges between
    routines (global labels) and falls through to the next routine when one
    does not end in an unconditional jump or return.

    python3 tools/check_bank5.py          # exit 1 on any violation

The build runs it after assembling the BIOS.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCREEN5_BASE = 0x62C0
SCREEN5_TOP = 0x8000
SINK = "write_1ffd"
PAGE_IN = "_page_in"
PAGE_OUT = "_page_out"

LINE_RX = re.compile(r"^\s*(\d+)\+*\s+([0-9A-F]{4})\s((?:[0-9A-F]{2} )+(?:\.\.\.)?)?\s*(.*)$")
LABEL_RX = re.compile(r"^(\.?[A-Za-z_][\w.]*):")
IDENT_RX = re.compile(r"(?<![\w.$])(\.?[A-Za-z_][\w.]*)")
BRANCH_RX = re.compile(
    r"^(call|jp|jr|djnz)\s+(?:(?:n?z|n?c|p|m|pe|po)\s*,\s*)?([.A-Za-z_][\w.]*)\s*$", re.I)
END_RX = re.compile(r"^(ret|reti|retn|halt)$|^(jp|jr)\s+(\(\s*(hl|ix|iy)\s*\)|[.A-Za-z_][\w.]*)\s*$", re.I)
REGISTERS = {
    "a", "b", "c", "d", "e", "h", "l", "i", "r", "af", "bc", "de", "hl", "sp",
    "ix", "iy", "ixh", "ixl", "iyh", "iyl", "nz", "z", "nc", "p", "m", "pe", "po",
    "af'",
}


class Line:
    __slots__ = ("num", "addr", "nbytes", "code", "raw", "section", "glob", "file")

    def __init__(self, num, addr, nbytes, code, raw, section, glob, file):
        self.num, self.addr, self.nbytes, self.code = num, addr, nbytes, code
        self.raw, self.section, self.glob, self.file = raw, section, glob, file


def code_of(text: str) -> str:
    out, quote = [], None
    for ch in text:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
        elif ch == ";":
            break
        out.append(ch)
    return "".join(out).strip()


def strip_strings(text: str) -> str:
    return re.sub(r"'[^']*'|\"[^\"]*\"", "", text)


def parse(lst: Path):
    """Return (lines, labels, label_section)."""
    lines: list[Line] = []
    labels: dict[str, int] = {}
    label_section: dict[str, str] = {}
    stack = ["file"]
    files = ["?"]
    glob = None
    for raw in lst.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("# file opened:"):
            files.append(raw.split(":", 1)[1].strip())
            continue
        if raw.startswith("# file closed:"):
            if len(files) > 1:
                files.pop()
            continue
        m = LINE_RX.match(raw)
        if not m:
            continue
        if "~" in raw[:24]:
            continue                       # inactive IF branch
        addr = int(m.group(2), 16)
        nbytes = len(m.group(3).replace("...", "").split()) if m.group(3) else 0
        code = code_of(m.group(4))
        low = code.lower()
        if low.startswith("phase "):
            arg = low.split(None, 1)[1].strip()
            stack.append({"0x0000": "bank4", "common_base": "common",
                          "screen5_base": "bank5"}.get(arg, "other"))
            continue
        if low == "dephase":
            if len(stack) > 1:
                stack.pop()
            continue
        section = stack[-1]
        lm = LABEL_RX.match(code)
        if lm:
            name = lm.group(1)
            rest = code[lm.end():].strip()
            if re.match(r"^equ\b", rest, re.I):
                continue                   # constants are not code labels
            if not name.startswith("."):
                glob = name
                full = name
            else:
                full = f"{glob}{name}"
            labels[full] = addr
            label_section[full] = section
            lines.append(Line(int(m.group(1)), addr, 0, "", raw, section, glob, files[-1]))
            code = rest
        if not code:
            continue
        lines.append(Line(int(m.group(1)), addr, nbytes, code, raw, section, glob, files[-1]))
    return lines, labels, label_section


def resolve(name: str, glob: str | None, labels: dict[str, int]) -> str | None:
    if name.startswith("."):
        full = f"{glob}{name}"
        return full if full in labels else None
    return name if name in labels else None


def references(line: Line, labels):
    text = strip_strings(line.code)
    parts = text.split(None, 1)
    if len(parts) < 2:
        return []
    out = []
    for m in IDENT_RX.finditer(parts[1]):
        tok = m.group(1)
        if tok.lower() in REGISTERS:
            continue
        full = resolve(tok, line.glob, labels)
        if full:
            out.append(full)
    return out


def routine_of(full: str) -> str:
    return full.split(".", 1)[0] if not full.startswith(".") else full


def build_graph(lines, labels):
    """Edges between routines (global labels), plus the routines whose own
    code names the sink."""
    edges: dict[str, set[str]] = {}
    order: list[str] = []
    last_code: dict[str, str] = {}
    for ln in lines:
        if ln.glob is None:
            continue
        if ln.glob not in edges:
            edges[ln.glob] = set()
            order.append(ln.glob)
        if not ln.code:
            continue
        last_code[ln.glob] = ln.code
        bm = BRANCH_RX.match(ln.code)
        if bm:
            full = resolve(bm.group(2), ln.glob, labels)
            if full:
                tgt = routine_of(full)
                if tgt != ln.glob:
                    edges[ln.glob].add(tgt)
    # Fall-through into the next routine of the same section.
    by_section: dict[str, list[str]] = {}
    seen = set()
    for ln in lines:
        if ln.glob and ln.glob not in seen:
            seen.add(ln.glob)
            by_section.setdefault(ln.section, []).append(ln.glob)
    for names in by_section.values():
        for a, b in zip(names, names[1:]):
            last = last_code.get(a)
            if last is not None and not END_RX.match(last):
                edges[a].add(b)
    return edges


def reaches_sink(start: str, edges) -> list[str] | None:
    """Path from start to the sink, or None."""
    prev = {start: None}
    todo = [start]
    while todo:
        cur = todo.pop()
        if cur == SINK:
            path = []
            while cur is not None:
                path.append(cur)
                cur = prev[cur]
            return list(reversed(path))
        for nxt in edges.get(cur, ()):
            if nxt not in prev:
                prev[nxt] = cur
                todo.append(nxt)
    return None


def check(lst: Path) -> list[str]:
    lines, labels, label_section = parse(lst)
    errors: list[str] = []
    bank5 = {n for n, s in label_section.items() if s == "bank5"}
    if not bank5:
        return [f"no bank-5 labels found in {lst} (missing PHASE SCREEN5_BASE?)"]
    for n in bank5:
        if not SCREEN5_BASE <= labels[n] < SCREEN5_TOP:
            errors.append(f"{n} at {labels[n]:04X} is outside {SCREEN5_BASE:04X}-{SCREEN5_TOP - 1:04X}")

    # Rule 1: unpaged references from bank 4 / common memory.
    paged = False
    glob = None
    for ln in lines:
        if ln.section not in ("bank4", "common"):
            continue
        if ln.glob != glob:
            glob = ln.glob
            paged = False
        if not ln.code:
            continue
        bm = BRANCH_RX.match(ln.code)
        target = bm.group(2) if bm else None
        refs = [r for r in references(ln, labels) if r in bank5]
        if refs and not paged and "paged" not in ln.raw.split(";", 1)[-1]:
            errors.append(
                f"{ln.file}:{ln.num}: {ln.code}  - names bank-5 "
                f"{', '.join(sorted(set(refs)))} without the screen paged in "
                f"(in {ln.glob}; add `call {PAGE_IN}` first)")
        if bm and bm.group(1).lower() == "call" and target == PAGE_IN:
            paged = True
        elif bm and target == PAGE_OUT:
            paged = False

    # Rule 2: calls from bank 5 must not switch banks.
    edges = build_graph(lines, labels)
    for ln in lines:
        if ln.section != "bank5" or not ln.code:
            continue
        bm = BRANCH_RX.match(ln.code)
        if not bm or bm.group(1).lower() != "call":
            continue
        full = resolve(bm.group(2), ln.glob, labels)
        if not full:
            continue
        path = reaches_sink(routine_of(full), edges)
        if path:
            errors.append(
                f"{ln.file}:{ln.num}: {ln.code}  - bank-5 code calls a routine that "
                f"switches banks ({' -> '.join(path)}); only a final "
                f"`jp {PAGE_OUT}` may leave bank 5")
    return errors


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--lst", type=Path, default=ROOT / "build" / "bios.lst")
    args = ap.parse_args(argv)
    if not args.lst.exists():
        print(f"error: listing not found: {args.lst}", file=sys.stderr)
        return 2
    errors = check(args.lst)
    for e in errors:
        print(e)
    if errors:
        print(f"check_bank5: {len(errors)} paging violation(s)")
        return 1
    print("  bank-5 paging discipline: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
