#!/usr/bin/env bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> <type> <from> [--cmd_id=X] [--task_id=Y] [--qc_result=pass|fail]
# Example: bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5
# Example (明示引数): bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5 --cmd_id=cmd_054 --task_id=subtask_054b2
# Example (QC結果付き): bash scripts/inbox_write.sh karo "足軽5号QC完了" report_received gunshi --cmd_id=cmd_054 --task_id=subtask_054b2 --qc_result=pass

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
    echo "Usage: inbox_write.sh <target_agent> <content> <type> <from> [--cmd_id=X] [--task_id=Y] [--qc_result=pass|fail]" >&2
    exit 1
fi

# Optional explicit --cmd_id=/--task_id= args (fix2: preferred over CONTENT regex extraction)
_ARG_CMD_ID=""
_ARG_TASK_ID=""
_ARG_REDO_OF=""
_ARG_QC_RESULT=""
for arg in "$@"; do
    case "$arg" in
        --cmd_id=*) _ARG_CMD_ID="${arg#--cmd_id=}" ;;
        --task_id=*) _ARG_TASK_ID="${arg#--task_id=}" ;;
        --redo_of=*) _ARG_REDO_OF="${arg#--redo_of=}" ;;
        --qc_result=*) _ARG_QC_RESULT="${arg#--qc_result=}" ;;
    esac
done

# Fix5 (cmd_072): resolve cmd_id/task_id BEFORE writing the message object,
# so they can be embedded as fields on the message itself. Previously these
# were computed only after the write succeeded (for log_timing_event.sh), so
# inbox_watcher.sh had no choice but to regex-parse CONTENT for agent_started
# events — which fails because task_assigned notification text never
# contains subtask_id. Calculation logic is unchanged, only moved earlier.
#
# Fix (cmd_160-A): determine the base event from $TYPE FIRST, then only let
# --redo_of upgrade it to redo_dispatched when $TYPE is a dispatch-direction
# type (task_assigned/clear_command — karo→agent redo command). Previously
# any --redo_of unconditionally forced redo_dispatched regardless of $TYPE,
# which silently mislabeled ashigaru's completion reports (report_received,
# which conventionally carries --redo_of=<original_task_id> per the redo
# report-back convention) as redo_dispatched instead of report_submitted.
# That made the redo task's own completion invisible to
# the (since removed) in-flight/stall detectors, which treat "no
# report_submitted after the latest assigned/redo_dispatched" as in-flight
# — so completed+QC-passed redo tasks stayed flagged as stalled forever
# (real incidents: subtask_158_B2/H2/E2, 2026-08-08).
case "$TYPE" in
    cmd_new) _TIMING_EVENT="cmd_received" ;;
    task_assigned) _TIMING_EVENT="assigned" ;;
    report_received) _TIMING_EVENT="report_submitted" ;;
    clear_command) _TIMING_EVENT="assigned" ;;
    *) _TIMING_EVENT="" ;;
esac
if [ -n "$_ARG_REDO_OF" ]; then
    case "$TYPE" in
        task_assigned|clear_command) _TIMING_EVENT="redo_dispatched" ;;
    esac
fi
_TIMING_CMD_ID="${_ARG_CMD_ID:-$(printf '%s' "$CONTENT" | grep -oE 'cmd_[0-9]+[a-zA-Z]*' | head -1)}"
_TIMING_TASK_ID="${_ARG_TASK_ID:-$(printf '%s' "$CONTENT" | grep -oE 'subtask_[0-9]+[a-zA-Z0-9]*' | head -1)}"

# Fix (cmd_206 工程1): the documented clear_command dispatch
# (`inbox_write.sh ashigaru{N} "タスクYAMLを読んで作業開始せよ。" clear_command karo`,
# instructions/karo.md STEP4) passes neither --cmd_id=/--task_id= nor CONTENT text that
# matches the regexes above, so _TIMING_CMD_ID/_TIMING_TASK_ID stay empty and the
# resulting timing_events.jsonl row is recorded with task_id=None. That row is silently
# unusable: deadman_watcher.sh's own get_in_flight_tasks() requires a non-empty task_id
# key to arm a task (the stall_watcher.sh path is unaffected — cmd_194
# already made it read queue/tasks/*.yaml status directly instead of timing_events.jsonl,
# but that change explicitly left deadman_watcher.sh's separate function out of scope).
# karo.md's dispatch STEP2 ("YAML-first principle") always writes queue/tasks/{TARGET}.yaml
# with the new task_id/parent_cmd BEFORE STEP4 sends clear_command, so when both ids are
# still unresolved for a dispatch-direction event, fall back to reading them from the
# target's own task YAML. Only fires when the base event will actually be logged, and only
# fills in whichever id is still missing — never overrides an explicitly resolved one.
if [ -z "$_TIMING_CMD_ID" ] || [ -z "$_TIMING_TASK_ID" ]; then
    case "$_TIMING_EVENT" in
        assigned|redo_dispatched)
            _TASK_YAML="$SCRIPT_DIR/queue/tasks/${TARGET}.yaml"
            if [ -f "$_TASK_YAML" ]; then
                _FALLBACK_IDS=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('$_TASK_YAML') as f:
        doc = yaml.safe_load(f) or {}
    task = doc.get('task') or {}
    print(task.get('task_id') or '')
    print(task.get('parent_cmd') or '')
except Exception:
    print('')
    print('')
" 2>/dev/null)
                _FB_TASK_ID=$(printf '%s\n' "$_FALLBACK_IDS" | sed -n '1p')
                _FB_CMD_ID=$(printf '%s\n' "$_FALLBACK_IDS" | sed -n '2p')
                [ -z "$_TIMING_TASK_ID" ] && [ -n "$_FB_TASK_ID" ] && _TIMING_TASK_ID="$_FB_TASK_ID"
                [ -z "$_TIMING_CMD_ID" ] && [ -n "$_FB_CMD_ID" ] && _TIMING_CMD_ID="$_FB_CMD_ID"
            fi
            ;;
    esac
fi

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
# dangling symlink recovery: queue/inbox が壊れたシンボリックリンクならリンク先を再生成
_inbox_parent="$(dirname "$INBOX")"
if [ -L "$_inbox_parent" ] && [ ! -d "$_inbox_parent" ]; then
    mkdir -p "$(readlink "$_inbox_parent")"
fi
if [ ! -f "$INBOX" ]; then
    mkdir -p "$_inbox_parent"
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
        'task_id': $_PY_TASK_ID
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
