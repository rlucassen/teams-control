# ============================================================
# Teams Companion Agent
#
# Transport:
#
#   Companion
#      |
#      | TCP 127.0.0.1:18124
#      v
#   CompanionPi: nc -lk
#      |
#      | stdin/stdout over SSH
#      v
#   This PowerShell process
#      |
#      v
#   Microsoft Teams via UI Automation
#
# There is NO TCP listener on Windows.
# ============================================================


# ============================================================
# CONFIG
#
# Settings (Pi address, SSH username/key, port, ...) live in
# config.ps1, which is git-ignored so they are never committed.
# See config.example.ps1 for a documented template.
# ============================================================

$ConfigPath = Join-Path $PSScriptRoot "config.ps1"

if (-not (Test-Path $ConfigPath)) {

    throw (
        "Configuration file not found: $ConfigPath`n" +
        "Copy config.example.ps1 to config.ps1 and fill in your own values."
    )
}

. $ConfigPath

# Older config.ps1 files may not define this yet.
if (-not $UnreachableRetryDelaySeconds) {
    $UnreachableRetryDelaySeconds = 60
}


# ============================================================
# INITIALIZATION
# ============================================================

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$script:UiRoot =
    [System.Windows.Automation.AutomationElement]::RootElement

$script:SshProcess = $null

# Task Scheduler's Stop/End only terminates the process it directly
# launched (wscript.exe/conhost.exe when running as a scheduled task),
# never this script - so this script has to notice its launcher died and
# exit itself. Captured once; a launcher's PID is never reassigned to it.
$script:LauncherProcessId =
    (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId


# ============================================================
# UI AUTOMATION CONDITIONS
# ============================================================

# Pre-build this condition once.
# Get-TeamsState therefore performs one UIA tree scan rather
# than four separate searches.

$stateConditions =
    [System.Windows.Automation.Condition[]]@(


        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            "microphone-button"
        )),


        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            "video-button"
        )),


        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            "raisehands-button"
        )),


        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            "share-button"
        ))
    )


$script:StateCondition =
    New-Object System.Windows.Automation.OrCondition(
        $stateConditions
    )


# ============================================================
# UI AUTOMATION HELPERS
# ============================================================

# Every FindFirst/FindAll below is scoped to Teams' own top-level
# window(s) rather than the whole desktop.
#
# Searching from AutomationElement.RootElement with
# TreeScope.Descendants walks the UI Automation tree of *every*
# open window (browsers, Electron/Chromium apps, etc.), which can
# take seconds. Get-TeamsWindows first lists top-level windows with
# TreeScope.Children (cheap - it does not descend into them) and
# keeps only the ones belonging to a Teams process, so subsequent
# Descendants searches only walk Teams' own UI tree.
function Get-TeamsWindows {

    $teamsProcessIds =
        @(
            Get-Process -Name "ms-teams" -ErrorAction SilentlyContinue
            Get-Process -Name "Teams" -ErrorAction SilentlyContinue
        ) |
        Select-Object -ExpandProperty Id -Unique


    if (-not $teamsProcessIds) {
        return @()
    }


    $topLevelWindows =
        $script:UiRoot.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition
        )


    $result = @()


    foreach ($window in $topLevelWindows) {

        try {

            if ($teamsProcessIds -contains $window.Current.ProcessId) {
                $result += $window
            }
        }
        catch {}
    }


    return $result
}


function Find-ElementByAutomationId {

    param(
        [Parameter(Mandatory = $true)]
        [string]$AutomationId
    )


    $condition =
        New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            $AutomationId
        )


    foreach ($window in (Get-TeamsWindows)) {

        try {

            $found =
                $window.FindFirst(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    $condition
                )


            if ($found) {
                return $found
            }
        }
        catch {}
    }


    return $null
}


function Invoke-UIElement {

    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Automation.AutomationElement]$Element
    )


    if (-not $Element.Current.IsEnabled) {

        throw (
            "UI element '$($Element.Current.Name)' is disabled."
        )
    }


    try {

        $pattern =
            $Element.GetCurrentPattern(
                [System.Windows.Automation.InvokePattern]::Pattern
            )
    }
    catch {

        throw (
            "UI element '$($Element.Current.Name)' " +
            "does not support InvokePattern."
        )
    }


    $invoke =
        [System.Windows.Automation.InvokePattern]$pattern


    $invoke.Invoke()
}


# ============================================================
# TEAMS STATE
# ============================================================

