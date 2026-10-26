@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"

set SJASMPLUS=C:\Apps\sjasmplus.exe

echo === Building CP/M 3.1 ===

:: Auto-bump build number
python3 -c "import re; f=open('src/bios/bios.zpa','r+'); c=f.read(); m=re.search(r'BUILD_NUM equ (\d+)',c); n=int(m.group(1))+1; c=c.replace(f'BUILD_NUM equ {m.group(1)}',f'BUILD_NUM equ {n}'); f.seek(0); f.write(c); f.truncate(); print(f'  Build #{n}')"

:: Stage 0a: ZPA preprocessing
echo   ZPA preprocessing...
if not exist build\zpa mkdir build\zpa
python3 tools\zpa.py src\bios\bios.zpa src\bios\common.zpa src\bios\fdc765.zpa src\bios\keyboard.zpa src\bios\screen.zpa src\bdos\bdos.zpa src\ccp\miniccp.zpa src\util\date.zpa -o build\zpa
if errorlevel 1 goto :fail

:: Stage 0b: Lint
echo   Linting...
python3 tools\z80lint.py

:: Stage 1: Assemble components
echo   Assembling CCP...
%SJASMPLUS% --raw=build\miniccp.bin build\zpa\miniccp.asm
if errorlevel 1 goto :fail

echo   Assembling BIOS...
%SJASMPLUS% --raw=build\bios.bin --lst=build\bios.lst -i build\zpa -i src\bios\ -i src\bdos\ -i build\ build\zpa\bios.asm
if errorlevel 1 goto :fail

echo   Checking layout...
python3 tools\build_memory_map.py
if errorlevel 1 goto :fail
python3 tools\check_layout.py
if errorlevel 1 goto :fail

echo   Assembling loader...
%SJASMPLUS% --raw=build\loader.bin src\boot\loader.asm
if errorlevel 1 goto :fail

echo   Assembling boot sector...
%SJASMPLUS% --raw=build\bootsect.bin src\boot\bootsect.asm
if errorlevel 1 goto :fail
python3 tools\patchsum.py build\bootsect.bin

echo   Assembling test programs...
%SJASMPLUS% --raw=build\bdostest.com src\test\bdostest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\xtetest.com src\test\xtetest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\disktest.com src\test\disktest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\termtest.com src\test\termtest.asm
if errorlevel 1 goto :fail
%SJASMPLUS% --raw=build\stacktest.com src\test\stacktest.asm
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

echo   Assembling FID modules...
%SJASMPLUS% --raw=build\RAMDISK.FID src\fid\ramdisk.asm
if errorlevel 1 goto :fail

:: Stage 2: Build DSK
echo   Building DSK...
copy /y build\bios.bin build\CPM3.SYS >nul

set REF_BINS=
for %%F in (references\binaries\*.COM references\binaries\*.SUB) do set REF_BINS=!REF_BINS! %%F

set EXTRA_FILES=
if /I "%~1"=="--add" shift
:collect_extra_files
if "%~1"=="" goto extra_files_done
set EXTRA_FILES=!EXTRA_FILES! %1
shift
goto collect_extra_files
:extra_files_done

python3 tools\mkdsk.py create build\cpm3.dsk --boot build\bootsect.bin --system build\loader.bin --add build\CPM3.SYS src\bios\font51.bin src\bios\font32.bin build\bdostest.com build\xtetest.com build\disktest.com build\termtest.com build\stacktest.com build\date.com build\showxdpb.com build\dump.com build\setdef.com build\RAMDISK.FID !REF_BINS! !EXTRA_FILES!
if errorlevel 1 goto :fail

for %%A in (build\loader.bin) do echo   Loader: %%~zA bytes
for %%A in (build\bios.bin) do echo   CPM3.SYS: %%~zA bytes

echo === Done ===
goto :eof

:fail
echo === FAILED ===
exit /b 1
