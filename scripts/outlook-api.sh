#!/bin/bash
# outlook-api.sh — Microsoft Outlook Email API via n8n oneshot workflow pattern
# Usage:
#   outlook-api.sh inbox [count]
#   outlook-api.sh read <message_id>
#   outlook-api.sh search <query>
#   outlook-api.sh search-from <email> [count]
#   outlook-api.sh search-subject <subject> [count]
#   outlook-api.sh send <to_email> <subject> <html_body>
#   outlook-api.sh reply <message_id> <html_body>
#   outlook-api.sh forward <message_id> <to_email> [comment]
#   outlook-api.sh draft <to_email> <subject> <html_body>
#   outlook-api.sh attachments <message_id>
#   outlook-api.sh folders
#   outlook-api.sh folder <folder_id> [count]
#
# Requires: N8N_API_KEY in ~/.claude/scripts/.teams-env or aws-n8n/.env.local

set -euo pipefail

OUTLOOK_CRED_ID="JQmgE6yvblQj6qoJ"
OUTLOOK_CRED_NAME="Microsoft Outlook Gergo account"
OUTLOOK_CRED_TYPE="microsoftOutlookOAuth2Api"
N8N_URL="https://n8n.dev.netlock.cloud"

# Load API key
load_api_key() {
  if [[ -f "$HOME/.claude/scripts/.teams-env" ]]; then
    source "$HOME/.claude/scripts/.teams-env"
  elif [[ -f "$HOME/work/aws-n8n/.env.local" ]]; then
    N8N_API_KEY=$(grep '^N8N_API_KEY=' "$HOME/work/aws-n8n/.env.local" | cut -d= -f2 | tr -d "'\"")
  fi
  if [[ -z "${N8N_API_KEY:-}" ]]; then
    echo '{"error": "N8N_API_KEY not found"}' >&2
    exit 1
  fi
}

