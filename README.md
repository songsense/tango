# Tango — Tap-to-Respond for Claude Code

Tango is a macOS menu-bar app that turns finger taps or claps into responses to Claude Code permission prompts. When Claude pauses to ask for approval, Tango posts a notification and listens for acoustic gestures on the microphone — useful when you're in a meeting and can't type or speak.

```
1 tap  →  Yes
2 taps →  Yes, always
3 taps →  No
```

You can also click the notification action buttons (Yes / Yes, always / No) as a fallback.

---

## How it works

1. Claude Code fires a `PreToolUse` or `Notification` hook
2. The hook runs `tango hook pretooluse` (or `notification`), which connects to the running `TangoApp` daemon over a Unix socket
3. The daemon posts a macOS notification summarizing what Claude wants to do
4. The daemon briefly listens on the microphone for tap/clap patterns
5. The gesture (or button press) is mapped to `yes` / `yes-always` / `no` and returned to Claude Code

Tango uses Apple's `SoundAnalysis` framework to suppress human voice — if you're in a meeting, speech is detected and gestures are ignored until the voice stops.

---

## Requirements

- macOS 13 Ventura or later
- Microphone access (for tap detection)
- Notification permission
- A running Claude Code session with hooks enabled

---

## Installation

### One-liner (Apple Silicon)

```bash
curl -fsSL https://raw.githubusercontent.com/songsense/tango/main/install.sh | bash
```

Downloads the latest release binary from GitHub, installs `tango` to `/usr/local/bin`, and copies `Tango.app` to `/Applications`.

### Build from source

```bash
git clone https://github.com/songsense/tango.git
cd tango
swift build -c release --product tango
swift build -c release --product ClaudeToolApp
```

The app bundle is at `.build/arm64-apple-macosx/release/ClaudeToolApp.app` and the CLI at `.build/arm64-apple-macosx/release/tango`.

### Install hooks

After building, install the Claude Code hooks:

```bash
.build/arm64-apple-macosx/release/tango install-hooks
```

This writes entries to `~/.claude/settings.json` for both `PreToolUse` and `Notification` events.

### Launch the daemon

Open `ClaudeToolApp.app` from Finder, or:

```bash
open .build/arm64-apple-macosx/release/ClaudeToolApp.app
```

The app lives in the menu bar. Grant microphone and notification permissions when prompted.

---

## Usage

| Gesture | Response |
|---------|----------|
| 1 tap / clap | Yes — allow this action |
| 2 taps | Yes, always — allow and remember |
| 3 taps | No — deny |
| Notification button | Same as tap (keyboard fallback) |
| No response | Times out (default 30 s), Claude decides |

Tap or clap anywhere near the Mac — desk, case, or open hand. Voice and keyboard noise are filtered automatically.

---

## CLI reference

```
tango install-hooks        # Write hooks to ~/.claude/settings.json
tango hook pretooluse      # Handle a PreToolUse hook event (reads JSON from stdin)
tango hook notification    # Handle a Notification hook event (reads JSON from stdin)
tango ask --prompt TEXT    # Post a notification and wait for a gesture
tango calibrate            # Interactive calibration for your mic/environment
tango config get <key>     # Read a config value
tango config set <key> <value>  # Write a config value
tango daemon status        # Check if the daemon is running
```

---

## Configuration

Config lives at `~/.config/tango/config.toml` (created on first run):

```toml
[detection]
timeout_seconds = 30
sensitivity_db = 12.0        # dB above noise floor to count as a tap
input_device = "default"     # mic name, or "default"

[gestures]
one_pat = "yes"
two_pat = "yes-always"
three_pat = "no"

[hooks.pre_tool_use]
mode = "all"                 # "all" or "whitelist"
whitelist = []               # e.g. ["Read", "Bash:git status"]

[notifications]
sound_enabled = true
include_command_in_body = true
```

---

## Calibration

Run `tango calibrate` from the menu bar (or CLI) the first time on each Mac. It samples your ambient noise floor and runs a few tap trials to tune detection thresholds.

---

## Monitor window

The **Monitor** option in the menu bar opens a live waveform view showing:
- Audio level and detected beats
- Noise floor
- Voice detection state (red background = speech suppressing gestures)
- Cluster count and last gesture result

---

## Architecture

```
Claude Code hook
    └── tango CLI  (thin client, sub-50ms startup)
            │  Unix socket (JSON)
            ▼
    TangoApp daemon  (menu-bar, always running)
            ├── PatDetector     AVAudioEngine onset detection
            ├── VoiceGate       SoundAnalysis speech suppression
            ├── NotificationManager  UNUserNotifications
            └── ControlServer   Unix socket IPC
```

The CLI is kept separate from the daemon so hook invocations don't pay app-launch cost.

---

## License

MIT
