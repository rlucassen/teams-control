# ============================================================
# Teams Companion Agent - Configuration Template
#
# Copy this file to "config.ps1" in the same folder and fill
# in your own values:
#
#   Copy-Item config.example.ps1 config.ps1
#
# "config.ps1" is listed in .gitignore, so your Pi's address,
# SSH username, and key path never end up in git history.
# ============================================================

# TCP port that `nc` listens on, on the Pi side.
# Only reachable from the Pi itself (127.0.0.1).
$Port = 18124

# Hostname or IP address of the Raspberry Pi ("CompanionPi").
$PiHost = "192.168.1.50"

# SSH username used to log in to the Pi.
$PiUser = "pi"

# Path to the private SSH key used to authenticate to the Pi.
# Generate a dedicated key just for this, e.g.:
#   ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\companionpi-teams"
$SshKey = "$env:USERPROFILE\.ssh\companionpi-teams"

# Path to ssh.exe (Windows' built-in OpenSSH client).
$SshExe = "$env:WINDIR\System32\OpenSSH\ssh.exe"

# Seconds to wait before reconnecting after the transport drops.
$ReconnectDelaySeconds = 5

# Which screen to share when the "share" command starts sharing, as a
# 1-based index into the screens Teams lists in its "Choose screen"
# picker (order as detected — not necessarily left-to-right).
#
# Run the agent visibly (see README "Test it manually"), trigger a
# share, and read the console output listing detected screens with
# their index/name/position to find the right number for your setup.
#
# If unset, invalid, or out of range, the first detected screen is used.
$SharePreferredScreenIndex = 1
