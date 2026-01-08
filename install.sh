#!/bin/bash
# Claude Telegram Orchestrator - Installer
# Run: curl -sL <raw-url> | bash
# Or: ./install.sh

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║       Claude Telegram Orchestrator - Installer             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check dependencies
echo "Checking dependencies..."

if ! command -v tmux &> /dev/null; then
    echo "Installing tmux..."
    if command -v brew &> /dev/null; then
        brew install tmux
    else
        echo "❌ Please install Homebrew first: https://brew.sh"
        exit 1
    fi
fi

if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    brew install jq
fi

if ! command -v claude &> /dev/null; then
    echo "❌ Claude Code CLI not found. Install from: https://claude.ai/code"
    exit 1
fi

echo "✅ Dependencies OK"
echo ""

# Get configuration
INSTALL_DIR="$HOME/.claude/telegram-orchestrator"
mkdir -p "$INSTALL_DIR/sessions" "$INSTALL_DIR/logs"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Setup your Telegram Bot:"
echo ""
echo "1. Open Telegram and message @BotFather"
echo "2. Send /newbot and follow instructions"
echo "3. Copy the bot token (looks like: 123456789:ABCdefGHI...)"
echo ""
read -p "Paste your bot token: " BOT_TOKEN

if [[ -z "$BOT_TOKEN" ]]; then
    echo "❌ Bot token required"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Now send any message to your bot in Telegram..."
echo "Waiting for your message to detect Chat ID..."

# Poll for chat ID
CHAT_ID=""
for i in {1..30}; do
    sleep 2
    RESPONSE=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates")
    CHAT_ID=$(echo "$RESPONSE" | jq -r '.result[-1].message.chat.id // empty')
    if [[ -n "$CHAT_ID" ]]; then
        echo "✅ Detected Chat ID: $CHAT_ID"
        break
    fi
    echo -n "."
done

if [[ -z "$CHAT_ID" ]]; then
    echo ""
    echo "⚠️  Could not auto-detect Chat ID."
    read -p "Enter your Telegram Chat ID manually: " CHAT_ID
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Installing files..."

# Create config
cat > "$INSTALL_DIR/config.env" << EOF
# Telegram Claude Orchestrator Configuration
TELEGRAM_BOT_TOKEN="$BOT_TOKEN"
TELEGRAM_CHAT_ID="$CHAT_ID"
POLL_INTERVAL=5
MAX_SESSIONS=5
EOF

# Download/copy scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/orchestrator.sh" ]]; then
    # Local install
    cp "$SCRIPT_DIR/orchestrator.sh" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/session-monitor.sh" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/start-claude.sh" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/notify.sh" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/tg" "$INSTALL_DIR/"
else
    echo "❌ Script files not found. Run from the repo directory."
    exit 1
fi

chmod +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR/tg"

# Create LaunchAgent
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.claude.telegram-orchestrator.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.telegram-orchestrator</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/orchestrator.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/logs/launchd.err.log</string>
    <key>WorkingDirectory</key>
    <string>$INSTALL_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF

# Add shell alias
SHELL_RC="$HOME/.zshrc"
[[ -f "$HOME/.bashrc" ]] && SHELL_RC="$HOME/.bashrc"

if ! grep -q "telegram-orchestrator/tg" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Claude Telegram Orchestrator" >> "$SHELL_RC"
    echo "alias tg=\"$INSTALL_DIR/tg\"" >> "$SHELL_RC"
fi

# Set Telegram bot commands
echo "Setting up bot commands..."
curl -s "https://api.telegram.org/bot${BOT_TOKEN}/setMyCommands" \
    -H "Content-Type: application/json" \
    -d '{
        "commands": [
            {"command": "status", "description": "List active Claude sessions"},
            {"command": "new", "description": "Start new Claude session"},
            {"command": "kill", "description": "Stop a session (e.g. /kill 1)"},
            {"command": "tts", "description": "Toggle TTS read-aloud on/off"},
            {"command": "1", "description": "Send to session claude-1"},
            {"command": "2", "description": "Send to session claude-2"},
            {"command": "3", "description": "Send to session claude-3"}
        ]
    }' > /dev/null

# Start the service
echo "Starting orchestrator..."
launchctl load "$HOME/Library/LaunchAgents/com.claude.telegram-orchestrator.plist" 2>/dev/null || true

# Create tmux config if missing
if [[ ! -f "$HOME/.tmux.conf" ]]; then
    cat > "$HOME/.tmux.conf" << 'EOF'
set -g mouse on
set -g history-limit 50000
set -g default-terminal "screen-256color"
set -g base-index 1
EOF
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    ✅ Installation Complete!               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Usage (from Telegram):"
echo "  /new            Start new Claude session"
echo "  /new <task>     Start with initial task"
echo "  /1 <message>    Send to session 1"
echo "  /status         List sessions"
echo "  /kill 1         Kill session 1"
echo "  /tts            Toggle TTS"
echo ""
echo "Usage (from Terminal):"
echo "  tg status       List sessions"
echo "  tg new          Start session"
echo "  tg attach 1     Attach to session"
echo "  tg logs         View logs"
echo ""
echo "Restart your terminal or run: source $SHELL_RC"
echo ""
