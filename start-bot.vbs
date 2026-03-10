Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Use the directory containing this script as the bot directory
Dim botDir
botDir = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.CurrentDirectory = botDir

' Start Discord Bot
' Requires: Node.js installed and `node` available in system PATH
WshShell.Run "node bot.js", 0, False

' Start claude-tracker monitor (process scan, token stats, idle alerts)
' Requires: claude-tracker installed via install.sh
Dim trackerPath, bashPath
trackerPath = WshShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.claude-tracker\bin\claude-tracker"

' Resolve bash.exe — prefer Git Bash, fall back to WSL bash
If fso.FileExists("C:\Program Files\Git\bin\bash.exe") Then
    bashPath = "C:\Program Files\Git\bin\bash.exe"
ElseIf fso.FileExists("C:\Windows\System32\bash.exe") Then
    bashPath = "C:\Windows\System32\bash.exe"
Else
    bashPath = "bash"
End If

If fso.FileExists(trackerPath) Then
    WshShell.Run """" & bashPath & """ """ & trackerPath & """ monitor 60", 0, False
End If
