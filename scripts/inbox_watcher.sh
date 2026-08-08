#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# inbox_watcher.sh — メールボックス監視＆起動シグナル配信
# Usage: bash scripts/inbox_watcher.sh <agent_id> <pane_target> [cli_type]
# Example: bash scripts/inbox_watcher.sh karo multiagent:0.0 claude
#
# 設計思想:
#   メッセージ本体はファイル（inbox YAML）に書く = 確実
#   起動シグナルは tmux send-keys（テキストとEnterを分離送信）
#   エージェントが自分でinboxをReadして処理する
#   冪等: 2回届いてもunreadがなければ何もしない
#
# inotifywait でファイル変更を検知（イベント駆動、ポーリングではない）
# Fallback 1: 30秒タイムアウト（WSL2 inotify不発時の安全網）
# Fallback 2: rc=1処理（Claude Code atomic write = tmp+rename でinode変更時）
#
# エスカレーション（未読メッセージが放置されている場合）:
#   0〜2分: 通常nudge（send-keys）。ただしWorking中はスキップ
#   2〜4分: Copilot/Kimi は Escape×2 + Ctrl-C + nudge。
#            Claude/Codex/OpenCode は通常nudgeへフォールバック
#   4分〜 : /clear送信（5分に1回まで。強制リセット+YAML再読）
# ═══════════════════════════════════════════════════════════════

# ─── Testing guard ───
# When __INBOX_WATCHER_TESTING__=1, only function definitions are loaded.
# Argument parsing, inotifywait check, and main loop are skipped.
# Test code sets variables (AGENT_ID, PANE_TARGET, CLI_TYPE, INBOX) externally.
if [ "${__INBOX_WATCHER_TESTING__:-}" != "1" ]; then
    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    AGENT_ID="$1"
    PANE_TARGET="$2"
    CLI_TYPE="${3:-claude}"  # CLI種別（claude/codex/copilot/kimi/opencode）。未指定→claude（後方互換）

    INBOX="$SCRIPT_DIR/queue/inbox/${AGENT_ID}.yaml"
    LOCKFILE="${INBOX}.lock"

    if [ -z "$AGENT_ID" ] || [ -z "$PANE_TARGET" ]; then
        echo "Usage: inbox_watcher.sh <agent_id> <pane_target> [cli_type]" >&2
        exit 1
    fi

    # Initialize inbox if not exists
    if [ ! -f "$INBOX" ]; then
        mkdir -p "$(dirname "$INBOX")"
        echo "messages: []" > "$INBOX"
    fi

    echo "[$(date)] inbox_watcher started — agent: $AGENT_ID, pane: $PANE_TARGET, cli: $CLI_TYPE" >&2

    # Fix: CLI starts at welcome screen = idle. Create idle flag so watcher
    # doesn't false-busy deadlock waiting for a stop_hook that never fires.
    if [[ "$CLI_TYPE" == "claude" ]]; then
        touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}"
        echo "[$(date)] Created initial idle flag for $AGENT_ID (CLI starts idle)" >&2
    fi

    # Source cli_adapter for get_startup_prompt() (Codex needs startup prompt after /new)
    _cli_adapter="${SCRIPT_DIR}/lib/cli_adapter.sh"
    if [ -f "$_cli_adapter" ]; then
        source "$_cli_adapter"
        echo "[$(date)] cli_adapter.sh loaded (get_startup_prompt available)" >&2
    fi

    # Source shared agent status library (busy/idle detection)
    _agent_status_lib="${SCRIPT_DIR}/lib/agent_status.sh"
    if [ -f "$_agent_status_lib" ]; then
        source "$_agent_status_lib"
    fi

    # Source shared agent registry library (fleet_all_ashigaru_idle_tri用, cmd_158)
    _agent_registry_lib="${SCRIPT_DIR}/lib/agent_registry.sh"
    if [ -f "$_agent_registry_lib" ]; then
        source "$_agent_registry_lib"
    fi

    # Detect OS and select file-watching backend
    INBOX_WATCHER_OS="$(uname -s)"
    if [ "$INBOX_WATCHER_OS" = "Darwin" ]; then
        # macOS: use fswatch instead of inotifywait
        if ! command -v fswatch &>/dev/null; then
            echo "[inbox_watcher] ERROR: fswatch not found. Install: brew install fswatch" >&2
            exit 1
        fi
        WATCH_BACKEND="fswatch"
        if ! command -v gtimeout &>/dev/null; then
            echo "[inbox_watcher] WARN: gtimeout not found. Using sleep-based fallback (higher CPU). Recommended: brew install coreutils" >&2
        fi
    else
        # Linux: use inotifywait
        if ! command -v inotifywait &>/dev/null; then
            echo "[inbox_watcher] ERROR: inotifywait not found. Install: sudo apt install inotify-tools" >&2
            exit 1
        fi
        WATCH_BACKEND="inotifywait"
    fi
    echo "[$(date)] File watch backend: $WATCH_BACKEND" >&2
fi

# ─── timeout command compatibility wrapper (macOS support) ───
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    timeout() { gtimeout "$@"; }
  else
    # Pure bash fallback: timeout DURATION COMMAND [ARGS...]
    timeout() {
      local duration="$1"; shift
      "$@" &
      local pid=$!
      ( sleep "$duration" && kill "$pid" 2>/dev/null ) &
      local watcher=$!
      wait "$pid" 2>/dev/null
      local rc=$?
      kill "$watcher" 2>/dev/null
      wait "$watcher" 2>/dev/null
      return $rc
    }
  fi
fi

# ─── Escalation state ───
# Time-based escalation: track how long unread messages have been waiting
FIRST_UNREAD_SEEN=${FIRST_UNREAD_SEEN:-0}
LAST_CLEAR_TS=${LAST_CLEAR_TS:-0}
LAST_ASSIGNMENT_TS=${LAST_ASSIGNMENT_TS:-0}
ESCALATE_PHASE1=${ESCALATE_PHASE1:-120}
ESCALATE_PHASE2=${ESCALATE_PHASE2:-240}
ESCALATE_COOLDOWN=${ESCALATE_COOLDOWN:-300}
# Local LLM (opencode/ollama) responds legitimately slowly (observed 150-300s).
# The default 120s/240s thresholds misjudge slow-but-working inference as
# "unresponsive" and bombard the TUI with send-keys mid-render, corrupting the
# PTY → setRawMode errno5 crash. Use generous thresholds for opencode.
ESCALATE_PHASE1_OPENCODE=${ESCALATE_PHASE1_OPENCODE:-600}
ESCALATE_PHASE2_OPENCODE=${ESCALATE_PHASE2_OPENCODE:-900}

# ─── Auto-heal watchdog (cmd_xxx: self-recovery for crashed TUI CLIs) ───
# A TUI crash (e.g. opencode setRawMode errno5) leaves the pane at a bare shell.
# Detect that state and relaunch the configured CLI via switch_cli.sh.
ASW_AUTO_HEAL=${ASW_AUTO_HEAL:-1}
HEAL_COOLDOWN_SEC=${HEAL_COOLDOWN_SEC:-120}
DEAD_CLI_STREAK=0
LAST_HEAL_TS=0

# ─── Auto-heal escalation config (cmd_052d) ───
# config/settings.yaml `auto_heal:` block, read via python3+yaml (this script's
# existing convention for structured config; matches switch_cli.sh/inbox_write.sh).
# Env vars override for ops/testing without editing settings.yaml.
_read_auto_heal_setting() {
    local key="$1" default="$2"
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/config/settings.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('auto_heal') or {}).get('$key')
    if v is None:
        v = '$default'
    if isinstance(v, bool):
        v = str(v).lower()
    print(v)
except Exception:
    print('$default')
" 2>/dev/null
}
AUTO_HEAL_SILENT_ENABLED=${AUTO_HEAL_SILENT_ENABLED:-$(_read_auto_heal_setting silent_heal_enabled true)}
AUTO_HEAL_ESCALATION_WINDOW_MIN=${AUTO_HEAL_ESCALATION_WINDOW_MIN:-$(_read_auto_heal_setting escalation_window_minutes 10)}
AUTO_HEAL_ESCALATION_THRESHOLD=${AUTO_HEAL_ESCALATION_THRESHOLD:-$(_read_auto_heal_setting escalation_threshold_count 3)}
AUTO_HEAL_ESCALATION_COOLDOWN_MIN=${AUTO_HEAL_ESCALATION_COOLDOWN_MIN:-$(_read_auto_heal_setting cooldown_after_escalation_minutes 30)}

# ─── Assignment grace window config (cmd_066) ───
# config/settings.yaml `assignment_grace:` block. Right after a nudge/task
# assignment is delivered, the PreToolUse hook (scripts/pretooluse_clear_idle.sh)
# needs a moment to fire before the idle flag is actually cleared. This grace
# window holds the escalation age at 0 during that lag so a real Phase1/2/3
# false-positive isn't triggered on an agent that just started working.
_read_assignment_grace_setting() {
    local key="$1" default="$2"
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/config/settings.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('assignment_grace') or {}).get('$key')
    if v is None:
        v = '$default'
    if isinstance(v, bool):
        v = str(v).lower()
    print(v)
except Exception:
    print('$default')
" 2>/dev/null
}
ASSIGNMENT_GRACE_SECONDS=${ASSIGNMENT_GRACE_SECONDS:-$(_read_assignment_grace_setting after_nudge_seconds 30)}

# ─── Nudge throttle ───
# Avoid spamming the same "inboxN" into the pane every timeout tick.
LAST_NUDGE_TS=${LAST_NUDGE_TS:-0}
LAST_NUDGE_COUNT=${LAST_NUDGE_COUNT:-""}
NUDGE_COOLDOWN_SEC=${NUDGE_COOLDOWN_SEC:-60}
# Codex は「思考中に入力が入ると即拾う」挙動があり、思考がループすることがあるため長めにする。
NUDGE_COOLDOWN_SEC_CODEX=${NUDGE_COOLDOWN_SEC_CODEX:-300}
# OpenCode/局所LLM は応答が遅く、推論中の send-keys 連打が TUI の PTY を壊す。長めに間引く。
NUDGE_COOLDOWN_SEC_OPENCODE=${NUDGE_COOLDOWN_SEC_OPENCODE:-300}

reset_nudge_throttle() {
    LAST_NUDGE_TS=0
    LAST_NUDGE_COUNT=""
}

# ─── Timing hook: agent_started event (cmd_054c, cmd_id/task_id fix: cmd_068) ───
# Fires alongside the "All messages read — escalation reset" log lines, i.e.
# near the moment the agent has finished processing its inbox. Callers extract
# cmd_id/task_id from the content of the most-recently-read message (via
# extract_timing_ids_from_content) and pass them in; on extraction failure
# they remain empty (log_timing_event.sh normalizes empty to null — same
# fail-safe fallback as inbox_write.sh's CONTENT regex extraction).
# Fire-and-forget: failure here must never affect the main watcher loop.
log_agent_started_event() {
    local cmd_id="${1:-}"
    local task_id="${2:-}"
    bash "${SCRIPT_DIR}/scripts/log_timing_event.sh" agent_started "$cmd_id" "$task_id" "$AGENT_ID" --source=inbox_watcher.sh 2>/dev/null || true
}

log_agent_notified_event() {
    local cmd_id="${1:-}"
    local task_id="${2:-}"
    bash "${SCRIPT_DIR}/scripts/log_timing_event.sh" agent_notified "$cmd_id" "$task_id" "$AGENT_ID" --source=inbox_watcher.sh 2>/dev/null || true
}

# Extract cmd_id/task_id from a message content string, using the same
# regex as inbox_write.sh's CONTENT fallback (cmd_068 Fix1). Prints
# "cmd_id<TAB>task_id" (either half may be empty on no-match).
extract_timing_ids_from_content() {
    local content="$1"
    local cmd_id task_id
    cmd_id=$(printf '%s' "$content" | grep -oE 'cmd_[0-9]+[a-zA-Z]*' | head -1)
    task_id=$(printf '%s' "$content" | grep -oE 'subtask_[0-9]+[a-zA-Z0-9]*' | head -1)
    printf '%s\t%s' "$cmd_id" "$task_id"
}

# Resolve cmd_id/task_id for the agent_started event (cmd_072 Fix5). Prefers
# the message object's own cmd_id/task_id fields (set by inbox_write.sh at
# write time — no ambiguity, no regex). Falls back to extract_timing_ids_from_content
# only when both fields are absent, which happens solely for messages written
# before Fix5 landed (backward compat, never touch new writes).
resolve_timing_ids() {
    local msg_cmd_id="$1" msg_task_id="$2" content="$3"
    if [ -n "$msg_cmd_id" ] || [ -n "$msg_task_id" ]; then
        printf '%s\t%s' "$msg_cmd_id" "$msg_task_id"
    else
        extract_timing_ids_from_content "$content"
    fi
}

acquire_inbox_lock() {
    local lock_dir="${LOCKFILE}.d"
    local i=0

    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ "$i" -ge 300 ] && return 1
    done

    if command -v flock &>/dev/null; then
        flock -x 200 || {
            rmdir "$lock_dir" 2>/dev/null
            return 1
        }
    fi
}

release_inbox_lock() {
    rmdir "${LOCKFILE}.d" 2>/dev/null || true
}

# ─── Context reset tracking ───
# Tracks whether we've sent /new or /clear for the current task_assigned batch.
# Resets to 0 when all messages are read (FIRST_UNREAD_SEEN → 0).
NEW_CONTEXT_SENT=${NEW_CONTEXT_SENT:-0}
# Tracks whether we sent a startup prompt (Codex) that includes full recovery.
# When set, skip follow-up nudge for this cycle (agent already knows what to do).
STARTUP_PROMPT_SENT=${STARTUP_PROMPT_SENT:-0}

# ─── Phase feature flags (cmd_107 Phase 1/2/3) ───
# ASW_PHASE:
#   1 = self-watch base (compatible)
#   2 = disable normal nudge by default
#   3 = FINAL_ESCALATION_ONLY (send-keys is fallback only)
ASW_PHASE=${ASW_PHASE:-2}
ASW_DISABLE_NORMAL_NUDGE=${ASW_DISABLE_NORMAL_NUDGE:-$([ "${ASW_PHASE}" -ge 2 ] && echo 1 || echo 0)}
ASW_FINAL_ESCALATION_ONLY=${ASW_FINAL_ESCALATION_ONLY:-$([ "${ASW_PHASE}" -ge 3 ] && echo 1 || echo 0)}
FINAL_ESCALATION_ONLY=${FINAL_ESCALATION_ONLY:-$ASW_FINAL_ESCALATION_ONLY}
ASW_NO_IDLE_FULL_READ=${ASW_NO_IDLE_FULL_READ:-1}
# Optional safety toggles:
# - ASW_DISABLE_ESCALATION=1: disable phase2/phase3 escalation actions
# - ASW_PROCESS_TIMEOUT=0: do not process unread on timeout ticks (event-only)
ASW_DISABLE_ESCALATION=${ASW_DISABLE_ESCALATION:-0}
ASW_PROCESS_TIMEOUT=${ASW_PROCESS_TIMEOUT:-1}

