#!/bin/bash
# Build CP/M 3.1 for Spectrum +3
# Usage: ./build.sh [--add FILE ...]

set -e

cd "$(dirname "$0")"

SJASMPLUS="${SJASMPLUS:-sjasmplus}"

echo "=== Building CP/M 3.1 ==="

# Build number (counter lives in build/buildnum; not tracked)
BUILD_NUM=$(python3 tools/buildnum.py)
echo "  Build #$BUILD_NUM"

# Stage 0a: ZPA preprocessing — expand every .zpa under src/ to build/zpa/
echo "  ZPA preprocessing..."
python3 tools/zpa.py src -o build/zpa

# Stage 0b: Lint (runs on the ZPA-expanded output, which is authoritative)
echo "  Linting..."
python3 tools/z80lint.py

# Stage 1: Assemble components
echo "  Assembling CCP..."
"$SJASMPLUS" --raw=build/miniccp.bin build/zpa/miniccp.asm

echo "  Assembling BIOS..."
"$SJASMPLUS" --raw=build/bios.bin --lst=build/bios.lst -i build/zpa -i src/bios/ -i src/bdos/ -i build/ -DBUILD_NUM="$BUILD_NUM" build/zpa/bios.asm

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
"$SJASMPLUS" --raw=build/systest.com src/test/systest.asm

echo "  Assembling utilities..."
"$SJASMPLUS" --raw=build/date.com build/zpa/date.asm
"$SJASMPLUS" --raw=build/showxdpb.com src/tools/showxdpb.asm
"$SJASMPLUS" --raw=build/dump.com src/tools/dump.asm
"$SJASMPLUS" --raw=build/setdef.com src/tools/setdef.asm
"$SJASMPLUS" --raw=build/submit.com src/tools/submit.asm

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

# The reference binaries are third-party files and are not tracked, so a
# fresh clone (including CI) builds without them.
REF_FILES=()
for ref in references/binaries/*.COM references/binaries/*.SUB; do
    case "$ref" in
        */SUBMIT.COM|*/submit.com) continue ;;
    esac
    if [ -f "$ref" ]; then
        REF_FILES+=("$ref")
    fi
done

python3 tools/mkdsk.py create build/cpm3.dsk \
    --boot build/bootsect.bin \
    --system build/loader.bin \
    --add build/CPM3.SYS src/bios/font51.bin src/bios/font32.bin \
    build/bdostest.com build/xtetest.com \
    build/disktest.com build/termtest.com build/systest.com \
    build/date.com build/showxdpb.com build/dump.com build/setdef.com \
    build/submit.com build/RAMDISK.FID src/test/smoke.txt src/test/smoke.sub \
    src/test/param.sub \
    "${REF_FILES[@]}" \
    $EXTRAFILES

echo "  Loader: $(wc -c < build/loader.bin) bytes"
echo "  CPM3.SYS: $(wc -c < build/bios.bin) bytes"

echo "=== Done ==="
