@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "RUNNER=%SCRIPT_DIR%rwe_runner.ps1"
set "INSTALLER=%SCRIPT_DIR%rwe_installer.ps1"
set "VENV_PY=%SCRIPT_DIR%venv\Scripts\python.exe"
set "BACKEND_FILE=%SCRIPT_DIR%rwe_backend.txt"
set "APP_RWE=%SCRIPT_DIR%app\rwe_v04.py"
set "APP_EDITOR=%SCRIPT_DIR%app\rwe_config_editor.py"
set "CACHE_DIR=%SCRIPT_DIR%cache"
set "VENV_DIR=%SCRIPT_DIR%venv"

set "NEEDS_INSTALL=0"
if not exist "%VENV_PY%" set "NEEDS_INSTALL=1"
if not exist "%BACKEND_FILE%" set "NEEDS_INSTALL=1"
if not exist "%APP_RWE%" set "NEEDS_INSTALL=1"
if not exist "%APP_EDITOR%" set "NEEDS_INSTALL=1"

if "%NEEDS_INSTALL%"=="1" (
  echo Installation required. Cleaning venv/cache and running installer...
  if exist "%VENV_DIR%" rmdir /s /q "%VENV_DIR%"
  if exist "%CACHE_DIR%" rmdir /s /q "%CACHE_DIR%"
  start "" /min /wait powershell -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%"
  if errorlevel 1 (
    echo Installer failed. Aborting.
    exit /b 1
  )
)

start "" /min /wait powershell -NoProfile -ExecutionPolicy Bypass -File "%RUNNER%"
endlocal
