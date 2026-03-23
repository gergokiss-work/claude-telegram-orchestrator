#!/bin/bash
# teams-api.sh — Microsoft Teams API via n8n oneshot workflow pattern
# Usage:
#   teams-api.sh read-chat <chat_id> [count]
#   teams-api.sh find-chats <search_term>
#   teams-api.sh send <chat_id> <html_message>
#   teams-api.sh send-to <email> <html_message>
#   teams-api.sh list-chats [count]
#
# Requires: N8N_API_KEY in ~/.claude/scripts/.teams-env or aws-n8n/.env.local
# All output is JSON to stdout. Errors go to stderr.

set -euo pipefail

TEAMS_CRED_ID="o7NAZsiVOEwGDVl6"
TEAMS_CRED_NAME="Microsoft Teams Gergo account"
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

# Create, activate, trigger, cleanup a oneshot n8n workflow
# Args: $1 = workflow JSON file, $2 = webhook path
run_oneshot() {
  local json_file="$1"
  local webhook_path="$2"

  # Create workflow
  local wf_id
  wf_id=$(curl -sf -X POST "$N8N_URL/api/v1/workflows" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$json_file" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

  if [[ -z "$wf_id" ]]; then
    echo '{"error": "Failed to create workflow"}' >&2
    exit 1
  fi

  # Activate
  curl -sf -X POST "$N8N_URL/api/v1/workflows/$wf_id/activate" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1

  sleep 1

  # Trigger and capture response
  local response
  response=$(curl -sf "$N8N_URL/webhook/$webhook_path" 2>/dev/null || echo '{"error": "webhook trigger failed"}')

  # Cleanup (best effort)
  curl -sf -X POST "$N8N_URL/api/v1/workflows/$wf_id/deactivate" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1 || true
  curl -sf -X DELETE "$N8N_URL/api/v1/workflows/$wf_id" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" > /dev/null 2>&1 || true

  echo "$response"
}

# Build a workflow JSON with a single HTTP Request node
# Args: $1 = webhook path, $2 = Graph API URL (expression-ready)
build_get_workflow() {
  local webhook_path="$1"
  local graph_url="$2"
  local tmp_file="/tmp/teams-wf-${webhook_path}.json"

  cat > "$tmp_file" << ENDJSON
{
  "name": "Teams API ${webhook_path}",
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
        "nodeCredentialType": "microsoftTeamsOAuth2Api",
        "options": {}
      },
      "id": "api-call",
      "name": "Graph API",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [450, 300],
      "credentials": {
        "microsoftTeamsOAuth2Api": {
          "id": "${TEAMS_CRED_ID}",
          "name": "${TEAMS_CRED_NAME}"
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

# Build a POST workflow (for sending messages)
build_post_workflow() {
  local webhook_path="$1"
  local graph_url="$2"
  local body_json="$3"
  local tmp_file="/tmp/teams-wf-${webhook_path}.json"

  python3 -c "
import json
wf = {
  'name': 'Teams API ${webhook_path}',
  'nodes': [
    {
      'parameters': {
        'path': '${webhook_path}',
        'responseMode': 'lastNode',
        'options': {}
      },
      'id': 'webhook',
      'name': 'Webhook',
      'type': 'n8n-nodes-base.webhook',
      'typeVersion': 2,
      'position': [250, 300],
      'webhookId': '${webhook_path}'
    },
    {
      'parameters': {
        'method': 'POST',
        'url': '=${graph_url}',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': 'microsoftTeamsOAuth2Api',
        'sendBody': True,
        'specifyBody': 'json',
        'jsonBody': json.dumps(json.loads('''${body_json}''')),
        'options': {}
      },
      'id': 'api-call',
      'name': 'Graph API',
      'type': 'n8n-nodes-base.httpRequest',
      'typeVersion': 4.2,
      'position': [450, 300],
      'credentials': {
        'microsoftTeamsOAuth2Api': {
          'id': '${TEAMS_CRED_ID}',
          'name': '${TEAMS_CRED_NAME}'
        }
      }
    }
  ],
  'connections': {
    'Webhook': {'main': [[{'node': 'Graph API', 'type': 'main', 'index': 0}]]}
  },
  'settings': {'executionOrder': 'v1'}
}
with open('$tmp_file', 'w') as f:
  json.dump(wf, f)
"

  echo "$tmp_file"
}

# ─── Commands ───────────────────────────────────────────

cmd_list_chats() {
  local count="${1:-20}"
  local wp="teams-list-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/chats?\$expand=members,lastMessagePreview&\$top=${count}&\$orderby=lastMessagePreview/createdDateTime desc&\$select=id,topic,chatType,members,lastMessagePreview"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  run_oneshot "$wf_file" "$wp"
}

cmd_find_chats() {
  local search="$1"
  # Fetch group + 1:1 chats, then filter with python
  local wp="teams-find-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/chats?\$expand=members&\$top=50&\$select=id,topic,chatType,members"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  local raw
  raw=$(run_oneshot "$wf_file" "$wp")

  # Filter chats containing the search term in member names or topic
  echo "$raw" | python3 -c "
import json, sys, re
data = json.loads(sys.stdin.read(), strict=False)
search = '${search}'.lower()
results = []
for chat in data.get('value', []):
    members = chat.get('members', [])
    member_names = [m.get('displayName', '') for m in members]
    topic = chat.get('topic', '') or ''
    match = any(search in n.lower() for n in member_names) or search in topic.lower()
    if match:
        results.append({
            'chatId': chat['id'],
            'topic': topic,
            'chatType': chat['chatType'],
            'members': member_names
        })
print(json.dumps(results, indent=2, ensure_ascii=False))
"
}

cmd_read_chat() {
  local chat_id="$1"
  local count="${2:-15}"
  local wp="teams-read-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/me/chats/${chat_id}/messages?\$top=${count}&\$orderby=createdDateTime desc"
  local wf_file
  wf_file=$(build_get_workflow "$wp" "$url")
  local raw
  raw=$(run_oneshot "$wf_file" "$wp")

  # Parse and clean messages
  echo "$raw" | python3 -c "
import json, sys, re, html
data = json.loads(sys.stdin.read(), strict=False)
messages = []
for m in data.get('value', []):
    sender = 'system'
    if m.get('from') and m['from'].get('user'):
        sender = m['from']['user'].get('displayName', 'unknown')
    body = m.get('body', {}).get('content', '')
    body_text = re.sub(r'<[^>]+>', '', body)
    body_text = html.unescape(body_text).strip()
    body_text = re.sub(r'\s+', ' ', body_text)
    att = m.get('attachments', []) or []
    msg = {
        'id': m.get('id'),
        'from': sender,
        'time': m.get('createdDateTime'),
        'body': body_text[:2000],
        'messageType': m.get('messageType')
    }
    if att:
        msg['attachments'] = [{'name': a.get('name'), 'contentType': a.get('contentType'), 'id': a.get('id')} for a in att]
    if m.get('messageType') == 'message':
        messages.append(msg)
print(json.dumps(messages, indent=2, ensure_ascii=False))
"
}

cmd_send() {
  local chat_id="$1"
  local message="$2"
  local wp="teams-send-$(date +%s)"
  local url="https://graph.microsoft.com/v1.0/chats/${chat_id}/messages"

  # Build body JSON safely with python
  local body_json
  body_json=$(python3 -c "
import json, sys
msg = sys.argv[1]
print(json.dumps({'body': {'contentType': 'html', 'content': msg}}))
" "$message")

  local tmp_file="/tmp/teams-wf-${wp}.json"

  python3 -c "
import json, sys
body = json.loads(sys.argv[1])
wf = {
  'name': 'Teams Send ${wp}',
  'nodes': [
    {
      'parameters': {
        'path': '${wp}',
        'responseMode': 'lastNode',
        'options': {}
      },
      'id': 'webhook',
      'name': 'Webhook',
      'type': 'n8n-nodes-base.webhook',
      'typeVersion': 2,
      'position': [250, 300],
      'webhookId': '${wp}'
    },
    {
      'parameters': {
        'method': 'POST',
        'url': '=${url}',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': 'microsoftTeamsOAuth2Api',
        'sendBody': True,
        'specifyBody': 'json',
        'jsonBody': json.dumps(body),
        'options': {}
      },
      'id': 'api-call',
      'name': 'Graph API',
      'type': 'n8n-nodes-base.httpRequest',
      'typeVersion': 4.2,
      'position': [450, 300],
      'credentials': {
        'microsoftTeamsOAuth2Api': {
          'id': '${TEAMS_CRED_ID}',
          'name': '${TEAMS_CRED_NAME}'
        }
      }
    }
  ],
  'connections': {
    'Webhook': {'main': [[{'node': 'Graph API', 'type': 'main', 'index': 0}]]}
  },
  'settings': {'executionOrder': 'v1'}
}
with open('${tmp_file}', 'w') as f:
  json.dump(wf, f)
" "$body_json"

  run_oneshot "$tmp_file" "$wp"
}

cmd_send_to() {
  local email="$1"
  local message="$2"
  local wp="teams-sendto-$(date +%s)"

  # Multi-step: Get Me → Find User → Create Chat → Send Message
  # We need a multi-node workflow for this
  local tmp_file="/tmp/teams-wf-${wp}.json"

  python3 -c "
import json, sys

email = sys.argv[1]
msg = sys.argv[2]
wp = '${wp}'
cred_id = '${TEAMS_CRED_ID}'
cred_name = '${TEAMS_CRED_NAME}'
cred = {'microsoftTeamsOAuth2Api': {'id': cred_id, 'name': cred_name}}

wf = {
  'name': 'Teams SendTo ' + wp,
  'nodes': [
    {
      'parameters': {'path': wp, 'responseMode': 'lastNode', 'options': {}},
      'id': 'webhook', 'name': 'Webhook',
      'type': 'n8n-nodes-base.webhook', 'typeVersion': 2,
      'position': [250, 300], 'webhookId': wp
    },
    {
      'parameters': {
        'method': 'GET',
        'url': 'https://graph.microsoft.com/v1.0/me',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': 'microsoftTeamsOAuth2Api',
        'options': {}
      },
      'id': 'get-me', 'name': 'Get Me',
      'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2,
      'position': [450, 300], 'credentials': cred
    },
    {
      'parameters': {
        'method': 'GET',
        'url': f'https://graph.microsoft.com/v1.0/users/{email}',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': 'microsoftTeamsOAuth2Api',
        'options': {}
      },
      'id': 'find-user', 'name': 'Find User',
      'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2,
      'position': [650, 300], 'credentials': cred
    },
    {
      'parameters': {
        'method': 'POST',
        'url': 'https://graph.microsoft.com/v1.0/chats',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': 'microsoftTeamsOAuth2Api',
        'sendBody': True,
        'specifyBody': 'json',
        'jsonBody': '={{ JSON.stringify({ chatType: \"oneOnOne\", members: [{ \"@odata.type\": \"#microsoft.graph.aadUserConversationMember\", roles: [\"owner\"], \"user@odata.bind\": \"https://graph.microsoft.com/v1.0/users/\" + \$json.id }, { \"@odata.type\": \"#microsoft.graph.aadUserConversationMember\", roles: [\"owner\"], \"user@odata.bind\": \"https://graph.microsoft.com/v1.0/users/\" + \$(\"Get Me\").item.json.id }] }) }}',
        'options': {}
      },
      'id': 'create-chat', 'name': 'Create Chat',
      'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2,
      'position': [850, 300], 'credentials': cred
    },
    {
      'parameters': {
        'method': 'POST',
        'url': '=https://graph.microsoft.com/v1.0/chats/{{ \$json.id }}/messages',
        'authentication': 'predefinedCredentialType',
        'nodeCredentialType': 'microsoftTeamsOAuth2Api',
        'sendBody': True,
        'specifyBody': 'json',
        'jsonBody': json.dumps({'body': {'contentType': 'html', 'content': msg}}),
        'options': {}
      },
      'id': 'send-msg', 'name': 'Send Message',
      'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2,
      'position': [1050, 300], 'credentials': cred
    }
  ],
  'connections': {
    'Webhook': {'main': [[{'node': 'Get Me', 'type': 'main', 'index': 0}]]},
    'Get Me': {'main': [[{'node': 'Find User', 'type': 'main', 'index': 0}]]},
    'Find User': {'main': [[{'node': 'Create Chat', 'type': 'main', 'index': 0}]]},
    'Create Chat': {'main': [[{'node': 'Send Message', 'type': 'main', 'index': 0}]]}
  },
  'settings': {'executionOrder': 'v1'}
}

with open('${tmp_file}', 'w') as f:
  json.dump(wf, f)
" "$email" "$message"

  run_oneshot "$tmp_file" "$wp"
}

# ─── Main ───────────────────────────────────────────────

load_api_key

case "${1:-help}" in
  list-chats)
    cmd_list_chats "${2:-20}"
    ;;
  find-chats)
    [[ -z "${2:-}" ]] && { echo '{"error": "Usage: teams-api.sh find-chats <search_term>"}'; exit 1; }
    cmd_find_chats "$2"
    ;;
  read-chat)
    [[ -z "${2:-}" ]] && { echo '{"error": "Usage: teams-api.sh read-chat <chat_id> [count]"}'; exit 1; }
    cmd_read_chat "$2" "${3:-15}"
    ;;
  send)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo '{"error": "Usage: teams-api.sh send <chat_id> <html_message>"}'; exit 1; }
    cmd_send "$2" "$3"
    ;;
  send-to)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo '{"error": "Usage: teams-api.sh send-to <email> <html_message>"}'; exit 1; }
    cmd_send_to "$2" "$3"
    ;;
  help|*)
    cat << 'EOF'
Usage: teams-api.sh <command> [args]

Commands:
  list-chats [count]              List recent chats with last message preview
  find-chats <name>               Find chats by member name or topic
  read-chat <chat_id> [count]     Read messages from a specific chat
  send <chat_id> <html_message>   Send a message to an existing chat
  send-to <email> <html_message>  Send a message to a user by email (creates 1:1 chat)
EOF
    ;;
esac