# ─── Metrics hooks (FR-006 / NFR-003) ───
# unread_latency_sec / read_count / estimated_tokens are intentionally explicit
READ_COUNT=${READ_COUNT:-0}
READ_BYTES_TOTAL=${READ_BYTES_TOTAL:-0}
ESTIMATED_TOKENS_TOTAL=${ESTIMATED_TOKENS_TOTAL:-0}
METRICS_FILE=${METRICS_FILE:-${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/queue/metrics/${AGENT_ID:-unknown}_selfwatch.yaml}

update_metrics() {
    local bytes_read="${1:-0}"
    local now
    now=$(date +%s)

    READ_COUNT=$((READ_COUNT + 1))
    READ_BYTES_TOTAL=$((READ_BYTES_TOTAL + bytes_read))
    ESTIMATED_TOKENS_TOTAL=$((ESTIMATED_TOKENS_TOTAL + ((bytes_read + 3) / 4)))

    local unread_latency_sec=0
    if [ "$FIRST_UNREAD_SEEN" -gt 0 ] 2>/dev/null; then
        unread_latency_sec=$((now - FIRST_UNREAD_SEEN))
    fi

    mkdir -p "$(dirname "$METRICS_FILE")" 2>/dev/null || true
    cat > "$METRICS_FILE" <<EOF
agent_id: "${AGENT_ID:-unknown}"
timestamp: "$(date '+%Y-%m-%dT%H:%M:%S%z')"
unread_latency_sec: $unread_latency_sec
read_count: $READ_COUNT
bytes_read: $READ_BYTES_TOTAL
estimated_tokens: $ESTIMATED_TOKENS_TOTAL
EOF
    # cmd_085 Phase2 item3: append-only history for cross-session/cross-cmd analysis.
    local hist_file="${SCRIPT_DIR}/queue/metrics/${AGENT_ID:-unknown}_selfwatch_history.jsonl"
    mkdir -p "$(dirname "$hist_file")" 2>/dev/null || true
    printf '{"ts":"%s","agent_id":"%s","unread_latency_sec":%s,"read_count":%s,"bytes_read":%s}\n' \
        "$(date -Iseconds)" "${AGENT_ID:-unknown}" "$unread_latency_sec" "$READ_COUNT" "$READ_BYTES_TOTAL" \
        >> "$hist_file" 2>/dev/null || true
}

disable_normal_nudge() {
    # Phase 2+: suppress nudge ONLY when agent is busy.
    # If agent is idle, nudge is needed (stop hook won't fire for idle agents).
    if [ "${ASW_DISABLE_NORMAL_NUDGE:-0}" != "1" ]; then
        return 1  # Phase 1: never suppress
    fi
    # Phase 2+: check if agent is idle via flag file
    if [ -f "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" ]; then
        return 1  # Agent is IDLE → don't suppress, send nudge
    fi
    return 0  # Agent is BUSY → suppress, stop hook will deliver
}

should_throttle_nudge() {
    local unread_count="${1:-0}"
    local now
    now=$(date +%s)

    local effective_cli
    effective_cli=$(get_effective_cli_type)

    local cooldown_sec="${NUDGE_COOLDOWN_SEC:-60}"
    if [[ "$effective_cli" == "codex" ]]; then
        cooldown_sec="${NUDGE_COOLDOWN_SEC_CODEX:-300}"
    elif [[ "$effective_cli" == "opencode" ]]; then
        # OpenCode/local LLM: slow inference; throttle send-keys hard to protect the TUI PTY.
        cooldown_sec="${NUDGE_COOLDOWN_SEC_OPENCODE:-300}"
    elif [[ "$effective_cli" == "claude" ]]; then
        # Claude Code: same cooldown as default (60s).
        # Stop hook is supplementary, not primary — nudge immediately.
        cooldown_sec="${NUDGE_COOLDOWN_SEC_CLAUDE:-60}"
    fi

    # Standard throttle: skip if same count within cooldown window.
    if [ "${LAST_NUDGE_COUNT:-}" = "$unread_count" ] && [ "${LAST_NUDGE_TS:-0}" -gt 0 ]; then
        local age=$((now - LAST_NUDGE_TS))
        if [ "$age" -lt "${cooldown_sec}" ]; then
            echo "[$(date)] [SKIP] Throttling nudge for $AGENT_ID: inbox${unread_count} (${age}s < ${cooldown_sec}s, cli=$effective_cli)" >&2
            return 0
        fi
    fi

    LAST_NUDGE_COUNT="$unread_count"
    LAST_NUDGE_TS="$now"
    return 1
}

is_valid_cli_type() {
    case "${1:-}" in
        claude|codex|copilot|kimi|opencode|gemini) return 0 ;;
        *) return 1 ;;
    esac
}

get_effective_cli_type() {
    local pane_cli_raw=""
    local pane_cli=""

    pane_cli_raw=$(timeout 2 tmux show-options -p -t "$PANE_TARGET" -v @agent_cli 2>/dev/null || true)
    pane_cli=$(echo "$pane_cli_raw" | tr -d '\r' | head -n1 | tr -d '[:space:]')

    if is_valid_cli_type "$pane_cli"; then
        if is_valid_cli_type "${CLI_TYPE:-}" && [ "$pane_cli" != "${CLI_TYPE}" ]; then
            echo "[$(date)] [WARN] CLI drift detected for $AGENT_ID: arg=${CLI_TYPE}, pane=${pane_cli}. Using pane value." >&2
        fi
        echo "$pane_cli"
        return 0
    fi

    if is_valid_cli_type "${CLI_TYPE:-}"; then
        if [ -n "$pane_cli" ]; then
            echo "[$(date)] [WARN] Invalid pane @agent_cli for $AGENT_ID: '${pane_cli}'. Falling back to arg=${CLI_TYPE}." >&2
        fi
        echo "${CLI_TYPE}"
        return 0
    fi

    # Fail-closed: when CLI is unknown, take codex-safe path (no C-c, /clear->/new)
    echo "[$(date)] [WARN] CLI unresolved for $AGENT_ID (pane='${pane_cli:-<empty>}', arg='${CLI_TYPE:-<empty>}'). Fallback=codex-safe." >&2
    echo "codex"
}

normalize_special_command() {
    local msg_type="${1:-}"
    local raw_content="${2:-}"

    case "$msg_type" in
        clear_command)
            echo "/clear"
            ;;
        model_switch)
            if [[ "$raw_content" =~ ^/model[[:space:]]+[^[:space:]].* ]]; then
                echo "$raw_content"
            else
                echo "[$(date)] [SKIP] Invalid model_switch payload for $AGENT_ID: ${raw_content:-<empty>}" >&2
            fi
            ;;
        cli_restart)
            # cli_restart is handled externally by switch_cli.sh, not via send_cli_command.
            # Emit a marker so the main loop can call switch_cli.sh.
            echo "__CLI_RESTART__:${raw_content}"
            ;;
    esac
}

enqueue_recovery_task_assigned() {
    (
        # acquire_inbox_lock also takes flock when available.
        if ! acquire_inbox_lock; then
            echo "ERROR"
            exit 0
        fi
        trap release_inbox_lock EXIT
        INBOX_PATH="$INBOX" AGENT_ID="$AGENT_ID" "$SCRIPT_DIR/.venv/bin/python3" - << 'PY'
import datetime
import os
import uuid
import yaml

inbox = os.environ.get("INBOX_PATH", "")
agent_id = os.environ.get("AGENT_ID", "agent")

try:
    with open(inbox, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    messages = data.get("messages", []) or []

    # Dedup guard: keep only one pending auto-recovery hint at a time.
    for m in reversed(messages):
        if (
            m.get("from") == "inbox_watcher"
            and m.get("type") == "task_assigned"
            and m.get("read", False) is False
            and "[auto-recovery]" in (m.get("content") or "")
        ):
            print("SKIP_DUPLICATE")
            raise SystemExit(0)

    # Task YAML status guard: skip auto-recovery if task is cancelled or idle.
    # This prevents restarting a task that Karo intentionally cancelled via clear_command.
    task_yaml_path = os.path.join(
        os.path.dirname(os.path.dirname(inbox)), "tasks", f"{agent_id}.yaml"
    )
    if os.path.exists(task_yaml_path):
        try:
            with open(task_yaml_path, "r", encoding="utf-8") as tf:
                task_data = yaml.safe_load(tf) or {}
            task_status = str(task_data.get("status") or "").strip().strip("'\"")
            if task_status in ("cancelled", "idle"):
                print(f"SKIP_CANCELLED:{task_status}")
                raise SystemExit(0)
        except SystemExit:
            raise
        except Exception:
            pass  # If task YAML is unreadable, proceed with auto-recovery as safety net

    now = datetime.datetime.now(datetime.timezone.utc).astimezone()
    # Persona re-establishment on /clear is handled by SessionStart hook
    # (scripts/session_start_hook.sh, matcher=clear). Auto-recovery message only
    # ensures task resumption after the /clear inbox nudge is consumed.
    msg = {
        "content": (
            f"[auto-recovery] /clear 後の再着手通知。"
            f"queue/tasks/{agent_id}.yaml を再読し、assigned タスクを即時再開せよ。"
        ),
        "from": "inbox_watcher",
        "id": f"msg_auto_recovery_{now.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}",
        "read": False,
        "timestamp": now.replace(microsecond=0).isoformat(),
        "type": "task_assigned",
    }
    messages.append(msg)
    data["messages"] = messages

    tmp_path = f"{inbox}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(
            data,
            f,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,
        )
    os.replace(tmp_path, inbox)
    print(msg["id"])
except Exception:
    # Best-effort safety net only. Primary /clear delivery must not fail here.
    print("ERROR")
PY
    ) 200>"$LOCKFILE" 2>/dev/null
}

no_idle_full_read() {
    local trigger="${1:-timeout}"
    [ "${ASW_NO_IDLE_FULL_READ:-1}" = "1" ] || return 1
    [ "$trigger" = "timeout" ] || return 1
    [ "${FIRST_UNREAD_SEEN:-0}" -eq 0 ] || return 1
    return 0
}

