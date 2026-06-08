@echo off
title SQX MQL5 File Patcher
cd /d "%~dp0"
if not exist "Patch-SQX-GV-Disable.ps1" goto error_file

REM If a file/folder was dragged, pass it as a parameter
if not "%~1"=="" (
    powershell -ExecutionPolicy Bypass -NoProfile -File "Patch-SQX-GV-Disable.ps1" -Path "%~1"
) else (
    powershell -ExecutionPolicy Bypass -NoProfile -File "Patch-SQX-GV-Disable.ps1"
)

if errorlevel 1 goto error_exec
goto end

:error_file
echo.
echo [ERROR] Could not find the file Patch-SQX-GV-Disable.ps1
echo.
pause
exit /b 1

:error_exec
echo.
echo [ERROR] An error occurred while running the script.
echo.
pause
exit /b 1

:end
exit /b 0
