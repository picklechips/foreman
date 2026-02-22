#!/usr/bin/env bash
set -euo pipefail

# ─── Foreman Server Setup ─────────────────────────────────────────────────────
# Run this once on the machine that will host the relay daemon.
# Idempotent — safe to run multiple times.

FOREMAN_DIR="$HOME/.foreman"
CONFIG_FILE="$FOREMAN_DIR/config.json"
TOKEN_FILE="$FOREMAN_DIR/token"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOKS_PORT=7822

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

ok()     { echo -e "${GREEN}✓${RESET} $1"; }
warn()   { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

# ─── Dependency checks ────────────────────────────────────────────────────────
header "Checking dependencies..."

node_version=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo "0")
if [ "$node_version" -lt 22 ]; then
  err "Node.js 22+ is required (found: $(node --version 2>/dev/null || echo 'not installed')). Install from https://nodejs.org"
fi
ok "Node.js $(node --version)"

if ! command -v tmux &>/dev/null; then
  err "tmux is required. Install with: brew install tmux (macOS) or apt install tmux (Linux)"
fi
ok "tmux $(tmux -V)"

if ! command -v claude &>/dev/null; then
  err "Claude Code CLI is required. Install with: npm install -g @anthropic-ai/claude-code"
fi
ok "claude $(claude --version 2>/dev/null || echo 'installed')"

if ! command -v openssl &>/dev/null; then
  err "openssl is required (should be pre-installed on macOS/Linux)"
fi
ok "openssl"

# ─── Get Tailscale IP ─────────────────────────────────────────────────────────
header "Detecting Tailscale IP..."

TAILSCALE_IP=""
if command -v tailscale &>/dev/null; then
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
fi

if [ -z "$TAILSCALE_IP" ]; then
  warn "Tailscale not found or not connected. The relay daemon will bind to 127.0.0.1 (loopback only)."
  warn "Install Tailscale from https://tailscale.com to access from your phone."
  BIND_HOST="127.0.0.1"
else
  ok "Tailscale IP: $TAILSCALE_IP"
  BIND_HOST="$TAILSCALE_IP"
fi

# ─── Create directory structure ───────────────────────────────────────────────
header "Creating ~/.foreman directory structure..."

mkdir -p "$FOREMAN_DIR"/{transcripts,pipes,logs}
# Set restrictive permissions on all foreman directories — transcripts contain
# conversation history and pipes are used for process communication.
chmod 700 "$FOREMAN_DIR" "$FOREMAN_DIR/transcripts" "$FOREMAN_DIR/pipes" "$FOREMAN_DIR/logs"
ok "Created $FOREMAN_DIR"

# ─── Generate bearer token (only if not already set) ─────────────────────────
if [ ! -f "$TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  ok "Generated bearer token → $TOKEN_FILE"
else
  ok "Bearer token already exists (not overwritten)"
fi

# ─── Write config (only if not already set) ───────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
  # Prompt for allowed directories
  echo ""
  echo "Enter the directories your agents are allowed to work in."
  echo "Separate multiple paths with commas. Example: ~/projects,~/work"
  read -r -p "Allowed directories [~/projects]: " ALLOWED_INPUT
  ALLOWED_INPUT="${ALLOWED_INPUT:-~/projects}"

  # Prompt for ntfy topic
  echo ""
  echo "Foreman uses ntfy.sh for push notifications."
  echo "Leave blank to skip (you can add it later in $CONFIG_FILE)."
  read -r -p "ntfy topic name (or leave blank): " NTFY_TOPIC

  # Use node to safely serialize config to JSON — avoids shell string injection
  # from user-supplied directory paths or ntfy topic values.
  node - "$CONFIG_FILE" "$BIND_HOST" "$ALLOWED_INPUT" "${NTFY_TOPIC:-}" "$HOOKS_PORT" << 'JSEOF'
const fs = require('fs');
const [, , configPath, bindHost, allowedInput, ntfyTopic, hooksPort] = process.argv;

const allowedDirs = allowedInput
  .split(',')
  .map(d => d.trim())
  .filter(Boolean);

const config = {
  port: 7821,
  hooksPort: parseInt(hooksPort, 10),
  bindHost,
  allowedDirs,
  model: 'claude-opus-4-6',
  ntfyTopic: ntfyTopic || '',
};

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
JSEOF

  chmod 600 "$CONFIG_FILE"
  ok "Created $CONFIG_FILE"
else
  ok "Config already exists (not overwritten) → $CONFIG_FILE"
fi

# ─── Install Claude Code hooks ────────────────────────────────────────────────
header "Installing Claude Code hooks..."

mkdir -p "$HOME/.claude"

# If settings.json doesn't exist, create a minimal one
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo '{}' > "$CLAUDE_SETTINGS"
fi

# Use node to safely merge hooks into existing settings (avoids clobbering)
node - "$CLAUDE_SETTINGS" "$HOOKS_PORT" << 'JSEOF'
const fs = require('fs');
const [, , settingsPath, hooksPort] = process.argv;

let settings = {};
try {
  settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
} catch {}

settings.hooks = settings.hooks ?? {};

settings.hooks.Stop = [{
  hooks: [{
    type: 'command',
    command: `curl -s -X POST http://127.0.0.1:${hooksPort}/hook/stop -H 'Content-Type: application/json' -d @-`,
  }],
}];

settings.hooks.Notification = [{
  hooks: [{
    type: 'command',
    command: `curl -s -X POST http://127.0.0.1:${hooksPort}/hook/notification -H 'Content-Type: application/json' -d @-`,
  }],
}];

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2));
JSEOF

ok "Claude Code hooks installed → $CLAUDE_SETTINGS"

# ─── Generate launchd plist (macOS) ───────────────────────────────────────────
if [[ "$OSTYPE" == "darwin"* ]]; then
  PLIST_PATH="$HOME/Library/LaunchAgents/com.foreman.relay.plist"
  RELAY_BIN=$(command -v foreman-relay 2>/dev/null || echo "$HOME/.foreman/bin/foreman-relay")

  if [ ! -f "$PLIST_PATH" ]; then
    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.foreman.relay</string>
    <key>ProgramArguments</key>
    <array>
        <string>$RELAY_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$FOREMAN_DIR/logs/relay.log</string>
    <key>StandardErrorPath</key>
    <string>$FOREMAN_DIR/logs/relay.error.log</string>
</dict>
</plist>
EOF
    ok "Created launchd plist → $PLIST_PATH"
    warn "To start the relay daemon now: launchctl load $PLIST_PATH"
  else
    ok "launchd plist already exists (not overwritten)"
  fi
fi

# ─── Print summary ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Foreman setup complete!${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "Add these details to the Foreman app on your phone:"
echo ""
echo -e "  ${BOLD}Host:${RESET}  ${BIND_HOST}"
echo -e "  ${BOLD}Port:${RESET}  7821"
echo -e "  ${BOLD}Token:${RESET} (run: cat ${TOKEN_FILE})"

NTFY_TOPIC_SAVED=$(node -e "try{const c=require('${CONFIG_FILE}');console.log(c.ntfyTopic||'')}catch{}" 2>/dev/null || echo "")
if [ -n "$NTFY_TOPIC_SAVED" ]; then
  echo -e "  ${BOLD}ntfy topic:${RESET} ${NTFY_TOPIC_SAVED}"
fi

echo ""
echo "To start the relay daemon:"
echo "  foreman-relay"
echo ""
