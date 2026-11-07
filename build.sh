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
python3 tools/z80lint.py --gate-annotations

# Stage 1: Assemble components
echo "  Assembling CCP..."
"$SJASMPLUS" --raw=build/CCP.COM build/zpa/miniccp.asm

echo "  Assembling BIOS..."
"$SJASMPLUS" --raw=build/bios.bin --lst=build/bios.lst -i build/zpa -i src/bios/ -i src/bdos/ -i build/ -DBUILD_NUM="$BUILD_NUM" build/zpa/bios.asm

echo "  Checking layout..."
python3 tools/build_memory_map.py
python3 tools/check_layout.py
python3 tools/check_ccp.py

echo "  Splitting system image..."
python3 tools/split_sys.py

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
"$SJASMPLUS" --raw=build/regtest.com src/test/regtest.asm
"$SJASMPLUS" --raw=build/inptest.com src/test/inptest.asm
"$SJASMPLUS" --raw=build/biostest.com src/test/biostest.asm
"$SJASMPLUS" --raw=build/chaintest.com src/test/chaintest.asm
# SCREENBM is the screen benchmark; tools/screen_bench.py reads the phase
# addresses from its listing, so the --lst is not optional.
"$SJASMPLUS" --raw=build/screenbm.com --lst=build/screenbm.lst src/test/screenbm.asm

echo "  Assembling utilities..."
"$SJASMPLUS" --raw=build/date.com build/zpa/date.asm
"$SJASMPLUS" --raw=build/showxdpb.com src/tools/showxdpb.asm
"$SJASMPLUS" --raw=build/dump.com src/tools/dump.asm
"$SJASMPLUS" --raw=build/setdef.com src/tools/setdef.asm
"$SJASMPLUS" --raw=build/submit.com src/tools/submit.asm
"$SJASMPLUS" --raw=build/screen.com src/tools/screen.asm
"$SJASMPLUS" --raw=build/set24x80.com src/tools/set24x80.asm
"$SJASMPLUS" --raw=build/format.com src/tools/format.asm
"$SJASMPLUS" --raw=build/diskcopy.com src/tools/diskcopy.asm
"$SJASMPLUS" --raw=build/stat.com src/tools/stat.asm
"$SJASMPLUS" --raw=build/sysgen.com src/tools/sysgen.asm

echo "  Assembling FID modules..."
"$SJASMPLUS" --raw=build/RAMDISK.FID src/fid/ramdisk.asm

# Stage 2: Build DSK
echo "  Building DSK..."
EXTRAFILES=""
if [ "$1" = "--add" ]; then
    shift
    EXTRAFILES="$*"
fi

# The reference binaries are third-party files and are not tracked, so a
# fresh clone (including CI) builds without them.  SUBMIT and RENAME are
# excluded because we build SUBMIT and the CCP has a built-in REN; NULU11
# (an LBR library manager) is not needed on the distribution disk.
# PROFILE.SUB is Amstrad's start-up script; it runs here, but auto-running
# it would copy ~10K into the 16K C: RAM disk at every cold boot.
REF_FILES=()
for ref in references/binaries/*.COM references/binaries/*.SUB; do
    case "$ref" in
        */SUBMIT.COM|*/submit.com|*/RENAME.COM|*/rename.com|\
        */NULU11.COM|*/nulu11.com|\
        */PROFILE.SUB|*/profile.sub) continue ;;
    esac
    if [ -f "$ref" ]; then
        REF_FILES+=("$ref")
    fi
done

python3 tools/mkdsk.py create build/cpm3.dsk \
    --boot build/bootsect.bin \
    --system build/loader.bin \
    --add build/CPM3.SYS build/CPM3C.SYS build/CCP.COM \
    src/bios/font51.bin src/bios/font32.bin src/bios/font64.bin \
    build/RAMDISK.FID \
    build/date.com build/showxdpb.com build/dump.com build/setdef.com \
    build/submit.com build/screen.com build/set24x80.com \
    build/format.com \
    build/diskcopy.com \
    build/stat.com \
    build/sysgen.com \
    "${REF_FILES[@]}" \
    $EXTRAFILES

# The test image is the distribution image plus the on-disk test programs
# and their fixtures.  Keep the two lists in step: distribution files never
# include a *TEST.COM, and everything the smoke runs is on cpm3-test.dsk.
python3 tools/mkdsk.py create build/cpm3-test.dsk \
    --boot build/bootsect.bin \
    --system build/loader.bin \
    --add build/CPM3.SYS build/CPM3C.SYS build/CCP.COM \
    src/bios/font51.bin src/bios/font32.bin src/bios/font64.bin \
    build/RAMDISK.FID \
    build/date.com build/showxdpb.com build/dump.com build/setdef.com \
    build/submit.com build/screen.com build/set24x80.com \
    build/format.com \
    build/diskcopy.com \
    build/stat.com \
    build/sysgen.com \
    build/bdostest.com build/xtetest.com \
    build/disktest.com build/termtest.com build/systest.com build/regtest.com \
    build/inptest.com build/biostest.com build/chaintest.com \
    build/screenbm.com \
    src/test/smoke.txt src/test/page.txt src/test/smoke.sub \
    src/test/param.sub \
    "${REF_FILES[@]}" \
    $EXTRAFILES

python3 tools/mkdsk.py create build/cpm3_720.dsk --format 720k \
    --add src/test/hello16.txt

echo "  Loader: $(wc -c < build/loader.bin) bytes"
echo "  BIOS blob: $(wc -c < build/bios.bin) bytes"
echo "  CPM3.SYS: $(wc -c < build/CPM3.SYS) bytes"
echo "  CPM3C.SYS: $(wc -c < build/CPM3C.SYS) bytes"
echo "  CCP.COM: $(wc -c < build/CCP.COM) bytes"
echo "  Images: build/cpm3.dsk (distribution), build/cpm3-test.dsk (tests)"
if [ -f references/binaries/BBCBASIC.COM ]; then
    echo "  BBC BASIC: on the distribution image (local copy)"
fi

echo "=== Done ==="