# summary-first: unread_count fast-path before full read
# cmd_126 Part 1: read/parse failure must NOT be collapsed into "count: 0"
# (0 is indistinguishable from "all read" and drives escalation-reset /
# idle-flag logic downstream). On failure we emit count:null + error:true
# and log a diagnostic to stderr; the caller (process_unread) must treat
# this as "unknown" and fall back to the full read, never as unread=0.
get_unread_count_fast() {
    INBOX_PATH="$INBOX" "$SCRIPT_DIR/.venv/bin/python3" - << 'PY'
import json
import os
import sys
import yaml

inbox = os.environ.get("INBOX_PATH", "")
try:
    with open(inbox, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    messages = data.get("messages", []) or []
    latest = messages[-1] if messages else {}
    unread_count = sum(1 for m in messages if not m.get("read", False))
    latest_content = latest.get("content", "")
    print(json.dumps({
        "count": unread_count,
        "latest_content": latest_content,
        "latest_cmd_id": latest.get("cmd_id") or "",
        "latest_task_id": latest.get("task_id") or "",
        "error": False,
    }))
except Exception as e:
    print(f"[ERROR] [unread_count_fast] read/parse failed for {inbox!r}: {type(e).__name__}: {e}", file=sys.stderr)
    print(json.dumps({
        "count": None,
        "latest_content": "",
        "latest_cmd_id": "",
        "latest_task_id": "",
        "error": True,
        "error_reason": type(e).__name__,
    }))
PY
}

# ─── Extract unread message info ───
# Returns JSON lines: {"count": N, "has_special": true/false, "specials": [...]}
# Test anchor for bats awk pattern: get_unread_info\\(\\)
get_unread_info() {
    (
        # acquire_inbox_lock also takes flock when available.
        # cmd_126 Part 1: lock-acquire failure is a read failure, not "all read".
        # count:null + error:true signals this to process_unread(), which must
        # not perform escalation-reset or idle-flag work on this result.
        if ! acquire_inbox_lock; then
            echo "[$(date)] [ERROR] get_unread_info: failed to acquire inbox lock for ${AGENT_ID:-unknown} — NOT treating as unread=0" >&2
            echo '{"count": null, "specials": [], "error": true, "error_reason": "lock_failed"}'
            exit 0
        fi
        trap release_inbox_lock EXIT
        INBOX_PATH="$INBOX" "$SCRIPT_DIR/.venv/bin/python3" - << 'PY'
import json
import os
import sys
import yaml

inbox = os.environ.get("INBOX_PATH", "")
try:
    with open(inbox, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    messages = data.get("messages", []) or []
    unread = [m for m in messages if not m.get("read", False)]
    special_types = ("clear_command", "model_switch", "cli_restart")
    specials = [m for m in unread if m.get("type") in special_types]

    if specials:
        for m in messages:
            if not m.get("read", False) and m.get("type") in special_types:
                m["read"] = True

        tmp_path = f"{inbox}.tmp.{os.getpid()}"
        with open(tmp_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(
                data,
                f,
                default_flow_style=False,
                allow_unicode=True,
                sort_keys=False,
            )
        os.replace(tmp_path, inbox)

    normal_count = len(unread) - len(specials)
    normal_msgs = [m for m in unread if m.get("type") not in special_types]
    has_task_assigned = any(m.get("type") == "task_assigned" for m in normal_msgs)
    latest = messages[-1] if messages else {}
    latest_content = latest.get("content", "")
    payload = {
        "count": normal_count,
        "has_task_assigned": has_task_assigned,
        "specials": [{"type": m.get("type", ""), "content": m.get("content", "")} for m in specials],
        "latest_content": latest_content,
        "latest_cmd_id": latest.get("cmd_id") or "",
        "latest_task_id": latest.get("task_id") or "",
        "error": False,
    }
    print(json.dumps(payload))
except Exception as e:
    print(f"[ERROR] [unread_info] read/parse failed for {inbox!r}: {type(e).__name__}: {e}", file=sys.stderr)
    print(json.dumps({
        "count": None,
        "specials": [],
        "error": True,
        "error_reason": type(e).__name__,
    }))
PY
    ) 200>"$LOCKFILE"
}

# cmd_126 Part 1: shared error-signal check for get_unread_count_fast /
# get_unread_info JSON payloads. Prints "0" only when the payload parses
# AND explicitly says error:false. Any parse failure or missing/true error
# field prints "1" (fail-safe: unknown is treated as a failure, never as
# "no error").
json_is_error() {
    echo "$1" | "$SCRIPT_DIR/.venv/bin/python3" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(1)
else:
    print(1 if d.get('error') else 0)
" 2>/dev/null
}

# ─── Send CLI command via pty direct write ───
# For /clear and /model only. These are CLI commands, not conversation messages.
# CLI_TYPE別分岐: claude→そのまま, codex→/clear対応・/modelスキップ,
#                  copilot→Ctrl-C+再起動・/modelスキップ, opencode→/clear→/new・/modelスキップ
# 実行時にtmux paneの @agent_cli を再確認し、ドリフト時はpane値を優先する。
send_cli_command() {
    local cmd="$1"
    local effective_cli
    effective_cli=$(get_effective_cli_type)

    # cli_restart: delegate to switch_cli.sh (full /exit → relaunch cycle)
    if [[ "$cmd" == __CLI_RESTART__:* ]]; then
        local restart_args="${cmd#__CLI_RESTART__:}"
        echo "[$(date)] [CLI-RESTART] Delegating to switch_cli.sh for $AGENT_ID: ${restart_args}" >&2
        bash "${SCRIPT_DIR}/scripts/switch_cli.sh" "$AGENT_ID" $restart_args 2>&1 | while IFS= read -r line; do  # SCRIPT_DIR=project_root
            echo "[$(date)] [switch_cli] $line" >&2
        done
        # Update effective CLI type after restart
        CLI_TYPE=$(tmux show-options -p -t "$PANE_TARGET" -v @agent_cli 2>/dev/null || echo "$CLI_TYPE")
        return 0
    fi

    # Safety: never inject CLI commands into the shogun pane.
    # Shogun is controlled by the Lord; keystroke injection can clobber human input.
    if [ "$AGENT_ID" = "shogun" ]; then
        echo "[$(date)] [SKIP] shogun: suppressing CLI command injection ($cmd)" >&2
        return 0
    fi

    # Busy guard: never send /clear when agent is actively processing.
    # clear_command inbox processor also checks busy, but this is a defense-in-depth guard.
    # Sending /clear during Working destroys in-progress context and causes data loss.
    # OpenCode startup can leave capture-pane blank before the first frame renders,
    # so only apply this guard after we can actually observe pane text.
    local pane_snapshot=""
    if [[ "$cmd" == "/clear" ]]; then
        pane_snapshot=$(timeout 2 tmux capture-pane -t "$PANE_TARGET" -p 2>/dev/null || true)
    fi
    if [[ "$cmd" == "/clear" ]] && ! [[ "$effective_cli" == "opencode" && -z "${pane_snapshot//[[:space:]]/}" ]] && agent_is_busy_for_clear; then
        echo "[$(date)] [SKIP] Agent is busy — /clear deferred to next cycle (agent=$AGENT_ID)" >&2
        return 0
    fi

    # CLI別コマンド変換
    local actual_cmd="$cmd"
    case "$effective_cli" in
        codex)
            # Codex: /clear不存在→/newで新規会話開始, /model非対応→スキップ
            # /clearはCodexでは未定義コマンドでCLI終了してしまうため、/newに変換
            if [[ "$cmd" == "/clear" ]]; then
                # Guard: skip duplicate /new if already sent for this batch
                if [ "${NEW_CONTEXT_SENT:-0}" -eq 1 ]; then
                    echo "[$(date)] [SKIP] Codex /new already sent for $AGENT_ID — skipping duplicate clear_command" >&2
                    return 0
                fi
                echo "[$(date)] [SEND-KEYS] Codex /clear→/new: starting new conversation for $AGENT_ID" >&2
                # Dismiss suggestion UI first (typing "x" clears autocomplete prompt)
                timeout 5 tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" "/new" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
                sleep 3
                # Send startup prompt immediately (don't defer to context-reset cycle)
                send_startup_prompt
                NEW_CONTEXT_SENT=1
                return 0
            fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (not supported on codex)" >&2
                return 0
            fi
            ;;
        opencode)
            # OpenCode: /clear is normalized to /new, /model changes are restart-only.
            if [[ "$cmd" == "/clear" ]]; then
                if [ "${NEW_CONTEXT_SENT:-0}" -eq 1 ]; then
                    echo "[$(date)] [SKIP] OpenCode /new already sent for $AGENT_ID — skipping duplicate clear_command" >&2
                    return 0
                fi
                echo "[$(date)] [SEND-KEYS] OpenCode /new for clear_command: starting new conversation for $AGENT_ID" >&2
                timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" "/new" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
                sleep 3
                NEW_CONTEXT_SENT=1
                return 0
             fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (OpenCode model changes are restart-only)" >&2
                return 0
            fi
            ;;
        copilot)
            # Copilot: /clearはCtrl-C+再起動, /model非対応→スキップ
            if [[ "$cmd" == "/clear" ]]; then
                echo "[$(date)] [SEND-KEYS] Copilot /clear: sending Ctrl-C + restart for $AGENT_ID" >&2
                timeout 5 tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null || true
                sleep 2
                timeout 5 tmux send-keys -t "$PANE_TARGET" "copilot --yolo" 2>/dev/null || true
                sleep 0.3
                timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
                sleep 3
                return 0
            fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (not supported on copilot)" >&2
                return 0
            fi
            ;;
        # claude: commands pass through as-is
    esac

    echo "[$(date)] [SEND-KEYS] Sending CLI command to $AGENT_ID ($effective_cli): $actual_cmd" >&2
    # Clear stale input first, then send command (text and Enter separated for Codex TUI)
    # Codex CLI: C-c when idle causes CLI to exit — skip it
    if [[ "$effective_cli" != "codex" ]]; then
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null || true
        sleep 0.5
    fi
    timeout 5 tmux send-keys -t "$PANE_TARGET" "$actual_cmd" 2>/dev/null || true
    # /clear needs longer gap before Enter — CLI prompt may not be ready at 0.3s
    if [[ "$actual_cmd" == "/clear" || "$actual_cmd" == "/new" ]]; then
        sleep 1.0
    else
        sleep 0.3
    fi
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true

    # /clear needs extra wait time before follow-up
    if [[ "$actual_cmd" == "/clear" ]]; then
        LAST_CLEAR_TS=$(date +%s)
        sleep 3
        # Claude: send startup prompt so agent re-runs Session Start after /clear
        if [[ "$effective_cli" == "claude" ]]; then
            send_startup_prompt
        fi
    else
        sleep 1
    fi
}

# ─── Send startup prompt after context reset ───
# Waits for agent to become idle, then sends a startup prompt that includes
# full recovery steps (identify, read task YAML, read inbox, start work).
# Codex uses a typed `x` to dismiss its suggestion UI.
# Called from both send_cli_command (clear_command) and send_context_reset.
send_startup_prompt() {
    # Poll until agent becomes idle (prompt ready) instead of fixed sleep.
    # Max 15s (3 attempts × 5s). If still busy after 15s, proceed anyway.
    local attempt
    for attempt in 1 2 3; do
        sleep 5
        if ! agent_is_busy; then
            echo "[$(date)] [STARTUP] $AGENT_ID idle after ${attempt}×5s — sending startup prompt" >&2
            break
        fi
        echo "[$(date)] [STARTUP] $AGENT_ID still busy after ${attempt}×5s — retrying" >&2
    done
    if agent_is_busy; then
        echo "[$(date)] [STARTUP] $AGENT_ID still busy after 15s — proceeding with startup prompt anyway" >&2
    fi

    local startup_prompt=""
    if type get_startup_prompt &>/dev/null; then
        startup_prompt=$(get_startup_prompt "$AGENT_ID" 2>/dev/null || true)
    fi
    if [[ -z "$startup_prompt" ]]; then
        startup_prompt="Session Start — do ALL of this in one turn, do NOT stop early: 1) tmux display-message to identify yourself. 2) Read queue/tasks/${AGENT_ID}.yaml. 3) Read queue/inbox/${AGENT_ID}.yaml, mark read:true. 4) Read context_files. 5) Execute the assigned task to completion — edit files, run commands, write reports. Keep working until done."
    fi
    local effective_cli
    effective_cli=$(get_effective_cli_type)
    echo "[$(date)] [STARTUP] Sending startup prompt to $AGENT_ID (${effective_cli}): ${startup_prompt:0:80}..." >&2
    # Dismiss suggestion UI, then send startup prompt
    if [[ "$effective_cli" != "opencode" ]]; then
        timeout 5 tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null || true
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
        sleep 0.3
    fi
    timeout 5 tmux send-keys -l -t "$PANE_TARGET" "$startup_prompt" 2>/dev/null || true
    sleep 0.3
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
    STARTUP_PROMPT_SENT=1
}

# ─── Send context reset before new task ───
# Called when task_assigned is detected in unread messages.
# Sends the appropriate "new conversation" command per CLI type to clear
# stale context from the previous task.
# CLI mapping: claude→/clear, codex→/new, opencode→/new, copilot→/clear, kimi→/clear

send_context_reset() {
    local effective_cli
    effective_cli=$(get_effective_cli_type)

    # Safety: never auto-reset context for command-layer agents.
    # Only ashigaru should receive automatic context resets (clear stale task context).
    # Shogun (human-controlled), Karo (coordinator state), Gunshi (strategic state)
    # all maintain complex running context that should not be wiped automatically.
    if [ "$AGENT_ID" = "shogun" ] || [ "$AGENT_ID" = "karo" ] || [ "$AGENT_ID" = "gunshi" ]; then
        echo "[$(date)] [SKIP] $AGENT_ID: suppressing context reset (command-layer agent)" >&2
        return 0
    fi

    local reset_cmd
    case "$effective_cli" in
        codex)    reset_cmd="/new" ;;
        opencode) reset_cmd="/new" ;;
        claude)   reset_cmd="/clear" ;;
        copilot)  reset_cmd="/clear" ;;
        kimi)     reset_cmd="/clear" ;;
        gemini)   reset_cmd="/clear" ;;
        *)        reset_cmd="/new" ;;  # safe default (codex-safe)
    esac

    echo "[$(date)] [CONTEXT-RESET] Sending $reset_cmd before task_assigned for $AGENT_ID ($effective_cli)" >&2

    # Codex/OpenCode: send /new as a single atomic operation.
    # When called from clear_command path, NEW_CONTEXT_SENT=1 prevents reaching here.
    # When called for standalone task_assigned, this is the only /new send.
    if [[ "$effective_cli" == "codex" || "$effective_cli" == "opencode" ]]; then
        # Dismiss suggestion UI (Codex only) + send /new
        if [[ "$effective_cli" == "codex" ]]; then
            timeout 5 tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null || true
            sleep 0.3
        fi
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" "/new" 2>/dev/null || true
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
        sleep 3
        # Codex: send startup prompt (agent has no auto-loaded instructions).
        # OpenCode: skip — agent definition is auto-loaded via --agent flag.
        if [[ "$effective_cli" == "codex" ]]; then
            send_startup_prompt
        fi
        return 0
    fi

    # Non-Codex CLIs: send /clear and wait for idle
    # Send the command (text and Enter separated for TUI compatibility)
    timeout 5 tmux send-keys -t "$PANE_TARGET" "$reset_cmd" 2>/dev/null || true
    # Longer gap for /clear — CLI prompt rendering needs time
    sleep 1.0
    timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
    # Mark /clear timestamp so agent_is_busy() treats it as busy during processing
    if [[ "$reset_cmd" == "/clear" ]]; then
        LAST_CLEAR_TS=$(date +%s)
    fi

    # Poll until agent becomes idle (prompt ready) instead of fixed sleep.
    # Max 15s (3 attempts × 5s). If still busy after 15s, proceed anyway.
    local attempt
    for attempt in 1 2 3; do
        sleep 5
        if ! agent_is_busy; then
            echo "[$(date)] [CONTEXT-RESET] $AGENT_ID idle after ${attempt}×5s — ready for nudge" >&2
            break
        fi
        echo "[$(date)] [CONTEXT-RESET] $AGENT_ID still busy after ${attempt}×5s — retrying" >&2
    done
    if agent_is_busy; then
        echo "[$(date)] [CONTEXT-RESET] $AGENT_ID still busy after 15s — proceeding anyway" >&2
    fi
}

# ─── Agent self-watch detection ───
# Check if the agent has an active inotifywait on its inbox.
# If yes, the agent will self-wake — no nudge needed.
agent_has_self_watch() {
    # Codex/Copilot/Kimi/OpenCode CLIs cannot run self-watch. Only Claude Code agents can.
    local effective_cli
    effective_cli=$(get_effective_cli_type)
    if [[ "$effective_cli" != "claude" ]]; then
        return 1  # non-Claude CLIs never have self-watch
    fi
    # For Claude Code agents: check if an inotifywait exists that is NOT
    # a child of this inbox_watcher process (exclude our own watcher).
    local my_pgid
    my_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    local found=1  # default: not found
    while IFS= read -r pid; do
        local pid_pgid
        pid_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ "$pid_pgid" != "$my_pgid" ]]; then
            found=0  # found an inotifywait NOT from our process group
            break
        fi
    done < <(pgrep -f "inotifywait.*inbox/${AGENT_ID}.yaml" 2>/dev/null)
    return $found
}

