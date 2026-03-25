#!/bin/bash
# teams-watch-daemon.sh — Background daemon that polls Teams conversations for replies
# and resumes waiting Claude agents via inject-prompt.sh
#
# Usage:
#   teams-watch-daemon.sh start    Start daemon in background
#   teams-watch-daemon.sh stop     Stop running daemon
#   teams-watch-daemon.sh status   Show daemon status
#   teams-watch-daemon.sh run      Run in foreground (for debugging)

set -uo pipefail

WATCH_DIR="$HOME/.claude/teams-watches"
COMPLETED_DIR="$WATCH_DIR/completed"
PID_FILE="$WATCH_DIR/daemon.pid"
LOG_FILE="$HOME/.claude/logs/teams-watch-daemon.log"
INJECT_SCRIPT="$HOME/.claude/telegram-orchestrator/inject-prompt.sh"
TEAMS_API="$HOME/.claude/scripts/teams-api.sh"
TELEGRAM_SEND="$HOME/.claude/telegram-orchestrator/send-summary.sh"

POLL_INTERVAL="${TEAMS_WATCH_INTERVAL:-60}"
SELF_USER_ID="873ef3a0-041c-458f-8af5-c44e6db0dcaf"

mkdir -p "$WATCH_DIR" "$COMPLETED_DIR" "$(dirname "$LOG_FILE")"

# ─── Logging ────────────────────────────────────────────

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" >> "$LOG_FILE"
}

log_and_echo() {
  log "$@"
  echo "$@"
}

# ─── Session State Detection ───────────────────────────

detect_session_state() {
  local session="$1"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "dead"
    return
  fi

  local pane_content
  pane_content=$(tmux capture-pane -t "$session" -p -l 20 2>/dev/null || echo "")

  if echo "$pane_content" | grep -qiE "esc to interrupt|thinking|Pondering|Reasoning|Waiting|Reading|Writing"; then
    echo "working"
  elif echo "$pane_content" | grep -qiE "↵ send|Press up to edit|queued messages"; then
    echo "input_pending"
  elif echo "$pane_content" | grep -qiE "bypass permissions"; then
    echo "idle"
  else
    echo "unknown"
  fi
}

# ─── Criteria Evaluation ───────────────────────────────

evaluate_criteria() {
  local watch_file="$1"
  local reply_body="$2"
  local reply_from="$3"

  local mode min_length keywords from_filter
  mode=$(python3 -c "import json; print(json.load(open('$watch_file')).get('criteria',{}).get('mode','any_reply'))")
  min_length=$(python3 -c "import json; print(json.load(open('$watch_file')).get('criteria',{}).get('minLength',0))")
  keywords=$(python3 -c "import json; print(','.join(json.load(open('$watch_file')).get('criteria',{}).get('keywords',[])))")
  from_filter=$(python3 -c "import json; print(json.load(open('$watch_file')).get('criteria',{}).get('fromFilter',''))")

  # Check min length
  local body_len=${#reply_body}
  if (( body_len < min_length )); then
    log "  Criteria: body too short ($body_len < $min_length)"
    return 1
  fi

  case "$mode" in
    any_reply)
      return 0
      ;;
    keyword_match)
      if [[ -z "$keywords" ]]; then
        return 0  # no keywords = match all
      fi
      local IFS=','
      for kw in $keywords; do
        kw=$(echo "$kw" | xargs)  # trim
        if echo "$reply_body" | grep -qi "$kw"; then
          log "  Criteria: keyword '$kw' matched"
          return 0
        fi
      done
      log "  Criteria: no keywords matched"
      return 1
      ;;
    from_specific)
      if [[ -z "$from_filter" ]]; then
        return 0
      fi
      if echo "$reply_from" | grep -qi "$from_filter"; then
        return 0
      fi
      log "  Criteria: from filter '$from_filter' not matched (got '$reply_from')"
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

# ─── Build Resume Prompt ───────────────────────────────

build_resume_prompt() {
  local watch_file="$1"
  local replies_json="$2"

  python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    watch = json.load(f)

replies = json.loads(sys.argv[2])

prompt_parts = ['[Teams Reply Monitor] New reply detected in your watched conversation.', '']

for r in replies:
    from_name = r.get('from', 'Unknown')
    time = r.get('time', '')
    body = r.get('body', '')
    prompt_parts.append(f'**From:** {from_name} ({time})')
    prompt_parts.append(f'**Message:**')
    prompt_parts.append(body)
    prompt_parts.append('')

original = watch.get('originalMessage', '')
if original:
    prompt_parts.append('---')
    prompt_parts.append(f'**Your original message:** {original}')
    prompt_parts.append('')

prompt_parts.append('Continue your work with this new information. If you need to reply, use /teams send.')
prompt_parts.append('To watch for another reply, use /teams watch.')

print('\n'.join(prompt_parts))
" "$watch_file" "$replies_json"
}

