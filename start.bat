@echo off
title SlipStream Auto Connector
cd /d "%~dp0"

:: Check if PowerShell is available
where powershell >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo ERROR: PowerShell is not available on this system.
    echo Please install PowerShell or run slipstream-connect.ps1 manually.
    pause
    exit /b 1
)

:: Launch with execution policy bypass so users don't need to configure anything
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0slipstream-connect.ps1" %*

:: Keep window open on error
if %ERRORLEVEL% neq 0 (
    echo.
    echo Script exited with error code %ERRORLEVEL%
    pause
)
