#!/usr/bin/env python3
"""Real-world CP/M compatibility suite for the +3 image.

Downloads a curated set of popular CP/M packages, builds a bootable +3 DSK
for each one, boots it through the zx84 MCP server, runs the package's
scripted checks, and reports pass/known-issue/fail.

Downloads are cached under references/realworld/ (gitignored). Built images
and extracted files live under build/realworld/.

Usage:
    python3 tools/zx84_realworld.py --list
    python3 tools/zx84_realworld.py --package zork1
    python3 tools/zx84_realworld.py --package dbase2 supercalc2
    python3 tools/zx84_realworld.py --download-only
    python3 tools/zx84_realworld.py --build-only --package zork1
    python3 tools/zx84_realworld.py --zx84 F:/src/zx/zx84

Some archives (e.g. Zork) use a ZIP compression method Python's zipfile does
not support; the runner falls back to 7z/7za when available.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from zx84_smoke import (  # noqa: E402
    MCP, SmokeError, bank_for_address, find_zx84, label_address)

CACHE = ROOT / "references" / "realworld"
BUILD = ROOT / "build" / "realworld"
MANIFEST = ROOT / "tests" / "realworld" / "manifest.json"
USER_AGENT = "opencpm-plus3-realworld/1.0"


class SetupError(RuntimeError):
    """Download, extraction or DSK-build failure."""


class RunError(RuntimeError):
    """The package booted but did not behave as expected."""


def load_manifest(path: Path = MANIFEST) -> dict:
    if not path.exists():
        raise SetupError(f"manifest not found: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SetupError(f"invalid manifest {path}: {exc}") from exc


def check_base(manifest: dict, pkg: dict | None = None) -> dict[str, Path]:
    base = dict(manifest.get("base", {}))
    # A package may override the boot pair, e.g. to use the 720K layout for
    # software that does not fit the 174K data area of a 180K disc.
    if pkg:
        base.update(pkg.get("base", {}))
    paths = {}
    for key in ("boot", "system"):
        raw = base.get(key)
        if not raw:
            raise SetupError(f"manifest base.{key} is missing")
        p = ROOT / raw
        if not p.exists():
            raise SetupError(f"{p} does not exist; run build.cmd/build.sh first")
        paths[key] = p
    files = []
    for raw in base.get("files", []):
        p = ROOT / raw
        if not p.exists():
            raise SetupError(f"{p} does not exist; run build.cmd/build.sh first")
        files.append(p)
    paths["files"] = files
    return paths


def _download(url: str, dest: Path, refresh: bool) -> Path:
    if dest.exists() and not refresh:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"[realworld] download {url}")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read()
    except Exception as exc:
        raise SetupError(f"download failed: {url}: {exc}") from exc
    dest.write_bytes(data)
    return dest


def _seven_zip() -> str | None:
    return shutil.which("7z") or shutil.which("7za") or shutil.which("7zz")


def _extract_zip(zip_path: Path, members: list[str], dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        names = [n for n in zf.namelist() if not n.endswith("/")]
        lookup = {}
        for name in names:
            lookup.setdefault(Path(name).name.lower(), []).append(name)
        for wanted in members:
            # A member may include a directory prefix to disambiguate
            # archives that carry several copies of the same basename.
            key = wanted.replace("\\", "/").lower()
            if "/" in key:
                matches = [n for n in names
                           if n.lower() == key or
                           n.lower().endswith("/" + key)]
            else:
                matches = lookup.get(Path(wanted).name.lower(), [])
            if not matches:
                available = ", ".join(sorted(Path(n).name for n in names)[:20])
                raise SetupError(
                    f"{wanted} not in {zip_path.name}; sample: {available}")
            if len(matches) > 1:
                raise SetupError(
                    f"{wanted} matches multiple members in {zip_path.name}: {matches}")
            member = matches[0]
            out = dest / Path(member).name
            try:
                out.write_bytes(zf.read(member))
            except NotImplementedError:
                seven = _seven_zip()
                if not seven:
                    raise SetupError(
                        f"{zip_path.name}:{member} uses an unsupported ZIP "
                        "compression method; install 7z/7za")
                result = subprocess.run(
                    [seven, "e", "-y", f"-o{dest}", str(zip_path), member],
                    capture_output=True, text=True)
                if result.returncode != 0 or not out.exists():
                    raise SetupError(
                        f"7z failed for {zip_path.name}:{member}: "
                        f"{result.stderr or result.stdout}")


def _extract_dsk(dsk_path: Path, members: list[str], dest: Path) -> None:
    """Pull CP/M files out of a DSK image into dest.

    CP/M records no byte length, so extracted files are a whole number of
    128-byte records; the trailing 0x1A / 0xE5 padding is harmless because
    CP/M ignores it.
    """
    sys.path.insert(0, str(ROOT / "tools"))
    from mkdsk import DSKImage

    dsk = DSKImage().load(dsk_path)
    dest.mkdir(parents=True, exist_ok=True)
    available = {label.upper(): label for label, _size, _user in dsk.list_files()}
    for wanted in members:
        want = Path(wanted).name.upper()
        if want not in available:
            sample = ", ".join(sorted(available)) or "(empty)"
            raise SetupError(
                f"{dsk_path.name}: {wanted} not in directory; has: {sample}")
        data = dsk.read_cpm_file(want)
        out = dest / want
        _check_cpm_name(out)
        out.write_bytes(data)


def _check_cpm_name(path: Path) -> None:
    stem, dot, ext = path.name.partition(".")
    if len(stem) > 8 or (dot and len(ext) > 3):
        raise SetupError(f"{path.name} is not an 8.3 CP/M filename")


def prepare_package(manifest: dict, pkg: dict, refresh: bool) -> list[Path]:
    pkg_id = pkg["id"]
    cache_dir = CACHE / pkg_id
    files_dir = BUILD / pkg_id / "files"
    if files_dir.exists():
        shutil.rmtree(files_dir)
    files_dir.mkdir(parents=True, exist_ok=True)

    url = pkg.get("url")
    if not url:
        raise SetupError(f"{pkg_id}: no url")
    archive = pkg.get("archive", "zip")
    download_dir = cache_dir
    raw_path = _download(url, download_dir / Path(url).name, refresh)

    if archive == "file":
        name = pkg.get("save_as") or Path(url).name
        out = files_dir / name
        _check_cpm_name(out)
        shutil.copyfile(raw_path, out)
    elif archive == "zip":
        members = pkg.get("members", [])
        if not members:
            raise SetupError(f"{pkg_id}: no members for zip archive")
        _extract_zip(raw_path, members, files_dir)
    elif archive == "dsk":
        # A CP/M disk image: pull the named files out of its directory.
        members = pkg.get("members", [])
        if not members:
            raise SetupError(f"{pkg_id}: no members for dsk archive")
        _extract_dsk(raw_path, members, files_dir)
    else:
        raise SetupError(f"{pkg_id}: unsupported archive type {archive!r}")

    fixtures_dir = ROOT / manifest.get("fixtures", "tests/realworld/fixtures")
    for name in pkg.get("fixtures", []):
        src = fixtures_dir / name
        if not src.exists():
            raise SetupError(f"{pkg_id}: fixture not found: {src}")
        dst = files_dir / name
        if dst.exists():
            raise SetupError(f"{pkg_id}: fixture collides with package file {name}")
        shutil.copyfile(src, dst)

    files = sorted(files_dir.iterdir())
    if not files:
        raise SetupError(f"{pkg_id}: no files prepared")
    for path in files:
        _check_cpm_name(path)
    return files


def build_dsk(manifest: dict, pkg: dict, files: list[Path],
              base: dict[str, Path]) -> Path:
    dsk = BUILD / pkg["id"] / f"{pkg['id']}.dsk"
    dsk.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable, str(ROOT / "tools" / "mkdsk.py"), "create", str(dsk),
        "--format", pkg.get("format", "180k"),
        "--boot", str(base["boot"]),
        "--system", str(base["system"]),
        "--add", *[str(p) for p in base["files"]], *[str(p) for p in files],
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0 or "WARNING" in output or not dsk.exists():
        raise SetupError(
            f"{pkg['id']}: DSK build failed\n{output.strip()}")
    return dsk


class RealWorld:
    def __init__(self, mcp: MCP):
        self.mcp = mcp
        self.cb = label_address("char_buffer")
        self.cb_bank = bank_for_address(self.cb)
        self.scr_cols = label_address("scr_cols")
        # 24x80 logical-screen state (bank 6, outside the image).
        self.mode80 = label_address("mode80")
        self.lg_off = label_address("lg_off")
        self.lg_auto = label_address("lg_auto")
        self.lg_step = label_address("lg_step")
        self.lg_savecols = label_address("lg_savecols")
        self.stl_on = label_address("stl_on")
        self.vp_height = label_address("vp_height")
        self.vp_width = label_address("vp_width")
        self.lg_buf = label_address("LG_BUF")
        self.history: list[str] = []

    def bank(self, addr: int) -> int:
        """RAM bank holding `addr` in system mode.

        `char_buffer` (A000) and the bank-6 scratch area live in bank 6;
        the rest of the image is bank 4.  `LG_BUF` is the exception and is
        always read with an explicit bank of 5.
        """
        return self.cb_bank if 0x8000 <= addr < 0xC000 else 4

    def memory(self, bank: int, addr: int, length: int) -> bytes:
        """Read `length` bytes from `bank` at `addr`.

        The MCP takes the address as an offset *within* a 16K bank, so an
        absolute address (0xA8C1) has to lose its top two bits (0x28C1).
        Masking happens here so callers can keep using label addresses.
        """
        offset = addr & 0x3FFF
        txt = self.mcp.call("read_memory", {
            "address": hex(offset), "length": min(length, 0x4000 - offset),
            "bank": bank})
        out = bytearray()
        for line in txt.splitlines():
            m = re.match(r"^([0-9A-F]{4})\s+((?:[0-9A-F]{2} )+)", line)
            if m:
                out.extend(bytes.fromhex(m.group(2)))
        return bytes(out[:length])

    def byte(self, addr: int, bank: int | None = None) -> int:
        got = self.memory(self.bank(addr) if bank is None else bank, addr, 1)
        return got[0] if got else 0

    def screen_state(self) -> dict:
        """Current terminal geometry, read from the BIOS state bytes."""
        cols = self.byte(self.scr_cols)
        if cols not in (32, 51, 64):
            cols = 51
        return {
            "cols": cols,
            "mode80": bool(self.byte(self.mode80)),
            "lg_off": self.byte(self.lg_off),
            "lg_auto": bool(self.byte(self.lg_auto)),
            "lg_step": self.byte(self.lg_step),
            "save_cols": self.byte(self.lg_savecols),
            "status": bool(self.byte(self.stl_on)),
            # Row 23 (0-based) is the status bar when it is on.
            "text_rows": 23 if self.byte(self.stl_on) else 24,
        }

    def _rows(self, data: bytes, cols: int, rows: int) -> list[str]:
        return ["".join(chr(b) if 32 <= b < 127 else "."
                        for b in data[r * cols:(r + 1) * cols]).rstrip()
                for r in range(rows)]

    def screen(self, rows: int | None = None) -> list[str]:
        """The screen as text, in one of four shapes.

        * 32 / 51 / 64 columns, no 24x80 - `char_buffer` *is* the screen.
        * 24x80 - `char_buffer` mirrors only the visible window
          (`lg_off .. lg_off+cols`), so reading it alone shows the left 51
          columns of an 80-column world.  The full logical screen is in
          LG_BUF at stride 80 in bank 5.

        With the status line on, row 23 is the status bar and only 23 rows
        carry text.
        """
        st = self.screen_state()
        cols, text_rows = st["cols"], st["text_rows"]
        if rows is None:
            rows = text_rows

        if st["mode80"]:
            # The logical screen is the whole 80-column world; char_buffer
            # only mirrors lg_off..lg_off+cols of it.  Return all 80 columns
            # so an assertion finds text whichever half is on show.
            data = self.memory(5, self.lg_buf, 80 * 24)
            if len(data) >= 80 * 24:
                return self._rows(data, 80, min(rows, 24))

        data = self.memory(self.cb_bank, self.cb, cols * 24)
        if len(data) < cols * 24:
            raise RunError(f"short char_buffer read: {len(data)} bytes")
        return self._rows(data, cols, min(rows, 24))

    def window(self) -> list[str]:
        """Only the columns physically on screen right now.

        In 24x80 that is `lg_off .. lg_off+cols` of the logical screen; in
        the narrow modes it is the whole screen.
        """
        st = self.screen_state()
        rows = st["text_rows"]
        if not st["mode80"]:
            return self.screen(rows)
        data = self.memory(5, self.lg_buf, 80 * 24)
        if len(data) < 80 * 24:
            return self.screen(rows)
        off, cols = st["lg_off"], st["cols"]
        lines = self._rows(data, 80, rows)
        return [line[off:off + cols].rstrip() for line in lines]

    def status_line(self) -> str | None:
        """Row 23 when the status bar is enabled, else None.

        The bar is drawn straight into `char_buffer` (see `_stl_mark`), not
        into LG_BUF, so it has to be read from the physical buffer even in
        24x80 mode.  In 24x80 it also carries the '<'/'>' page markers.
        """
        st = self.screen_state()
        if not st["status"]:
            return None
        cols = st["cols"]
        data = self.memory(self.cb_bank, self.cb, cols * 24)
        if len(data) < cols * 24:
            return None
        row = data[23 * cols:24 * cols]
        return "".join(chr(b) if 32 <= b < 127 else "."
                       for b in row).rstrip()

    def text(self) -> str:
        return "\n".join(self.screen())

    def record(self) -> None:
        self.history.extend(self.screen())
        if len(self.history) > 400:
            self.history = self.history[-400:]

    def expect(self, needles: list[str], label: str = "screen") -> None:
        screen = self.text()
        missing = [n for n in needles if n not in screen]
        if missing:
            raise RunError(
                f"{label}: missing {missing!r}\n{screen}")

    def wait_for(self, needles: list[str], frames: int = 500,
                 attempts: int = 6, label: str = "screen") -> str:
        for _ in range(attempts):
            screen = self.text()
            self.record()
            if all(n in screen for n in needles):
                return screen
            self.mcp.call("run", {"frames": frames})
        raise RunError(
            "expected " + ", ".join(repr(n) for n in needles) + f"\n{self.text()}")

    def boot(self, dsk: Path) -> None:
        self.mcp.call("model", {"target": "zx128kplus3"})
        self.mcp.call("load", {"file": str(dsk)})
        self.mcp.call("disk_boot", {})
        self.mcp.call("run", {"frames": 1000})
        self.wait_for(["A>"], frames=500, attempts=8, label="boot")

    def command(self, cmd: str, frames: int = 2000) -> None:
        self.mcp.call("type", {"text": cmd})
        self.mcp.call("key", {"name": "enter"})
        self.mcp.call("run", {"frames": frames})
        self.record()

    def step(self, step: dict) -> None:
        if step.get("wait"):
            # Run without typing: lets a long tool (e.g. Link-80 writing a
            # large .COM) finish before the next command is sent.
            self.mcp.call("run", {"frames": int(step.get("frames", 900))})
            self.record()
        elif "key" in step:
            self.mcp.call("key", {"name": step["key"]})
        elif "text" in step:
            self.mcp.call("type", {"text": step["text"]})
            self.mcp.call("key", {"name": "enter"})
        else:
            raise RunError(f"step has no key/text/wait: {step}")
        self.mcp.call("run", {"frames": int(step.get("frames", 900))})
        self.record()
        if step.get("expect"):
            self.wait_for(step["expect"], label="step")

    def fdc_errors(self) -> list[str]:
        log = self.mcp.call("fdc_log", {})
        return [line for line in log.splitlines()
                if "retry" in line.lower() or "rejected" in line.lower()]


def run_package(rw: RealWorld, pkg: dict, dsk: Path) -> None:
    rw.boot(dsk)
    for setup in pkg.get("setup", []):
        if isinstance(setup, str):
            rw.command(setup, 900)
        else:
            rw.command(setup["command"], int(setup.get("frames", 900)))
            if setup.get("expect"):
                rw.wait_for(setup["expect"], label="setup")
    rw.command(pkg["command"], int(pkg.get("frames", 3000)))
    if pkg.get("expect"):
        rw.wait_for(pkg["expect"], label="start")
    for step in pkg.get("steps", []):
        rw.step(step)
    errors = rw.fdc_errors()
    if errors:
        raise RunError("FDC retry/error lines:\n" + "\n".join(errors[:20]))


def short_screen(rw: RealWorld) -> str:
    rows = [line for line in rw.screen() if line.strip()]
    return "\n".join(rows[-12:])


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true", help="list packages")
    ap.add_argument("--package", nargs="+", metavar="ID",
                    help="package id(s); default: all")
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--model", default="zx128kplus3")
    ap.add_argument("--refresh", action="store_true",
                    help="re-download cached archives")
    ap.add_argument("--download-only", action="store_true")
    ap.add_argument("--build-only", action="store_true")
    ap.add_argument("--strict-known", action="store_true",
                    help="treat known issues as failures")
    args = ap.parse_args(argv)

    try:
        manifest = load_manifest()
        packages = manifest.get("packages", [])
    except SetupError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.list:
        for pkg in packages:
            status = "KNOWN" if pkg.get("known_issue") else "TEST"
            print(f"{pkg['id']:<14} {status:<5} {pkg['title']}")
            print(f"  {pkg['url']}")
        return 0

    selected = packages
    if args.package:
        wanted = set(args.package)
        selected = [p for p in packages if p["id"] in wanted]
        missing = wanted - {p["id"] for p in selected}
        if missing:
            print(f"error: unknown package(s): {', '.join(sorted(missing))}",
                  file=sys.stderr)
            return 2
    if not selected:
        print("error: no packages selected", file=sys.stderr)
        return 2

    try:
        check_base(manifest)
    except SetupError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    prepared: dict[str, list[Path]] = {}
    for pkg in selected:
        try:
            prepared[pkg["id"]] = prepare_package(manifest, pkg, args.refresh)
            print(f"[realworld] prepared {pkg['id']} "
                  f"({len(prepared[pkg['id']])} files)")
        except SetupError as exc:
            print(f"FAIL {pkg['id']}: {exc}", file=sys.stderr)
            return 1

    if args.download_only:
        print(f"[realworld] downloaded {len(prepared)} package(s)")
        return 0

    built: dict[str, Path] = {}
    for pkg in selected:
        try:
            built[pkg["id"]] = build_dsk(
                manifest, pkg, prepared[pkg["id"]], check_base(manifest, pkg))
            print(f"[realworld] built {built[pkg['id']]}")
        except SetupError as exc:
            print(f"FAIL {pkg['id']}: {exc}", file=sys.stderr)
            return 1

    if args.build_only:
        print(f"[realworld] built {len(built)} package(s)")
        return 0

    try:
        mcp = MCP(find_zx84(args.zx84), args.model)
    except (SmokeError, OSError) as exc:
        print(f"error: cannot start zx84 MCP: {exc}", file=sys.stderr)
        return 2

    rw = RealWorld(mcp)
    results = {"PASS": 0, "KNOWN": 0, "FAIL": 0}
    failures: list[str] = []
    try:
        for pkg in selected:
            pkg_id = pkg["id"]
            try:
                run_package(rw, pkg, built[pkg_id])
                results["PASS"] += 1
                print(f"PASS  {pkg_id:<14} {pkg['title']}")
            except RunError as exc:
                if pkg.get("known_issue"):
                    if args.strict_known:
                        results["FAIL"] += 1
                        failures.append(f"{pkg_id}: {exc}")
                        print(f"FAIL  {pkg_id:<14} {pkg['title']} (known issue)")
                    else:
                        results["KNOWN"] += 1
                        print(f"KNOWN {pkg_id:<14} {pkg['title']}")
                        print(f"      {pkg['known_issue']}")
                    continue
                results["FAIL"] += 1
                failures.append(f"{pkg_id}: {exc}")
                print(f"FAIL  {pkg_id:<14} {pkg['title']}")
                print(short_screen(rw))
    finally:
        mcp.close()

    print(f"\n[realworld] {results['PASS']} passed, "
          f"{results['KNOWN']} known issue(s), {results['FAIL']} failed")
    for failure in failures:
        print(f"  {failure.splitlines()[0]}", file=sys.stderr)
    return 1 if results["FAIL"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