# Create, activate, trigger (GET), cleanup
run_oneshot_get() {
  local json_file="$1"
  local webhook_path="$2"

  local wf_id
  wf_id=$(curl -sf -X POST "$N8N_URL/api/v1/workflows" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$json_file" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

  if [[ -z "$wf_id" ]]; then
    echo '{"error": "Failed to create workflow"}' >&2
    exit 1
  fi

  curl -sf -X POST "$N8N_URL/api/v1/workflows/$wf_id/activate" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1
  sleep 1

  local response
  response=$(curl -sf "$N8N_URL/webhook/$webhook_path" 2>/dev/null || echo '{"error": "webhook trigger failed"}')

  curl -sf -X POST "$N8N_URL/api/v1/workflows/$wf_id/deactivate" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1 || true
  curl -sf -X DELETE "$N8N_URL/api/v1/workflows/$wf_id" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1 || true

  echo "$response"
}

# Create, activate, trigger (POST with body), cleanup
run_oneshot_post() {
  local json_file="$1"
  local webhook_path="$2"
  local post_body="$3"

  local wf_id
  wf_id=$(curl -sf -X POST "$N8N_URL/api/v1/workflows" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$json_file" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

  if [[ -z "$wf_id" ]]; then
    echo '{"error": "Failed to create workflow"}' >&2
    exit 1
  fi

  curl -sf -X POST "$N8N_URL/api/v1/workflows/$wf_id/activate" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1
  sleep 1

  local response
  response=$(curl -sf -X POST "$N8N_URL/webhook/$webhook_path" \
    -H "Content-Type: application/json" \
    -d "$post_body" 2>/dev/null || echo '{"error": "webhook trigger failed"}')

  curl -sf -X POST "$N8N_URL/api/v1/workflows/$wf_id/deactivate" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1 || true
  curl -sf -X DELETE "$N8N_URL/api/v1/workflows/$wf_id" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1 || true

  echo "$response"
}

# Build a simple GET workflow (Webhook → HTTP GET → return)
build_get_workflow() {
  local webhook_path="$1"
  local graph_url="$2"
  local tmp_file="/tmp/outlook-wf-${webhook_path}.json"

  cat > "$tmp_file" << ENDJSON
{
  "name": "Outlook API ${webhook_path}",
  "nodes": [
    {
      "parameters": {
        "path": "${webhook_path}",
        "responseMode": "lastNode",
        "options": {}
      },
      "id": "webhook",
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 2,
      "position": [250, 300],
      "webhookId": "${webhook_path}"
    },
    {
      "parameters": {
        "method": "GET",
        "url": "=${graph_url}",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "${OUTLOOK_CRED_TYPE}",
        "options": {}
      },
      "id": "api-call",
      "name": "Graph API",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [450, 300],
      "credentials": {
        "${OUTLOOK_CRED_TYPE}": {
          "id": "${OUTLOOK_CRED_ID}",
          "name": "${OUTLOOK_CRED_NAME}"
        }
      }
    }
  ],
  "connections": {
    "Webhook": {"main": [[{"node": "Graph API", "type": "main", "index": 0}]]}
  },
  "settings": {"executionOrder": "v1"}
}
ENDJSON

  echo "$tmp_file"
}

# Build a multi-node workflow via Python (for complex POST operations)
build_python_workflow() {
  local webhook_path="$1"
  local python_code="$2"
  local tmp_file="/tmp/outlook-wf-${webhook_path}.json"

  python3 -c "$python_code" > "$tmp_file"
  echo "$tmp_file"
}

# Parse email list JSON into clean output
parse_email_list() {
  python3 -c "
import json, sys, re, html as htmlmod
data = json.loads(sys.stdin.read(), strict=False)
emails = data.get('value', [])
results = []
for e in emails:
    sender = e.get('from', {}).get('emailAddress', {})
    results.append({
        'id': e.get('id', ''),
        'subject': e.get('subject', '(no subject)'),
        'from': sender.get('name', '') + ' <' + sender.get('address', '') + '>',
        'date': e.get('receivedDateTime', ''),
        'isRead': e.get('isRead', False),
        'hasAttachments': e.get('hasAttachments', False),
        'importance': e.get('importance', 'normal'),
        'preview': e.get('bodyPreview', '')[:150]
    })
print(json.dumps(results, indent=2, ensure_ascii=False))
"
}

# Parse single email JSON
parse_single_email() {
  python3 -c "
import json, sys, re, html as htmlmod
data = json.loads(sys.stdin.read(), strict=False)
body = data.get('body', {}).get('content', '')
body_text = re.sub(r'<[^>]+>', '', body)
body_text = htmlmod.unescape(body_text).strip()
body_text = re.sub(r'\s+', ' ', body_text)
sender = data.get('from', {}).get('emailAddress', {})
to_list = [r.get('emailAddress', {}).get('address', '') for r in data.get('toRecipients', [])]
cc_list = [r.get('emailAddress', {}).get('address', '') for r in data.get('ccRecipients', [])]
att = data.get('attachments', []) or []
result = {
    'id': data.get('id', ''),
    'subject': data.get('subject', ''),
    'from': sender.get('name', '') + ' <' + sender.get('address', '') + '>',
    'to': to_list,
    'cc': cc_list,
    'date': data.get('receivedDateTime', ''),
    'isRead': data.get('isRead', False),
    'hasAttachments': data.get('hasAttachments', False),
    'importance': data.get('importance', 'normal'),
    'body': body_text[:5000],
    'bodyHtml': data.get('body', {}).get('content', '')[:5000]
}
if att:
    result['attachments'] = [{'name': a.get('name'), 'size': a.get('size'), 'contentType': a.get('contentType'), 'id': a.get('id')} for a in att]
print(json.dumps(result, indent=2, ensure_ascii=False))
"
}

# ─── Commands ───────────────────────────────────────────

cmd_inbox() {
  local count="${1:-15}"
  local wp="outlook-inbox-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/messages?\$top=${count}&\$orderby=receivedDateTime desc&\$select=id,subject,from,receivedDateTime,isRead,importance,hasAttachments,bodyPreview"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  run_oneshot_get "$wf_file" "$wp" | parse_email_list
}

cmd_read() {
  local msg_id="$1"
  local wp="outlook-read-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/messages/${msg_id}?\$expand=attachments(\$select=id,name,size,contentType)"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  run_oneshot_get "$wf_file" "$wp" | parse_single_email
}

cmd_search() {
  local query="$1"
  local count="${2:-10}"
  local wp="outlook-search-$(date +%s)"
  # $search requires double-quote wrapping, URL-encoded
  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('\"' + '$query' + '\"'))")
  local url="https://graph.microsoft.com/v1.0/me/messages?\$search=${encoded_query}&\$top=${count}&\$select=id,subject,from,receivedDateTime,isRead,importance,hasAttachments,bodyPreview"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  run_oneshot_get "$wf_file" "$wp" | parse_email_list
}

cmd_search_from() {
  local email="$1"
  local count="${2:-10}"
  local wp="outlook-sfrom-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/messages?\$filter=from/emailAddress/address eq '${email}'&\$top=${count}&\$orderby=receivedDateTime desc&\$select=id,subject,from,receivedDateTime,isRead,importance,hasAttachments,bodyPreview"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  run_oneshot_get "$wf_file" "$wp" | parse_email_list
}

cmd_search_subject() {
  local subject="$1"
  local count="${2:-10}"
  local wp="outlook-ssubj-$(date +%s)"
  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('\"subject:' + '$subject' + '\"'))")
  local url="https://graph.microsoft.com/v1.0/me/messages?\$search=${encoded_query}&\$top=${count}&\$select=id,subject,from,receivedDateTime,isRead,importance,hasAttachments,bodyPreview"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  run_oneshot_get "$wf_file" "$wp" | parse_email_list
}

