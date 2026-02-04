#!/bin/bash
# Response Analyzer Library for RALPH Worker
# Parses Claude's output to extract structured status information
#
# Usage:
#   source lib/response_analyzer.sh
#   ra_analyze "session" "$output"
#   ra_get_exit_signal "session"
#   ra_get_status "session"

# State directory
RA_STATE_DIR="${RA_STATE_DIR:-$HOME/.claude/telegram-orchestrator/worker-state}"

#
# Internal helpers
#

_ra_response_file() {
    local session=$1
    echo "$RA_STATE_DIR/$session/response.json"
}

_ra_ensure_dir() {
    local session=$1
    mkdir -p "$RA_STATE_DIR/$session"
}

#
# RALPH_STATUS Block Parsing
#

# Extract RALPH_STATUS block from output
# Returns JSON with extracted fields
ra_parse_ralph_status() {
    local output="$1"

    # Default values
    local status="unknown"
    local exit_signal="false"
    local work_type="unknown"
    local files_modified="0"
    local tasks_remaining="0"
    local recommendation=""

    # Look for RALPH_STATUS block (supports multiple formats)
    if echo "$output" | grep -qE "(RALPH_STATUS:|---RALPH_STATUS---)"; then
        # Extract the block (up to 15 lines after marker)
        local block=$(echo "$output" | grep -A15 -E "(RALPH_STATUS:|---RALPH_STATUS---)" | head -15)

        # Parse each field with flexible patterns
        status=$(echo "$block" | grep -E "^STATUS:" | sed 's/STATUS:[[:space:]]*//' | tr -d ' ' | head -1)
        exit_signal=$(echo "$block" | grep -E "^EXIT_SIGNAL:" | sed 's/EXIT_SIGNAL:[[:space:]]*//' | tr -d ' ' | head -1)
        work_type=$(echo "$block" | grep -E "^WORK_TYPE:" | sed 's/WORK_TYPE:[[:space:]]*//' | tr -d ' ' | head -1)
        files_modified=$(echo "$block" | grep -E "^FILES_MODIFIED:" | sed 's/FILES_MODIFIED:[[:space:]]*//' | tr -d ' ' | head -1)
        tasks_remaining=$(echo "$block" | grep -E "^TASKS_REMAINING:" | sed 's/TASKS_REMAINING:[[:space:]]*//' | tr -d ' ' | head -1)
        recommendation=$(echo "$block" | grep -E "^RECOMMENDATION:" | sed 's/RECOMMENDATION:[[:space:]]*//' | head -1)
    fi

    # Normalize exit_signal to boolean string
    case "$exit_signal" in
        "true"|"TRUE"|"True"|"yes"|"YES"|"1") exit_signal="true" ;;
        *) exit_signal="false" ;;
    esac

    # Ensure numeric values
    [[ ! "$files_modified" =~ ^[0-9]+$ ]] && files_modified="0"
    [[ ! "$tasks_remaining" =~ ^[0-9]+$ ]] && tasks_remaining="0"

    # Default status if not found
    [[ -z "$status" || "$status" == "unknown" ]] && status="IN_PROGRESS"

    # Output as JSON
    cat << EOF
{
    "status": "$status",
    "exit_signal": $exit_signal,
    "work_type": "$work_type",
    "files_modified": $files_modified,
    "tasks_remaining": $tasks_remaining,
    "recommendation": "$recommendation"
}
EOF
}

#
# Heuristic Detection
#

# Detect completion indicators from natural language
ra_detect_completion_indicators() {
    local output="$1"

    # Count completion-like phrases
    local count=$(echo "$output" | grep -ciE \
        "all done|all tasks complete|task complete|finished|all items|nothing more|work is done|completed successfully|implementation complete|feature complete|ready for review" \
        2>/dev/null || echo "0")

    echo "$count"
}

