@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"

set SJASMPLUS=C:\Apps\sjasmplus.exe

echo === Building CP/M 3.1 ===

:: Build number (counter lives in build/buildnum; not tracked)
for /f %%N in ('python3 tools\buildnum.py') do set BUILD_NUM=%%N
if not defined BUILD_NUM goto :fail
echo   Build #%BUILD_NUM%

:: Stage 0a: ZPA preprocessing
echo   ZPA preprocessing...
if not exist build\zpa mkdir build\zpa
python3 tools\zpa.py src -o build\zpa
if errorlevel 1 goto :fail

:: Stage 0b: Lint
echo   Linting...
python3 tools\z80lint.py --gate-annotations
if errorlevel 1 goto :fail

:: Stage 1: Assemble components
echo   Assembling CCP...
%SJASMPLUS% --raw=build\CCP.COM build\zpa\miniccp.asm
if errorlevel 1 goto :fail

echo   Assembling BIOS...
%SJASMPLUS% --raw=build\bios.bin --lst=build\bios.lst -i build\zpa -i src\bios\ -i src\bdos\ -i build\ -DBUILD_NUM=%BUILD_NUM% build\zpa\bios.asm
if errorlevel 1 goto :fail

echo   Checking layout...
python3 tools\build_memory_map.py
if errorlevel 1 goto :fail
python3 tools\check_layout.py
if errorlevel 1 goto :fail
python3 tools\check_ccp.py
if errorlevel 1 goto :fail

echo   Splitting system image...
python3 tools\split_sys.py
if errorlevel 1 goto :fail

echo   Assembling loader...
%SJASMPLUS% --raw=build\loader.bin src\boot\loader.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\loader720.bin -DDS720 src\boot\loader.asm
if errorlevel 1 goto :fail

echo   Assembling boot sector...
%SJASMPLUS% --raw=build\bootsect.bin src\boot\bootsect.asm
if errorlevel 1 goto :fail
python3 tools\patchsum.py build\bootsect.bin
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\bootsect720.bin -DDS720 src\boot\bootsect.asm
if errorlevel 1 goto :fail
python3 tools\patchsum.py build\bootsect720.bin
if errorlevel 1 goto :fail

echo   Assembling test programs...
%SJASMPLUS% --raw=build\bdostest.com src\test\bdostest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\xtetest.com src\test\xtetest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\disktest.com src\test\disktest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\termtest.com src\test\termtest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\systest.com src\test\systest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\regtest.com src\test\regtest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\inptest.com src\test\inptest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\biostest.com src\test\biostest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\chaintest.com src\test\chaintest.asm
if errorlevel 1 goto :fail

:: SCREENBM is the screen benchmark; tools/screen_bench.py reads the phase
:: addresses from its listing, so the --lst is not optional.
%SJASMPLUS% --raw=build\screenbm.com --lst=build\screenbm.lst src\test\screenbm.asm
if errorlevel 1 goto :fail

echo   Assembling utilities...
%SJASMPLUS% --raw=build\date.com build\zpa\date.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\showxdpb.com src\tools\showxdpb.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\dump.com src\tools\dump.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\setdef.com src\tools\setdef.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\submit.com src\tools\submit.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\screen.com src\tools\screen.asm
%SJASMPLUS% --raw=build\set24x80.com src\tools\set24x80.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\format.com src\tools\format.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\diskcopy.com src\tools\diskcopy.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\stat.com src\tools\stat.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\sysgen.com src\tools\sysgen.asm
if errorlevel 1 goto :fail

echo   Assembling FID modules...
%SJASMPLUS% --raw=build\RAMDISK.FID src\fid\ramdisk.asm
if errorlevel 1 goto :fail

:: Stage 2: Build DSK
echo   Building DSK...

set REF_BINS=
:: RENAME.COM: the CCP's built-in REN covers it.  NULU11.COM: not needed.
:: PROFILE.SUB: Amstrad's start-up script.  It runs here, but auto-running it
:: would copy ~10K into the 16K C: RAM disk at every cold boot.
:: PMAUTOAE.COM: third-party toolkit, test image only (PMAUTOAE_FILE below).
for %%F in (references\binaries\*.COM references\binaries\*.SUB) do if /I not "%%~nxF"=="SUBMIT.COM" if /I not "%%~nxF"=="RENAME.COM" if /I not "%%~nxF"=="NULU11.COM" if /I not "%%~nxF"=="PROFILE.SUB" if /I not "%%~nxF"=="PMAUTOAE.COM" set REF_BINS=!REF_BINS! %%F

set EXTRA_FILES=
if /I "%~1"=="--add" shift
:collect_extra_files
if "%~1"=="" goto extra_files_done
set EXTRA_FILES=!EXTRA_FILES! %1
shift
goto collect_extra_files
:extra_files_done

