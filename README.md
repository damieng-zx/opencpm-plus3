# OpenCP/M +3

Clean-room CP/M 3.1 implementation for the ZX Spectrum +3.

All code is original Z80 assembly — the BIOS, BDOS, CCP, drivers, and tools are written from scratch.

## Status

> Currently experimental, not ready for any kind of real use.

### Features

- **51×24 and 32x24 screen modes**
- **Full BDOS** with console I/O and file operations
- **uPD765A FDC driver** with 512→128 byte sector deblocking
- **Banked memory** — TPA mode (~62K user space) and system mode with bank switching
- **MiniCCP** with built-in DIR, TYPE, VER, HELP, DUMP commands and `.COM` loading
- **Z80 linter** (`z80lint.py`) that validates stack balance and register clobbering across all return paths
- **ZPA preprocessor** for source-level abstractions on top of Z80 assembly
- **RTC clock** although stalls during disk-IO like Locomotive version

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

### Test suites
- bdostest.com - Testing the CP/M BDOS functions 1-35
- termtest.com - Testing the terminal emulation/ESC codes
- disktest.com - Testing file and disk operations
  
### Wishlist/TODO

- .SUB execution
- Format command
- RAMdisk support
- 64-column mode
- User area/file spec on command lines

### Out of scope

- Serial I/O
- Printer/parallel I/O
- Disckit.com

## Technical

### Memory Layout

| Range | TPA Mode | System Mode |
|-------|----------|-------------|
| 0000–00FF | Page zero (vectors) | Bank 4 — BIOS, BDOS, drivers |
| 0100–F9FF | ~63K user TPA | |
| FA00–FFFF | Common stub (bank 3) | Common stub (bank 3) |

Banking is controlled via port `0x1FFD`. See [AGENTS.md](AGENTS.md) for full architectural details.

### Building

Requires [sjasmplus](https://github.com/z00m128/sjasmplus) and Python 3.

```bash
# Lint the source
python3 tools/z80lint.py

# Build the disk image
build.cmd

# Build with additional files
build.cmd --add FILE ...
```

Output: `build/cpm3.dsk` — a standard +3 disk image ready for emulation.

### Testing

Use the [zx84](https://github.com/nickvdp/zx84) MCP emulator:

```
model +3
load build/cpm3.dsk
disk_boot
run 1000
```

zx84 snapshots can also be saved and loaded through MCP. After reaching a clean
prompt, use `save build/prompt.szx`; later use `load build/prompt.szx` to resume
testing from that prompt without rebooting the disk image.

### Project Structure

```
src/
  boot/     Boot sector and stage-2 loader
  bios/     BIOS, screen/keyboard/FDC drivers, common memory stub
  bdos/     BDOS (console + file I/O)
  ccp/      MiniCCP command processor
  util/     CP/M utilities (.COM programs)
  test/     Test programs
tools/      Build tools (mkdsk, zpa preprocessor, linter, patchsum)
docs/       API reference, filesystem documentation
```

## Documentation

- [CP/M 3.1 BDOS API Reference](docs/API.md)
- [Filesystem Layout](docs/filesystem.md)
- [zx84 MCP Smoke Test](docs/mcp-smoke-test.md)

## License

This project is licensed under the [MIT License](LICENSE).
