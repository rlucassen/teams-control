Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Resolve teams-agent.ps1 relative to this .vbs file's own
' location, so the repo can be cloned anywhere without editing
' this script.
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
agentScript = fso.BuildPath(scriptDir, "teams-agent.ps1")

' Wait (True) so wscript.exe stays alive for the agent's whole
' lifetime - Task Scheduler tracks wscript.exe directly, so this
' keeps the task's Status/End/Run in sync with the real process
' (a non-waiting Run made Task Scheduler lose track of it).
shell.Run _
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & agentScript & """", _
    0, _
    True