cmd_send() {
  local to_email="$1"
  local subject="$2"
  local body="$3"
  local wp="outlook-send-$(date +%s)"
  local tmp_file="/tmp/outlook-wf-${wp}.json"

  python3 -c "
import json, sys

to_email = sys.argv[1]
subject = sys.argv[2]
body_html = sys.argv[3]
wp = sys.argv[4]
cred_id = sys.argv[5]
cred_name = sys.argv[6]
cred_type = sys.argv[7]

wf = {
  'name': 'Outlook Send ' + wp,
  'nodes': [
    {
      'parameters': {'path': wp, 'httpMethod': 'POST', 'responseMode': 'lastNode', 'options': {}},
      'id': 'webhook', 'name': 'Webhook',
      'type': 'n8n-nodes-base.webhook', 'typeVersion': 2,
      'position': [250, 300], 'webhookId': wp
    },
    {
      'parameters': {
        'method': 'POST',
        'url': 'https://graph.microsoft.com/v1.0/me/sendMail',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': cred_type,
        'sendBody': True,
        'specifyBody': 'json',
        'jsonBody': json.dumps({
          'message': {
            'subject': subject,
            'body': {'contentType': 'html', 'content': body_html},
            'toRecipients': [{'emailAddress': {'address': to_email}}]
          },
          'saveToSentItems': True
        }),
        'options': {}
      },
      'id': 'send-mail', 'name': 'Send Mail',
      'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2,
      'position': [450, 300],
      'credentials': {cred_type: {'id': cred_id, 'name': cred_name}}
    }
  ],
  'connections': {
    'Webhook': {'main': [[{'node': 'Send Mail', 'type': 'main', 'index': 0}]]}
  },
  'settings': {'executionOrder': 'v1'}
}

with open(sys.argv[8], 'w') as f:
  json.dump(wf, f)
" "$to_email" "$subject" "$body" "$wp" "$OUTLOOK_CRED_ID" "$OUTLOOK_CRED_NAME" "$OUTLOOK_CRED_TYPE" "$tmp_file"

  run_oneshot_post "$tmp_file" "$wp" '{}'
  echo '{"status": "sent", "to": "'"$to_email"'", "subject": "'"$subject"'"}'
}

cmd_reply() {
  local msg_id="$1"
  local body="$2"
  local wp="outlook-reply-$(date +%s)"
  local tmp_file="/tmp/outlook-wf-${wp}.json"

  python3 -c "
import json, sys

msg_id = sys.argv[1]
body_html = sys.argv[2]
wp = sys.argv[3]
cred_id = sys.argv[4]
cred_name = sys.argv[5]
cred_type = sys.argv[6]

wf = {
  'name': 'Outlook Reply ' + wp,
  'nodes': [
    {
      'parameters': {'path': wp, 'httpMethod': 'POST', 'responseMode': 'lastNode', 'options': {}},
      'id': 'webhook', 'name': 'Webhook',
      'type': 'n8n-nodes-base.webhook', 'typeVersion': 2,
      'position': [250, 300], 'webhookId': wp
    },
    {
      'parameters': {
        'method': 'POST',
        'url': f'https://graph.microsoft.com/v1.0/me/messages/{msg_id}/reply',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': cred_type,
        'sendBody': True,
        'specifyBody': 'json',
        'jsonBody': json.dumps({
          'message': {
            'body': {'contentType': 'html', 'content': body_html}
          }
        }),
        'options': {}
      },
      'id': 'reply-mail', 'name': 'Reply',
      'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2,
      'position': [450, 300],
      'credentials': {cred_type: {'id': cred_id, 'name': cred_name}}
    }
  ],
  'connections': {
    'Webhook': {'main': [[{'node': 'Reply', 'type': 'main', 'index': 0}]]}
  },
  'settings': {'executionOrder': 'v1'}
}

with open(sys.argv[7], 'w') as f:
  json.dump(wf, f)
" "$msg_id" "$body" "$wp" "$OUTLOOK_CRED_ID" "$OUTLOOK_CRED_NAME" "$OUTLOOK_CRED_TYPE" "$tmp_file"

  run_oneshot_post "$tmp_file" "$wp" '{}'
  echo '{"status": "replied", "messageId": "'"$msg_id"'"}'
}

