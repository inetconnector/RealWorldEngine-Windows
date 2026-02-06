@echo off
setlocal
cd /d "%~dp0"

REM Run the PowerShell bootstrap minimized so the GUI remains the primary window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0rwe_runner.ps1" > out.log
endlocal
