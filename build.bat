@echo off
setlocal

set SDK=C:\Users\User\AppData\Roaming\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-8.4.1-2026-02-03-e9f77eeaa\bin
set WIDGET_DIR=C:\python 專案\Garmine X Ticktick\widget

echo [1/1] Compiling widget for fr955solar...
"%SDK%\monkeyc.bat" -f "%WIDGET_DIR%\monkey.jungle" -o "%WIDGET_DIR%\bin\widget.prg" -y "%WIDGET_DIR%\developer_key" -d fr955

if %ERRORLEVEL% EQU 0 (
    echo.
    echo BUILD SUCCESS: %WIDGET_DIR%\bin\widget.prg
) else (
    echo.
    echo BUILD FAILED - check errors above
    exit /b 1
)
endlocal
