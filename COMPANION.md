## Configuring Bitfocus Companion

The easiest way to communicate with the agent is the **Generic TCP/UDP** Companion module.

Create a Generic TCP/UDP connection with the following settings:

| Setting | Value |
|---|---|
| Target IP / Host | `127.0.0.1` |
| Port | `18124` |
| Protocol | `TCP` |
| Save TCP Response | `Yes` |
| Convert TCP Response | `String` |
| Command End Character | `LF - \n` |

The address is `127.0.0.1` because the TCP listener runs locally on the CompanionPi. The SSH connection created by `teams-agent.ps1` carries the traffic between the Pi and the Windows computer.


## Sending commands

Create a Companion button and add a Generic TCP/UDP **Send TCP** action.

Send one of the following commands as plain text:

| Command | Action |
|---|---|
| `mute` | Toggle microphone mute |
| `camera` | Toggle camera |
| `hand` | Raise or lower hand |
| `share` | Start or stop screen sharing |
| `leave` | Leave the current meeting |
| `chat` | Open or close meeting chat |
| `people` | Open or close the participants panel |
| `status` | Request the current meeting state |
| `ping` | Test communication with the agent |

For example, a mute button simply sends:

```text
mute
```

Do not manually add a newline to the command if Companion is configured with `LF - \n` as the command end character.


## State feedback

The agent sends a response after each command.

For meeting controls, the response looks like this:

```text
STATE meeting=1 muted=1 camera=0 hand=0 sharing=0
```

Each value is either `0` or `1`:

| State | Meaning when `1` |
|---|---|
| `meeting` | Teams meeting controls are currently available |
| `muted` | Microphone is muted |
| `camera` | Camera is enabled |
| `hand` | Hand is raised |
| `sharing` | Screen sharing is active |

For example:

```text
STATE meeting=1 muted=1 camera=1 hand=0 sharing=0
```

means that a meeting is active, the microphone is muted, the camera is on, the hand is not raised and screen sharing is not active.

Because **Save TCP Response** is enabled in the Generic TCP/UDP connection, Companion stores the response in its `tcp_response` variable.

This can be used for button feedback. For example, the mute button can use an expression such as:

```text
includes($(CONNECTION:tcp_response), 'muted=1')
```

The same pattern can be used for the other controls:

```text
includes($(CONNECTION:tcp_response), 'camera=1')
includes($(CONNECTION:tcp_response), 'hand=1')
includes($(CONNECTION:tcp_response), 'sharing=1')
includes($(CONNECTION:tcp_response), 'meeting=1')
```

Replace `CONNECTION` with the Companion connection identifier used for your Generic TCP/UDP connection.


## Keeping the Stream Deck state synchronized

Every control command automatically returns the updated Teams state, so a button pressed through Companion updates its feedback immediately.

However, Teams can also be controlled directly from the Teams UI, keyboard shortcuts, headsets or other devices. Companion would otherwise not know that the state changed.

To keep Companion synchronized, create a Companion trigger that periodically sends:

```text
status
```

A polling interval of approximately **2 seconds** works well.

This provides near-real-time feedback while avoiding unnecessary UI Automation queries.

The resulting flow is:

```text
Every 2 seconds
      |
      v
send "status"
      |
      v
teams-agent.ps1 reads Teams controls
      |
      v
STATE meeting=1 muted=0 camera=1 hand=0 sharing=0
      |
      v
Companion tcp_response
      |
      v
Stream Deck feedback updates
```

Actions initiated from the Stream Deck do not have to wait for this polling interval: the agent returns a new state immediately after executing the action.


## Screen sharing

The `share` command is slightly more advanced than the other commands.

When screen sharing is not active, the agent:

1. Invokes the Teams **Share** button.
2. Waits for the Teams screen picker.
3. Detects the available monitors using Windows UI Automation.
4. Selects the preferred screen.

When sharing is already active, the same command invokes the Teams **Stop sharing** control.

This means a single Companion button can be used as a toggle:

```text
share
```

and its feedback can be driven by:

```text
sharing=1
```


## Testing the connection

A simple communication test can be performed by sending:

```text
ping
```

The agent should respond with:

```text
PONG
```

If `PONG` is returned but Teams commands do not work, the Companion/SSH transport is working and the problem is most likely related to Teams UI Automation.

If Companion cannot receive `PONG`, troubleshoot the Companion TCP connection, the `nc` listener on the CompanionPi and the SSH connection before troubleshooting Teams itself.