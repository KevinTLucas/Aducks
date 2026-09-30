@echo off
REM Aducks launcher. Delegates to Aducks.vbs which runs PowerShell fully hidden
REM (no console). For a truly flash-free launch, double-click Aducks.vbs instead.
wscript.exe "%~dp0Aducks.vbs"
