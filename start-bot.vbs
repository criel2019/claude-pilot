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
Dim trackerPath
trackerPath = WshShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.claude-tracker\bin\claude-tracker"
WshShell.Run "bash """ & trackerPath & """ monitor 60", 0, False