function Get-TeamsState {

    try {

        # One UI Automation scan (per Teams window) for all
        # relevant controls.
        $elements = @()

        foreach ($window in (Get-TeamsWindows)) {

            try {

                $elements +=
                    $window.FindAll(
                        [System.Windows.Automation.TreeScope]::Descendants,
                        $script:StateCondition
                    )
            }
            catch {}
        }


        $mic   = $null
        $video = $null
        $hand  = $null
        $share = $null


        foreach ($element in $elements) {

            try {

                switch ($element.Current.AutomationId) {

                    "microphone-button" {
                        $mic = $element
                    }


                    "video-button" {
                        $video = $element
                    }


                    "raisehands-button" {
                        $hand = $element
                    }


                    "share-button" {
                        $share = $element
                    }
                }
            }
            catch {}
        }


        # The microphone button is our indication that
        # meeting controls currently exist.
        if (-not $mic) {

            return (
                "STATE meeting=0 muted=0 camera=0 " +
                "hand=0 sharing=0"
            )
        }


        $muted   = 0
        $camera  = 0
        $handUp  = 0
        $sharing = 0


        # ----------------------------------------------------
        # Microphone
        #
        # "Unmute" means it is currently muted.
        # ----------------------------------------------------

        try {

            if (
                $mic.Current.Name -match
                "(?i)unmute"
            ) {
                $muted = 1
            }
        }
        catch {}


        # ----------------------------------------------------
        # Camera
        #
        # "Turn camera off" means camera is currently ON.
        # ----------------------------------------------------

        if ($video) {

            try {

                if (
                    $video.Current.Name -match
                    "(?i)turn camera off"
                ) {
                    $camera = 1
                }
            }
            catch {}
        }


        # ----------------------------------------------------
        # Hand
        #
        # "Lower your hand" means hand is currently raised.
        # ----------------------------------------------------

        if ($hand) {

            try {

                if (
                    $hand.Current.Name -match
                    "(?i)lower.*hand"
                ) {
                    $handUp = 1
                }
            }
            catch {}
        }


        # ----------------------------------------------------
        # Screen sharing
        # ----------------------------------------------------

        if ($share) {

            try {

                if (
                    $share.Current.Name -match
                    "(?i)stop.*shar|stop.*present"
                ) {
                    $sharing = 1
                }
            }
            catch {}
        }


        return (
            "STATE meeting=1 " +
            "muted=$muted " +
            "camera=$camera " +
            "hand=$handUp " +
            "sharing=$sharing"
        )
    }
    catch {

        Write-Warning (
            "Could not read Teams state: " +
            $_.Exception.Message
        )


        return (
            "STATE meeting=0 muted=0 camera=0 " +
            "hand=0 sharing=0"
        )
    }
}


# ============================================================
# SCREEN SHARE
#
# Preferred screen:
#
#   [ screen ] [ SELECT THIS ]
#   [ screen ]
#
# ============================================================

