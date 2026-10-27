#!/bin/bash
# Build CP/M 3.1 for Spectrum +3
# Usage: ./build.sh [--add FILE ...]

set -e

cd "$(dirname "$0")"

SJASMPLUS="${SJASMPLUS:-sjasmplus}"

echo "=== Building CP/M 3.1 ==="

# Auto-bump build number
python3 -c "
import re
f = open('src/bios/bios.zpa', 'r+')
content = f.read()
m = re.search(r'BUILD_NUM equ (\d+)', content)
n = int(m.group(1)) + 1
content = content.replace(f'BUILD_NUM equ {m.group(1)}', f'BUILD_NUM equ {n}')
f.seek(0); f.write(content); f.truncate()
print(f'  Build #{n}')
"

# Stage 0a: ZPA preprocessing — expand any .zpa files in src/ to build/zpa/
ZPA_FILES=$(find src -name '*.zpa' 2>/dev/null | sort)
if [ -n "$ZPA_FILES" ]; then
    echo "  ZPA preprocessing..."
    python3 tools/zpa.py $ZPA_FILES -o build/zpa
fi

# Stage 0b: Lint (runs on the ZPA-expanded output, which is authoritative)
echo "  Linting..."
python3 tools/z80lint.py

# Stage 1: Assemble components
echo "  Assembling CCP..."
"$SJASMPLUS" --raw=build/miniccp.bin build/zpa/miniccp.asm

echo "  Assembling BIOS..."
"$SJASMPLUS" --raw=build/bios.bin --lst=build/bios.lst -i build/zpa -i src/bios/ -i src/bdos/ -i build/ build/zpa/bios.asm

echo "  Checking layout..."
python3 tools/build_memory_map.py
python3 tools/check_layout.py

echo "  Assembling loader..."
"$SJASMPLUS" --raw=build/loader.bin src/boot/loader.asm

echo "  Assembling boot sector..."
"$SJASMPLUS" --raw=build/bootsect.bin src/boot/bootsect.asm
python3 tools/patchsum.py build/bootsect.bin

echo "  Assembling test programs..."
"$SJASMPLUS" --raw=build/bdostest.com src/test/bdostest.asm
"$SJASMPLUS" --raw=build/xtetest.com src/test/xtetest.asm
"$SJASMPLUS" --raw=build/disktest.com src/test/disktest.asm
"$SJASMPLUS" --raw=build/termtest.com src/test/termtest.asm
"$SJASMPLUS" --raw=build/stktest.com src/test/stacktest.asm

echo "  Assembling utilities..."
"$SJASMPLUS" --raw=build/date.com build/zpa/date.asm
"$SJASMPLUS" --raw=build/showxdpb.com src/tools/showxdpb.asm
"$SJASMPLUS" --raw=build/dump.com src/tools/dump.asm
"$SJASMPLUS" --raw=build/setdef.com src/tools/setdef.asm

echo "  Assembling FID modules..."
"$SJASMPLUS" --raw=build/RAMDISK.FID src/fid/ramdisk.asm

# Stage 2: Build DSK
echo "  Building DSK..."
EXTRAFILES=""
if [ "$1" = "--add" ]; then
    shift
    EXTRAFILES="$*"
fi

# Always add CPM3.SYS (the BIOS binary) as a CP/M file
python3 -c "
import shutil, sys
shutil.copy('build/bios.bin', 'build/CPM3.SYS')
print(f'  CPM3.SYS: {__import__(\"os\").path.getsize(\"build/CPM3.SYS\")} bytes')
"

python3 tools/mkdsk.py create build/cpm3.dsk \
    --boot build/bootsect.bin \
    --system build/loader.bin \
    --add build/CPM3.SYS src/bios/font51.bin src/bios/font32.bin \
    build/bdostest.com build/xtetest.com \
    build/disktest.com build/termtest.com build/stktest.com \
    build/date.com build/showxdpb.com build/dump.com build/setdef.com \
    build/RAMDISK.FID \
    references/binaries/*.COM references/binaries/*.SUB \
    $EXTRAFILES

echo "  Loader: $(wc -c < build/loader.bin) bytes"
echo "  CPM3.SYS: $(wc -c < build/bios.bin) bytes"

echo "=== Done ==="