# ─── Agent busy detection (three-valued) ───
# Check if the agent's CLI is currently processing (Working/thinking/etc).
# Sending nudge during Working causes text to queue but Enter to be lost.
# Returns 0=busy(観測成功), 1=idle(観測成功), 2=unknown(観測失敗)。
# Implementation: delegates to lib/agent_status.sh (shared library) for the
# pane-based path.
#
# cmd_123 Part A / Fable裁定20260728 Q8: 「観測できなかった」(unknown) を
# 「観測してidleだった」と同一視しない。呼び出し側は自身の動作の破壊性に
# 応じて正しいfail-safeの向きを選べ — agent_is_busy() / agent_is_busy_for_clear()
# を参照。
#
# cmd_126 Part 2 / Fable裁定20260729 Q11: idleフラグの「不在」は
# 「busyの観測」ではなく「判定未了」である（Stop hook未発火・フラグ
# ディレクトリ喪失・エージェント未起動を畳み込み得る＝観測失敗側を含む）。
# フラグ不在から即busy確定する二値潰しをやめ、既存のpane解析三値経路へ
# 縦続する（不在→unknown読替ではなく、不在→本物の観測を追加する）。
agent_is_busy_tri() {
    AGENT_STATUS_UNKNOWN_REASON=""

    # /clear cooldown: treat agent as busy for 30s after /clear was sent.
    # Claude Code's /clear takes 10-30s (CLAUDE.md reload + context init).
    # Without this, nudges sent during /clear processing queue up at the prompt
    # and cause race conditions (inbox1 arrives before /clear completes).
    # This is a known state (not an observation failure), so busy, not unknown.
    local now_busy
    now_busy=$(date +%s)
    if [ "${LAST_CLEAR_TS:-0}" -gt 0 ] && [ "$((now_busy - LAST_CLEAR_TS))" -lt 30 ]; then
        echo "[$(date)] [BUSY-DETERMINATION] agent=$AGENT_ID path=cooldown verdict=busy" >&2
        return 0  # busy — /clear still processing
    fi

    local effective_cli
    effective_cli=$(get_effective_cli_type)
    if [[ "$effective_cli" == "claude" ]]; then
        # フラグ存在 = idle確定（陽性証拠として信頼。従来どおり）。
        if [ -f "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" ]; then
            echo "[$(date)] [BUSY-DETERMINATION] agent=$AGENT_ID path=flag verdict=idle" >&2
            return 1  # idle
        fi
        # フラグ不在 = 判定未了 → pane解析へ縦続（下記の共通処理へ）。
    fi

    # pane解析。claude型はフラグ不在時の第二観測として、非claude型
    # (Codex/OpenCode等)は元来の唯一の判定経路として使う。rc=0/1/2を
    # そのまま透過する。
    agent_is_busy_check "$PANE_TARGET" "$effective_cli"
    local rc=$?
    local verdict="unknown"
    case "$rc" in
        0) verdict="busy" ;;
        1) verdict="idle" ;;
    esac
    if [ "$rc" -eq 2 ]; then
        echo "[$(date)] [UNKNOWN] Busy observation failed for $AGENT_ID: ${AGENT_STATUS_UNKNOWN_REASON:-<no reason recorded>}" >&2
        echo "[$(date)] [BUSY-DETERMINATION] agent=$AGENT_ID path=pane verdict=unknown reason=${AGENT_STATUS_UNKNOWN_REASON:-<no reason recorded>}" >&2
    else
        echo "[$(date)] [BUSY-DETERMINATION] agent=$AGENT_ID path=pane verdict=$verdict" >&2
    fi
    return "$rc"
}

# ─── Fleet-wide ashigaru idle detection (cmd_158 依頼事項1) ───
# agent_is_busy_tri()は自プロセスのAGENT_ID/PANE_TARGETグローバルに暗黙依存する
# 設計(1プロセス=1エージェント専属)であり、karo等の単一プロセスから他の
# ashigaruの状態をこの関数経由で問い合わせることはできない
# (gunshi_decompose_158 item1)。パラメータ化済みの下位プリミティブ
# agent_is_busy_check(pane, cli)を直接呼ぶことで再発明を避ける。
#
# watcher_supervisor.shのget_multiagent_pane_base()と同型のpane_base解決。
# 別ファイルの関数を直接参照できないため、同一ロジックをここに複製する。
_fleet_multiagent_pane_base() {
    if [ -n "${SHOGUN_PANE_BASE:-}" ]; then
        echo "$SHOGUN_PANE_BASE"
        return 0
    fi
    tmux show-options -gv pane-base-index 2>/dev/null || echo 0
}

# 戻り値はagent_is_busy_check()と同じ規約: 0=busy(1体でもbusy)
# / 1=idle(全ashigaru idle) / 2=unknown(1体でも判定不能)。
# 判定不能をidle側へ倒す経路は作らない(judgment_model原則1)。
fleet_all_ashigaru_idle_tri() {
    if ! type agent_registry_default_agents &>/dev/null || ! type agent_is_busy_check &>/dev/null; then
        echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=ALL verdict=unknown reason=required_lib_functions_unavailable" >&2
        return 2
    fi

    local pane_base
    pane_base=$(_fleet_multiagent_pane_base)

    local agent pane cli rc verdict
    local saw_unknown=0
    local saw_busy=0

    while IFS= read -r agent; do
        [[ "$agent" =~ ^ashigaru[0-9]+$ ]] || continue

        if [ -f "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${agent}" ]; then
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=$agent path=flag verdict=idle" >&2
            continue
        fi

        if ! pane=$(agent_registry_pane_for_agent "$agent" "$pane_base"); then
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=$agent path=pane verdict=unknown reason=pane_resolution_failed" >&2
            saw_unknown=1
            continue
        fi

        cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "")

        agent_is_busy_check "$pane" "$cli"
        rc=$?
        case "$rc" in
            0) verdict="busy"; saw_busy=1 ;;
            1) verdict="idle" ;;
            *) verdict="unknown"; saw_unknown=1 ;;
        esac
        if [ "$rc" -eq 2 ]; then
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=$agent path=pane verdict=unknown reason=${AGENT_STATUS_UNKNOWN_REASON:-<no reason recorded>}" >&2
        else
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=$agent path=pane verdict=$verdict" >&2
        fi
    done < <(agent_registry_default_agents)

    if [ "$saw_unknown" -eq 1 ]; then
        echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=ALL verdict=unknown" >&2
        return 2
    fi
    if [ "$saw_busy" -eq 1 ]; then
        echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=ALL verdict=busy" >&2
        return 0
    fi
    echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=ALL verdict=idle" >&2
    return 1
}

# ─── Non-destructive fail-safe direction (nudge / delivery actions) ───
# unknown → treated as NOT busy (proceed with delivery). Wrong-guess loss is
# minor: one extra short nudge into a working agent's input; the inbox
# read-flag makes reprocessing idempotent (see T-NUDGE-IDEMPOTENT).
# This preserves the existing agent_is_busy() contract used throughout this
# file (0=true/busy, non-zero=false/not-busy in `if agent_is_busy; then`).
agent_is_busy() {
    agent_is_busy_tri
    local rc=$?
    [ "$rc" -eq 0 ]
}

# ─── Destructive fail-safe direction (/clear, forced-reset-class actions) ───
# unknown → treated as busy (block/defer). Wrong-guess loss is severe: /clear
# (or Escape/Ctrl-C forced interrupt) destroys an in-progress agent's context.
# Only a KNOWN idle observation (rc=1) is allowed to proceed.
agent_is_busy_for_clear() {
    agent_is_busy_tri
    local rc=$?
    [ "$rc" -ne 1 ]
}

# ─── Pane focus detection (human safety) ───
# If the target pane is currently active, avoid injecting keystrokes.
pane_is_active() {
    local active=""
    active=$(timeout 2 tmux display-message -p -t "$PANE_TARGET" '#{pane_active}' 2>/dev/null || true)
    [ "$active" = "1" ]
}

# ─── Session attach detection ───
# Function: session_has_client
# Description: Checks if the tmux session containing PANE_TARGET has at least
#   one client attached. Used to avoid suppressing send-keys when no human is
#   watching (e.g. single-pane shogun session where pane_is_active is always true).
# Arguments: none (uses global PANE_TARGET)
# Returns: 0 if at least one client is attached, 1 otherwise
session_has_client() {
    local session_name
    session_name=$(timeout 2 tmux display-message -p -t "$PANE_TARGET" '#{session_name}' 2>/dev/null || true)
    [ -n "$session_name" ] && [ "$(tmux list-clients -t "$session_name" 2>/dev/null | wc -l)" -gt 0 ]
}

# ─── Send wake-up nudge ───
# Layered approach:
#   1. If agent has active inotifywait self-watch → skip (agent wakes itself)
#   2. If agent is busy (Working) → skip (nudge during Working loses Enter)
#   3. tmux send-keys (短いnudgeのみ、timeout 5s)
send_wakeup() {
    local unread_count="$1"
    local nudge="inbox${unread_count}"

    if [ "${FINAL_ESCALATION_ONLY:-0}" = "1" ]; then
        echo "[$(date)] [SKIP] FINAL_ESCALATION_ONLY=1, suppressing normal nudge for $AGENT_ID" >&2
        return 0
    fi

    # 優先度1: Agent self-watch — nudge不要（エージェントが自分で気づく）
    if agent_has_self_watch; then
        echo "[$(date)] [SKIP] Agent $AGENT_ID has active self-watch, no nudge needed" >&2
        return 0
    fi

    # 優先度2: Agent busy — nudge送信するとEnterが消失するためスキップ
    # Claude Code: Stop hook catches unread at turn end. Skip nudge to avoid Enter loss.
    # Exception: shogun — ntfy must be delivered immediately regardless of busy state.
    if agent_is_busy && [[ "$AGENT_ID" != "shogun" ]]; then
        local busy_cli_wakeup
        busy_cli_wakeup=$(get_effective_cli_type)
        if [[ "$busy_cli_wakeup" == "claude" ]]; then
            echo "[$(date)] [SKIP] Agent $AGENT_ID is busy (claude) — Stop hook will deliver, no nudge" >&2
        else
            echo "[$(date)] [SKIP] Agent $AGENT_ID is busy ($busy_cli_wakeup), deferring nudge" >&2
        fi
        return 0
    fi

    if should_throttle_nudge "$unread_count"; then
        return 0
    fi

    # Shogun: deliver nudge via send-keys like other agents.
    # ntfy messages must reach Claude Code directly.

    # 優先度3: tmux send-keys（テキストとEnterを分離 — Codex TUI対策）
    echo "[$(date)] [SEND-KEYS] Sending nudge to $PANE_TARGET for $AGENT_ID" >&2

    # Codex suggestion UI dismissal: typing any character dismisses the autocomplete
    # suggestion prompt (› Implement {feature} etc.) that traps idle agents.
    # Sequence: "x" (dismiss suggestion) → C-u (clear input) → nudge → Enter
    local effective_cli_for_nudge
    effective_cli_for_nudge=$(get_effective_cli_type)

    # OpenCode/Gemini agents: use explicit instruction instead of terse "inboxN"
    # These agents cannot parse "inbox2" as a protocol trigger
    if [[ "$effective_cli_for_nudge" == "opencode" ]] || [[ "$effective_cli_for_nudge" == "gemini" ]]; then
        nudge="queue/inbox/${AGENT_ID}.yaml と queue/tasks/${AGENT_ID}.yaml を Read してタスクを実行せよ。完了後 scripts/inbox_write.sh で軍師に報告すること。"
    fi

    # 非Claudeエージェント（gemini/opencode）は inbox を自律的に read:true にできない
    # inbox_watcher 側で自動既読にすることで重複 nudge を防ぐ
    if [[ "$effective_cli_for_nudge" == "gemini" ]] || [[ "$effective_cli_for_nudge" == "opencode" ]]; then
        python3 -c "
import sys, re
path = '${INBOX}'
try:
    with open(path, 'r') as f:
        content = f.read()
    updated = re.sub(r'^(\s+read: )false', r'\1true', content, flags=re.MULTILINE)
    with open(path, 'w') as f:
        f.write(updated)
    print('[auto-mark] Marked all messages as read for ${AGENT_ID}', file=sys.stderr)
except Exception as e:
    print(f'[auto-mark] Failed: {e}', file=sys.stderr)
" 2>&1 >&2 || true
    fi

    if [[ "$effective_cli_for_nudge" == "codex" ]]; then
        timeout 5 tmux send-keys -t "$PANE_TARGET" "x" 2>/dev/null || true
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
        sleep 0.3
    fi

    # 行クリア（残存テキスト除去）→ nudge送信 → Enter → 確認 → 最大2回リトライ
    local max_retries=2
    local attempt=0
    while [ $attempt -le $max_retries ]; do
        # C-u で行をクリア
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
        sleep 0.3
        # nudge 送信
        if ! timeout 5 tmux send-keys -t "$PANE_TARGET" "$nudge" 2>/dev/null; then
            echo "[$(date)] WARNING: send-keys nudge failed for $AGENT_ID (attempt $((attempt+1)))" >&2
            attempt=$((attempt+1))
            continue
        fi
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
        sleep 0.5
        if [[ "$effective_cli_for_nudge" == "codex" ]]; then
            # Codex echoes submitted text in the transcript; seeing inboxN after
            # Enter does not mean it is still stuck in the input field.
            LAST_ASSIGNMENT_TS=$(date +%s)
            echo "[$(date)] Wake-up sent to $AGENT_ID (${unread_count} unread, attempt $((attempt+1)), cli=codex)" >&2
            return 0
        fi
        # 送信確認: capture-pane でプロンプトにnudgeテキストが残っていないか確認
        local pane_content
        pane_content=$(timeout 3 tmux capture-pane -t "$PANE_TARGET" -p 2>/dev/null | tail -5 || echo "")
        if echo "$pane_content" | grep -qF "$nudge"; then
            # nudgeテキストが残存 → 送信失敗 → C-u クリアしてリトライ
            echo "[$(date)] WARNING: nudge text still visible in pane, retrying (attempt $((attempt+1)))" >&2
            timeout 5 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
            sleep 0.3
            attempt=$((attempt+1))
            continue
        fi
        # 送信成功
        # NOTE: アイドルフラグは削除しない。nudge送信≠エージェント起動確認。
        # フラグを消すと agent_is_busy()=true → 以降のnudge全スキップ → デッドロック。
        # フラグはエージェントが実際に作業開始した時に自然消滅する（stop_hook設計と整合）。
        LAST_ASSIGNMENT_TS=$(date +%s)
        echo "[$(date)] Wake-up sent to $AGENT_ID (${unread_count} unread, attempt $((attempt+1)))" >&2
        return 0
    done
    echo "[$(date)] WARNING: send-keys failed after $max_retries retries for $AGENT_ID" >&2
    return 0  # Never return 1 — set -euo pipefail would kill the watcher daemon
}