cmd_forward() {
  local msg_id="$1"
  local to_email="$2"
  local comment="${3:-}"
  local wp="outlook-fwd-$(date +%s)"
  local tmp_file="/tmp/outlook-wf-${wp}.json"

  python3 -c "
import json, sys

msg_id = sys.argv[1]
to_email = sys.argv[2]
comment = sys.argv[3]
wp = sys.argv[4]
cred_id = sys.argv[5]
cred_name = sys.argv[6]
cred_type = sys.argv[7]

body = {
  'toRecipients': [{'emailAddress': {'address': to_email}}]
}
if comment:
  body['comment'] = comment

wf = {
  'name': 'Outlook Forward ' + wp,
  'nodes': [
    {
      'parameters': {'path': wp, 'httpMethod': 'POST', 'responseMode': 'lastNode', 'options': {}},
      'id': 'webhook', 'name': 'Webhook',
      'type': 'n8n-nodes-base.webhook', 'typeVersion': 2,
      'position': [250, 300], 'webhookId': wp
    },
    {
      'parameters': {
        'method': 'POST',
        'url': f'https://graph.microsoft.com/v1.0/me/messages/{msg_id}/forward',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': cred_type,
        'sendBody': True,
        'specifyBody': 'json',
        'jsonBody': json.dumps(body),
        'options': {}
      },
      'id': 'fwd-mail', 'name': 'Forward',
      'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2,
      'position': [450, 300],
      'credentials': {cred_type: {'id': cred_id, 'name': cred_name}}
    }
  ],
  'connections': {
    'Webhook': {'main': [[{'node': 'Forward', 'type': 'main', 'index': 0}]]}
  },
  'settings': {'executionOrder': 'v1'}
}

with open(sys.argv[8], 'w') as f:
  json.dump(wf, f)
" "$msg_id" "$to_email" "$comment" "$wp" "$OUTLOOK_CRED_ID" "$OUTLOOK_CRED_NAME" "$OUTLOOK_CRED_TYPE" "$tmp_file"

  run_oneshot_post "$tmp_file" "$wp" '{}'
  echo '{"status": "forwarded", "messageId": "'"$msg_id"'", "to": "'"$to_email"'"}'
}

cmd_draft() {
  local to_email="$1"
  local subject="$2"
  local body="$3"
  local wp="outlook-draft-$(date +%s)"
  local tmp_file="/tmp/outlook-wf-${wp}.json"

  python3 -c "
import json, sys

to_email = sys.argv[1]
subject = sys.argv[2]
body_html = sys.argv[3]
wp = sys.argv[4]
cred_id = sys.argv[5]
cred_name = sys.argv[6]
cred_type = sys.argv[7]

wf = {
  'name': 'Outlook Draft ' + wp,
  'nodes': [
    {
      'parameters': {'path': wp, 'httpMethod': 'POST', 'responseMode': 'lastNode', 'options': {}},
      'id': 'webhook', 'name': 'Webhook',
      'type': 'n8n-nodes-base.webhook', 'typeVersion': 2,
      'position': [250, 300], 'webhookId': wp
    },
    {
      'parameters': {
        'method': 'POST',
        'url': 'https://graph.microsoft.com/v1.0/me/messages',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': cred_type,
        'sendBody': True,
        'specifyBody': 'json',
        'jsonBody': json.dumps({
          'subject': subject,
          'body': {'contentType': 'html', 'content': body_html},
          'toRecipients': [{'emailAddress': {'address': to_email}}]
        }),
        'options': {}
      },
      'id': 'create-draft', 'name': 'Create Draft',
      'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2,
      'position': [450, 300],
      'credentials': {cred_type: {'id': cred_id, 'name': cred_name}}
    }
  ],
  'connections': {
    'Webhook': {'main': [[{'node': 'Create Draft', 'type': 'main', 'index': 0}]]}
  },
  'settings': {'executionOrder': 'v1'}
}

with open(sys.argv[8], 'w') as f:
  json.dump(wf, f)
" "$to_email" "$subject" "$body" "$wp" "$OUTLOOK_CRED_ID" "$OUTLOOK_CRED_NAME" "$OUTLOOK_CRED_TYPE" "$tmp_file"

  local response
  response=$(run_oneshot_post "$tmp_file" "$wp" '{}')
  echo "$response" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read(), strict=False)
print(json.dumps({'status': 'draft_created', 'draftId': data.get('id', ''), 'subject': data.get('subject', '')}, indent=2))
" 2>/dev/null || echo "$response"
}

