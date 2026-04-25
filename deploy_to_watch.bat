@echo off
setlocal

set PRG=C:\python 專案\Garmine X Ticktick\widget\bin\widget.prg

if not exist "%PRG%" (
    echo ERROR: widget.prg not found. Run build.bat first.
    exit /b 1
)

echo Searching for Garmin watch (USB storage)...
set FOUND=0
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\GARMIN\Apps" (
        echo Found Garmin at %%d:\
        echo Copying widget.prg...
        copy /Y "%PRG%" "%%d:\GARMIN\Apps\"
        echo.
        echo DONE. Now:
        echo   1. Safely eject the watch from Windows
        echo   2. Disconnect USB
        echo   3. On the watch: swipe up to widget list, find TickTick
        set FOUND=1
        goto :end
    )
)
:end
if "%FOUND%"=="0" (
    echo Garmin watch not found.
    echo Make sure the watch is connected via USB and in File Transfer / MTP mode.
    echo On fr955: hold UP button - Settings - System - USB Mode - Garmin/MTP
)
endlocal
