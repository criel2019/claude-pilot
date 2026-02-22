Set WshShell = CreateObject("WScript.Shell")

' Discord Bot 시작
WshShell.CurrentDirectory = "C:\Users\User\Desktop\작업 폴더\Claude Tools"
WshShell.Run """C:\Program Files\nodejs\node.exe"" bot.js", 0, False

' Monitor 시작 (프로세스 스캔, 토큰 스냅샷, idle 알림)
WshShell.Run "bash ""C:\Users\User\.claude-tracker\bin\claude-tracker"" monitor 60", 0, False
