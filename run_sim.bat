@echo off
setlocal

set SDK=C:\Users\User\AppData\Roaming\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-8.4.1-2026-02-03-e9f77eeaa\bin
set WIDGET_DIR=C:\python 專案\Garmine X Ticktick\widget

echo [1/3] Building...
"%SDK%\monkeyc.bat" -f "%WIDGET_DIR%\monkey.jungle" -o "%WIDGET_DIR%\bin\widget.prg" -y "%WIDGET_DIR%\developer_key" -d fr955
if %ERRORLEVEL% NEQ 0 (
    echo BUILD FAILED
    pause
    exit /b 1
)

echo [2/3] Starting simulator...
start "" "%SDK%\simulator.exe"
echo Waiting 5 seconds for simulator to initialize...
timeout /t 5 /nobreak > nul

echo [3/3] Loading widget into simulator...
"%SDK%\monkeydo.bat" "%WIDGET_DIR%\bin\widget.prg" fr955

endlocal