function Select-PreferredShareScreen {

    Write-Host "Waiting for Teams share picker..."


    # --------------------------------------------------------
    # Find the "Choose screen" list
    # --------------------------------------------------------

    $nameCondition =
        New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            "Choose screen"
        )


    $typeCondition =
        New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::List
        )


    $screenListCondition =
        New-Object System.Windows.Automation.AndCondition(
            $nameCondition,
            $typeCondition
        )


    $screenList = $null


    # Wait up to roughly 3 seconds.
    for ($i = 0; $i -lt 60; $i++) {

        foreach ($window in (Get-TeamsWindows)) {

            try {

                $screenList =
                    $window.FindFirst(
                        [System.Windows.Automation.TreeScope]::Descendants,
                        $screenListCondition
                    )
            }
            catch {}


            if ($screenList) {
                break
            }
        }


        if ($screenList) {
            break
        }


        Start-Sleep -Milliseconds 50
    }


    if (-not $screenList) {

        throw (
            "Teams share picker ('Choose screen') did not appear."
        )
    }


    # --------------------------------------------------------
    # Find ListItems inside the screen picker
    # --------------------------------------------------------

    $listItemCondition =
        New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem
        )


    $monitors = @()


    for ($attempt = 0; $attempt -lt 40; $attempt++) {

        $items =
            $screenList.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                $listItemCondition
            )


        $found = @()


        foreach ($item in $items) {

            try {

                $rect =
                    $item.Current.BoundingRectangle


                if (
                    $rect.Width -le 0 -or
                    $rect.Height -le 0
                ) {
                    continue
                }


                # Verify that Teams lets us invoke it.
                try {

                    $null =
                        $item.GetCurrentPattern(
                            [System.Windows.Automation.InvokePattern]::Pattern
                        )
                }
                catch {

                    continue
                }


                $found +=
                    [PSCustomObject]@{

                        Element = $item

                        Name = $item.Current.Name

                        X = $rect.X
                        Y = $rect.Y

                        Width  = $rect.Width
                        Height = $rect.Height
                    }
            }
            catch {}
        }


        if ($found.Count -gt 0) {

            $monitors = $found
            break
        }


        Start-Sleep -Milliseconds 50
    }


    if ($monitors.Count -eq 0) {

        throw (
            "No monitor entries found in Teams share picker."
        )
    }


    Write-Host "Found $($monitors.Count) screens."


    for ($i = 0; $i -lt $monitors.Count; $i++) {

        $monitor = $monitors[$i]

        Write-Host (
            "  [{0}] '{1}' X={2} Y={3} W={4} H={5}" -f
            ($i + 1),
            $monitor.Name,
            [math]::Round($monitor.X),
            [math]::Round($monitor.Y),
            [math]::Round($monitor.Width),
            [math]::Round($monitor.Height)
        )
    }


    # --------------------------------------------------------
    # Select the configured screen
    #
    # $SharePreferredScreenIndex (config.ps1) is a 1-based
    # index into $monitors, in the order Teams lists them.
    # Falls back to the first entry if unset/invalid/out of
    # range, rather than throwing.
    # --------------------------------------------------------

    $preferredIndexVar =
        Get-Variable `
            -Name SharePreferredScreenIndex `
            -ErrorAction SilentlyContinue


    $target = $null


    if ($preferredIndexVar) {

        $preferredIndex = $preferredIndexVar.Value

        if (
            $preferredIndex -is [int] -and
            $preferredIndex -ge 1 -and
            $preferredIndex -le $monitors.Count
        ) {

            $target = $monitors[$preferredIndex - 1]
        }
        else {

            Write-Warning (
                "SharePreferredScreenIndex ($preferredIndex) is " +
                "out of range (1-$($monitors.Count)); " +
                "using the first detected screen instead."
            )
        }
    }
    else {

        Write-Warning (
            "SharePreferredScreenIndex is not set in config.ps1; " +
            "using the first detected screen instead."
        )
    }


    if (-not $target) {

        $target = $monitors[0]
    }


    Write-Host (
        "Selecting screen '{0}' X={1}, Y={2}" -f
        $target.Name,
        [math]::Round($target.X),
        [math]::Round($target.Y)
    )


    Invoke-UIElement $target.Element
}


# ============================================================
# TEAMS COMMANDS
# ============================================================

$AutomationIds = @{

    mute   = "microphone-button"
    camera = "video-button"
    hand   = "raisehands-button"

    share  = "share-button"

    leave  = "hangup-button"

    chat   = "chat-button"
    people = "roster-button"
}


function Invoke-TeamsCommand {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )


    switch ($Command) {


        "ping" {

            return "PONG"
        }


        "status" {

            return Get-TeamsState
        }


        { $AutomationIds.ContainsKey($_) } {

            $automationId =
                $AutomationIds[$Command]


            # Always find the control fresh.
            #
            # Teams/WebView can replace UI Automation elements
            # while a meeting is running.
            $button =
                Find-ElementByAutomationId $automationId


            if (-not $button) {

                throw (
                    "Teams control '$Command' " +
                    "($automationId) not found."
                )
            }


            $buttonNameBeforeInvoke =
                $button.Current.Name


            Write-Host ""
            Write-Host "Action  : $Command"

            Write-Host (
                "Control : $buttonNameBeforeInvoke " +
                "[$automationId]"
            )


            Invoke-UIElement $button


            # ------------------------------------------------
            # Sharing requires an additional selection
            # ------------------------------------------------

            if ($Command -eq "share") {

                # If it already said Stop sharing, this click
                # has just stopped sharing.
                if (
                    $buttonNameBeforeInvoke -match
                    "(?i)stop.*shar|stop.*present"
                ) {

                    Write-Host "Screen sharing stopped."
                }
                else {

                    Select-PreferredShareScreen

                    Write-Host "Screen sharing started."
                }
            }


            # Allow Teams' accessibility tree to update.
            switch ($Command) {

                "share" {

                    Start-Sleep -Milliseconds 200
                }


                "leave" {

                    Start-Sleep -Milliseconds 300
                }


                default {

                    Start-Sleep -Milliseconds 100
                }
            }


            return Get-TeamsState
        }


        default {

            throw "Unknown command '$Command'."
        }
    }
}