:: PMAUTOAE.COM is third-party (Yoshihiko Mino, 1990) and is not committed.
:: tools\fetch_pmautoae.py downloads it into the git-ignored references
:: tree; when it is there the test image carries it so the smoke runner can
:: extract the PMARC/PMEXT toolkit once inside CP/M.
set PMAUTOAE_FILE=
if exist references\binaries\PMAUTOAE.COM set PMAUTOAE_FILE=references\binaries\PMAUTOAE.COM
if defined PMAUTOAE_FILE echo   PMAUTOAE.COM: %PMAUTOAE_FILE% (local copy)

:: Two images share the system and the utilities we build:
::   build\cpm3.dsk       distribution - system, built-in utilities and the
::                        local reference binaries (BBC BASIC, ED, PIP, ...)
::   build\cpm3-test.dsk  the same plus the *TEST.COM programs and fixtures
:: The test image is a 720K PCW DS/DD disk (boot sector and loader built
:: with -DDS720), so there is room for third-party toolkits such as
:: PMAUTOAE.COM on the same disk as the system.
python3 tools\mkdsk.py create build\cpm3.dsk --boot build\bootsect.bin --system build\loader.bin --add build\CPM3.SYS build\CPM3C.SYS build\CCP.COM src\bios\font51.bin src\bios\font32.bin src\bios\font64.bin build\RAMDISK.FID build\date.com build\showxdpb.com build\dump.com build\setdef.com build\submit.com build\screen.com build\set24x80.com build\format.com build\diskcopy.com build\stat.com build\sysgen.com !REF_BINS! !EXTRA_FILES!
if errorlevel 1 goto :fail

python3 tools\mkdsk.py create build\cpm3-test.dsk --format 720k --boot build\bootsect720.bin --system build\loader720.bin --add build\CPM3.SYS build\CPM3C.SYS build\CCP.COM src\bios\font51.bin src\bios\font32.bin src\bios\font64.bin build\RAMDISK.FID build\date.com build\showxdpb.com build\dump.com build\setdef.com build\submit.com build\screen.com build\set24x80.com build\format.com build\diskcopy.com build\stat.com build\sysgen.com build\bdostest.com build\xtetest.com build\disktest.com build\termtest.com build\systest.com build\regtest.com build\inptest.com build\biostest.com build\chaintest.com build\screenbm.com src\test\smoke.txt src\test\page.txt src\test\smoke.sub src\test\param.sub !PMAUTOAE_FILE! !REF_BINS! !EXTRA_FILES!
if errorlevel 1 goto :fail

python3 tools\mkdsk.py create build\cpm3_720.dsk --format 720k --add src\test\hello16.txt
if errorlevel 1 goto :fail

:: The 720K distribution: the same CP/M files as build\cpm3.dsk, on a 720K
:: PCW DS/DD disc with the -DDS720 boot pair.  It carries nothing extra yet;
:: the point is the room (about 570K free vs 57K on the 180K disc) for a
:: later larger tool set.  Still no *TEST.COM programs and no PMAUTOAE.COM.
python3 tools\mkdsk.py create build\cpm3-dist720.dsk --format 720k --boot build\bootsect720.bin --system build\loader720.bin --add build\CPM3.SYS build\CPM3C.SYS build\CCP.COM src\bios\font51.bin src\bios\font32.bin src\bios\font64.bin build\RAMDISK.FID build\date.com build\showxdpb.com build\dump.com build\setdef.com build\submit.com build\screen.com build\set24x80.com build\format.com build\diskcopy.com build\stat.com build\sysgen.com !REF_BINS! !EXTRA_FILES!
if errorlevel 1 goto :fail

for %%A in (build\loader.bin) do echo   Loader: %%~zA bytes
for %%A in (build\bios.bin) do echo   BIOS blob: %%~zA bytes
for %%A in (build\CPM3.SYS) do echo   CPM3.SYS:  %%~zA bytes
for %%A in (build\CPM3C.SYS) do echo   CPM3C.SYS: %%~zA bytes
for %%A in (build\CCP.COM) do echo   CCP.COM: %%~zA bytes
echo   Images: build\cpm3.dsk (distribution), build\cpm3-test.dsk (tests)
echo           build\cpm3-dist720.dsk (720K distribution), build\cpm3_720.dsk (data)
if exist references\binaries\BBCBASIC.COM echo   BBC BASIC: on the distribution image (local copy)
if defined PMAUTOAE_FILE echo   PMAUTOAE: on the test image (local copy)

echo === Done ===
goto :eof

:fail
echo === FAILED ===
exit /b 1
