@echo off
setlocal
cd /d "C:\python 專案\Garmine X Ticktick"
echo Starting Flask proxy on port 8765...
.venv\Scripts\python.exe server.py
endlocal
