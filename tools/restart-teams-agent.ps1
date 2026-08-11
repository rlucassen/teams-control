# ============================================================
# Restart-TeamsAgent.ps1
#
# Stops and/or restarts the Teams Companion Agent.
#
# teams-agent.ps1 normally runs as a detached powershell.exe
# process launched by start-teams-agent.vbs (e.g. via Task
# Scheduler). Once wscript.exe exits, neither that process nor
# its child ssh.exe transport is tracked by Task Scheduler
# anymore, so they can't be stopped by task name - both have to
# be found by matching command line / parent PID instead.
#
# Usage:
#   restart-teams-agent.ps1 -Stop       Stop the agent (and its
#                                        ssh.exe transport).
#   restart-teams-agent.ps1 -Restart    Stop it, then start it
#                                        again the same way Task
#                                        Scheduler does.
# ============================================================

param(
    [switch]$Stop,

    [switch]$Restart
)

if (-not $Stop -and -not $Restart) {

    Write-Host "Usage:"
    Write-Host "  restart-teams-agent.ps1 -Stop"
    Write-Host "  restart-teams-agent.ps1 -Restart"

    exit 1
}

$ScriptRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $ScriptRoot "config.ps1"
$StartVbs   = Join-Path $ScriptRoot "start-teams-agent.vbs"


# ============================================================
# STOP
# ============================================================

$agentProcesses =
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object {

            # Exclude this restart script's own process. Its
            # command line (...\tools\restart-teams-agent.ps1)
            # otherwise also matches "*teams-agent.ps1*", since
            # that's a substring of "restart-teams-agent.ps1" -
            # which caused this script to kill itself before it
            # ever reached the restart step below.
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match '(?i)[\\/]teams-agent\.ps1'
        }

if (-not $agentProcesses) {

    Write-Host "Teams Companion Agent is not running."
}
else {

    foreach ($proc in $agentProcesses) {

        # Kill the child ssh.exe transport first. Stop-Transport's
        # 'finally' block never runs on a forceful kill, so the
        # transport (and the nc listener on the Pi) would otherwise
        # be left orphaned.
        Get-CimInstance Win32_Process -Filter "ParentProcessId = $($proc.ProcessId) AND Name = 'ssh.exe'" |
            ForEach-Object {

                Write-Host "Stopping ssh.exe (PID=$($_.ProcessId))..."

                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }

        Write-Host "Stopping teams-agent.ps1 (PID=$($proc.ProcessId))..."

        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Catch any ssh.exe left orphaned by an earlier forceful kill
# (parent already gone by the time this script runs).
if (Test-Path $ConfigPath) {

    . $ConfigPath

    Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" |
        Where-Object { $_.CommandLine -like "*${PiUser}@${PiHost}*nc -lk 127.0.0.1 $Port*" } |
        ForEach-Object {

            Write-Host "Stopping orphaned ssh.exe (PID=$($_.ProcessId))..."

            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}


# ============================================================
# RESTART
# ============================================================

if ($Restart) {

    Write-Host "Starting Teams Companion Agent..."

    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$StartVbs`""
}
