#!/usr/bin/env bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> <type> <from> [--cmd_id=X] [--task_id=Y] [--qc_result=pass|fail] [--urgent[=true]]
# Example: bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5
# Example (明示引数): bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5 --cmd_id=cmd_054 --task_id=subtask_054b2
# Example (QC結果付き): bash scripts/inbox_write.sh karo "足軽5号QC完了" report_received gunshi --cmd_id=cmd_054 --task_id=subtask_054b2 --qc_result=pass
# Example (緊急フラグ付き・cmd_146): bash scripts/inbox_write.sh karo "至急確認されたし" report_received gunshi --urgent

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$1"
CONTENT="$2"
TYPE="$3"
FROM="$4"
shift 4 2>/dev/null || true

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ] || [ -z "$TYPE" ] || [ -z "$FROM" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> <type> <from> [--cmd_id=X] [--task_id=Y] [--qc_result=pass|fail] [--urgent[=true]]" >&2
    exit 1
fi

# Optional explicit --cmd_id=/--task_id= args (fix2: preferred over CONTENT regex extraction)
_ARG_CMD_ID=""
_ARG_TASK_ID=""
_ARG_REDO_OF=""
_ARG_QC_RESULT=""
_ARG_URGENT="false"
for arg in "$@"; do
    case "$arg" in
        --cmd_id=*) _ARG_CMD_ID="${arg#--cmd_id=}" ;;
        --task_id=*) _ARG_TASK_ID="${arg#--task_id=}" ;;
        --redo_of=*) _ARG_REDO_OF="${arg#--redo_of=}" ;;
        --qc_result=*) _ARG_QC_RESULT="${arg#--qc_result=}" ;;
        --urgent=*) _ARG_URGENT="${arg#--urgent=}" ;;
        --urgent) _ARG_URGENT="true" ;;
    esac
done
# Normalize to python-literal True/False (cmd_146: urgent_inbox_escalation reads
# msg.get('urgent') truthily via yaml.safe_load, so the written value must be a
# real YAML bool, not the string "true"/"false").
_PY_URGENT="False"
[ "$_ARG_URGENT" = "true" ] && _PY_URGENT="True"

# Fix5 (cmd_072): resolve cmd_id/task_id BEFORE writing the message object,
# so they can be embedded as fields on the message itself. Previously these
# were computed only after the write succeeded (for log_timing_event.sh), so
# inbox_watcher.sh had no choice but to regex-parse CONTENT for agent_started
# events — which fails because task_assigned notification text never
# contains subtask_id. Calculation logic is unchanged, only moved earlier.
_TIMING_EVENT=""
if [ -n "$_ARG_REDO_OF" ]; then
    _TIMING_EVENT="redo_dispatched"
else
    case "$TYPE" in
        cmd_new) _TIMING_EVENT="cmd_received" ;;
        task_assigned) _TIMING_EVENT="assigned" ;;
        report_received) _TIMING_EVENT="report_submitted" ;;
    esac
fi
_TIMING_CMD_ID="${_ARG_CMD_ID:-$(printf '%s' "$CONTENT" | grep -oE 'cmd_[0-9]+[a-zA-Z]*' | head -1)}"
_TIMING_TASK_ID="${_ARG_TASK_ID:-$(printf '%s' "$CONTENT" | grep -oE 'subtask_[0-9]+[a-zA-Z0-9]*' | head -1)}"

# Python literals for embedding into the message object (null when empty,
# matching log_timing_event.sh's none_if_empty() convention).
_PY_CMD_ID="None"
[ -n "$_TIMING_CMD_ID" ] && _PY_CMD_ID="'''$_TIMING_CMD_ID'''"
_PY_TASK_ID="None"
[ -n "$_TIMING_TASK_ID" ] && _PY_TASK_ID="'''$_TIMING_TASK_ID'''"

# Self-send guard: reject messages where sender == target
# Exception: clear_command type is allowed for self-send (karo self-/clear use case)
if [ "$FROM" = "$TARGET" ] && [ "$TYPE" != "clear_command" ]; then
    echo "[inbox_write] REJECTED: self-send detected (from=$FROM, target=$TARGET)" >&2
    exit 1
fi

# Initialize inbox if not exists
if [ ! -f "$INBOX" ]; then
    mkdir -p "$(dirname "$INBOX")"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp + 4 random bytes).