# ============================================================
# NETWORK
# ============================================================

# Cheap check so the reconnect loop doesn't spend ~15-20s
# spawning and waiting on ssh.exe just to find out the Pi isn't
# even on this network (e.g. away from home).
function Test-PiReachable {

    param(
        [int]$TimeoutMilliseconds = 2000
    )

    $client = New-Object System.Net.Sockets.TcpClient

    try {

        $result = $client.BeginConnect($PiHost, 22, $null, $null)

        if (-not $result.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }

        $client.EndConnect($result)

        return $true
    }
    catch {

        return $false
    }
    finally {

        $client.Close()
    }
}


# ============================================================
# LAUNCHER MONITORING
# ============================================================

# True if the process that launched us (or no known launcher) is still
# alive. A stale/reused PID could in theory produce a false positive, but
# that's an acceptable risk for this use case.
function Test-LauncherAlive {

    if (-not $script:LauncherProcessId) {
        return $true
    }

    return [bool](
        Get-Process -Id $script:LauncherProcessId -ErrorAction SilentlyContinue
    )
}


# Sleeps in small increments instead of one long Start-Sleep, so a killed
# launcher is noticed within ~500ms instead of only after the full delay.
function Wait-WhileLauncherAlive {

    param(
        [int]$Seconds
    )

    $deadline = (Get-Date).AddSeconds($Seconds)

    while ((Get-Date) -lt $deadline) {

        if (-not (Test-LauncherAlive)) {
            return $false
        }

        Start-Sleep -Milliseconds 500
    }

    return $true
}


# ============================================================
# SSH / NETCAT TRANSPORT
# ============================================================

function Start-Transport {

    if (-not (Test-Path $SshExe)) {

        throw "ssh.exe not found: $SshExe"
    }


    if (-not (Test-Path $SshKey)) {

        throw "SSH key not found: $SshKey"
    }


    Write-Host ""
    Write-Host "Starting SSH/netcat transport..."


    # This runs ON THE PI.
    #
    # -l : listen
    # -k : keep accepting new TCP clients after disconnect
    #
    # A sleeping/hibernating Windows host can leave the previous nc
    # listener behind on the Pi. Remove only this app's old listener
    # for the configured port before exec'ing the live one.
    #
    # stdin/stdout of nc are carried through the SSH session.

    $remoteCommand =
        "sh -c 'for i in 1 2 3; do fuser -k -9 $Port/tcp 2>/dev/null; sleep 0.2; done; exec nc -lk 127.0.0.1 $Port'"


    $arguments =
        "-T " +
        "-o ConnectTimeout=5 " +
        "-o BatchMode=yes " +
        "-o StrictHostKeyChecking=accept-new " +
        "-o ServerAliveInterval=5 " +
        "-o ServerAliveCountMax=2 " +
        "-i `"$SshKey`" " +
        "${PiUser}@${PiHost} " +
        "`"$remoteCommand`""


    $startInfo =
        New-Object System.Diagnostics.ProcessStartInfo


    $startInfo.FileName =
        $SshExe


    $startInfo.Arguments =
        $arguments


    # Critical: the Teams agent communicates with nc through
    # SSH's stdin/stdout.
    $startInfo.RedirectStandardInput =
        $true


    $startInfo.RedirectStandardOutput =
        $true


    # Leave stderr attached to the current process.
    #
    # When debugging visibly, SSH errors will therefore appear
    # in this PowerShell window.
    #
    # More importantly: stderr cannot fill a redirected buffer
    # and deadlock ssh.exe.
    $startInfo.RedirectStandardError =
        $false


    $startInfo.UseShellExecute =
        $false


    $startInfo.CreateNoWindow =
        $true


    $process =
        New-Object System.Diagnostics.Process


    $process.StartInfo =
        $startInfo


    if (-not $process.Start()) {

        throw "Could not start ssh.exe."
    }


    # StreamWriter used to send responses back to Companion.
    $process.StandardInput.AutoFlush =
        $true


    $script:SshProcess =
        $process


    Write-Host (
        "SSH process started. PID=" +
        $process.Id
    )


    Write-Host (
        "Pi listener: 127.0.0.1:$Port"
    )


    return $process
}


