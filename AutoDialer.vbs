Option Explicit

' Hidden launcher for AutoDialer.ps1.
' Task Scheduler or the Startup folder starts this file with wscript.exe.
Dim fso, shell, baseDir, scriptPath, powerShell, commandLine

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = baseDir & "\AutoDialer.ps1"

If Not fso.FileExists(scriptPath) Then
    WScript.Quit 2
End If

powerShell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
commandLine = """" & powerShell & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"

' 0 = hidden window, False = do not wait.
shell.Run commandLine, 0, False
WScript.Quit 0
