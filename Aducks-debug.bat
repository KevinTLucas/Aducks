@echo off
REM Debug launcher — keeps the console open and turns on verbose logging so you
REM can see capture/CDP progress and any errors.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -Command "$VerbosePreference='Continue'; & '%~dp0src\Main.ps1' -Verbose"
