@echo off
REM ===================================================================
REM  sync_to_mt5.bat
REM  Pulls the latest EAs from GitHub and copies every .mq5 file in
REM  MQL5\Experts straight into your MetaTrader 5 terminal's Experts
REM  folder(s), so they are ready to compile in MetaEditor.
REM
REM  Usage: just double-click this file.
REM ===================================================================
setlocal enabledelayedexpansion

REM --- Move to the repository root (this script lives in \tools).
cd /d "%~dp0.."

echo.
echo === Pulling latest changes from GitHub ===
git pull
if errorlevel 1 (
    echo.
    echo  ^!^! git pull failed. Check your internet / git setup and retry.
    echo.
    pause
    exit /b 1
)

set "SRC=%~dp0..\MQL5\Experts"
set "found=0"

echo.
echo === Copying EAs into MetaTrader 5 Experts folders ===
for /d %%T in ("%APPDATA%\MetaQuotes\Terminal\*") do (
    if exist "%%T\MQL5\Experts" (
        echo  -^> %%T\MQL5\Experts
        copy /Y "%SRC%\*.mq5" "%%T\MQL5\Experts\" >nul
        set "found=1"
    )
)

if "!found!"=="0" (
    echo.
    echo  ^!^! No MetaTrader 5 terminal folders were found under:
    echo     %APPDATA%\MetaQuotes\Terminal
    echo     ^(Open MT5 at least once, or copy the .mq5 by hand from MQL5\Experts.^)
)

echo.
echo === Done ===
echo Now open MetaEditor ^(F4 in MT5^), select the EA, and press F7 to compile.
echo Then refresh Navigator -^> Expert Advisors in MT5.
echo.
pause
