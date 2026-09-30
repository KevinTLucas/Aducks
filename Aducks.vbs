' Aducks launcher - double-click to run with NO console window at all.
' Starts PowerShell hidden (window style 0) via wscript, which itself has no
' console, so only the Aducks app window appears. Closing the app window exits.
Dim sh, fso, here, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & here & "\src\Main.ps1"""
sh.Run cmd, 0, False
