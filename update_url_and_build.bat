@echo off
setlocal

echo [1/2] Updating ngrok URL in TickTickView.mc...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update_url.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo Aborted.
    exit /b 1
)

echo.
echo [2/2] Building widget...
call "%~dp0build.bat"
if %ERRORLEVEL% NEQ 0 (
    exit /b 1
)

echo.
echo Done! Run deploy_to_watch.bat to install on the watch.
endlocal
