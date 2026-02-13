#!/bin/bash
# tmux-log-pipe.sh - Receives tmux pipe-pane output, strips ANSI, writes to log
# Called by tmux pipe-pane: pipe-pane "exec ~/.claude/scripts/tmux-log-pipe.sh '#{session_name}'"
#
# One file per session lifetime: {session}_{YYYY-MM-DD-HHMM}.log
# No rotation - file is bound to session lifetime.

set -u

SESSION_NAME="${1:-unknown}"
LOG_DIR="$HOME/.claude/logs/tmux"
mkdir -p "$LOG_DIR"

# Generate timestamp once at startup - this file lives for the session's lifetime
TIMESTAMP=$(date '+%Y-%m-%d-%H%M')
LOG_FILE="${LOG_DIR}/${SESSION_NAME}_${TIMESTAMP}.log"

# Use perl as the main processor for performance
# Strips ANSI escape sequences and writes clean text to log file
exec perl -e '
    use strict;
    my $log_file = $ARGV[0];

    open(my $fh, ">>", $log_file) or die "Cannot open $log_file: $!";
    select $fh; $| = 1; select STDOUT;

    while (<STDIN>) {
        # Strip ANSI escape sequences
        s/\e\[\??[0-9;]*[a-zA-Z]//g;    # CSI sequences incl DEC private mode (?-prefixed)
        s/\e\[[0-9;]*[hlm]//g;          # Catch remaining mode set/reset
        s/\e\][^\x07]*\x07//g;           # OSC sequences (BEL terminated)
        s/\e\][^\e]*\e\\//g;             # OSC sequences (ST terminated)
        s/\e[()][AB012]//g;              # Character set selection
        s/\e[>=]//g;                      # Keypad modes
        s/\e\[\?[0-9;]*[hl]//g;         # DEC private mode set/reset
        s/\r//g;                          # Carriage returns

        # Skip empty lines from stripping
        next if /^\s*$/;

        print $fh $_;
    }
    close $fh;
' "$LOG_FILE"
