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
python3 tools/jp2jr.py --check      # JP that could be JR fails the build
python3 tools/check_bank5.py         # bank-5 screen code paging discipline

echo "  Splitting system image..."
python3 tools/split_sys.py

echo "  Assembling loader..."
"$SJASMPLUS" --raw=build/loader.bin src/boot/loader.asm
"$SJASMPLUS" --raw=build/loader720.bin -DDS720 src/boot/loader.asm

echo "  Assembling boot sector..."
"$SJASMPLUS" --raw=build/bootsect.bin src/boot/bootsect.asm
python3 tools/patchsum.py build/bootsect.bin
"$SJASMPLUS" --raw=build/bootsect720.bin -DDS720 src/boot/bootsect.asm
python3 tools/patchsum.py build/bootsect720.bin

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
"$SJASMPLUS" --raw=build/fonttest.com src/test/fonttest.asm
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
"$SJASMPLUS" --raw=build/setkeys.com src/tools/setkeys.asm
"$SJASMPLUS" --raw=build/format.com src/tools/format.asm
"$SJASMPLUS" --raw=build/diskcopy.com src/tools/diskcopy.asm
"$SJASMPLUS" --raw=build/stat.com src/tools/stat.asm
"$SJASMPLUS" --raw=build/sysgen.com src/tools/sysgen.asm
"$SJASMPLUS" --raw=build/erase.com src/tools/erase.asm
"$SJASMPLUS" --raw=build/dir.com src/tools/dir.asm
"$SJASMPLUS" --raw=build/device.com src/tools/device.asm

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
# SETKEYS.COM and RESET.KEY are Locomotive Software/Amstrad code ("Developed
# by Locomotive Software Ltd."), which a clean-room CP/M must not ship; the
# DRI harness copies both into its own scratch image instead.
REF_FILES=()
for ref in references/binaries/*.COM references/binaries/*.SUB; do
    case "$ref" in
        */SUBMIT.COM|*/submit.com|*/RENAME.COM|*/rename.com|\
        */NULU11.COM|*/nulu11.com|\
        */PROFILE.SUB|*/profile.sub|\
        */SETKEYS.COM|*/setkeys.com|*/RESET.KEY|*/reset.key|\
        */PMAUTOAE.COM|*/pmautoae.com) continue ;;
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
    build/setkeys.com \
    build/format.com \
    build/diskcopy.com \
    build/stat.com \
    build/sysgen.com build/erase.com build/dir.com build/device.com \
    "${REF_FILES[@]}" \
    $EXTRAFILES

# PMAUTOAE.COM is third-party (Yoshihiko Mino, 1990) and is not committed.
# tools/fetch_pmautoae.py downloads it into the git-ignored references tree;
# when it is there the 720K test image carries it so the smoke runner can
# extract the PMARC/PMEXT toolkit once inside CP/M.
PMAUTOAE_FILE=""
if [ -f references/binaries/PMAUTOAE.COM ]; then
    PMAUTOAE_FILE="references/binaries/PMAUTOAE.COM"
    echo "  PMAUTOAE.COM: $PMAUTOAE_FILE (local copy)"
fi

# The test image is the distribution image plus the on-disk test programs
# and their fixtures, on a 720K PCW DS/DD disk (boot sector and loader built
# with -DDS720) so third-party toolkits fit alongside the system.  Keep the
# two lists in step: distribution files never include a *TEST.COM, and
# everything the smoke runs is on cpm3-test.dsk.
python3 tools/mkdsk.py create build/cpm3-test.dsk \
    --format 720k \
    --boot build/bootsect720.bin \
    --system build/loader720.bin \
    --add build/CPM3.SYS build/CPM3C.SYS build/CCP.COM \
    src/bios/font51.bin src/bios/font32.bin src/bios/font64.bin \
    build/RAMDISK.FID \
    build/date.com build/showxdpb.com build/dump.com build/setdef.com \
    build/submit.com build/screen.com build/set24x80.com \
    build/setkeys.com \
    build/format.com \
    build/diskcopy.com \
    build/stat.com \
    build/sysgen.com build/erase.com build/dir.com build/device.com \
    build/bdostest.com build/xtetest.com \
    build/disktest.com build/termtest.com build/systest.com build/regtest.com \
    build/inptest.com build/biostest.com build/chaintest.com \
    build/fonttest.com \
    build/screenbm.com \
    src/test/smoke.txt src/test/page.txt src/test/smoke.sub \
    src/test/param.sub \
    $PMAUTOAE_FILE \
    "${REF_FILES[@]}" \
    $EXTRAFILES

python3 tools/mkdsk.py create build/cpm3_720.dsk --format 720k \
    --add src/test/hello16.txt

# The 720K distribution: the same CP/M files as build/cpm3.dsk, on a 720K
# PCW DS/DD disc with the -DDS720 boot pair.  It carries nothing extra yet;
# the point is the room (about 570K free vs 57K on the 180K disc) for a later
# larger tool set.  Still no *TEST.COM programs and no PMAUTOAE.COM.
python3 tools/mkdsk.py create build/cpm3-dist720.dsk \
    --format 720k \
    --boot build/bootsect720.bin \
    --system build/loader720.bin \
    --add build/CPM3.SYS build/CPM3C.SYS build/CCP.COM \
    src/bios/font51.bin src/bios/font32.bin src/bios/font64.bin \
    build/RAMDISK.FID \
    build/date.com build/showxdpb.com build/dump.com build/setdef.com \
    build/submit.com build/screen.com build/set24x80.com \
    build/setkeys.com \
    build/format.com \
    build/diskcopy.com \
    build/stat.com \
    build/sysgen.com build/erase.com build/dir.com build/device.com \
    "${REF_FILES[@]}" \
    $EXTRAFILES

echo "  Loader: $(wc -c < build/loader.bin) bytes"
echo "  BIOS blob: $(wc -c < build/bios.bin) bytes"
echo "  CPM3.SYS: $(wc -c < build/CPM3.SYS) bytes"
echo "  CPM3C.SYS: $(wc -c < build/CPM3C.SYS) bytes"
echo "  CCP.COM: $(wc -c < build/CCP.COM) bytes"
echo "  Images: build/cpm3.dsk (distribution), build/cpm3-test.dsk (tests, 720K)"
echo "          build/cpm3-dist720.dsk (720K distribution), build/cpm3_720.dsk (data)"
if [ -f references/binaries/BBCBASIC.COM ]; then
    echo "  BBC BASIC: on the distribution image (local copy)"
fi
if [ -n "$PMAUTOAE_FILE" ]; then
    echo "  PMAUTOAE: on the test image (local copy)"
fi

echo "=== Done ==="