# ─── Send wake-up nudge with Escape prefix ───
# Phase 2 escalation: Copilot/Kimi get Escape×2 + single Ctrl-C + nudge.
# Claude/Codex/OpenCode fall back to a plain nudge.
send_wakeup_with_escape() {
    local unread_count="$1"
    local nudge="inbox${unread_count}"
    local effective_cli
    effective_cli=$(get_effective_cli_type)

    # Safety: never send Escape escalation to shogun. It can wipe the Lord's input.
    if [ "$AGENT_ID" = "shogun" ]; then
        echo "[$(date)] [SKIP] shogun: suppressing Escape escalation; sending plain nudge" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    # Codex CLI: ESC は「中断」になりやすく、人間操作中の事故も多い。
    # Phase 2 の Escape エスカレーションは無効化し、通常 nudge のみに落とす。
    if [[ "$effective_cli" == "codex" ]]; then
        echo "[$(date)] [SKIP] codex: suppressing Escape escalation for $AGENT_ID; sending plain nudge" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    # Claude Code: Stop hookがturn終了時にinbox未読を検出→自動処理する。
    # Escape送信は処理中のturnを中断させるため有害。Phase 2は通常nudgeに落とす。
    if [[ "$effective_cli" == "claude" ]]; then
        echo "[$(date)] [SKIP] claude: suppressing Escape escalation for $AGENT_ID (Stop hook handles delivery); sending plain nudge" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    # OpenCode: Escape is bound to session_interrupt in the pinned TUI config.
    # Phase 2 must not interrupt the session; fall back to a plain nudge.
    if [[ "$effective_cli" == "opencode" ]]; then
        echo "[$(date)] [SKIP] opencode: suppressing Escape escalation for $AGENT_ID (Escape interrupts the session); sending plain nudge" >&2
        send_wakeup "$unread_count"
        return 0
    fi

    if [ "${FINAL_ESCALATION_ONLY:-0}" = "1" ]; then
        echo "[$(date)] [SKIP] FINAL_ESCALATION_ONLY=1, suppressing phase2 nudge for $AGENT_ID" >&2
        return 0
    fi

    if agent_has_self_watch; then
        return 0
    fi

    # Phase 2 still skips if agent is busy — Escape during Working would interrupt.
    # Escape/Ctrl-C is a forced-interrupt-class action (強制リセット類), so unknown
    # observation must fail toward NOT sending it (agent_is_busy_for_clear direction).
    if agent_is_busy_for_clear; then
        echo "[$(date)] [SKIP] Agent $AGENT_ID is busy (Working), deferring Phase 2 nudge" >&2
        return 0
    fi

    echo "[$(date)] [SEND-KEYS] ESCALATION Phase 2: Escape×2 + nudge for $AGENT_ID (cli=$effective_cli)" >&2
    # Escape×2 to exit any mode
    timeout 5 tmux send-keys -t "$PANE_TARGET" Escape Escape 2>/dev/null || true
    sleep 0.5
    if [[ "$effective_cli" == "copilot" || "$effective_cli" == "kimi" ]]; then
        timeout 5 tmux send-keys -t "$PANE_TARGET" C-c 2>/dev/null || true
        sleep 0.5
    fi
    if timeout 5 tmux send-keys -t "$PANE_TARGET" "$nudge" 2>/dev/null; then
        sleep 0.3
        timeout 5 tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true
        echo "[$(date)] Escape+nudge sent to $AGENT_ID (${unread_count} unread, cli=$effective_cli)" >&2
        return 0
    fi

    echo "[$(date)] WARNING: send-keys failed for Escape+nudge ($AGENT_ID)" >&2
    return 0  # Never return 1 — set -euo pipefail would kill the watcher daemon
}

# ─── Process cycle ───
process_unread() {
    local trigger="${1:-event}"

    # summary-first: unread_count fast-path (Phase 2/3 optimization)
    # unread_count fast-path lets us skip expensive full reads when idle.
    local fast_info
    fast_info=$(get_unread_count_fast)
    local fast_err
    fast_err=$(json_is_error "$fast_info")
    local fast_count
    fast_count=$(echo "$fast_info" | "$SCRIPT_DIR/.venv/bin/python3" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
c = d.get('count')
print(c if c is not None else '')
" 2>/dev/null)

    # cmd_126 Part 1: fail-loud — a read/parse failure must never be treated
    # as unread=0. On failure, fast_count is empty (never "0"), so the
    # no_idle_full_read short-circuit below naturally falls through to the
    # full read (get_unread_info) instead of assuming "all read".
    if [ "$fast_err" != "0" ]; then
        echo "[$(date)] [ERROR] $AGENT_ID: get_unread_count_fast failed to read/parse inbox — NOT assuming unread=0, falling back to full read" >&2
    fi

    if [ "$fast_err" = "0" ] && no_idle_full_read "$trigger" && [ "$fast_count" -eq 0 ] 2>/dev/null; then
        # no_idle_full_read guard: unread=0 and timeout path → no full inbox read
        if [ "$FIRST_UNREAD_SEEN" -ne 0 ]; then
            echo "[$(date)] All messages read for $AGENT_ID — escalation reset (fast-path)" >&2
            local fast_latest_content fast_msg_cmd_id fast_msg_task_id fast_ids
            fast_latest_content=$(echo "$fast_info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_content',''))" 2>/dev/null)
            fast_msg_cmd_id=$(echo "$fast_info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_cmd_id',''))" 2>/dev/null)
            fast_msg_task_id=$(echo "$fast_info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_task_id',''))" 2>/dev/null)
            fast_ids=$(resolve_timing_ids "$fast_msg_cmd_id" "$fast_msg_task_id" "$fast_latest_content")
            log_agent_started_event "$(printf '%s' "$fast_ids" | cut -f1)" "$(printf '%s' "$fast_ids" | cut -f2)"
        fi
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
        reset_nudge_throttle
        # Ensure idle flag exists (fast-path recovery)
        touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" 2>/dev/null || true
        if ! agent_is_busy; then
            # Shogun: only clear input when pane is not active (Lord is away)
            if [ "$AGENT_ID" = "shogun" ] && pane_is_active; then
                : # Lord may be typing — skip C-u
            else
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
            fi
        fi
        return 0
    fi

    local info
    info=$(get_unread_info)
    local info_err
    info_err=$(json_is_error "$info")
    if [ "$info_err" != "0" ]; then
        # cmd_126 Part 1: fail-loud — do not perform escalation-reset or
        # idle-flag work on a failed read. Safe default: skip this cycle
        # (no destructive action either way) and retry on the next poll.
        echo "[$(date)] [ERROR] $AGENT_ID: get_unread_info failed to read/parse inbox — skipping this cycle (no escalation reset, unread NOT assumed 0)" >&2
        return 0
    fi

    local read_bytes=0
    if [ -f "$INBOX" ]; then
        read_bytes=$(wc -c < "$INBOX" 2>/dev/null || echo 0)
    fi
    update_metrics "${read_bytes:-0}"

    # Handle special CLI commands first (/clear, /model)
    local specials
    specials=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('specials', []):
    t = s.get('type', '')
    c = (s.get('content', '') or '').replace('\t', ' ').replace('\n', ' ').strip()
    print(f'{t}\t{c}')
" 2>/dev/null)

    local clear_seen=0
    local clear_sent=0  # tracks if /clear was actually sent (not just seen)
    if [ -n "$specials" ]; then
        local msg_type msg_content cmd
        while IFS=$'\t' read -r msg_type msg_content; do
            [ -n "$msg_type" ] || continue
            if [ "$msg_type" = "clear_command" ]; then
                clear_seen=1
                # Busy guard: skip /clear if agent is currently processing.
                # Sending /clear during active work destroys in-progress context.
                if agent_is_busy_for_clear && [[ "$AGENT_ID" != "shogun" ]]; then
                    echo "[$(date)] [SKIP] Agent $AGENT_ID is busy — /clear (clear_command) deferred to next cycle" >&2
                    continue
                fi
            fi
            cmd=$(normalize_special_command "$msg_type" "$msg_content")
            if [ -n "$cmd" ]; then
                send_cli_command "$cmd"
                [ "$msg_type" = "clear_command" ] && clear_sent=1
            fi
        done <<< "$specials"
    fi

    # /clear は Codex で /new へ変換される。再起動直後の取りこぼし防止として
    # 追加 task_assigned を自動投入し、次サイクルで確実に wake-up 可能にする。
    # 案B+待機: Karo がタスク YAML を cancelled に更新するまでの猶予を確保してから
    # status チェックを行い、cancelled/idle の場合はスキップする。
    # clear_sent（実際に送信）のみauto-recoveryを起動。busy時スキップは対象外。
    if [ "$clear_sent" -eq 1 ]; then
        # Wait for Karo to update task YAML status (cancellation race condition mitigation).
        # send_cli_command already slept 3s for /clear; add 5s more = ~8s total before check.
        sleep 5
        local recovery_id
        recovery_id=$(enqueue_recovery_task_assigned)
        if [[ "$recovery_id" == SKIP_CANCELLED:* ]]; then
            echo "[$(date)] [AUTO-RECOVERY] skipped for $AGENT_ID — task is ${recovery_id#SKIP_CANCELLED:} (not restarting)" >&2
        elif [ -n "$recovery_id" ] && [ "$recovery_id" != "SKIP_DUPLICATE" ] && [ "$recovery_id" != "ERROR" ]; then
            echo "[$(date)] [AUTO-RECOVERY] queued task_assigned for $AGENT_ID ($recovery_id)" >&2
        fi
        info=$(get_unread_info)
        local info_err2
        info_err2=$(json_is_error "$info")
        if [ "$info_err2" != "0" ]; then
            echo "[$(date)] [ERROR] $AGENT_ID: get_unread_info failed after /clear dispatch — skipping remainder of cycle (no escalation reset)" >&2
            return 0
        fi
    fi

    # Send wake-up nudge for normal messages (with escalation)
    local normal_count
    normal_count=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)

    # Check if unread messages include task_assigned (for context reset)
    local has_task_assigned
    has_task_assigned=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(1 if json.load(sys.stdin).get('has_task_assigned') else 0)" 2>/dev/null)

    if [ "$normal_count" -gt 0 ] 2>/dev/null; then
        local now
        now=$(date +%s)

        # When the agent is busy/thinking, do NOT escalate. Interrupting with Escape or /clear
        # can terminate the current thought. Also pause the escalation timer while busy so we
        # don't immediately jump to Phase 2/3 once it becomes idle.
        # Exception: shogun — ntfy must be delivered immediately.
        # Safety net: if busy detection persists for >5 min, assume false-busy (stale flag)
        # and force-create idle flag to allow nudge delivery.
        if agent_is_busy && [[ "$AGENT_ID" != "shogun" ]]; then
            local busy_cli
            busy_cli=$(get_effective_cli_type)
            # Stale busy safety net: if agent has been "busy" for >5 minutes with
            # unread messages, force-create idle flag. This recovers from false-busy
            # deadlock where stop_hook failed to create the flag.
            #
            # cmd_126 Part 2 / Fable裁定20260729 Q12: この発火(WARNING行、
            # grep -c 'stale busy recovery')は絶対回数ではなく
            #   stale busy recovery発火回数 ÷ [BUSY-DETERMINATION]総数(grep -c)
            # の比率(配達機会あたりの発火率)で読むこと。かつ解釈順序を固定する
            # — Q11是正(フラグ不在→pane解析への縦続)が実トラフィックに乗るまでは、
            # 発火率が下がらなくても「別の穴」ではなく「修正が当該経路に未到達」
            # と読め。Q8-(4)の読み筋(激減しなければ別の穴)はQ11是正の反映後に
            # 初めて適用する。それまでの計測はベースライン収集と位置づける。
            local stale_busy_limit=300  # 5 minutes
            if [ "${FIRST_UNREAD_SEEN:-0}" -gt 0 ] && [ "$((now - FIRST_UNREAD_SEEN))" -ge "$stale_busy_limit" ]; then
                echo "[$(date)] WARNING: $AGENT_ID busy for $((now - FIRST_UNREAD_SEEN))s with $normal_count unread — forcing idle flag (stale busy recovery)" >&2
                touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}"
                # Fall through to normal nudge/escalation below
            else
                if [[ "$busy_cli" == "claude" ]]; then
                    # Claude Code: Stop hook will catch unread messages when the agent's
                    # turn ends. No nudge needed at all — just log and skip completely.
                    # Set FIRST_UNREAD_SEEN so the stale-busy safety net (above) can
                    # activate if the stop hook never fires.
                    if [ "${FIRST_UNREAD_SEEN:-0}" -eq 0 ]; then
                        FIRST_UNREAD_SEEN=$now
                    fi
                    echo "[$(date)] $normal_count unread for $AGENT_ID but agent is busy (claude) — Stop hook will deliver" >&2
                else
                    # Codex/Copilot/Kimi/OpenCode: No Stop hook. Pause escalation timer while busy.
                    FIRST_UNREAD_SEEN=$now
                    echo "[$(date)] $normal_count unread for $AGENT_ID but agent is busy ($busy_cli) — pausing escalation timer" >&2
                fi
                return 0
            fi
        fi

        # ─── Context reset before new task ───
        # Send /new or /clear once when task_assigned is first detected,
        # to clear stale context from the previous task.
        # Skip if: (1) already sent this batch, (2) clear_command already handled above,
        #          (3) agent is shogun (human-controlled).
        if [ "$has_task_assigned" = "1" ] && [ "$NEW_CONTEXT_SENT" -eq 0 ] && [ "$clear_seen" -eq 0 ]; then
            send_context_reset
            NEW_CONTEXT_SENT=1
            LAST_ASSIGNMENT_TS=$(date +%s)
        fi

        # If startup prompt was just sent (Codex), skip follow-up nudge this cycle.
        # The prompt itself contains full recovery instructions (identify + read YAML + work).
        if [ "$STARTUP_PROMPT_SENT" -eq 1 ]; then
            STARTUP_PROMPT_SENT=0
            echo "[$(date)] [SKIP] Startup prompt just sent to $AGENT_ID — skipping nudge this cycle" >&2
            FIRST_UNREAD_SEEN=$now
            return 0
        fi

        # Track when we first saw unread messages
        if [ "$FIRST_UNREAD_SEEN" -eq 0 ]; then
            FIRST_UNREAD_SEEN=$now
            local notify_content notify_cmd_id notify_task_id notify_ids
            notify_content=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_content',''))" 2>/dev/null)
            notify_cmd_id=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_cmd_id',''))" 2>/dev/null)
            notify_task_id=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_task_id',''))" 2>/dev/null)
            notify_ids=$(resolve_timing_ids "$notify_cmd_id" "$notify_task_id" "$notify_content")
            log_agent_notified_event "$(printf '%s' "$notify_ids" | cut -f1)" "$(printf '%s' "$notify_ids" | cut -f2)"
        fi

        if [ "${ASW_DISABLE_ESCALATION:-0}" = "1" ]; then
            echo "[$(date)] $normal_count unread for $AGENT_ID (escalation disabled)" >&2
            if disable_normal_nudge; then
                echo "[$(date)] [SKIP] disable_normal_nudge=1, no normal nudge for $AGENT_ID" >&2
            else
                send_wakeup "$normal_count"
            fi
            return 0
        fi

        local age=$((now - FIRST_UNREAD_SEEN))

        # Assignment grace window (cmd_066): right after a nudge/task_assigned is
        # delivered, the PreToolUse hook needs a moment to fire and clear the idle
        # flag. Hold age at 0 during that lag so Phase1/2/3 doesn't misfire on an
        # agent that just started working.
        if [ "${LAST_ASSIGNMENT_TS:-0}" -gt 0 ] && \
           [ "$((now - LAST_ASSIGNMENT_TS))" -lt "$ASSIGNMENT_GRACE_SECONDS" ]; then
            age=0
        fi

        # CLI-aware escalation thresholds. Local LLMs (opencode) respond slowly;
        # the default 120s/240s windows misjudge active inference as unresponsive
        # and corrupt the TUI PTY with mid-render send-keys (setRawMode errno5).
        local phase1=$ESCALATE_PHASE1
        local phase2=$ESCALATE_PHASE2
        if [[ "$(get_effective_cli_type)" == "opencode" ]]; then
            phase1=${ESCALATE_PHASE1_OPENCODE:-600}
            phase2=${ESCALATE_PHASE2_OPENCODE:-900}
        fi

        if [ "$age" -lt "$phase1" ]; then
            # Phase 1 (0-2 min): Standard nudge
            echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s)" >&2
            if disable_normal_nudge; then
                echo "[$(date)] [SKIP] disable_normal_nudge=1, deferring to escalation-only path" >&2
            else
                send_wakeup "$normal_count"
            fi
        elif [ "$age" -lt "$phase2" ]; then
            # Phase 2 (2-4 min): Escape + nudge
            echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s — escalating: Escape+nudge)" >&2
            send_wakeup_with_escape "$normal_count"
        else
            # Phase 3 (4+ min): /clear (throttled to once per 5 min)
            if [ "$LAST_CLEAR_TS" -lt "$((now - ESCALATE_COOLDOWN))" ]; then
                local effective_cli
                effective_cli=$(get_effective_cli_type)
                if [[ "$effective_cli" == "codex" ]]; then
                    # Codex /clear -> /new は会話を切ってしまうため、安全側に倒す。
                    echo "[$(date)] ESCALATION Phase 3: $AGENT_ID unresponsive for ${age}s, but cli=codex — skipping /clear." >&2
                    FIRST_UNREAD_SEEN=$now  # Reset timer (no destructive action)
                    send_wakeup "$normal_count"
                elif [ "$AGENT_ID" = "shogun" ] || [ "$AGENT_ID" = "karo" ] || [ "$AGENT_ID" = "gunshi" ]; then
                    # Command-layer agents (karo/gunshi/shogun): suppress /clear even in Phase 3
                    echo "[$(date)] [SKIP] ESCALATION Phase 3: $AGENT_ID suppressed (command-layer agent, ${age}s). Using Escape+nudge." >&2
                    FIRST_UNREAD_SEEN=$now  # Reset timer
                    send_wakeup_with_escape "$normal_count"
                else
                    echo "[$(date)] ESCALATION Phase 3: Agent $AGENT_ID unresponsive for ${age}s. Sending /clear." >&2
                    # cmd_087 Part B: Phase3発火時の状態計装(しきい値・判定条件は無変更)
                    local p3_busy p3_pane_cmd p3_age p3_content p3_cmd_id p3_task_id p3_ids
                    # cmd_123 Part A: log the raw tri-state (not the collapsed boolean) so
                    # "unknown" observation failures at the moment /clear fires are visible
                    # in the metric used to track today's 17-fire/5696s baseline.
                    agent_is_busy_tri
                    case $? in
                        0) p3_busy="true" ;;
                        1) p3_busy="false" ;;
                        2) p3_busy="unknown" ;;
                    esac
                    p3_pane_cmd=$(timeout 2 tmux display-message -t "$PANE_TARGET" -p '#{pane_current_command}' 2>/dev/null || echo "")
                    p3_age="$age"
                    p3_content=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_content',''))" 2>/dev/null)
                    p3_cmd_id=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_cmd_id',''))" 2>/dev/null)
                    p3_task_id=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_task_id',''))" 2>/dev/null)
                    p3_ids=$(resolve_timing_ids "$p3_cmd_id" "$p3_task_id" "$p3_content")
                    extra_json=$(printf '{"busy":"%s","pane_cmd":"%s","age_sec":"%s"}' "$p3_busy" "$p3_pane_cmd" "$p3_age")
                    bash "${SCRIPT_DIR}/scripts/log_timing_event.sh" phase3_fired \
                        "$(printf '%s' "$p3_ids" | cut -f1)" "$(printf '%s' "$p3_ids" | cut -f2)" "$AGENT_ID" \
                        --source="inbox_watcher.sh:phase3" --extra="$extra_json"
                    send_cli_command "/clear"
                    LAST_CLEAR_TS=$now
                    FIRST_UNREAD_SEEN=0  # Reset — will re-detect on next cycle
                    NEW_CONTEXT_SENT=0
                fi
            else
                # Cooldown active — fall back to Escape+nudge
                echo "[$(date)] $normal_count unread for $AGENT_ID (${age}s — /clear cooldown, using Escape+nudge)" >&2
                send_wakeup_with_escape "$normal_count"
            fi
        fi
    else
        # No unread messages — reset escalation tracker
        if [ "$FIRST_UNREAD_SEEN" -ne 0 ]; then
            echo "[$(date)] All messages read for $AGENT_ID — escalation reset" >&2
            local latest_content msg_cmd_id msg_task_id ids
            latest_content=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_content',''))" 2>/dev/null)
            msg_cmd_id=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_cmd_id',''))" 2>/dev/null)
            msg_task_id=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(json.load(sys.stdin).get('latest_task_id',''))" 2>/dev/null)
            ids=$(resolve_timing_ids "$msg_cmd_id" "$msg_task_id" "$latest_content")
            log_agent_started_event "$(printf '%s' "$ids" | cut -f1)" "$(printf '%s' "$ids" | cut -f2)"
        fi
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
        reset_nudge_throttle
        # Ensure idle flag exists when all messages are read.
        # Recovers from stop_hook_inbox.sh flag loss during block cycles.
        touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" 2>/dev/null || true
        # Clear stale nudge text from input field (Codex CLI prefills last input on idle).
        # Only send C-u when agent is idle — during Working it would be disruptive.
        if ! agent_is_busy; then
            # Shogun: only clear input when pane is not active (Lord is away)
            if [ "$AGENT_ID" = "shogun" ] && pane_is_active; then
                : # Lord may be typing — skip C-u
            else
                timeout 2 tmux send-keys -t "$PANE_TARGET" C-u 2>/dev/null || true
            fi
        fi
    fi
}

