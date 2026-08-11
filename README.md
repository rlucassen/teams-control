# Teams Companion Agent

Control the Microsoft Teams desktop client from a hardware control surface
(e.g. a Stream Deck running [Bitfocus Companion](https://bitfocus.io/companion)
on a Raspberry Pi) — mute/unmute, toggle camera, raise/lower hand, start/stop
screen sharing, leave a meeting, and open chat/roster — using Windows UI
Automation, since Teams has no official local automation API for this.

## How it works

The tool is designed to work with **Bitfocus Companion** running on a
separate Raspberry Pi ("CompanionPi"):

```
Stream Deck
    |
    v
Bitfocus Companion
    |
    | TCP 127.0.0.1:<port>
    v
CompanionPi: nc -lk 127.0.0.1 <port>
    |
    | stdin/stdout, tunneled over SSH
    v
teams-agent.ps1 (this repo, running on Windows)
    |
    | Windows UI Automation
    v
Microsoft Teams
```

The Windows computer does not need to accept any incoming network
connections. Instead, `teams-agent.ps1` makes an *outbound* SSH connection
to the CompanionPi and remotely starts a small `nc -lk 127.0.0.1 <port>`
listener there. Text commands written to that Pi-local port travel back to
Windows through the SSH connection's stdin/stdout, and responses travel
back the same way. Because `nc` only binds `127.0.0.1`, nothing on the
Pi's network can reach that port directly — only processes running locally
on the Pi (such as Companion) can talk to the agent.

This is particularly useful on managed corporate laptops, where inbound TCP
connections are often blocked by endpoint security or firewall policies:
only the CompanionPi ever listens on a TCP port, while the Windows computer
only ever initiates outbound SSH connections.

On the Windows side, each command is translated into a UI Automation
`Invoke` on the matching Teams meeting-toolbar button, and the agent replies
with a `STATE ...` line describing the current mic/camera/hand/sharing
state.

## Why this tool exists

Microsoft Teams previously exposed a legacy third-party meeting and call control interface that allowed external applications and hardware to control meeting functions such as:

- Mute / unmute microphone
- Enable / disable camera
- Raise / lower hand
- Start / stop screen sharing
- Leave a meeting

This interface was used by applications such as Bitfocus Companion to control Teams directly.

Microsoft retired the legacy external meeting-control integration on **June 30, 2026**. As part of that change, the corresponding third-party API setting was removed from the Teams desktop client and integrations depending on it stopped working.

This tool provides an alternative way to control the Teams desktop client.

Instead of using a Teams API, the agent runs on the Windows computer where Teams is running and uses **Windows UI Automation** to locate and invoke the actual Teams meeting controls.

For example, instead of calling an API to mute Teams, the agent locates the Teams control with the Automation ID:

`microphone-button`

and invokes it in the same way an accessibility tool would.

This approach also allows the agent to inspect the current state of the Teams controls and report that state back to Companion.

> [!NOTE]
> This is not an official Microsoft Teams API. It depends on the accessibility/UI Automation information exposed by the Teams desktop client. A future Teams UI change could therefore require changes to this tool.

## Repository layout

| Path | Purpose |
|---|---|
| [teams-agent.ps1](teams-agent.ps1) | Main agent. Runs continuously on the Windows PC that has Teams open. |
| [start-teams-agent.vbs](start-teams-agent.vbs) | Launches `teams-agent.ps1` with no visible window; used for Task Scheduler. |
| [config.example.ps1](config.example.ps1) | Documented configuration template. Checked into git. |
| `config.ps1` | Your local configuration (Pi address, SSH user, key path). **Git-ignored** — never committed. |
| [tools/inspect-under-mouse.ps1](tools/inspect-under-mouse.ps1) | Diagnostic tool: prints the UI Automation properties of whatever element is under your mouse cursor. Used to (re)discover Teams' AutomationIds when its UI changes. |
| [tools/restart-teams-agent.ps1](tools/restart-teams-agent.ps1) | Stops and/or restarts the agent, including its child `ssh.exe` transport process. Use this instead of ending `powershell.exe` from Task Manager. |
| [COMPANION.md](COMPANION.md) | Full walkthrough for wiring up Bitfocus Companion: the Generic TCP/UDP connection, buttons, state feedback, and polling. |

## Commands understood by the agent

Each command is a single line of plain ASCII text, terminated with a newline.

| Command | Effect |
|---|---|
| `ping` | Replies `PONG`. Useful as a connectivity check. |
| `status` | Returns the current `STATE ...` line without changing anything. |
| `mute` | Toggles microphone mute. |
| `camera` | Toggles the camera. |
| `hand` | Raises/lowers your hand. |
| `share` | Starts screen sharing (selects the monitor configured by `$SharePreferredScreenIndex` in `config.ps1`, see [teams-agent.ps1](teams-agent.ps1)'s `Select-PreferredShareScreen`) or stops it if already sharing. |
| `leave` | Leaves the current meeting. |
| `chat` | Opens/toggles the chat panel. |
| `people` | Opens/toggles the roster (people) panel. |

Every command that changes state returns an updated `STATE` line, e.g.:

```
STATE meeting=1 muted=0 camera=1 hand=0 sharing=0
```

## Prerequisites

**Windows PC** (the one running Teams):
- Windows with Microsoft Teams desktop app installed.
- Windows PowerShell 5.1 (included with Windows).
- OpenSSH Client optional feature installed, providing
  `C:\Windows\System32\OpenSSH\ssh.exe`
  (Settings → Optional Features → "OpenSSH Client").

**Pi / Companion side**:
- A Raspberry Pi (or any Linux box) reachable via SSH from the Windows PC.
- OpenSSH server running on it.
- `netcat-openbsd` installed (needs to support the `-k` flag; BusyBox's
  built-in `nc` typically does not).
- Bitfocus Companion (or anything else able to send raw TCP text) running
  locally on that same Pi.

## Setup

### 1. Generate a dedicated SSH key (on Windows)

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\companionpi-teams" -C "teams-agent"
```

Use a dedicated key (not your everyday one) so it can be revoked
independently, and leave the passphrase empty — the agent connects
unattended (e.g. from Task Scheduler at logon), so nothing will be able to
type a passphrase for it.

### 2. Authorize that key on the Pi

```powershell
type "$env:USERPROFILE\.ssh\companionpi-teams.pub" | ssh <pi-user>@<pi-host> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

### 3. Install netcat and enable SSH on the Pi

```bash
sudo apt install netcat-openbsd
sudo systemctl enable --now ssh
```

No firewall changes are needed — `nc` only listens on `127.0.0.1`, so the
port is never exposed to the LAN.

### 4. Configure the agent (Windows)

Copy the template and fill in your own values:

```powershell
Copy-Item config.example.ps1 config.ps1
notepad config.ps1
```

Set `$PiHost`, `$PiUser`, `$SshKey`, and `$Port` to match your setup.
`config.ps1` is listed in [.gitignore](.gitignore), so these values never
end up in git.

`$SharePreferredScreenIndex` picks which monitor the `share` command shares,
as a 1-based index into the screens Teams lists in its "Choose screen"
picker. See step 5 below to find the right value for your setup.

### 5. Test it manually

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\teams-agent.ps1
```

Join a Teams meeting, then from the Pi:

```bash
echo status | nc 127.0.0.1 <port>
```

You should see a `STATE ...` reply.

To find the right `$SharePreferredScreenIndex` for your setup, send `share`
from the Pi:

```bash
echo share | nc 127.0.0.1 <port>
```

and check the agent's console output, which lists each detected screen with
its index, name, and position, e.g.:

```
Found 2 screens.
  [1] 'Dell U2415' X=0 Y=0 W=1920 H=1200
  [2] 'LG UltraGear' X=1920 Y=0 W=2560 H=1440
```

Set `$SharePreferredScreenIndex` in `config.ps1` to the number in brackets
for the screen you want shared, then restart the agent. If unset, invalid,
or out of range, the first detected screen is used instead.

### 6. Run it in the background via Task Scheduler

UI Automation needs to run inside the interactive desktop session that has
Teams open, so this can't run as a hidden SYSTEM service — Task Scheduler
running at user logon is the simplest reliable option.
[start-teams-agent.vbs](start-teams-agent.vbs) launches
`teams-agent.ps1` through `wscript.exe` with `WindowStyle Hidden` and a
non-waiting `shell.Run`, so no console window or taskbar icon ever appears.

1. Open **Task Scheduler** → **Create Task…** (not "Create Basic Task", so
   all options are available).
2. **General** tab: give it a name, select **"Run only when user is logged
   on"**, and tick **"Hidden"**.
3. **Triggers** tab: **New…** → **"At log on"**.
4. **Actions** tab: **New…** → Action **"Start a program"**:
   - Program/script: `wscript.exe`
   - Add arguments: `"C:\path\to\teams-control\start-teams-agent.vbs"`
     (use the actual path where you cloned this repo).
5. **Conditions** tab: uncheck "Start the task only if the computer is on
   AC power" if this runs on a laptop.
6. **Settings** tab: optionally enable "If the task fails, restart every
   ..." for resilience.
7. Save, then log off/on (or right-click the task → **Run**) to verify it
   starts silently. Check Task Manager's "Details" tab for a
   `powershell.exe` process to confirm it's running.

> [!NOTE]
> Because `start-teams-agent.vbs` launches `teams-agent.ps1` detached (via a
> non-waiting `shell.Run`), Task Scheduler's status column reverts to
> **Ready** almost immediately even while the agent keeps running in the
> background — that's expected, not a failure. Since the agent is no longer
> tied to the scheduled task, use
> [tools/restart-teams-agent.ps1](tools/restart-teams-agent.ps1) to stop or
> restart it rather than ending the task from Task Scheduler:
>
> ```powershell
> # Stop it
> powershell -ExecutionPolicy Bypass -File .\tools\restart-teams-agent.ps1 -Stop
>
> # Stop it and start it again
> powershell -ExecutionPolicy Bypass -File .\tools\restart-teams-agent.ps1 -Restart
> ```

### 7. Configure Companion (on the Pi)

In Bitfocus Companion, add a **Generic TCP/UDP** connection pointed at
`127.0.0.1:<port>` (the same port from `config.ps1`), then configure
buttons to send the command strings from the table above.

See **[COMPANION.md](COMPANION.md)** for the full walkthrough, including
connection settings, button actions, driving feedback from the `STATE ...`
response, and keeping the Stream Deck in sync with polling.

## tools/inspect-under-mouse.ps1

A standalone diagnostic script, independent from the agent. Run it, then
within 5 seconds hover your mouse over a Teams control (e.g. the mute
button). It walks up the UI Automation tree from that point and prints the
`Name`, `ControlType`, `AutomationId`, `ClassName`, and supported patterns
for up to 10 ancestor levels. Use it to rediscover AutomationIds if a Teams
update changes its UI and [teams-agent.ps1](teams-agent.ps1) stops finding
a control.

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\inspect-under-mouse.ps1
```

## Known issues

- **Teams window comes to the foreground on every command.** Windows UI
  Automation's `Invoke` on Teams' meeting-toolbar buttons only reliably
  works when the Teams window is the foreground window, so the agent brings
  it forward before invoking a control. This means Teams cannot be
  controlled purely in the background — it will briefly steal focus (and
  may cover whatever you were working on) each time a command like `mute`,
  `camera`, `hand`, `share`, `leave`, `chat`, or `people` is run.

## Security notes

- `config.ps1` contains your Pi's address, SSH username, and key path.
  It's git-ignored — never commit it. Only `config.example.ps1`
  (placeholder values) is tracked.
- Use a dedicated SSH key for this agent so it can be revoked without
  affecting other access.
- The Pi-side port is bound to `127.0.0.1` and reached only through the SSH
  tunnel or locally on the Pi itself — it is never exposed to the network.

## License

[MIT](LICENSE)