function Stop-Transport {

    if (-not $script:SshProcess) {
        return
    }


    try {

        if (-not $script:SshProcess.HasExited) {

            Write-Host "Stopping SSH transport..."


            try {
                $script:SshProcess.StandardInput.Close()
            }
            catch {}


            Start-Sleep -Milliseconds 100


            if (-not $script:SshProcess.HasExited) {

                Stop-Process `
                    -Id $script:SshProcess.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}


    try {
        $script:SshProcess.Dispose()
    }
    catch {}


    $script:SshProcess = $null
}


# ============================================================
# MAIN
# ============================================================

Write-Host ""
Write-Host "====================================================="
Write-Host " Teams Companion Agent"
Write-Host "====================================================="
Write-Host " Pi       : $PiUser@$PiHost"
Write-Host " TCP      : Pi 127.0.0.1:$Port"
Write-Host " Transport: SSH + nc"
Write-Host " Windows  : NO local TCP listener"
Write-Host "====================================================="
Write-Host ""


$script:ShutdownRequested = $false

try {

    while (-not $script:ShutdownRequested) {

        if (-not (Test-PiReachable)) {

            Write-Warning (
                "Pi not reachable at ${PiHost}:22. " +
                "Retrying in $UnreachableRetryDelaySeconds seconds..."
            )

            if (-not (Wait-WhileLauncherAlive -Seconds $UnreachableRetryDelaySeconds)) {
                $script:ShutdownRequested = $true
            }

            continue
        }


        $ssh = $null
        $subscription = $null


        try {

            $ssh =
                Start-Transport


            # stdin to ssh == data written by nc back to
            # Companion.
            $writer =
                $ssh.StandardInput


            Write-Host ""
            Write-Host "Transport ready."
            Write-Host "Waiting for Companion commands..."


            # ------------------------------------------------
            # Read stdout asynchronously (OutputDataReceived)
            # instead of blocking on ReadLine(), so this loop
            # can also poll Test-LauncherAlive - a blocking
            # ReadLine() would never notice a killed launcher.
            #
            # Because nc uses -k, Companion may disconnect and
            # reconnect without restarting this SSH session.
            # ------------------------------------------------

            $outputQueue =
                [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

            $subscription =
                Register-ObjectEvent -InputObject $ssh -EventName OutputDataReceived -Action {
                    $Event.MessageData.Enqueue($EventArgs.Data)
                } -MessageData $outputQueue

            $ssh.BeginOutputReadLine()

            while (-not $ssh.HasExited) {

                if (-not (Test-LauncherAlive)) {

                    Write-Warning "Launcher process is gone. Shutting down."

                    $script:ShutdownRequested = $true

                    break
                }


                $line = $null

                if (-not $outputQueue.TryDequeue([ref]$line)) {
                    Start-Sleep -Milliseconds 200
                    continue
                }


                # EOF means ssh/nc ended.
                if ($null -eq $line) {
                    break
                }


                $command =
                    $line.Trim().ToLowerInvariant()


                if (
                    [string]::IsNullOrWhiteSpace(
                        $command
                    )
                ) {
                    continue
                }


                Write-Host ""
                Write-Host "Received: $command"


                try {

                    $response =
                        Invoke-TeamsCommand $command


                    Write-Host (
                        "Response: $response"
                    )


                    $writer.WriteLine(
                        $response
                    )


                    $writer.Flush()
                }
                catch {

                    $message =
                        $_.Exception.Message


                    Write-Warning $message


                    try {

                        $writer.WriteLine(
                            "ERROR command=$command message=$message"
                        )


                        $writer.Flush()
                    }
                    catch {}
                }
            }


            if ($script:ShutdownRequested) {
                # Nothing to warn about - this is a normal stop.
            }
            elseif ($ssh.HasExited) {

                Write-Warning (
                    "SSH transport exited. Exit code: " +
                    $ssh.ExitCode
                )
            }
            else {

                Write-Warning (
                    "SSH transport stream closed."
                )
            }
        }
        catch {

            Write-Warning (
                "Transport error: " +
                $_.Exception.Message
            )
        }
        finally {

            if ($subscription) {
                Unregister-Event -SourceIdentifier $subscription.Name -ErrorAction SilentlyContinue
                Remove-Job -Name $subscription.Name -Force -ErrorAction SilentlyContinue
            }

            Stop-Transport
        }


        if ($script:ShutdownRequested) {
            continue
        }


        Write-Host (
            "Reconnecting in " +
            "$ReconnectDelaySeconds seconds..."
        )


        if (-not (Wait-WhileLauncherAlive -Seconds $ReconnectDelaySeconds)) {
            $script:ShutdownRequested = $true
        }
    }
}
finally {

    Stop-Transport


    Write-Host ""
    Write-Host "Teams Companion Agent stopped."
}