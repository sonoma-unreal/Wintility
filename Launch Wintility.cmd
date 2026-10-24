@echo off
rem Wintility launcher. Double-click this file to start Wintility.
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File .\Wintility.ps1
if errorlevel 1 pause