process_unread_once() {
    process_unread "startup"
}

# ─── Startup: process any existing unread messages (skipped in testing mode) ───
if [ "${__INBOX_WATCHER_TESTING__:-}" != "1" ]; then
    process_unread_once
fi

# ─── Function definitions below are always loaded, even in testing mode ───
# (cmd_146: check_dashboard_staleness/check_urgent_inbox_escalation need to be
# unit-testable via bats; only the main loop itself stays gated — see below)

# ─── Escalation threshold check (cmd_052d) ───
# Counts this agent's auto_heal events in logs/auto_heal_events.jsonl within the
# last AUTO_HEAL_ESCALATION_WINDOW_MIN minutes (the ts field is compared via
# python3 datetime, not date(1), since jsonl already carries ISO8601+offset).
# Prints one of: FIRE:<count> / COOLDOWN:<count> / BELOW:<count> / ERROR.
check_auto_heal_escalation() {
    local agent_id="$1"
    local jsonl="${SCRIPT_DIR}/logs/auto_heal_events.jsonl"
    [ -f "$jsonl" ] || { echo "BELOW:0"; return 0; }

    AGENT_ID_FOR_ESC="$agent_id" \
    WINDOW_MIN="$AUTO_HEAL_ESCALATION_WINDOW_MIN" \
    THRESHOLD="$AUTO_HEAL_ESCALATION_THRESHOLD" \
    COOLDOWN_MIN="$AUTO_HEAL_ESCALATION_COOLDOWN_MIN" \
    JSONL_PATH="$jsonl" \
    timeout 2 "$SCRIPT_DIR/.venv/bin/python3" -c "
import datetime, json, os

agent = os.environ['AGENT_ID_FOR_ESC']
window_min = float(os.environ['WINDOW_MIN'])
threshold = int(os.environ['THRESHOLD'])
cooldown_min = float(os.environ['COOLDOWN_MIN'])
path = os.environ['JSONL_PATH']

now = datetime.datetime.now().astimezone()
window_start = now - datetime.timedelta(minutes=window_min)
cooldown_start = now - datetime.timedelta(minutes=cooldown_min)

heal_count = 0
last_escalation_ts = None
try:
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get('agent') != agent:
                continue
            ts_raw = rec.get('ts')
            if not ts_raw:
                continue
            try:
                ts = datetime.datetime.fromisoformat(ts_raw)
            except Exception:
                continue
            if rec.get('event') == 'auto_heal' and ts >= window_start:
                heal_count += 1
            elif rec.get('event') == 'auto_heal_escalated':
                if last_escalation_ts is None or ts > last_escalation_ts:
                    last_escalation_ts = ts
except Exception:
    print('ERROR')
    raise SystemExit

if heal_count < threshold:
    print(f'BELOW:{heal_count}')
elif last_escalation_ts is not None and last_escalation_ts >= cooldown_start:
    print(f'COOLDOWN:{heal_count}')
else:
    print(f'FIRE:{heal_count}')
" 2>/dev/null || echo "ERROR"
}

# ─── Auto-heal watchdog ───
# If the CLI's TUI process has crashed, the pane drops back to a bare login
# shell. Detect that (requiring 2 consecutive observations to avoid catching the
# brief shell window during a normal switch_cli relaunch) and revive the agent.
check_and_heal_dead_cli() {
    [ "${ASW_AUTO_HEAL:-1}" = "1" ] || return 0
    [ -f "${SCRIPT_DIR}/logs/auto_heal_paused/${AGENT_ID}" ] && return 0

    local pane_cmd
    pane_cmd=$(timeout 2 tmux display-message -t "$PANE_TARGET" -p '#{pane_current_command}' 2>/dev/null || echo "")

    case "$pane_cmd" in
        bash|sh|zsh|fish|-bash|-sh|-zsh)
            DEAD_CLI_STREAK=$((DEAD_CLI_STREAK + 1))
            ;;
        *)
            DEAD_CLI_STREAK=0
            return 0
            ;;
    esac

    # Require 2 consecutive dead detections (~30-60s of confirmed shell) before acting.
    [ "$DEAD_CLI_STREAK" -ge 2 ] || return 0

    local now
    now=$(date +%s)
    if [ "$LAST_HEAL_TS" -gt "$((now - HEAL_COOLDOWN_SEC))" ]; then
        return 0  # cooldown active — relaunch already in progress
    fi

    local configured_cli
    configured_cli=$(get_effective_cli_type)
    echo "[$(date)] [AUTO-HEAL] $AGENT_ID CLI ($configured_cli) appears dead (pane_cmd=$pane_cmd, streak=$DEAD_CLI_STREAK). Relaunching via switch_cli.sh." >&2
    local heal_event_ts
    heal_event_ts=$(date +%Y-%m-%dT%H:%M:%S%:z)
    mkdir -p "${SCRIPT_DIR}/logs" 2>/dev/null || true

    # ─── Root cause snapshot (cmd_052c) ───
    # Collected here — the last moment before switch_cli.sh overwrites the pane
    # by relaunching the CLI. All sub-commands are timeout-guarded (2s) so this
    # never delays revival.
    local rc_pane_tail rc_pane_tail_40 rc_errno5_found rc_pane_size
    local rc_backend_alive rc_backend_method rc_snapshot_json

    rc_pane_tail=$(timeout 2 tmux capture-pane -t "$PANE_TARGET" -p -S -200 2>/dev/null || echo "")
    rc_pane_tail_40=$(printf '%s' "$rc_pane_tail" | tail -n 40)

    if printf '%s' "$rc_pane_tail" | grep -aEq 'setRawMode|errno[ :]?5|EIO|ENOTTY'; then
        rc_errno5_found=true
    else
        rc_errno5_found=false
    fi

    rc_pane_size=$(timeout 2 tmux display-message -t "$PANE_TARGET" -p '#{pane_width}x#{pane_height}' 2>/dev/null || echo "unknown")

    # Backend health check: connection reachability only (curl "000" = unreachable).
    # A non-"000" HTTP code (even 401/404) means the backend process is up.
    case "$AGENT_ID" in
        ashigaru3)
            rc_backend_method="curl openrouter models endpoint (2s timeout)"
            local rc_http_code
            rc_http_code=$(timeout 2 curl -s -o /dev/null -w '%{http_code}' https://openrouter.ai/api/v1/models 2>/dev/null || echo "000")
            [ -n "$rc_http_code" ] && [ "$rc_http_code" != "000" ] && rc_backend_alive=true || rc_backend_alive=false
            ;;
        ashigaru4)
            rc_backend_method="curl ollama tags endpoint (2s timeout)"
            local rc_http_code
            rc_http_code=$(timeout 2 curl -s -o /dev/null -w '%{http_code}' http://localhost:11434/api/tags 2>/dev/null || echo "000")
            [ -n "$rc_http_code" ] && [ "$rc_http_code" != "000" ] && rc_backend_alive=true || rc_backend_alive=false
            ;;
        *)
            rc_backend_method="n/a (Claude-family agent, not applicable)"
            rc_backend_alive="not_applicable"
            ;;
    esac

    # JSON escaping (jq非依存): python3 json.dumps()に一任し、制御文字含む全エッジケースをカバーする。
    local rc_pane_tail_escaped
    rc_pane_tail_escaped=$(printf '%s' "$rc_pane_tail_40" | "$SCRIPT_DIR/.venv/bin/python3" -c \
        "import json,sys; print(json.dumps(sys.stdin.read())[1:-1])")

    local rc_backend_alive_json
    if [ "$rc_backend_alive" = "true" ] || [ "$rc_backend_alive" = "false" ]; then
        rc_backend_alive_json="$rc_backend_alive"
    else
        rc_backend_alive_json="\"$rc_backend_alive\""
    fi

    rc_snapshot_json=$(printf '"root_cause_snapshot":{"pane_tail_last_40":"%s","errno5_signature_found":%s,"pane_size":"%s","backend_alive":%s,"backend_check_method":"%s"}' \
        "$rc_pane_tail_escaped" "$rc_errno5_found" "$rc_pane_size" "$rc_backend_alive_json" "$rc_backend_method")

    printf '{"ts":"%s","agent":"%s","event":"auto_heal","cli":"%s","pane_cmd_before":"%s","cooldown_sec":%s,%s}\n' \
        "$heal_event_ts" "$AGENT_ID" "$configured_cli" "$pane_cmd" "$HEAL_COOLDOWN_SEC" "$rc_snapshot_json" \
        >> "${SCRIPT_DIR}/logs/auto_heal_events.jsonl" 2>/dev/null || true

    # ─── Escalation ntfy + auto-heal pause (cmd_052d / cmd_069) ───
    # Runs BEFORE the relaunch below: switch_cli.sh's inbox_watcher restart
    # (Step 7 pkill) self-terminates this very watcher process, so anything
    # placed after the switch_cli.sh call never executes. This block — ntfy,
    # jsonl logging, and pause-marker creation — must land on disk first.
    # silent_heal_enabled=false → skip entirely, preserving pre-052d silent behavior.
    if [ "${AUTO_HEAL_SILENT_ENABLED}" = "true" ]; then
        local esc_result
        esc_result=$(check_auto_heal_escalation "$AGENT_ID")
        case "$esc_result" in
            FIRE:*)
                local esc_count="${esc_result#FIRE:}"
                echo "[$(date)] [AUTO-HEAL-ESCALATION] $AGENT_ID reached ${esc_count} auto_heal(s) within ${AUTO_HEAL_ESCALATION_WINDOW_MIN}min — firing ntfy." >&2
                bash "${SCRIPT_DIR}/scripts/ntfy.sh" "🚨 auto_heal閾値到達: ${AGENT_ID}が${AUTO_HEAL_ESCALATION_WINDOW_MIN}分内${esc_count}回蘇生。以後のauto-healを一時停止した" >&2 || true
                local esc_ts
                esc_ts=$(date +%Y-%m-%dT%H:%M:%S%:z)
                printf '{"ts":"%s","agent":"%s","event":"auto_heal_escalated","window_minutes":%s,"count":%s}\n' \
                    "$esc_ts" "$AGENT_ID" "$AUTO_HEAL_ESCALATION_WINDOW_MIN" "$esc_count" \
                    >> "${SCRIPT_DIR}/logs/auto_heal_events.jsonl" 2>/dev/null || true
                mkdir -p "${SCRIPT_DIR}/logs/auto_heal_paused" 2>/dev/null || true
                touch "${SCRIPT_DIR}/logs/auto_heal_paused/${AGENT_ID}" 2>/dev/null || true
                printf '{"ts":"%s","agent":"%s","event":"auto_heal_paused","reason":"escalation_threshold_reached","count":%s,"window_minutes":%s}\n' \
                    "$esc_ts" "$AGENT_ID" "$esc_count" "$AUTO_HEAL_ESCALATION_WINDOW_MIN" \
                    >> "${SCRIPT_DIR}/logs/auto_heal_events.jsonl" 2>/dev/null || true
                ;;
            COOLDOWN:*)
                echo "[$(date)] [AUTO-HEAL-ESCALATION] $AGENT_ID over threshold but cooldown active — skipping ntfy." >&2
                ;;
            BELOW:*) ;;  # under threshold — no-op
            *)
                echo "[$(date)] WARNING: check_auto_heal_escalation failed for $AGENT_ID (result=$esc_result)" >&2
                ;;
        esac
    fi

    LAST_HEAL_TS=$now
    DEAD_CLI_STREAK=0
    bash "${SCRIPT_DIR}/scripts/switch_cli.sh" "$AGENT_ID" 2>&1 | while IFS= read -r line; do
        echo "[$(date)] [switch_cli] $line" >&2
    done
    return 0
}