# ─── Process Single Watch ──────────────────────────────

process_watch() {
  local watch_file="$1"
  local session
  session=$(python3 -c "import json; print(json.load(open('$watch_file')).get('sessionName',''))")
  local chat_id
  chat_id=$(python3 -c "import json; print(json.load(open('$watch_file')).get('chatId',''))")
  local last_msg_time
  last_msg_time=$(python3 -c "import json; print(json.load(open('$watch_file')).get('lastMessageTime',''))")
  local status
  status=$(python3 -c "import json; print(json.load(open('$watch_file')).get('status',''))")

  if [[ "$status" != "active" ]]; then
    return
  fi

  log "Processing watch: $session (chat: ${chat_id:0:30}...)"

  # Check expiry
  local expires_at
  expires_at=$(python3 -c "import json; print(json.load(open('$watch_file')).get('expiresAt',''))")
  local now_epoch expires_epoch
  now_epoch=$(date +%s)
  if [[ "$(uname)" == "Darwin" ]]; then
    expires_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expires_at" '+%s' 2>/dev/null || echo "0")
  else
    expires_epoch=$(date -u -d "$expires_at" '+%s' 2>/dev/null || echo "0")
  fi

  if (( now_epoch >= expires_epoch )); then
    log "  Watch expired for $session"
    python3 -c "
import json
with open('$watch_file') as f:
    w = json.load(f)
w['status'] = 'expired'
with open('$watch_file', 'w') as f:
    json.dump(w, f, indent=2)
"
    mv "$watch_file" "$COMPLETED_DIR/$(basename "$watch_file" .json)-$(date +%s).json"
    # Notify via Telegram
    if [[ -x "$TELEGRAM_SEND" ]]; then
      "$TELEGRAM_SEND" --session "teams-watch" "⏰ <b>Teams Watch Expired</b>

Session <code>$session</code> watch expired after timeout.
No reply was received." 2>/dev/null || true
    fi
    return
  fi

  # Check if session is alive
  local session_state
  session_state=$(detect_session_state "$session")
  if [[ "$session_state" == "dead" ]]; then
    log "  Session $session is dead, marking watch orphaned"
    python3 -c "
import json
with open('$watch_file') as f:
    w = json.load(f)
w['status'] = 'orphaned'
with open('$watch_file', 'w') as f:
    json.dump(w, f, indent=2)
"
    mv "$watch_file" "$COMPLETED_DIR/$(basename "$watch_file" .json)-$(date +%s).json"
    return
  fi

  # Poll Teams for new messages
  local raw_messages
  raw_messages=$("$TEAMS_API" read-chat "$chat_id" 5 2>/dev/null || echo "[]")

  # Filter new messages from non-self
  local new_replies
  new_replies=$(python3 -c "
import json, sys

raw = json.loads(sys.argv[1])
last_time = sys.argv[2]
self_id = sys.argv[3]

new = []
for m in raw:
    msg_time = m.get('time', '')
    # Compare ISO timestamps as strings (works for same timezone)
    if msg_time > last_time:
        new.append(m)

# Reverse to chronological order (API returns newest first)
new.reverse()
print(json.dumps(new, ensure_ascii=False))
" "$raw_messages" "$last_msg_time" "$SELF_USER_ID" 2>/dev/null || echo "[]")

  local reply_count
  reply_count=$(python3 -c "import json; print(len(json.loads('''$new_replies''')))" 2>/dev/null || echo "0")

  if (( reply_count == 0 )); then
    log "  No new replies for $session"
    return
  fi

  log "  Found $reply_count new reply(s) for $session"

  # Get first reply details for criteria check
  local first_from first_body
  first_from=$(python3 -c "import json; r=json.loads('''$new_replies'''); print(r[0].get('from','') if r else '')" 2>/dev/null)
  first_body=$(python3 -c "import json; r=json.loads('''$new_replies'''); print(r[0].get('body','') if r else '')" 2>/dev/null)

  # Evaluate criteria
  if ! evaluate_criteria "$watch_file" "$first_body" "$first_from"; then
    log "  Criteria not met, updating lastMessageTime"
    # Update lastMessageTime to latest message time
    python3 -c "
import json
raw = json.loads('''$new_replies''')
if raw:
    latest = max(m.get('time','') for m in raw)
    with open('$watch_file') as f:
        w = json.load(f)
    w['lastMessageTime'] = latest
    with open('$watch_file', 'w') as f:
        json.dump(w, f, indent=2)
" 2>/dev/null
    return
  fi

  # Check session state before injecting
  if [[ "$session_state" == "working" ]]; then
    log "  Session $session is working, will retry next cycle"
    return
  fi

  # Build and inject resume prompt
  log "  Building resume prompt and injecting into $session"
  local resume_prompt
  resume_prompt=$(build_resume_prompt "$watch_file" "$new_replies")

  if [[ -x "$INJECT_SCRIPT" ]]; then
    "$INJECT_SCRIPT" "$session" "$resume_prompt" >> "$LOG_FILE" 2>&1
    log "  Injected resume prompt into $session"
  else
    log "  ERROR: inject-prompt.sh not found or not executable"
    return
  fi

  # Move watch to completed
  python3 -c "
import json
with open('$watch_file') as f:
    w = json.load(f)
w['status'] = 'triggered'
w['triggeredAt'] = '$(date -u '+%Y-%m-%dT%H:%M:%SZ')'
with open('$watch_file', 'w') as f:
    json.dump(w, f, indent=2)
"
  mv "$watch_file" "$COMPLETED_DIR/$(basename "$watch_file" .json)-$(date +%s).json"
  log "  Watch completed and moved for $session"

  # Notify via Telegram
  if [[ -x "$TELEGRAM_SEND" ]]; then
    "$TELEGRAM_SEND" --session "teams-watch" "🔔 <b>Teams Reply → Agent Resumed</b>

<code>$session</code> received a Teams reply from <b>$first_from</b>.
Reply injected, agent should resume working." 2>/dev/null || true
  fi
}

# ─── Main Loop ──────────────────────────────────────────

run_daemon() {
  log "Daemon started (PID $$, interval ${POLL_INTERVAL}s)"

  trap 'log "Daemon stopping (SIGTERM)"; rm -f "$PID_FILE"; exit 0' SIGTERM
  trap 'log "Daemon stopping (SIGINT)"; rm -f "$PID_FILE"; exit 0' SIGINT

  echo $$ > "$PID_FILE"

  while true; do
    local watch_files=()
    for f in "$WATCH_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      watch_files+=("$f")
    done

    if (( ${#watch_files[@]} > 0 )); then
      log "Checking ${#watch_files[@]} active watch(es)"
      for wf in "${watch_files[@]}"; do
        process_watch "$wf" || true
        sleep 2  # small delay between watches to avoid n8n rate issues
      done
    fi

    sleep "$POLL_INTERVAL"
  done
}

# ─── CLI ────────────────────────────────────────────────

cmd_start() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    log_and_echo "Daemon already running (PID $(cat "$PID_FILE"))"
    return
  fi

  log_and_echo "Starting teams-watch daemon..."
  nohup "$0" run >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo $pid > "$PID_FILE"
  log_and_echo "Daemon started (PID $pid)"
  log_and_echo "Log: $LOG_FILE"
}

cmd_stop() {
  if [[ ! -f "$PID_FILE" ]]; then
    log_and_echo "Daemon not running (no PID file)"
    return
  fi

  local pid
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    rm -f "$PID_FILE"
    log_and_echo "Daemon stopped (PID $pid)"
  else
    rm -f "$PID_FILE"
    log_and_echo "Daemon was not running (stale PID file removed)"
  fi
}

cmd_status() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Daemon: RUNNING (PID $(cat "$PID_FILE"))"
  else
    echo "Daemon: STOPPED"
  fi

  local watch_count
  watch_count=$(find "$WATCH_DIR" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  echo "Active watches: $watch_count"

  if (( watch_count > 0 )); then
    echo ""
    "$HOME/.claude/telegram-orchestrator/scripts/teams-watch.sh" list
  fi
}

case "${1:-help}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  run)    run_daemon ;;
  help|*)
    cat << 'EOF'
Usage: teams-watch-daemon.sh <command>

Commands:
  start    Start daemon in background
  stop     Stop running daemon
  status   Show daemon and watch status
  run      Run in foreground (for debugging)

Environment:
  TEAMS_WATCH_INTERVAL  Poll interval in seconds (default: 60)
EOF
    ;;
esac
