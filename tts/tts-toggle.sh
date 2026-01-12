#!/bin/bash
# Toggle TTS on/off for Claude Code
#
# Usage: ./tts-toggle.sh [on|off|status]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
TTS_DIR="$PROJECT_DIR/.claude/tts"
ENABLED_FILE="$TTS_DIR/enabled"

# Fallback to home .claude if project-level doesn't exist
if [[ ! -d "$TTS_DIR" ]]; then
    TTS_DIR="$HOME/.claude/tts"
    ENABLED_FILE="$TTS_DIR/enabled"
fi

mkdir -p "$TTS_DIR/queue"

case "${1:-toggle}" in
    on|enable)
        touch "$ENABLED_FILE"
        echo "TTS enabled"
        say "Text to speech enabled" &
        ;;
    off|disable)
        rm -f "$ENABLED_FILE"
        echo "TTS disabled"
        ;;
    status)
        if [[ -f "$ENABLED_FILE" ]]; then
            echo "TTS is ON"
        else
            echo "TTS is OFF"
        fi
        ;;
    toggle|*)
        if [[ -f "$ENABLED_FILE" ]]; then
            rm -f "$ENABLED_FILE"
            echo "TTS disabled"
        else
            touch "$ENABLED_FILE"
            echo "TTS enabled"
            say "Text to speech enabled" &
        fi
        ;;
esac
