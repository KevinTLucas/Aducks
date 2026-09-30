@echo off
REM Aducks launcher - double-click to run. Starts PowerShell minimized and
REM hidden, then this console closes right away (it may flash for a moment).
REM For a console with logs, use Aducks-debug.bat instead.
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\Main.ps1"
