#!/bin/bash
# Play stop sound with dedup — only one ding at a time
# Uses atomic mkdir lock, exits silently if another is already playing

LOCK_DIR="/tmp/claude-stop-sound.lockdir"

# Try to acquire lock atomically
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Another ding is playing, skip
    exit 0
fi

trap "rm -rf '$LOCK_DIR'" EXIT

/usr/bin/afplay /System/Library/Sounds/Blow.aiff 2>/dev/null
