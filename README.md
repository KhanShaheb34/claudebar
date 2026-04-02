# ClaudeBar

A macOS menubar app that shows your Claude Code usage, stats, and model breakdown at a glance.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange) ![No Xcode Required](https://img.shields.io/badge/Xcode-not%20required-green)

## Features

- **Live usage** -- Session and weekly rate limit percentages, context window usage, session cost
- **Activity heatmap** -- GitHub-style contribution grid showing your Claude Code usage over the past 6 months
- **Stats** -- Active days, streaks, peak hours, longest session, most active day
- **Model breakdown** -- Token usage per model with stacked daily chart (Opus, Sonnet, Haiku)
- **Auto-updating** -- Reads data passively from `~/.claude/` with no extra API calls

## How it works

ClaudeBar reads two data sources:

1. **`~/.claude/stats-cache.json`** -- Historical stats, model usage, activity data (written by Claude Code)
2. **`~/.claude/claudebar-usage.json`** -- Live rate limits and session info (written by a statusline hook you configure)

The statusline hook is the key to live usage data. When Claude Code runs, it periodically sends rate limit info to a configured command. We use a small shell script that saves this data to a JSON file that ClaudeBar reads.

## Setup

```bash
git clone https://github.com/shakirulhkhan/claudebar.git
cd claudebar
./install.sh
```

The installer:

1. Checks prerequisites (`swiftc`, `~/.claude/`, `claude` CLI)
2. Compiles `ClaudeBarApp.swift` into a native binary
3. Creates the statusline hook script at `~/.claude/claudebar-statusline.sh`
4. Adds the `statusLine` config to `~/.claude/settings.json` (preserves existing settings)

Then run:

```bash
./ClaudeBar
```

The sparkle icon appears in your menu bar. Click it to see your dashboard.

### Manual setup

If you prefer to set things up yourself, see the [manual setup guide](#manual-setup-guide) at the bottom.

### Optional: Run on login

To start ClaudeBar automatically when you log in:

```bash
# Create a LaunchAgent
cat > ~/Library/LaunchAgents/com.claudebar.app.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudebar.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(pwd)/ClaudeBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
```

## Tabs

### Usage

Shows live rate limits (session %, weekly %), active model, session cost, context window usage, and today's activity summary.

### Stats

GitHub-style activity heatmap, streaks, most active day, hourly activity distribution, and lifetime stats.

### Models

Stacked tokens-per-day chart and per-model breakdown showing output tokens, input tokens, and cache usage.

## Data sources

| Data                               | Source                                    | Update frequency                                     |
| ---------------------------------- | ----------------------------------------- | ---------------------------------------------------- |
| Rate limits (session %, weekly %)  | Statusline hook -> `claudebar-usage.json` | Every statusline update (~seconds during active use) |
| Context window, model, cost        | Statusline hook -> `claudebar-usage.json` | Same as above                                        |
| Historical stats, heatmap, streaks | `~/.claude/stats-cache.json`              | Polled every 30s                                     |
| Claude version, project count      | CLI + filesystem                          | On app launch + refresh                              |

## Requirements

- macOS 14+ (Sonnet)
- Swift 5.9+ (ships with Xcode Command Line Tools)
- Claude Code CLI installed
- No Xcode project required -- single-file `swiftc` build

## Architecture

Single-file SwiftUI app (`ClaudeBarApp.swift`) using the `NSStatusItem + NSPopover` pattern:

- **Data layer** -- JSON file readers for stats-cache and statusline output
- **Monitor** -- `ObservableObject` with dual timers (5s for usage file, 30s for stats)
- **Views** -- Three tabs with custom heatmap, charts, and usage bars
- **AppDelegate** -- Menubar icon + popover lifecycle

## Manual setup guide

If you don't want to use `install.sh`:

**Build:**

```bash
swiftc -parse-as-library -framework SwiftUI -framework AppKit -o ClaudeBar ClaudeBarApp.swift
```

**Create the statusline script** at `~/.claude/claudebar-statusline.sh`:

```bash
#!/bin/bash
INPUT=$(cat)
echo "$INPUT" > "$HOME/.claude/claudebar-usage.json"
echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get('rate_limits', {})
    h = r.get('five_hour', {})
    w = r.get('seven_day', {})
    print(f'Session: {h.get(\"used_percentage\", \"?\")}% | Week: {w.get(\"used_percentage\", \"?\")}%')
except: pass
" 2>/dev/null
```

**Add to `~/.claude/settings.json`:**

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/claudebar-statusline.sh"
  }
}
```

## License

MIT