# Use `od` instead of `xxd` because `od` is available on both GNU/Linux and macOS runners by default.
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Cross-process lock: mkdir coordinates with OpenCode tools; flock is added when available.
LOCK_DIR="${LOCKFILE}.d"

_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ $i -ge 50 ] && return 1  # 5s timeout
    done

    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w 5 200 || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
    fi
    return 0
}

_release_lock() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

# Atomic write with lock (3 retries)
attempt=0
max_attempts=3

while [ $attempt -lt $max_attempts ]; do
    if _acquire_lock; then
        trap _release_lock EXIT
        if "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml, sys

try:
    # Load existing inbox
    with open('$INBOX') as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get('messages'):
        data['messages'] = []

    # Add new message
    new_msg = {
        'id': '$MSG_ID',
        'from': '$FROM',
        'timestamp': '$TIMESTAMP',
        'type': '$TYPE',
        'content': '''$CONTENT''',
        'read': False,
        'cmd_id': $_PY_CMD_ID,
        'task_id': $_PY_TASK_ID,
        'urgent': $_PY_URGENT
    }
    data['messages'].append(new_msg)

    # Overflow protection: keep max 50 messages
    if len(data['messages']) > 50:
        msgs = data['messages']
        unread = [m for m in msgs if not m.get('read', False)]
        read = [m for m in msgs if m.get('read', False)]
        # Keep all unread + newest 30 read messages
        data['messages'] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    import tempfile, os
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname('$INBOX'), suffix='.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, '$INBOX')
    except:
        os.unlink(tmp_path)
        raise

except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
"; then
            STATUS=0
        else
            STATUS=$?
        fi
        _release_lock
        trap - EXIT
        if [ $STATUS -eq 0 ]; then
            if [ -n "$_TIMING_EVENT" ]; then
                _TIMING_AGENT="$TARGET"
                [ "$_TIMING_EVENT" = "report_submitted" ] && _TIMING_AGENT="$FROM"
                # Fix4 (cmd_068): warn when neither explicit arg nor CONTENT regex
                # resolved cmd_id, so a missed --cmd_id= is visible immediately
                # instead of surfacing as a 92%-unmeasurable E2E result later.
                if [ -z "$_TIMING_CMD_ID" ] && [ "$_TIMING_EVENT" != "agent_started" ]; then
                    echo "[inbox_write] WARNING: cmd_id not resolved for timing event '$_TIMING_EVENT' (pass --cmd_id= explicitly)" >&2
                fi
                bash "${SCRIPT_DIR}/scripts/log_timing_event.sh" "$_TIMING_EVENT" "$_TIMING_CMD_ID" "$_TIMING_TASK_ID" "$_TIMING_AGENT" --redo_of="$_ARG_REDO_OF" --qc_result="$_ARG_QC_RESULT" --source=inbox_write.sh 2>/dev/null || true
                if [ "$_TIMING_EVENT" = "redo_dispatched" ]; then
                    _ESC_RESULT=$(bash "${SCRIPT_DIR}/scripts/check_event_escalation.sh" \
                        "$_ARG_REDO_OF" redo_dispatched redo_of \
                        --threshold="${REDO_ESCALATION_THRESHOLD:-2}" \
                        --cooldown="${REDO_ESCALATION_COOLDOWN_MIN:-30}" \
                        --jsonl="${SCRIPT_DIR}/logs/timing_events.jsonl" 2>/dev/null || echo "ERROR")
                    case "$_ESC_RESULT" in
                        FIRE:*)
                            _ESC_COUNT="${_ESC_RESULT#FIRE:}"
                            bash "${SCRIPT_DIR}/scripts/ntfy.sh" "🚨 redo${_ESC_COUNT}回到達: ${_ARG_REDO_OF} が${_ESC_COUNT}回redoされても未解決。殿の判断を仰ぐ" 2>/dev/null || true
                            bash "${SCRIPT_DIR}/scripts/log_timing_event.sh" redo_dispatched_escalated "" "$_ARG_REDO_OF" "" --redo_of="$_ARG_REDO_OF" --source=inbox_write.sh 2>/dev/null || true
                            ;;
                    esac
                fi
            fi
            exit 0
        fi
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep 1
    else
        # Lock timeout
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] Lock timeout for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        else
            echo "[inbox_write] Failed to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done
