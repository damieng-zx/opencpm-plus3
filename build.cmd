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

echo   Assembling loader...
%SJASMPLUS% --raw=build\loader.bin src\boot\loader.asm
if errorlevel 1 goto :fail

echo   Assembling boot sector...
%SJASMPLUS% --raw=build\bootsect.bin src\boot\bootsect.asm
if errorlevel 1 goto :fail
python3 tools\patchsum.py build\bootsect.bin
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

echo   Assembling FID modules...
%SJASMPLUS% --raw=build\RAMDISK.FID src\fid\ramdisk.asm
if errorlevel 1 goto :fail

:: Stage 2: Build DSK
echo   Building DSK...
copy /y build\bios.bin build\CPM3.SYS >nul

set REF_BINS=
for %%F in (references\binaries\*.COM references\binaries\*.SUB) do if /I not "%%~nxF"=="SUBMIT.COM" if /I not "%%~nxF"=="RENAME.COM" set REF_BINS=!REF_BINS! %%F

set EXTRA_FILES=
if /I "%~1"=="--add" shift
:collect_extra_files
if "%~1"=="" goto extra_files_done
set EXTRA_FILES=!EXTRA_FILES! %1
shift
goto collect_extra_files
:extra_files_done

python3 tools\mkdsk.py create build\cpm3.dsk --boot build\bootsect.bin --system build\loader.bin --add build\CPM3.SYS build\CCP.COM src\bios\font51.bin src\bios\font32.bin src\bios\font64.bin build\bdostest.com build\xtetest.com build\disktest.com build\termtest.com build\systest.com build\regtest.com build\date.com build\showxdpb.com build\dump.com build\setdef.com build\submit.com build\RAMDISK.FID src\test\smoke.txt src\test\smoke.sub src\test\param.sub !REF_BINS! !EXTRA_FILES!
if errorlevel 1 goto :fail

for %%A in (build\loader.bin) do echo   Loader: %%~zA bytes
for %%A in (build\bios.bin) do echo   CPM3.SYS: %%~zA bytes
for %%A in (build\CCP.COM) do echo   CCP.COM: %%~zA bytes

echo === Done ===
goto :eof

:fail
echo === FAILED ===
exit /b 1