# Detect test-only loops
ra_detect_test_only() {
    local output="$1"

    # Check if output is predominantly about testing
    local test_mentions=$(echo "$output" | grep -ciE "test|spec|bats|jest|pytest|unittest|assertion" 2>/dev/null || echo "0")
    local impl_mentions=$(echo "$output" | grep -ciE "implement|create|add|build|feature|function|class|method" 2>/dev/null || echo "0")

    if [[ $test_mentions -gt 5 && $impl_mentions -lt 2 ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# Detect errors in output (two-stage filtering)
ra_detect_errors() {
    local output="$1"

    # Stage 1: Filter out JSON field patterns that contain "error" as field name
    local filtered=$(echo "$output" | grep -v '"[^"]*error[^"]*":')

    # Stage 2: Detect actual error patterns
    local error_count=$(echo "$filtered" | grep -cE \
        '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL|FAILED|panic:)' \
        2>/dev/null || echo "0")

    echo "$error_count"
}

# Generate error hash for same-error detection
ra_generate_error_hash() {
    local output="$1"

    # Extract first error line and hash it
    local error_line=$(echo "$output" | grep -E '(Error:|ERROR:|error:|Exception|Fatal|FAILED)' | head -1)

    if [[ -n "$error_line" ]]; then
        echo "$error_line" | md5sum | cut -d' ' -f1
    else
        echo ""
    fi
}

# Count files modified indicators
ra_count_file_changes() {
    local output="$1"

    # Count various file change indicators
    local count=$(echo "$output" | grep -cE \
        '(✔.*Write|✔.*Edit|✔.*Created|✔.*Modified|Created file|Edited file|Written to|Modified:)' \
        2>/dev/null || echo "0")

    echo "$count"
}

#
# Full Analysis
#

# Analyze response and store results
ra_analyze() {
    local session=$1
    local output="$2"
    local loop_number=${3:-0}

    _ra_ensure_dir "$session"
    local response_file=$(_ra_response_file "$session")

    # Parse RALPH_STATUS block
    local ralph_status=$(ra_parse_ralph_status "$output")

    # Extract key values
    local status=$(echo "$ralph_status" | jq -r '.status')
    local exit_signal=$(echo "$ralph_status" | jq -r '.exit_signal')
    local work_type=$(echo "$ralph_status" | jq -r '.work_type')
    local files_from_status=$(echo "$ralph_status" | jq -r '.files_modified')
    local tasks_remaining=$(echo "$ralph_status" | jq -r '.tasks_remaining')

    # Heuristic detection
    local completion_indicators=$(ra_detect_completion_indicators "$output")
    local is_test_only=$(ra_detect_test_only "$output")
    local error_count=$(ra_detect_errors "$output")
    local error_hash=$(ra_generate_error_hash "$output")
    local files_changed=$(ra_count_file_changes "$output")

    # Use max of status-reported and detected file changes
    [[ $files_from_status -gt $files_changed ]] && files_changed=$files_from_status

    # Determine has_errors
    local has_errors="false"
    [[ $error_count -gt 0 ]] && has_errors="true"

    # Output length for decline detection
    local output_length=${#output}

    # Build full analysis
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    cat > "$response_file" << EOF
{
    "timestamp": "$timestamp",
    "loop": $loop_number,
    "ralph_status": $ralph_status,
    "analysis": {
        "exit_signal": $exit_signal,
        "status": "$status",
        "work_type": "$work_type",
        "files_modified": $files_changed,
        "tasks_remaining": $tasks_remaining,
        "completion_indicators": $completion_indicators,
        "is_test_only": $is_test_only,
        "error_count": $error_count,
        "error_hash": "$error_hash",
        "has_errors": $has_errors,
        "output_length": $output_length
    }
}
EOF

    # Return key values for immediate use
    echo "$files_changed|$has_errors|$error_hash|$completion_indicators|$output_length|$exit_signal"
}

# Get exit signal from last analysis
ra_get_exit_signal() {
    local session=$1
    local response_file=$(_ra_response_file "$session")

    if [[ -f "$response_file" ]]; then
        jq -r '.analysis.exit_signal // false' "$response_file" 2>/dev/null || echo "false"
    else
        echo "false"
    fi
}

# Get status from last analysis
ra_get_status() {
    local session=$1
    local response_file=$(_ra_response_file "$session")

    if [[ -f "$response_file" ]]; then
        jq -r '.analysis.status // "unknown"' "$response_file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get full analysis
ra_get_analysis() {
    local session=$1
    local response_file=$(_ra_response_file "$session")

    if [[ -f "$response_file" ]]; then
        cat "$response_file"
    else
        echo '{"error": "no analysis available"}'
    fi
}

# Clear analysis (for respawn)
ra_clear() {
    local session=$1
    local response_file=$(_ra_response_file "$session")
    rm -f "$response_file"
}

# Export functions
export -f ra_parse_ralph_status ra_detect_completion_indicators ra_detect_test_only
export -f ra_detect_errors ra_generate_error_hash ra_count_file_changes
export -f ra_analyze ra_get_exit_signal ra_get_status ra_get_analysis ra_clear