cmd_attachments() {
  local msg_id="$1"
  local wp="outlook-att-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/messages/${msg_id}/attachments?\$select=id,name,size,contentType,isInline"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  local raw
  raw=$(run_oneshot_get "$wf_file" "$wp")
  echo "$raw" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read(), strict=False)
atts = [{'id': a.get('id'), 'name': a.get('name'), 'size': a.get('size'), 'contentType': a.get('contentType'), 'isInline': a.get('isInline', False)} for a in data.get('value', [])]
print(json.dumps(atts, indent=2, ensure_ascii=False))
"
}

cmd_folders() {
  local wp="outlook-folders-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/mailFolders?\$top=50&\$select=id,displayName,totalItemCount,unreadItemCount"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  local raw
  raw=$(run_oneshot_get "$wf_file" "$wp")
  echo "$raw" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read(), strict=False)
folders = [{'id': f.get('id'), 'name': f.get('displayName'), 'total': f.get('totalItemCount'), 'unread': f.get('unreadItemCount')} for f in data.get('value', [])]
print(json.dumps(folders, indent=2, ensure_ascii=False))
"
}

cmd_folder() {
  local folder_id="$1"
  local count="${2:-15}"
  local wp="outlook-folder-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/mailFolders/${folder_id}/messages?\$top=${count}&\$orderby=receivedDateTime desc&\$select=id,subject,from,receivedDateTime,isRead,importance,hasAttachments,bodyPreview"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  run_oneshot_get "$wf_file" "$wp" | parse_email_list
}

# ─── Main ───────────────────────────────────────────────

load_api_key

case "${1:-help}" in
  inbox)
    cmd_inbox "${2:-15}"
    ;;
  read)
    [[ -z "${2:-}" ]] && { echo '{"error": "Usage: outlook-api.sh read <message_id>"}'; exit 1; }
    cmd_read "$2"
    ;;
  search)
    [[ -z "${2:-}" ]] && { echo '{"error": "Usage: outlook-api.sh search <query>"}'; exit 1; }
    cmd_search "$2" "${3:-10}"
    ;;
  search-from)
    [[ -z "${2:-}" ]] && { echo '{"error": "Usage: outlook-api.sh search-from <email> [count]"}'; exit 1; }
    cmd_search_from "$2" "${3:-10}"
    ;;
  search-subject)
    [[ -z "${2:-}" ]] && { echo '{"error": "Usage: outlook-api.sh search-subject <subject> [count]"}'; exit 1; }
    cmd_search_subject "$2" "${3:-10}"
    ;;
  send)
    [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]] && { echo '{"error": "Usage: outlook-api.sh send <to_email> <subject> <html_body>"}'; exit 1; }
    cmd_send "$2" "$3" "$4"
    ;;
  reply)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo '{"error": "Usage: outlook-api.sh reply <message_id> <html_body>"}'; exit 1; }
    cmd_reply "$2" "$3"
    ;;
  forward)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo '{"error": "Usage: outlook-api.sh forward <message_id> <to_email> [comment]"}'; exit 1; }
    cmd_forward "$2" "$3" "${4:-}"
    ;;
  draft)
    [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]] && { echo '{"error": "Usage: outlook-api.sh draft <to_email> <subject> <html_body>"}'; exit 1; }
    cmd_draft "$2" "$3" "$4"
    ;;
  attachments)
    [[ -z "${2:-}" ]] && { echo '{"error": "Usage: outlook-api.sh attachments <message_id>"}'; exit 1; }
    cmd_attachments "$2"
    ;;
  folders)
    cmd_folders
    ;;
  folder)
    [[ -z "${2:-}" ]] && { echo '{"error": "Usage: outlook-api.sh folder <folder_id> [count]"}'; exit 1; }
    cmd_folder "$2" "${3:-15}"
    ;;
  help|*)
    cat << 'EOF'
Usage: outlook-api.sh <command> [args]

Reading:
  inbox [count]                       List recent inbox emails (default 15)
  read <message_id>                   Read full email with body and attachments
  search <query>                      Full-text search across emails
  search-from <email> [count]         Find emails from a specific sender
  search-subject <subject> [count]    Search by subject keyword
  folders                             List all mail folders with counts
  folder <folder_id> [count]          List emails in a specific folder
  attachments <message_id>            List attachments on an email

Writing:
  send <to_email> <subject> <body>    Send an email (HTML body)
  reply <message_id> <body>           Reply to an email (HTML body)
  forward <message_id> <to> [comment] Forward an email
  draft <to_email> <subject> <body>   Create a draft email
EOF
    ;;
esac
