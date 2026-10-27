# OpenCP/M +3

Clean-room CP/M 3.1 implementation for the ZX Spectrum +3.

All code is original Z80 assembly — the BIOS, BDOS, CCP, drivers, and tools are written from scratch.

## Status

> Currently experimental, not ready for any kind of real use.

### Features

- **51x24 and 32x24 screen modes**
- **BDOS** with console I/O, file operations and extended functions (F46 free-space accounting is a stub)
- **uPD765A FDC driver** with 512->128 byte sector deblocking
- **Banked memory** - TPA mode (~61K user space) and system mode with bank switching
- **MiniCCP** with built-in DIR, TYPE, HELP, SCREEN commands and `.COM` loading
- **Z80 linter** (`z80lint.py`) that validates stack balance and register clobbering across all return paths
- **ZPA preprocessor** for source-level abstractions on top of Z80 assembly
- **RTC clock** (runs during TPA execution; interrupts are briefly disabled during FDC access)

### Compatibility

- BBCBASIC.com
- Mallard BASIC
- Ed
- Pip
- B: drive
- Custom formats (CPC + XDPB formats; PCW 720K is detected and shown by
  SHOWXDPB, but 16-bit block file I/O is not implemented)
- Various other simple CP/M tools

### Tools

- Date.com with Y2K compliance
- Dump.com with screen-width adaption
- Showxdpb.com - Show the eXtended Disk Parameter Blocks
- Submit.com - Create the `$$$.SUB` command file drained by the CCP

### Test suites
- bdostest.com - BDOS function tests (F1-F35, F104)
- disktest.com - File, directory, extent and SCB tests (T1-T22)
- termtest.com - Terminal emulation/ESC codes
- xtetest.com - XBIOS/TE probe
- systest.com - Stack/MOVE/clock, page-zero, TAB and delimiter checks
  
### Wishlist/TODO

- Format command
- 64-column mode
- Richer command-line file specs
- F46 real free-space accounting
- 16-bit block formats (PCW 720K file I/O)

### Out of scope

- Serial I/O
- Printer/parallel I/O
- Disckit.com

## Technical

### Memory Layout

| Range | TPA Mode | System Mode |
|-------|----------|-------------|
| 0000–00FF | Page zero (vectors) | Bank 4 — BIOS, BDOS, drivers |
| 0100–F5FF | ~61K user TPA | |
| F600–FFFF | Common stub (bank 3) | Common stub (bank 3) |

Banking is controlled via port `0x1FFD`. See [AGENTS.md](AGENTS.md) for full architectural details.

### Building

Requires [sjasmplus](https://github.com/z00m128/sjasmplus) and Python 3.

```bash
# Lint the source
python3 tools/z80lint.py

# Build the disk image
build.cmd

# or, on a Unix-like shell
./build.sh

# Build with additional files
build.cmd --add FILE ...
```

Output: `build/cpm3.dsk` — a standard +3 disk image ready for emulation.

The third-party binaries under `references/binaries/` are untracked and
optional. When present they are added automatically; a fresh clone (and CI)
builds a source-only disk, and the smoke runner skips the checks that need
them.

### Testing

Use the [zx84](https://github.com/damieng-zx/zx84) MCP emulator:

```
model +3
load build/cpm3.dsk
disk_boot
run 1000
```

zx84 snapshots can also be saved and loaded through MCP. After reaching a clean
prompt, use `save build/prompt.szx`; later use `load build/prompt.szx` to resume
testing from that prompt without rebooting the disk image.

The automated smoke runner boots the image, runs `SYSTEST`, `DISKTEST`,
`BDOSTEST` and the main CCP flows, and asserts the screen buffer:

```bash
python3 tools/zx84_smoke.py
python3 tools/zx84_negative.py   # corrupted images must not boot
```

### Project Structure

```
src/
  boot/     Boot sector and stage-2 loader
  bios/     BIOS, screen/keyboard/FDC drivers, common memory stub
  bdos/     BDOS (console + file I/O)
  ccp/      MiniCCP command processor
  fid/      RAM disk FID module
  util/     CP/M utilities (.COM programs)
  test/     Test programs
tools/      Build tools (mkdsk, zpa preprocessor, linter, patchsum)
docs/       API reference, filesystem documentation
```

## Documentation

- [CP/M 3.1 BDOS API Reference](docs/API.md)
- [Filesystem Layout](docs/filesystem.md)
- [XBIOS/TE Interface](docs/cpm-plus-xbios.md)
- [CI with zx84](docs/ci.md)
- [zx84 MCP Smoke Test](docs/mcp-smoke-test.md)

## License

This project is licensed under the [MIT License](LICENSE).
