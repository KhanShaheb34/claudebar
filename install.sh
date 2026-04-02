#!/bin/bash
set -e

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STATUSLINE_SCRIPT="$CLAUDE_DIR/claudebar-statusline.sh"

step() { echo -e "\n${CYAN}${BOLD}[$1/4]${RESET} $2"; }
ok()   { echo -e "  ${GREEN}OK${RESET} $1"; }
skip() { echo -e "  ${DIM}--${RESET} $1 ${DIM}(skipped)${RESET}"; }
warn() { echo -e "  ${YELLOW}!!${RESET} $1"; }
fail() { echo -e "  ${RED}ERROR${RESET} $1"; exit 1; }

echo -e "${BOLD}ClaudeBar Installer${RESET}"
echo -e "${DIM}macOS menubar app for Claude Code usage & stats${RESET}"

# ── Step 1: Check prerequisites ──────────────────────────────────────

step 1 "Checking prerequisites"

if ! command -v swiftc &>/dev/null; then
    fail "swiftc not found. Install Xcode Command Line Tools: xcode-select --install"
fi
ok "swiftc found"

if [ ! -d "$CLAUDE_DIR" ]; then
    fail "~/.claude/ not found. Install and run Claude Code first."
fi
ok "~/.claude/ exists"

if ! command -v claude &>/dev/null; then
    warn "claude CLI not found in PATH (version display will show 'Unknown')"
else
    ok "claude CLI found ($(claude --version 2>/dev/null || echo 'unknown'))"
fi

# ── Step 2: Build ────────────────────────────────────────────────────

step 2 "Building ClaudeBar"

cd "$INSTALL_DIR"
swiftc -parse-as-library \
    -framework SwiftUI \
    -framework AppKit \
    -O \
    -o ClaudeBar ClaudeBarApp.swift

ok "Built $INSTALL_DIR/ClaudeBar"

# ── Step 3: Statusline hook ──────────────────────────────────────────

step 3 "Setting up statusline hook"

# 3a: Create the statusline script
cat > "$STATUSLINE_SCRIPT" << 'HOOKSCRIPT'
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
except:
    pass
" 2>/dev/null
HOOKSCRIPT
chmod +x "$STATUSLINE_SCRIPT"
ok "Created $STATUSLINE_SCRIPT"

# 3b: Add statusLine to settings.json if not already present
EXPECTED_COMMAND="bash $STATUSLINE_SCRIPT"

if [ ! -f "$SETTINGS_FILE" ]; then
    echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"$EXPECTED_COMMAND\"}}" \
        | python3 -m json.tool > "$SETTINGS_FILE"
    ok "Created $SETTINGS_FILE with statusLine"
elif python3 -c "
import json, sys
with open('$SETTINGS_FILE') as f:
    d = json.load(f)
sl = d.get('statusLine')
if sl and isinstance(sl, dict) and sl.get('command','').find('claudebar') != -1:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    skip "statusLine already configured in settings.json"
else
    python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    d = json.load(f)
d['statusLine'] = {'type': 'command', 'command': '$EXPECTED_COMMAND'}
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
" 2>/dev/null
    if [ $? -eq 0 ]; then
        ok "Added statusLine to $SETTINGS_FILE"
    else
        warn "Could not update settings.json automatically."
        echo -e "  Add this to your ${BOLD}~/.claude/settings.json${RESET}:"
        echo -e "  ${DIM}\"statusLine\": {\"type\": \"command\", \"command\": \"bash $STATUSLINE_SCRIPT\"}${RESET}"
    fi
fi

# ── Step 4: Done ─────────────────────────────────────────────────────

step 4 "Ready"

echo -e "\n  Run the app:"
echo -e "    ${BOLD}$INSTALL_DIR/ClaudeBar${RESET}"
echo ""
echo -e "  Or build a distributable .app bundle:"
echo -e "    ${DIM}./build-app.sh${RESET}"
echo ""
echo -e "  ${DIM}The sparkle icon will appear in your menu bar."
echo -e "  Usage data populates when you use Claude Code in a terminal.${RESET}"
echo ""
