#!/bin/bash
# teams-watch.sh — Register/manage Teams conversation watches
# Usage:
#   teams-watch.sh register --session <name> --chat-id <id> --last-msg-time <iso> \
#     [--last-msg-id <id>] [--original-msg <text>] [--timeout <duration>] \
#     [--criteria-mode <mode>] [--keywords <csv>] [--min-length <n>] [--from-filter <name>]
#   teams-watch.sh unregister --session <name>
#   teams-watch.sh list
#   teams-watch.sh status [--session <name>]

set -euo pipefail

WATCH_DIR="$HOME/.claude/teams-watches"
COMPLETED_DIR="$WATCH_DIR/completed"

mkdir -p "$WATCH_DIR" "$COMPLETED_DIR"

# ─── Helpers ────────────────────────────────────────────

log() { echo "[teams-watch] $*" >&2; }

parse_timeout() {
  local timeout="$1"
  local now
  now=$(date +%s)
  local seconds=0

  if [[ "$timeout" =~ ^([0-9]+)h$ ]]; then
    seconds=$(( ${BASH_REMATCH[1]} * 3600 ))
  elif [[ "$timeout" =~ ^([0-9]+)m$ ]]; then
    seconds=$(( ${BASH_REMATCH[1]} * 60 ))
  elif [[ "$timeout" =~ ^([0-9]+)d$ ]]; then
    seconds=$(( ${BASH_REMATCH[1]} * 86400 ))
  elif [[ "$timeout" =~ ^([0-9]+)$ ]]; then
    seconds=$(( ${BASH_REMATCH[1]} * 3600 ))  # default to hours
  else
    seconds=86400  # default 24h
  fi

  local expires_epoch=$(( now + seconds ))
  if [[ "$(uname)" == "Darwin" ]]; then
    date -u -r "$expires_epoch" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "@$expires_epoch" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

is_expired() {
  local expires_at="$1"
  local now
  now=$(date +%s)
  local exp
  if [[ "$(uname)" == "Darwin" ]]; then
    exp=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expires_at" '+%s' 2>/dev/null || echo "0")
  else
    exp=$(date -u -d "$expires_at" '+%s' 2>/dev/null || echo "0")
  fi
  [[ "$now" -ge "$exp" ]]
}

age_human() {
  local created_at="$1"
  local now
  now=$(date +%s)
  local created
  if [[ "$(uname)" == "Darwin" ]]; then
    created=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" '+%s' 2>/dev/null || echo "$now")
  else
    created=$(date -u -d "$created_at" '+%s' 2>/dev/null || echo "$now")
  fi
  local diff=$(( now - created ))
  if (( diff < 60 )); then
    echo "${diff}s"
  elif (( diff < 3600 )); then
    echo "$(( diff / 60 ))m"
  elif (( diff < 86400 )); then
    echo "$(( diff / 3600 ))h $(( (diff % 3600) / 60 ))m"
  else
    echo "$(( diff / 86400 ))d $(( (diff % 86400) / 3600 ))h"
  fi
}

# ─── Commands ───────────────────────────────────────────

cmd_register() {
  local session="" chat_id="" last_msg_id="" last_msg_time=""
  local original_msg="" timeout="24h" resume_prompt=""
  local criteria_mode="any_reply" keywords="" min_length=0 from_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session)       session="$2"; shift 2 ;;
      --chat-id)       chat_id="$2"; shift 2 ;;
      --last-msg-id)   last_msg_id="$2"; shift 2 ;;
      --last-msg-time) last_msg_time="$2"; shift 2 ;;
      --original-msg)  original_msg="$2"; shift 2 ;;
      --timeout)       timeout="$2"; shift 2 ;;
      --resume-prompt) resume_prompt="$2"; shift 2 ;;
      --criteria-mode) criteria_mode="$2"; shift 2 ;;
      --keywords)      keywords="$2"; shift 2 ;;
      --min-length)    min_length="$2"; shift 2 ;;
      --from-filter)   from_filter="$2"; shift 2 ;;
      *) log "Unknown option: $1"; shift ;;
    esac
  done

  if [[ -z "$session" || -z "$chat_id" || -z "$last_msg_time" ]]; then
    echo '{"error": "Required: --session, --chat-id, --last-msg-time"}'
    exit 1
  fi

  local expires_at
  expires_at=$(parse_timeout "$timeout")
  local created_at
  created_at=$(now_iso)

  # Build keywords array
  local keywords_json="[]"
  if [[ -n "$keywords" ]]; then
    keywords_json=$(python3 -c "import json; print(json.dumps([k.strip() for k in '$keywords'.split(',')]))")
  fi

  local watch_file="$WATCH_DIR/${session}.json"

  python3 -c "
import json, sys
watch = {
    'chatId': sys.argv[1],
    'lastMessageId': sys.argv[2],
    'lastMessageTime': sys.argv[3],
    'sessionName': sys.argv[4],
    'originalMessage': sys.argv[5],
    'resumePrompt': sys.argv[6],
    'criteria': {
        'mode': sys.argv[7],
        'keywords': json.loads(sys.argv[8]),
        'minLength': int(sys.argv[9]),
        'fromFilter': sys.argv[10]
    },
    'timeout': sys.argv[11],
    'createdAt': sys.argv[12],
    'expiresAt': sys.argv[13],
    'status': 'active'
}
with open(sys.argv[14], 'w') as f:
    json.dump(watch, f, indent=2, ensure_ascii=False)
