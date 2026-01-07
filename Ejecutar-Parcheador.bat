@echo off
title Parcheador de Archivos SQX MQL5
cd /d "%~dp0"
if not exist "Patch-SQX-GV-Disable.ps1" goto error_file

REM Si se arrastro un archivo/carpeta, pasarlo como parametro
if not "%~1"=="" (
    powershell -ExecutionPolicy Bypass -NoProfile -File "Patch-SQX-GV-Disable.ps1" -Path "%~1"
) else (
    powershell -ExecutionPolicy Bypass -NoProfile -File "Patch-SQX-GV-Disable.ps1"
)

if errorlevel 1 goto error_exec
goto end

:error_file
echo.
echo [ERROR] No se encontro el archivo Patch-SQX-GV-Disable.ps1
echo.
pause
exit /b 1

:error_exec
echo.
echo [ERROR] Ocurrio un error al ejecutar el script.
echo.
pause
exit /b 1

:end
exit /b 0
