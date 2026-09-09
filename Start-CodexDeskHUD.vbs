Option Explicit
Dim shell, fso, base, ps, cmd, q
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
q = Chr(34)
base = fso.GetParentFolderName(WScript.ScriptFullName)
ps = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = q & ps & q & " -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & base & "\CodexDeskHUD.ps1" & q
shell.CurrentDirectory = base
shell.Run cmd, 0, False