print(json.dumps({'status': 'registered', 'session': sys.argv[4], 'expiresAt': sys.argv[13], 'watchFile': sys.argv[14]}))
" "$chat_id" "$last_msg_id" "$last_msg_time" "$session" \
  "$original_msg" "$resume_prompt" "$criteria_mode" "$keywords_json" \
  "$min_length" "$from_filter" "$timeout" "$created_at" "$expires_at" "$watch_file"

  # Ensure daemon is running
  local pid_file="$WATCH_DIR/daemon.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    : # daemon already running
  else
    log "Daemon not running. Start it with: teams-watch-daemon.sh start"
  fi
}

cmd_unregister() {
  local session=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      *) session="$1"; shift ;;
    esac
  done

  if [[ -z "$session" ]]; then
    echo '{"error": "Required: --session <name>"}'
    exit 1
  fi

  local watch_file="$WATCH_DIR/${session}.json"
  if [[ -f "$watch_file" ]]; then
    # Move to completed with cancelled status
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    w = json.load(f)
w['status'] = 'cancelled'
w['cancelledAt'] = '$(now_iso)'
with open(sys.argv[2], 'w') as f:
    json.dump(w, f, indent=2)
" "$watch_file" "$COMPLETED_DIR/${session}-$(date +%s).json"
    rm -f "$watch_file"
    echo "{\"status\": \"unregistered\", \"session\": \"$session\"}"
  else
    echo "{\"error\": \"No active watch for session $session\"}"
  fi
}

cmd_list() {
  local watches=()
  for f in "$WATCH_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "daemon.pid" ]] && continue
    watches+=("$f")
  done

  if [[ ${#watches[@]} -eq 0 ]]; then
    echo "No active watches."
    return
  fi

  printf "%-15s %-10s %-20s %-10s %s\n" "SESSION" "STATUS" "CHAT" "AGE" "CRITERIA"
  printf "%-15s %-10s %-20s %-10s %s\n" "-------" "------" "----" "---" "--------"

  for f in "${watches[@]}"; do
    python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    w = json.load(fh)
session = w.get('sessionName', '?')
status = w.get('status', '?')
chat = w.get('chatId', '?')[:20]
created = w.get('createdAt', '')
mode = w.get('criteria', {}).get('mode', '?')
print(f'{session:<15} {status:<10} {chat:<20} {created:<28} {mode}')
" "$f"
  done
}

cmd_status() {
  local session=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session) session="$2"; shift 2 ;;
      *) session="$1"; shift ;;
    esac
  done

  # Daemon status
  local pid_file="$WATCH_DIR/daemon.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "Daemon: RUNNING (PID $(cat "$pid_file"))"
  else
    echo "Daemon: STOPPED"
  fi

  local watch_count
  watch_count=$(find "$WATCH_DIR" -maxdepth 1 -name "*.json" | wc -l | tr -d ' ')
  echo "Active watches: $watch_count"

  local completed_count
  completed_count=$(find "$COMPLETED_DIR" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  echo "Completed watches: $completed_count"
  echo ""

  if [[ -n "$session" ]]; then
    local watch_file="$WATCH_DIR/${session}.json"
    if [[ -f "$watch_file" ]]; then
      echo "Watch details for $session:"
      python3 -c "
import json
with open('$watch_file') as f:
    w = json.load(f)
for k, v in w.items():
    if isinstance(v, dict):
        print(f'  {k}:')
        for kk, vv in v.items():
            print(f'    {kk}: {vv}')
    else:
        val = str(v)
        if len(val) > 80:
            val = val[:77] + '...'
        print(f'  {k}: {val}')
"
    else
      echo "No active watch for session $session"
    fi
  else
    cmd_list
  fi
}

# ─── Main ───────────────────────────────────────────────

case "${1:-help}" in
  register)   shift; cmd_register "$@" ;;
  unregister) shift; cmd_unregister "$@" ;;
  list)       cmd_list ;;
  status)     shift; cmd_status "$@" ;;
  help|*)
    cat << 'EOF'
Usage: teams-watch.sh <command> [options]

Commands:
  register    Register a watch on a Teams conversation
              --session <name>       Session to resume (required)
              --chat-id <id>         Teams chat ID (required)
              --last-msg-time <iso>  ISO timestamp of last message (required)
              --last-msg-id <id>     Last message ID
              --original-msg <text>  Your original message text
              --timeout <duration>   Watch timeout (e.g. 24h, 30m, 2d) [default: 24h]
              --criteria-mode <mode> any_reply|keyword_match|from_specific [default: any_reply]
              --keywords <csv>       Comma-separated keywords (for keyword_match)
              --min-length <n>       Minimum reply length [default: 0]
              --from-filter <name>   Only trigger on replies from this person

  unregister  Cancel a watch
              --session <name>       Session to cancel watch for

  list        List all active watches
  status      Show daemon and watch status
              [--session <name>]     Show details for specific session
EOF
    ;;
esac