# ─── Dashboard staleness watchdog (cmd_065 Part A-2) ───
# dashboard.md の🚨要対応項目が created_at (HTMLコメント埋込) から
# dashboard_staleness.hours 経過しても放置されている場合、ntfy で再通知する。
# karo の inbox_watcher インスタンスのみが呼び出す(配線側でAGENT_ID判定)。
_read_dashboard_staleness_setting() {
    local key="$1" default="$2"
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/config/settings.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('dashboard_staleness') or {}).get('$key')
    if v is None:
        v = '$default'
    print(v)
except Exception:
    print('$default')
" 2>/dev/null
}

check_dashboard_staleness() {
    local marker="${SCRIPT_DIR}/logs/.dashboard_staleness_last_check"
    local interval_min
    interval_min=$(_read_dashboard_staleness_setting check_interval_minutes 30)
    [ -n "$interval_min" ] || interval_min=30

    mkdir -p "${SCRIPT_DIR}/logs" 2>/dev/null || true

    if [ -f "$marker" ]; then
        local last_check now_epoch elapsed_min
        last_check=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        elapsed_min=$(( (now_epoch - last_check) / 60 ))
        if [ "$elapsed_min" -lt "$interval_min" ]; then
            return 0
        fi
    fi
    touch "$marker" 2>/dev/null || true

    local hours cooldown_min
    hours=$(_read_dashboard_staleness_setting hours 24)
    cooldown_min=$(_read_dashboard_staleness_setting cooldown_after_escalation_minutes 360)
    [ -n "$hours" ] || hours=24
    [ -n "$cooldown_min" ] || cooldown_min=360

    local dashboard_path="${SCRIPT_DIR}/dashboard.md"
    [ -f "$dashboard_path" ] || return 0

    DASHBOARD_PATH="$dashboard_path" \
    DASHBOARD_STALE_HOURS="$hours" \
    DASHBOARD_STALE_COOLDOWN_MIN="$cooldown_min" \
    TIMING_JSONL="${SCRIPT_DIR}/logs/timing_events.jsonl" \
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import datetime, json, os, re

dashboard_path = os.environ['DASHBOARD_PATH']
stale_hours = float(os.environ['DASHBOARD_STALE_HOURS'])
cooldown_min = float(os.environ['DASHBOARD_STALE_COOLDOWN_MIN'])
jsonl_path = os.environ['TIMING_JSONL']

try:
    with open(dashboard_path, encoding='utf-8') as f:
        content = f.read()
except Exception:
    raise SystemExit

now = datetime.datetime.now()

# cmd_146①: created_at走査を🚨要対応セクション内(次の`## `見出しまで、またはEOF)に
# 限定する。見出し検出は行頭`## `+「要対応」部分一致とし、絵文字の有無を吸収する。
section_start_re = re.compile(r'^## .*要対応.*\n', re.MULTILINE)
m_start = section_start_re.search(content)
if m_start:
    m_end = re.compile(r'^## ', re.MULTILINE).search(content, m_start.end())
    scan_content = content[m_start.end():m_end.start() if m_end else len(content)]
else:
    scan_content = ''

# cmd_146③: 再通知を段階的に頻度低下させる(初回360分→2回目720分→3回目以降1440分)。
# 通知回数はlog_timing_event.shの--extra=へ`notify_count=N`として埋め込み、
# 新規ストレージを増やさずtiming_events.jsonlのみで完結させる(judgment_model.md原則6)。
# 直近の1件(最新ts)のみを見ればよい——古い記録は段階判定に不要。
notify_history = {}
try:
    with open(jsonl_path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get('event') != 'dashboard_stale_notified':
                continue
            tid = rec.get('task_id')
            ts_raw = rec.get('ts')
            if not tid or not ts_raw:
                continue
            try:
                ts = datetime.datetime.fromisoformat(ts_raw)
            except Exception:
                continue
            if ts.tzinfo is not None:
                ts = ts.replace(tzinfo=None)
            extra = rec.get('extra') or ''
            m_count = re.match(r'notify_count=(\d+)', extra)
            count = int(m_count.group(1)) if m_count else 1
            prev = notify_history.get(tid)
            if prev is None or ts > prev[0]:
                notify_history[tid] = (ts, count)
except Exception:
    pass

def stage_gap_min(prev_count):
    if prev_count <= 1:
        return cooldown_min
    if prev_count == 2:
        return 720.0
    return 1440.0

for m in re.finditer(r'<!-- created_at: (\S+) -->\s*\n(.+)', scan_content):
    created_at_raw, text = m.group(1), m.group(2)
    try:
        created_at = datetime.datetime.fromisoformat(created_at_raw)
    except Exception:
        continue
    age_hours = (now - created_at).total_seconds() / 3600
    if age_hours < stale_hours:
        continue
    hist = notify_history.get(created_at_raw)
    if hist is not None:
        last_ts, prev_count = hist
        elapsed_min = (now - last_ts).total_seconds() / 60
        if elapsed_min < stage_gap_min(prev_count):
            continue
        next_count = prev_count + 1
    else:
        next_count = 1
    print(f'{created_at_raw}\t{next_count}\t' + text.strip()[:50])
" 2>/dev/null | while IFS=$'\t' read -r created_at_raw notify_count snippet; do
        [ -n "$created_at_raw" ] || continue
        bash "${SCRIPT_DIR}/scripts/ntfy.sh" "🚨 24時間放置: ${snippet}" >&2 || true
        bash "${SCRIPT_DIR}/scripts/log_timing_event.sh" dashboard_stale_notified "" "$created_at_raw" karo --source=inbox_watcher.sh --extra="notify_count=${notify_count}" || true
    done

    return 0
}

# ─── Urgent inbox escalation watchdog (cmd_146②) ───
# queue/inbox/*.yaml の各エントリに`urgent: true`かつ`read: false`のまま
# 閾値時間を超えたものがあれば殿へntfyエスカレーションする。2026-08-01、
# 軍師の緊急報告がkaroのinboxでread:falseのまま3日間放置された実損事案の
# 再発防止(north_star cmd_146)。karo instanceのメインループからのみ呼ばれる
# (check_dashboard_staleness()と同じ設計パターン)。
_read_urgent_escalation_setting() {
    local key="$1" default="$2"
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/config/settings.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('urgent_inbox_escalation') or {}).get('$key')
    if v is None:
        v = '$default'
    print(v)
except Exception:
    print('$default')
" 2>/dev/null
}

check_urgent_inbox_escalation() {
    local marker="${SCRIPT_DIR}/logs/.urgent_inbox_escalation_last_check"
    local interval_min
    interval_min=$(_read_urgent_escalation_setting check_interval_minutes 5)
    [ -n "$interval_min" ] || interval_min=5

    mkdir -p "${SCRIPT_DIR}/logs" 2>/dev/null || true

    if [ -f "$marker" ]; then
        local last_check now_epoch elapsed_min
        last_check=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        elapsed_min=$(( (now_epoch - last_check) / 60 ))
        if [ "$elapsed_min" -lt "$interval_min" ]; then
            return 0
        fi
    fi
    touch "$marker" 2>/dev/null || true

    local threshold_min cooldown_min
    threshold_min=$(_read_urgent_escalation_setting threshold_minutes 120)
    cooldown_min=$(_read_urgent_escalation_setting cooldown_after_escalation_minutes 60)
    [ -n "$threshold_min" ] || threshold_min=120
    [ -n "$cooldown_min" ] || cooldown_min=60

    local inbox_dir="${SCRIPT_DIR}/queue/inbox"
    [ -d "$inbox_dir" ] || return 0

    INBOX_DIR="$inbox_dir" \
    URGENT_THRESHOLD_MIN="$threshold_min" \
    URGENT_COOLDOWN_MIN="$cooldown_min" \
    TIMING_JSONL="${SCRIPT_DIR}/logs/timing_events.jsonl" \
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import datetime, glob, json, os
import yaml

inbox_dir = os.environ['INBOX_DIR']
threshold_min = float(os.environ['URGENT_THRESHOLD_MIN'])
cooldown_min = float(os.environ['URGENT_COOLDOWN_MIN'])
jsonl_path = os.environ['TIMING_JSONL']

now = datetime.datetime.now()
cooldown_start = now - datetime.timedelta(minutes=cooldown_min)

# 直近cooldown内にエスカレーション済みのmessage idを集める(単一情報源=timing_events.jsonl)
escalated_recently = set()
try:
    with open(jsonl_path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get('event') != 'urgent_inbox_escalated':
                continue
            mid = rec.get('task_id')
            ts_raw = rec.get('ts')
            if not mid or not ts_raw:
                continue
            try:
                ts = datetime.datetime.fromisoformat(ts_raw)
            except Exception:
                continue
            if ts.tzinfo is not None:
                ts = ts.replace(tzinfo=None)
            if ts >= cooldown_start:
                escalated_recently.add(mid)
except Exception:
    pass

for path in sorted(glob.glob(os.path.join(inbox_dir, '*.yaml'))):
    agent = os.path.splitext(os.path.basename(path))[0]
    try:
        with open(path, encoding='utf-8') as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        continue
    for msg in (data.get('messages') or []):
        if not isinstance(msg, dict):
            continue
        if not msg.get('urgent'):
            continue
        if msg.get('read'):
            continue
        mid = msg.get('id')
        ts_raw = msg.get('timestamp')
        if not mid or not ts_raw:
            continue
        try:
            ts = datetime.datetime.fromisoformat(ts_raw)
        except Exception:
            continue
        age_min = (now - ts).total_seconds() / 60
        if age_min < threshold_min:
            continue
        if mid in escalated_recently:
            continue
        snippet = str(msg.get('content') or '')[:50]
        print(agent + '\t' + mid + '\t' + snippet)
" 2>/dev/null | while IFS=$'\t' read -r agent msg_id snippet; do
        [ -n "$msg_id" ] || continue
        bash "${SCRIPT_DIR}/scripts/ntfy.sh" "🚨 緊急未読(${threshold_min}分超): [${agent}] ${snippet}" >&2 || true
        bash "${SCRIPT_DIR}/scripts/log_timing_event.sh" urgent_inbox_escalated "" "$msg_id" "$agent" --source=inbox_watcher.sh || true
    done

    return 0
}

# ─── 陣手空き検知: cmd実行中判定・inbox未読集約判定 (cmd_158 依頼事項1後半) ───
# 戻り値はfleet_all_ashigaru_idle_tri()と同じ規約: 0=busy/1=idle/2=unknown。
_fleet_cmd_status_tri() {
    local out
    out=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/queue/shogun_to_karo.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    commands = data.get('commands') or []
    if not commands:
        print('idle')
    else:
        terminal = {'done', 'done_with_caveat'}
        has_busy = False
        has_unknown = False
        for c in commands:
            status = c.get('status') if isinstance(c, dict) else None
            if status in ('pending', 'in_progress'):
                has_busy = True
            elif isinstance(status, str) and (status in terminal or status.startswith('superseded')):
                pass
            else:
                has_unknown = True
        if has_busy:
            print('busy')
        elif has_unknown:
            print('unknown')
        else:
            print('idle')
except Exception:
    print('unknown')
" 2>/dev/null)
    case "$out" in
        busy)
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] element=cmd verdict=busy" >&2
            return 0 ;;
        idle)
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] element=cmd verdict=idle" >&2
            return 1 ;;
        *)
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] element=cmd verdict=unknown reason=shogun_to_karo_yaml_unreadable_or_unparseable" >&2
            return 2 ;;
    esac
}

# 対象は明示列挙(shogun/karo/gunshi/ashigaru1-7)。test_*.yaml等の
# 非エージェントファイルをglobで拾わないため。shogunを含める根拠:
# 通知対象自身(将軍宛の未処理下命)を除外すると誤ってidle判定してしまう
# (gunshi_decompose_158 item1後半)。
_fleet_inbox_unread_tri() {
    local inbox_dir="${SCRIPT_DIR}/queue/inbox"
    local out
    out=$(INBOX_DIR="$inbox_dir" "$SCRIPT_DIR/.venv/bin/python3" -c "
import os
import yaml

inbox_dir = os.environ['INBOX_DIR']
agents = ['shogun', 'karo', 'gunshi', 'ashigaru1', 'ashigaru2', 'ashigaru3',
          'ashigaru4', 'ashigaru5', 'ashigaru6', 'ashigaru7']
total = 0
error = False
for name in agents:
    path = os.path.join(inbox_dir, name + '.yaml')
    try:
        with open(path, encoding='utf-8') as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        error = True
        continue
    for msg in (data.get('messages') or []):
        if isinstance(msg, dict) and not msg.get('read'):
            total += 1
if error:
    print('unknown\t0')
else:
    print(('busy' if total > 0 else 'idle') + '\t' + str(total))
" 2>/dev/null)
    local verdict="${out%%$'\t'*}"
    local count="${out#*$'\t'}"
    case "$verdict" in
        busy)
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] element=inbox verdict=busy unread_total=$count" >&2
            return 0 ;;
        idle)
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] element=inbox verdict=idle unread_total=0" >&2
            return 1 ;;
        *)
            echo "[$(date)] [FLEET-IDLE-DETERMINATION] element=inbox verdict=unknown reason=inbox_yaml_unreadable_or_unparseable" >&2
            return 2 ;;
    esac
}

# 通知本文生成 (cmd_158 依頼事項4・subtask_158_C 正式実装)。
# mandate/approval_queue.mdのAQエントリを走査し、pending系(状態欄に
# approved/rejectedのいずれも含まないもの)が1件以上あれば件数・ID列挙を
# 末尾に付記する。引数なし・通知本文をstdoutへ返す規約はプレースホルダから変更なし。
build_fleet_idle_message() {
    local prefix="🈳 全cmd消化・次の下命待ち"
    local aq_file="${SCRIPT_DIR}/mandate/approval_queue.md"
    local pending_out
    pending_out=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import re
try:
    with open('${aq_file}', encoding='utf-8') as f:
        text = f.read()
except Exception:
    print('')
    raise SystemExit(0)

# エントリ境界: 行頭'- ID: AQ-<num>'から次の同パターン(またはEOF)まで。
entries = list(re.finditer(r'^- ID: (AQ-\d+)', text, re.MULTILINE))
pending_ids = []
for i, m in enumerate(entries):
    aq_id = m.group(1)
    start = m.end()
    end = entries[i + 1].start() if i + 1 < len(entries) else len(text)
    body = text[start:end]
    status_m = re.search(r'^\s*状態:\s*(.+)\$', body, re.MULTILINE)
    if status_m is None:
        continue
    status_val = status_m.group(1)
    # 消去法判定(軍師設計注記: approved/rejected以外は全てpending系とみなす。
    # 将来の状態語彙追加〈例: 'on_hold'等〉で誤判定し得る既知の脆さがある)。
    if 'approved' not in status_val and 'rejected' not in status_val:
        pending_ids.append(aq_id)
print(str(len(pending_ids)) + '\t' + ','.join(pending_ids))
" 2>/dev/null)

    local pending_count="${pending_out%%$'\t'*}"
    local pending_ids_csv="${pending_out#*$'\t'}"
    if [[ "$pending_count" =~ ^[0-9]+$ ]] && [ "$pending_count" -gt 0 ]; then
        local pending_ids_joined
        pending_ids_joined=$(echo "$pending_ids_csv" | sed 's/,/, /g')
        echo "${prefix} approval_queue pending ${pending_count}件(${pending_ids_joined})"
    else
        echo "$prefix"
    fi
}

# ─── 陣手空き検知→ntfy通知 本体 (cmd_158 依頼事項2) ───
# 3要素(全ashigaru idle・cmd実行中/queuedなし・全エージェントinbox未読ゼロ)を
# 集約した三値判定がidleへ遷移してから features.fleet_idle_notify_stable_sec
# 秒(既定300)安定したら1回だけ通知する。既存のkaro限定rc=2(30秒timeout)
# ティックへ相乗りする設計であり、新規ポーリングループは作らない(F004)。
check_fleet_idle_notify() {
    # 🔴フラグゲート: enforce/observe以外(未設定・off・読取失敗含む)は
    # 即return 0。settings.yamlはPyYAMLのYAML1.1解釈で無引用の`off`が
    # bool Falseへ変換されるが、'observe'/'enforce'のいずれとも一致しない
    # 限りすべて'off'扱いになるため fail-safe は影響を受けない。
    local mode
    mode=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/config/settings.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('features') or {}).get('fleet_idle_notify_enabled')
    print(v if v in ('observe', 'enforce') else 'off')
except Exception:
    print('off')
" 2>/dev/null)
    if [ "$mode" != "observe" ] && [ "$mode" != "enforce" ]; then
        echo "[$(date)] [FLEET-IDLE-DETERMINATION] element=flag_mode mode=off action=silent_return" >&2
        return 0
    fi

    mkdir -p "${SCRIPT_DIR}/logs" 2>/dev/null || true
    local candidate_marker="${SCRIPT_DIR}/logs/.fleet_idle_candidate_since"
    local notified_marker="${SCRIPT_DIR}/logs/.fleet_idle_notified_since"
    local events_jsonl="${SCRIPT_DIR}/logs/fleet_idle_events.jsonl"

    local ashigaru_rc cmd_rc inbox_rc overall
    fleet_all_ashigaru_idle_tri; ashigaru_rc=$?
    _fleet_cmd_status_tri; cmd_rc=$?
    _fleet_inbox_unread_tri; inbox_rc=$?

    if [ "$ashigaru_rc" -eq 2 ] || [ "$cmd_rc" -eq 2 ] || [ "$inbox_rc" -eq 2 ]; then
        overall="unknown"
        local reasons=""
        [ "$ashigaru_rc" -eq 2 ] && reasons="${reasons}ashigaru "
        [ "$cmd_rc" -eq 2 ] && reasons="${reasons}cmd "
        [ "$inbox_rc" -eq 2 ] && reasons="${reasons}inbox "
        echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=ALL verdict=unknown reason=undetermined_elements:${reasons% }" >&2
    elif [ "$ashigaru_rc" -eq 0 ] || [ "$cmd_rc" -eq 0 ] || [ "$inbox_rc" -eq 0 ]; then
        overall="busy"
        echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=ALL verdict=busy" >&2
    else
        overall="idle"
        echo "[$(date)] [FLEET-IDLE-DETERMINATION] agent=ALL verdict=idle" >&2
    fi

    if [ "$overall" != "idle" ]; then
        # 候補状態が安定待ちの途中で崩れた場合、抑止した事実をログへ残す
        # (誤発火抑止の実測、judgment_model原則14)。
        if [ -f "$candidate_marker" ]; then
            local candidate_since now_epoch held_for
            candidate_since=$(cat "$candidate_marker" 2>/dev/null || echo "")
            if [[ "$candidate_since" =~ ^[0-9]+$ ]]; then
                now_epoch=$(date +%s)
                held_for=$((now_epoch - candidate_since))
                printf '{"event":"candidate_broken","candidate_since":%s,"broken_at":%s,"held_for_sec":%s}\n' \
                    "$candidate_since" "$now_epoch" "$held_for" >> "$events_jsonl"
            fi
            rm -f "$candidate_marker"
        fi
        # busy/unknownへ戻ったら次回idle再遷移時に新エピソードとして扱う。
        rm -f "$notified_marker"
        return 0
    fi

    # overall == idle
    local now_epoch candidate_since
    now_epoch=$(date +%s)
    if [ -f "$candidate_marker" ]; then
        candidate_since=$(cat "$candidate_marker" 2>/dev/null || echo "")
    fi
    if ! [[ "${candidate_since:-}" =~ ^[0-9]+$ ]]; then
        candidate_since="$now_epoch"
        echo "$candidate_since" > "$candidate_marker"
    fi

    local stable_sec
    stable_sec=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/config/settings.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('features') or {}).get('fleet_idle_notify_stable_sec')
    print(int(v))
except Exception:
    print(300)
" 2>/dev/null)
    [[ "$stable_sec" =~ ^[0-9]+$ ]] || stable_sec=300

    local elapsed=$((now_epoch - candidate_since))
    if [ "$elapsed" -lt "$stable_sec" ]; then
        return 0
    fi

    local notified_since=""
    if [ -f "$notified_marker" ]; then
        notified_since=$(cat "$notified_marker" 2>/dev/null || echo "")
    fi
    if [ -n "$notified_since" ] && [ "$notified_since" = "$candidate_since" ]; then
        # 同一の手空きエピソード内 → 再送しない
        return 0
    fi

    local message
    message=$(build_fleet_idle_message)

    # 秘匿値混入防止ガード(多重防御・cmd_158-C): 一次防御は通知文の構成要素に
    # トピック名・トークンを一切含めない設計そのもの。加えて送信直前にfail-loudな
    # 簡易パターン検査を行う(cmd_149「トピック名は非git管理ファイル経由のみ」運用との多重防御)。
    if echo "$message" | grep -qi "ntfy\.sh/\|Bearer \|topic"; then
        echo "[$(date)] [FLEET-IDLE-NOTIFY] ERROR blocked_possible_secret_leak_in_message" >&2
        return 0
    fi

    if [ "$mode" = "enforce" ]; then
        bash "${SCRIPT_DIR}/scripts/ntfy.sh" "$message" >&2 || true
        bash "${SCRIPT_DIR}/scripts/log_timing_event.sh" fleet_idle_notified cmd_158 "" "" \
            --source=inbox_watcher.sh --extra="candidate_since:${candidate_since}" || true
    else
        echo "[$(date)] [FLEET-IDLE-NOTIFY] mode=observe suppressed message=${message}" >&2
    fi
    echo "$candidate_since" > "$notified_marker"
    return 0
}

# ─── Main loop: event-driven via inotifywait (skipped in testing mode) ───
if [ "${__INBOX_WATCHER_TESTING__:-}" != "1" ]; then
# Timeout 30s: WSL2 /mnt/c/ can miss inotify events.
# Shorter timeout = faster escalation retry for stuck agents.
INOTIFY_TIMEOUT="${INOTIFY_TIMEOUT:-30}"

while true; do
    # Block until file is modified OR timeout
    # Backend-specific file watching: inotifywait (Linux) or fswatch (macOS)
    set +e
    if [ "${WATCH_BACKEND:-inotifywait}" = "fswatch" ]; then
        # macOS: fswatch -1 exits after one event. Use timeout for safety net.
        # gtimeout (from coreutils) or perl fallback for macOS timeout
        if command -v gtimeout &>/dev/null; then
            gtimeout "$INOTIFY_TIMEOUT" fswatch -1 --event Updated --event Renamed "$INBOX" 2>/dev/null
            rc=$?
            # gtimeout returns 124 on timeout
            if [ "$rc" -eq 124 ]; then rc=2; else rc=0; fi
        else
            # Fallback: use background fswatch + sleep timeout
            fswatch -1 --event Updated --event Renamed "$INBOX" &>/dev/null &
            FSWATCH_PID=$!
            WAITED=0
            while [ "$WAITED" -lt "$INOTIFY_TIMEOUT" ] && kill -0 "$FSWATCH_PID" 2>/dev/null; do
                sleep 2
                WAITED=$((WAITED + 1))
            done
            if kill -0 "$FSWATCH_PID" 2>/dev/null; then
                kill "$FSWATCH_PID" 2>/dev/null
                wait "$FSWATCH_PID" 2>/dev/null
                rc=2  # timeout
            else
                wait "$FSWATCH_PID" 2>/dev/null
                rc=0  # event
            fi
        fi
    else
        # Linux: inotifywait (original behavior)
        inotifywait -q -t "$INOTIFY_TIMEOUT" -e modify -e close_write "$INBOX" 2>/dev/null
        rc=$?
    fi
    set -e

    # rc=0: event fired (instant delivery)
    # rc=1: watch invalidated — Claude Code uses atomic write (tmp+rename),
    #        which replaces the inode. inotifywait sees DELETE_SELF → rc=1.
    #        File still exists with new inode. Treat as event, re-watch next loop.
    # rc=2: timeout (30s safety net for WSL2 inotify gaps / macOS fswatch timeout)
    # All cases: check for unread, then loop back (re-watches new inode)
    sleep 0.3

    if [ "$rc" -eq 2 ]; then
        check_and_heal_dead_cli
        if [ "$AGENT_ID" = "karo" ]; then
            check_dashboard_staleness || true
            check_urgent_inbox_escalation || true
            check_fleet_idle_notify || true
        fi
        if [ "${ASW_PROCESS_TIMEOUT:-1}" = "1" ]; then
            process_unread "timeout"
        fi
    else
        process_unread "event"
    fi
done

fi  # end testing guard

# Source shared agent status library outside the testing guard so that
# agent_is_busy_check() is available in test mode too.
# In normal mode it was already sourced above; double-sourcing is harmless.
_agent_status_lib="${SCRIPT_DIR}/lib/agent_status.sh"
if [ -f "$_agent_status_lib" ] && ! type agent_is_busy_check &>/dev/null; then
    source "$_agent_status_lib"
fi

# Same rationale for lib/agent_registry.sh (fleet_all_ashigaru_idle_tri用, cmd_158):
# make agent_registry_* functions available in test mode too.
_agent_registry_lib="${SCRIPT_DIR}/lib/agent_registry.sh"
if [ -f "$_agent_registry_lib" ] && ! type agent_registry_default_agents &>/dev/null; then
    source "$_agent_registry_lib"
fi
