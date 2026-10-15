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
#   ただし (cmd_231/殿命S-19) 画面が働き中と見える足軽には、未読の古さを問わず /clear を
#   送らない(stale busy recoveryは撤去)。働き中が長く続くときは /clear せず殿へntfyで知らせる
#   (busy_guard。目安は config/settings.yaml の busy_guard: ブロック)。
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
    CLI_TYPE="${3:-claude}"  # CLI種別（claude/codex/copilot/kimi/opencode/antigravity）。未指定→claude（後方互換）
    case "$CLI_TYPE" in
        gemini|agy) CLI_TYPE="antigravity" ;;
    esac

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

# ─── Busy guard config (cmd_231 / 殿命 S-19) ───
# 働き中と見える足軽へ /clear を送らぬ。働き中が長く続くときは /clear せず殿へ ntfy で知らせる。
# config/settings.yaml `busy_guard:` ブロック(無ければ下記の既定=将軍案)。env でも上書き可。
#   unread_notify_minutes     働き中のまま未読が残る分数 → 知らせ(既定30)
#   continuous_notify_minutes 未読の有無を問わず働き中が連続する分数 → 知らせ(既定60)
#   repeat_notify_minutes     知らせた後、続く間の再通知間隔(既定60)
# 試験用の口(本番では使わぬ):
#   INBOX_WATCHER_TEST_NOW    process_unread / busy_guard_tick の「いま」(epoch秒)を注入する
#   BUSYGUARD_NOTIFY_CMD      ntfy の送り先を写しに替える実行ファイル(引数1=本文)。空なら scripts/ntfy.sh
#   BUSYGUARD_STATE_DIR       足軽ごとの状態ファイルの置場(既定: <repo>/logs/watcher_busy。logs/ は追跡外)
_read_busy_guard_setting() {
    local key="$1" default="$2"
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/config/settings.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('busy_guard') or {}).get('$key')
    if v is None:
        v = '$default'
    if isinstance(v, bool):
        v = str(v).lower()
    print(v)
except Exception:
    print('$default')
" 2>/dev/null
}
# 正の整数でなければ既定へ戻す(設定の誤記で知らせが暴走・沈黙せぬように)
_bg_posint() {
    case "${1:-}" in
        ''|*[!0-9]*) echo "$2" ;;
        *) if [ "$1" -gt 0 ]; then echo "$1"; else echo "$2"; fi ;;
    esac
}
BUSYGUARD_UNREAD_MIN=$(_bg_posint "${BUSYGUARD_UNREAD_MIN:-$(_read_busy_guard_setting unread_notify_minutes 30)}" 30)
BUSYGUARD_CONTINUOUS_MIN=$(_bg_posint "${BUSYGUARD_CONTINUOUS_MIN:-$(_read_busy_guard_setting continuous_notify_minutes 60)}" 60)
BUSYGUARD_REPEAT_MIN=$(_bg_posint "${BUSYGUARD_REPEAT_MIN:-$(_read_busy_guard_setting repeat_notify_minutes 60)}" 60)
# 観測がこれ以上途切れたら(見張り役の停止等)、働き中の連続は数え直す
BUSYGUARD_RESUME_GAP_SEC=${BUSYGUARD_RESUME_GAP_SEC:-300}
# ntfy が失敗したときの再試行間隔(毎tick叩かぬ)
BUSYGUARD_RETRY_SEC=${BUSYGUARD_RETRY_SEC:-300}
BUSYGUARD_STATE_DIR=${BUSYGUARD_STATE_DIR:-${SCRIPT_DIR}/logs/watcher_busy}
BUSYGUARD_NOTIFY_CMD=${BUSYGUARD_NOTIFY_CMD:-}

# ─── Key gate config (cmd_231 工程B / 殿命 S-19 追補 00:20) ───
# 見張り役がキー(起こしの文字・Enter・Escape・C-u・/clear・起動の口上 ほか全て)を送ってよいのは、
# 送る直前に画面(pane の capture)を見て『待機中のプロンプト』と言い切れるときのみ(wk_screen_class)。
#   confirm_screen_regex            確認画面の検出文言(ERE・大小無視)。Claude Code の画面文言が変わったら
#                                   config/settings.yaml の busy_guard.confirm_screen_regex で差し替える。
#                                   ※ 実機未確認: 既定値は模擬画面(偽ペイン)で確かめたもの。実 Claude Code の確認画面の文言は未確認。
#   confirm_repeat_notify_minutes   同じ確認画面が続く間の再通知間隔(既定30分)。確認画面と判じたときは待たず即時に1回知らせる。
# 画面の窓: WK_PROMPT_WINDOW 行(空行除く)の中の最後の入力欄を『入力欄』とみなす。
_BUSYGUARD_CONFIRM_RE_DEFAULT='Esc to cancel|Do you want to |\(y/n\)|\[Y/n\]|\[y/N\]|[0-9]+\.[[:space:]]+(Yes|No)([[:space:]]|,|$)|Press Enter to|Enter to confirm'
_read_busy_guard_regex() {
    # 文字列値をそのまま(YAMLのパース結果として)出す。空・誤記・読めぬときは何も出さない(呼び側で既定へ)。
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${SCRIPT_DIR}/config/settings.yaml', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('busy_guard') or {}).get('confirm_screen_regex')
    if isinstance(v, str) and v.strip():
        print(v.strip())
except Exception:
    pass
" 2>/dev/null
}
BUSYGUARD_CONFIRM_RE=${BUSYGUARD_CONFIRM_RE:-$(_read_busy_guard_regex)}
BUSYGUARD_CONFIRM_RE=${BUSYGUARD_CONFIRM_RE:-$_BUSYGUARD_CONFIRM_RE_DEFAULT}
# 誤記の ERE(grep が構文エラーを返す)は既定へ戻す: 検出が黙って無効になるのを防ぐ
if printf 'x\n' | grep -qiE -- "$BUSYGUARD_CONFIRM_RE" 2>/dev/null; [ $? -eq 2 ]; then
    BUSYGUARD_CONFIRM_RE=$_BUSYGUARD_CONFIRM_RE_DEFAULT
fi
BUSYGUARD_CONFIRM_REPEAT_MIN=$(_bg_posint "${BUSYGUARD_CONFIRM_REPEAT_MIN:-$(_read_busy_guard_setting confirm_repeat_notify_minutes 30)}" 30)
WK_PROMPT_WINDOW=${WK_PROMPT_WINDOW:-7}      # 入力欄を探す範囲(末尾から数えた空行を除く行数)
WK_PENDING_WINDOW=${WK_PENDING_WINDOW:-10}   # 文字を打ちかけの入力欄(折り返しで下へ伸びる)を探す範囲
WK_ABOVE_LINES=${WK_ABOVE_LINES:-4}          # 入力欄の上で作業中の目印を探す行数
WK_BELOW_MAX=${WK_BELOW_MAX:-4}              # 入力欄の下に許す行数(罫線・状態行)
WK_STARTUP_WAIT_TRIES=${WK_STARTUP_WAIT_TRIES:-6}   # /clear 後に待機のプロンプトを待つ回数(5秒ごと)

_now_epoch() { echo "${INBOX_WATCHER_TEST_NOW:-$(date +%s)}"; }

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
        claude|codex|copilot|kimi|opencode|antigravity|gemini|agy) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_watcher_cli_type() {
    case "${1:-}" in
        gemini|agy) echo "antigravity" ;;
        *) echo "${1:-}" ;;
    esac
}

get_effective_cli_type() {
    local pane_cli_raw=""
    local pane_cli=""

    pane_cli_raw=$(timeout 2 tmux show-options -p -t "$PANE_TARGET" -v @agent_cli 2>/dev/null || true)
    pane_cli=$(echo "$pane_cli_raw" | tr -d '\r' | head -n1 | tr -d '[:space:]')

    if is_valid_cli_type "$pane_cli"; then
        pane_cli=$(normalize_watcher_cli_type "$pane_cli")
        local arg_cli
        arg_cli=$(normalize_watcher_cli_type "${CLI_TYPE:-}")
        if is_valid_cli_type "${CLI_TYPE:-}" && [ "$pane_cli" != "$arg_cli" ]; then
            echo "[$(date)] [WARN] CLI drift detected for $AGENT_ID: arg=${CLI_TYPE}, pane=${pane_cli}. Using pane value." >&2
        fi
        echo "$pane_cli"
        return 0
    fi

    if is_valid_cli_type "${CLI_TYPE:-}"; then
        if [ -n "$pane_cli" ]; then
            echo "[$(date)] [WARN] Invalid pane @agent_cli for $AGENT_ID: '${pane_cli}'. Falling back to arg=${CLI_TYPE}." >&2
        fi
        normalize_watcher_cli_type "${CLI_TYPE}"
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

# ─── Key gate (cmd_231 工程B / 殿命 S-19 追補 00:20) ───────────────────────────────────────
# 見張り役がキー(起こしの文字・Enter・Escape・C-u・C-c・/clear・起動の口上 ほか全て)を送ってよいのは、
# 『送る直前に画面を見て、待機中のプロンプトと言い切れるとき』だけ。許すものだけを数える形で、
# 確認画面を見分けて避ける形ではない。待機の目印ファイル(idle flag)は参考にとどめ、根拠にしない。
# 送信口は全て wk_send_keys を通る(この関数群の外に tmux send-keys を書かぬこと。T-KG-S1 が数える)。

# wk_screen_class [empty|pending] — 画面の分類。待機と言い切れる条件はここ1箇所に集約する。
#   idle         待機中のプロンプト。次を全て満たす:
#                 ①画面を取れた  ②末尾 WK_PROMPT_WINDOW 行(空行除く)に入力欄(❯ / › / 枠内の >)がある
#                 ③入力欄の上 WK_ABOVE_LINES 行と下の全行に、作業中の目印(WK_WORKING_RE)も確認画面の文言
#                  (BUSYGUARD_CONFIRM_RE)も無く、最終行が『esc to interrupt』等の作業中の状態行でない
#                 ④入力欄の下が WK_BELOW_MAX 行以内(罫線・状態行だけ)
#                 ⑤mode=empty: 入力欄が空、または自分が打った nudge の打ち残し(inboxN)のみ
#                  mode=pending: 自分が打った列の途中(入力欄に文字があってよい。下へ折り返す分だけ窓を広げる)
#   confirm      確認画面(許可待ち・Dangerous 確認 ほか): BUSYGUARD_CONFIRM_RE に合い、最終行が作業中の状態行でない
#   working      作業中の目印(WK_WORKING_RE / 最終行の状態行)
#   undetermined 画面は取れたが待機と言い切れぬ(空画面・入力欄が無い・入力欄に見慣れぬ文字・余計な行・見慣れぬ状態)
# 薄字の例外(S-23/S-24): 待機中の Claude Code は入力欄に薄字(SGR 2)の提案文『Try "…"』等を出す。画面は -e つきで取り、
#   入力欄の文字が『見える字の全てが薄字(SGR 2・属性が読める)』と証明できるときに限り、その提案文を空と見なす。
#   通常の字が1字でも混じる・属性が読めぬ(コロン区切りの SGR・未知の制御列)・薄字の字が無い は従来どおり undetermined=送らぬ。
#   確認画面・作業中の判定は薄字の判定より先に行う(提案文があっても確認画面・作業中は送らぬ)。
#   failed       画面を取れなかった(pane不在・capture失敗・timeout)
# idle 以外は全て『送らない』。判別不能・取得失敗は送らない側に倒れる。
# wk_strip_ansi — 標準入力の制御列(SGR ほかの CSI・OSC)を落とし、NBSP を空白にして出す(行数は変えぬ)
wk_strip_ansi() {
    LC_ALL=C sed -E $'s/\x1b\\[[0-9;:?<=>]*[ -/]*[@-~]//g; s/\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)//g; s/\xc2\xa0/ /g'
}

# wk_prompt_is_dim_placeholder <入力欄の行(属性つきの生)> — 0=入力欄の見える字が全て薄字(SGR 2)と証明できた。
# 先頭の入力欄の印(❯ ›)までは読み飛ばし、以降の字を1字ずつ見る。薄字でない字が1字でもある・見える字が無い・
# 読めぬ属性(コロン区切りの SGR)や未知の制御列がある、のいずれかなら 1(=証明できぬ=従来どおり送らぬ)。
wk_prompt_is_dim_placeholder() {
    local s="$1" nb=$'\xc2\xa0'
    s="${s//$nb/ }"
    local glyph_re='(❯|›)'
    if [[ "$s" =~ $glyph_re ]]; then
        s="${s#*"${BASH_REMATCH[1]}"}"
    else
        return 1
    fi
    local dim=0 saw=0 i=0 k n=${#s} ch rest params
    local -a P
    local sgr_re=$'^\x1b\\[([0-9;:]*)m' csi_re=$'^\x1b\\[[0-9;:?]*[ -/]*[@-~]'
    while [ "$i" -lt "$n" ]; do
        ch="${s:i:1}"
        if [ "$ch" = $'\x1b' ]; then
            rest="${s:i}"
            if [[ "$rest" =~ $sgr_re ]]; then
                params="${BASH_REMATCH[1]}"
                i=$((i + ${#BASH_REMATCH[0]}))
                if [[ "$params" == *:* ]]; then return 1; fi
                IFS=';' read -ra P <<< "$params"
                if [ "${#P[@]}" -eq 0 ]; then dim=0; fi
                k=0
                while [ "$k" -lt "${#P[@]}" ]; do
                    case "${P[k]:-0}" in
                        0) dim=0 ;;
                        2) dim=1 ;;
                        22) dim=0 ;;
                        38|48|58)   # 色の指定。後ろの 5;n(2つ)・2;r;g;b(4つ)は色の引数ゆえ、薄字の 2 と取り違えぬ
                            if [ "${P[k+1]:-}" = "5" ]; then k=$((k + 2))
                            elif [ "${P[k+1]:-}" = "2" ]; then k=$((k + 4)); fi ;;
                    esac
                    k=$((k + 1))
                done
                continue
            elif [[ "$rest" =~ $csi_re ]]; then
                i=$((i + ${#BASH_REMATCH[0]}))
                continue
            fi
            return 1
        fi
        if [[ "$ch" != [[:space:]] ]]; then
            if [ "$dim" -ne 1 ]; then return 1; fi
            saw=1
        fi
        i=$((i + 1))
    done
    [ "$saw" -eq 1 ]
}

WK_PROMPT_RE='^([[:space:]]|│|\|)*(❯|›)(.*)$'
WK_PROMPT_BOX_RE='^[[:space:]]*│[[:space:]]*>(.*)$'
WK_BUSYBAR_RE='esc to interrupt|ctrl\+c to (stop|interrupt)'
WK_WORKING_RE='esc to |ctrl\+c to |…[[:space:]]*\(|\.\.\.[[:space:]]*\(|Compacting conversation|background terminal running'
_wk_classify() {
    local mode="${1:-empty}"
    WK_PLACEHOLDER=0
    WK_CLASS_RESULT=undetermined
    local cap rc=0
    # 1回の取得(-e つき)から、属性を落とした文字列と属性つきの生の行を同じ画面で得る(取得の間のずれを避ける)
    cap=$(timeout 2 tmux capture-pane -t "$PANE_TARGET" -p -e 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then WK_CLASS_RESULT=failed; return 0; fi

    local -a L=() RAWL=() RAWALL=() PLNALL=()
    local line i2 rawline
    mapfile -t RAWALL <<< "$cap"
    mapfile -t PLNALL < <(wk_strip_ansi <<< "$cap")
    for ((i2 = 0; i2 < ${#PLNALL[@]}; i2++)); do
        line="${PLNALL[i2]}"
        rawline="${RAWALL[i2]:-}"
        line="${line%"${line##*[![:space:]]}"}"
        if [ -n "$line" ]; then L+=("$line"); RAWL+=("$rawline"); fi
    done
    local n=${#L[@]}
    if [ "$n" -eq 0 ]; then WK_CLASS_RESULT=undetermined; return 0; fi

    local window="$WK_PROMPT_WINDOW" below_max="$WK_BELOW_MAX"
    if [ "$mode" = "pending" ]; then window="$WK_PENDING_WINDOW"; below_max=12; fi

    # 入力欄: 窓の中で最後にある行
    local pi=-1 i lo=$((n - window)) text=""
    if [ "$lo" -lt 0 ]; then lo=0; fi
    for ((i = n - 1; i >= lo; i--)); do
        if [[ "${L[i]}" =~ $WK_PROMPT_RE ]]; then text="${BASH_REMATCH[3]}"; pi=$i; break; fi
        if [[ "${L[i]}" =~ $WK_PROMPT_BOX_RE ]]; then text="${BASH_REMATCH[1]}"; pi=$i; break; fi
    done

    local last="${L[n-1]}" region="" start
    if [ "$pi" -lt 0 ]; then
        # 入力欄が見えぬ: 待機とは言えぬ。知らせ分けのため、末尾8行から確認画面/作業中/不明を見分ける
        start=$((n - 8)); if [ "$start" -lt 0 ]; then start=0; fi
        region=$(printf '%s\n' "${L[@]:$start}")
        if grep -qiE -- "$WK_BUSYBAR_RE" <<< "$last"; then WK_CLASS_RESULT=working; return 0; fi
        if grep -qiE -- "$BUSYGUARD_CONFIRM_RE" <<< "$region"; then WK_CLASS_RESULT=confirm; return 0; fi
        if grep -qiE -- "$WK_WORKING_RE" <<< "$region"; then WK_CLASS_RESULT=working; return 0; fi
        WK_CLASS_RESULT=undetermined; return 0
    fi

    # 入力欄の文字を整える(前後の空白・枠線を落とす)
    text="${text#"${text%%[![:space:]]*}"}"
    local t2
    while :; do
        t2="${text%[[:space:]]}"; t2="${t2%│}"; t2="${t2%|}"
        if [ "$t2" = "$text" ]; then break; fi
        text="$t2"
    done

    # 入力欄の上 WK_ABOVE_LINES 行 + 入力欄の文字 + 入力欄より下の全行
    start=$((pi - WK_ABOVE_LINES)); if [ "$start" -lt 0 ]; then start=0; fi
    if [ "$start" -lt "$pi" ]; then region=$(printf '%s\n' "${L[@]:$start:$((pi - start))}"); fi
    region+=$'\n'"$text"
    if [ "$((n - 1))" -gt "$pi" ]; then region+=$'\n'"$(printf '%s\n' "${L[@]:$((pi + 1))}")"; fi

    if grep -qiE -- "$WK_BUSYBAR_RE" <<< "$last"; then WK_CLASS_RESULT=working; return 0; fi
    if grep -qiE -- "$BUSYGUARD_CONFIRM_RE" <<< "$region"; then WK_CLASS_RESULT=confirm; return 0; fi
    if grep -qiE -- "$WK_WORKING_RE" <<< "$region"; then WK_CLASS_RESULT=working; return 0; fi
    if [ "$((n - 1 - pi))" -gt "$below_max" ]; then WK_CLASS_RESULT=undetermined; return 0; fi
    if [ "$mode" = "pending" ]; then WK_CLASS_RESULT=idle; return 0; fi
    if [ -z "$text" ] || [[ "$text" =~ ^inbox[0-9]+$ ]]; then WK_CLASS_RESULT=idle; return 0; fi
    # 薄字の例外: 入力欄の文字が全て薄字(SGR 2)と証明できるときだけ、提案文として空と見なす
    if wk_prompt_is_dim_placeholder "${RAWL[pi]}"; then WK_PLACEHOLDER=1; WK_CLASS_RESULT=idle; return 0; fi
    WK_CLASS_RESULT=undetermined
}

# 分類の結果は WK_CLASS_RESULT、薄字の例外で idle にしたかは WK_PLACEHOLDER(1/0)。サブシェルを介さず現在の shell に残す。
WK_CLASS_RESULT=""
WK_PLACEHOLDER=0
# wk_screen_class [empty|pending] — 分類を標準出力へ(試験・知らせ用)
wk_screen_class() { _wk_classify "$@"; echo "$WK_CLASS_RESULT"; }

# wk_pane_ready [empty|pending] — idle と言い切れるときだけ 0。結果の分類を WK_LAST_CLASS に残す。
WK_LAST_CLASS=""
WK_SEQ_OPEN=0       # 1=この列で既に1キー送った(以降は pending で判定する)
WK_REFUSED=0        # 直近の列で見送りがあったか
WK_PORT=""          # 送信口の名前(ログ用)
wk_pane_ready() {
    _wk_classify "${1:-empty}"
    WK_LAST_CLASS="$WK_CLASS_RESULT"
    [ "$WK_LAST_CLASS" = "idle" ]
}

# wk_begin_seq <送信口> — キー列の頭。以降の wk_send_keys の最初の1キーは mode=empty で判定する。
wk_begin_seq() { WK_PORT="${1:-?}"; WK_SEQ_OPEN=0; WK_REFUSED=0; }

# wk_log_withheld — 見送りの記録(秘匿値なし。待機の目印は参考として併記)
wk_log_withheld() {
    local flag=absent
    if [ -f "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" ]; then flag=present; fi
    echo "[$(date)] [KEY-WITHHELD] agent=$AGENT_ID port=${WK_PORT:-?} screen=${WK_LAST_CLASS:-?} seq=${1:-empty} idle_flag=${flag}(参考のみ) — 待機中のプロンプトと言い切れぬためキーを送らない" >&2
}

# wk_send_keys <tmux send-keys の引数...> — 全ての送信口の唯一の出口。
# 送る直前に画面を見て、idle と言い切れなければ送らず 1 を返す(WK_REFUSED=1)。送れたら tmux の戻り値。
WK_CALL_REFUSED=0   # 直近の1回の呼び出しが見送られたか
wk_send_keys() {
    local mode=empty
    WK_CALL_REFUSED=0
    if [ "${WK_SEQ_OPEN:-0}" = "1" ]; then mode=pending; fi
    if ! wk_pane_ready "$mode"; then
        WK_REFUSED=1; WK_CALL_REFUSED=1
        wk_log_withheld "$mode"
        return 1
    fi
    WK_SEQ_OPEN=1
    timeout 5 tmux send-keys -t "$PANE_TARGET" "$@" 2>/dev/null
}

# wk_send_soft <tmux send-keys の引数...> — 従来の『tmux が失敗しても続ける(|| true)』キーの送り方。
# 見送り(待機と言い切れぬ)のときだけ 1 を返す。tmux 自体の失敗は従来どおり無視する(戻り値 0)。
wk_send_soft() {
    wk_send_keys "$@" || true
    if [ "${WK_CALL_REFUSED:-0}" = "1" ]; then return 1; fi
    return 0
}

# wk_gate <送信口> — 列を始める前の事前確認(副作用の前に見送れるように)。0=送ってよい
wk_gate() {
    wk_begin_seq "$1"
    if wk_pane_ready empty; then
        if [ "$WK_PLACEHOLDER" = "1" ]; then
            echo "[$(date)] [KEY-GATE] agent=$AGENT_ID port=$1 screen=idle placeholder=dim — 入力欄は薄字の提案文のみ(全字が SGR 2)ゆえ空と見なして送る" >&2
        fi
        return 0
    fi
    WK_REFUSED=1
    wk_log_withheld empty
    return 1
}

# ─── Send CLI command via pty direct write ───
# For /clear and /model only. These are CLI commands, not conversation messages.
# CLI_TYPE別分岐: claude→そのまま, codex→/clear対応・/modelスキップ,
#                  copilot→Ctrl-C+再起動・/modelスキップ, opencode→/clear→/new・/modelスキップ,
#                  antigravity→/clearそのまま・/modelスキップ
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
        return 1
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

    # cmd_231 工程B / 殿命 S-19 追補: /clear に限らず全ての CLI コマンド(/new・/model・再起動の口上 ほか)は、
    # 画面が『待機中のプロンプト』と言い切れるときだけ送る。見送りは return 1(呼び側は送った扱いにしない)。
    if ! wk_gate "cli-command:${cmd%% *}"; then
        echo "[$(date)] [KEY-WITHHELD] $cmd deferred to next cycle (agent=$AGENT_ID)" >&2
        return 1
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
                wk_send_soft "x" || return 1
                sleep 0.3
                wk_send_soft C-u || return 1
                sleep 0.3
                wk_send_soft "/new" || return 1
                sleep 0.3
                wk_send_soft Enter || return 1
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
                wk_send_soft C-u || return 1
                sleep 0.3
                wk_send_soft "/new" || return 1
                sleep 0.3
                wk_send_soft Enter || return 1
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
                wk_send_soft C-c || return 1
                sleep 2
                wk_send_soft "copilot --yolo" || return 1
                sleep 0.3
                wk_send_soft Enter || return 1
                sleep 3
                return 0
            fi
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (not supported on copilot)" >&2
                return 0
            fi
            ;;
        cursor)
            # Cursor: /clear不存在→/new-chatで新規会話開始, /modelは対応
            if [[ "$cmd" == "/clear" ]]; then
                if [ "${NEW_CONTEXT_SENT:-0}" -eq 1 ]; then
                    echo "[$(date)] [SKIP] Cursor /new-chat already sent for $AGENT_ID — skipping duplicate clear_command" >&2
                    return 0
                fi
                echo "[$(date)] [SEND-KEYS] Cursor /clear→/new-chat: starting new conversation for $AGENT_ID" >&2
                wk_send_soft "/new-chat" || return 1
                sleep 0.3
                wk_send_soft Enter || return 1
                sleep 3
                NEW_CONTEXT_SENT=1
                return 0
            fi
            ;;
        antigravity)
            if [[ "$cmd" == /model* ]]; then
                echo "[$(date)] Skipping $cmd (Antigravity model changes are restart-only)" >&2
                return 0
            fi
            ;;
        # claude: commands pass through as-is
    esac

    echo "[$(date)] [SEND-KEYS] Sending CLI command to $AGENT_ID ($effective_cli): $actual_cmd" >&2
    # Clear stale input first, then send command (text and Enter separated for Codex TUI)
    # Codex CLI: C-c when idle causes CLI to exit — skip it
    if [[ "$effective_cli" != "codex" ]]; then
        wk_send_soft C-c || return 1
        sleep 0.5
    fi
    wk_send_soft "$actual_cmd" || return 1
    # /clear needs longer gap before Enter — CLI prompt may not be ready at 0.3s
    if [[ "$actual_cmd" == "/clear" || "$actual_cmd" == "/new" ]]; then
        sleep 1.0
    else
        sleep 0.3
    fi
    wk_send_soft Enter || return 1

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
    # cmd_231 工程B / 殿命 S-19 追補: 『待機中のプロンプト』と言い切れるまで待つ。最後まで言い切れなければ
    # 送らない(旧: 15秒待って "proceeding anyway" で送っていた)。送らなかった分は、次の周期の nudge(同じ関門)が起こす。
    local attempt ready=0
    for attempt in $(seq 1 "$WK_STARTUP_WAIT_TRIES"); do
        sleep 5
        if wk_pane_ready empty; then
            echo "[$(date)] [STARTUP] $AGENT_ID at idle prompt after ${attempt}×5s — sending startup prompt" >&2
            ready=1
            break
        fi
        echo "[$(date)] [STARTUP] $AGENT_ID not at idle prompt (screen=${WK_LAST_CLASS}) after ${attempt}×5s — waiting" >&2
    done
    if [ "$ready" -ne 1 ]; then
        WK_PORT="startup-prompt"; WK_REFUSED=1
        wk_log_withheld empty
        echo "[$(date)] [STARTUP] $AGENT_ID: startup prompt withheld (no idle prompt within $((WK_STARTUP_WAIT_TRIES * 5))s)" >&2
        return 0
    fi
    wk_begin_seq "startup-prompt"

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
        wk_send_soft "x" || return 0
        sleep 0.3
        wk_send_soft C-u || return 0
        sleep 0.3
    fi
    wk_send_soft -l "$startup_prompt" || return 0
    sleep 0.3
    wk_send_soft Enter || return 0
    STARTUP_PROMPT_SENT=1
}

# ─── Send context reset before new task ───
# Called when task_assigned is detected in unread messages.
# Sends the appropriate "new conversation" command per CLI type to clear
# stale context from the previous task.
# CLI mapping: claude→/clear, codex→/new, opencode→/new, cursor→/new-chat, copilot→/clear, kimi→/clear
# CLI mapping: claude→/clear, codex→/new, opencode→/new, copilot→/clear, kimi→/clear, antigravity→/clear

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

    # cmd_231 / 殿命S-19: 働き中と見える足軽には /clear・/new を送らぬ(観測不能もbusy側=従来の向き)。
    # 見送った場合は return 1 — 呼び出し側は NEW_CONTEXT_SENT を立てず、idleになってから送り直す。
    if agent_is_busy_for_clear; then
        echo "[$(date)] [BUSY-GUARD] $AGENT_ID: context reset withheld (agent working or not observable)" >&2
        return 1
    fi
    # cmd_231 工程B: 待機中のプロンプトと言い切れぬ画面(確認画面・判別不能 ほか)には /clear・/new も送らない
    if ! wk_gate "context-reset"; then return 1; fi

    local reset_cmd
    case "$effective_cli" in
        codex)    reset_cmd="/new" ;;
        opencode) reset_cmd="/new" ;;
        cursor)   reset_cmd="/new-chat" ;;
        claude)   reset_cmd="/clear" ;;
        copilot)  reset_cmd="/clear" ;;
        kimi)     reset_cmd="/clear" ;;
        antigravity) reset_cmd="/clear" ;;
        *)        reset_cmd="/new" ;;  # safe default (codex-safe)
    esac

    echo "[$(date)] [CONTEXT-RESET] Sending $reset_cmd before task_assigned for $AGENT_ID ($effective_cli)" >&2

    # Codex/OpenCode/Cursor: send new-context command as a single atomic operation.
    # When called from clear_command path, NEW_CONTEXT_SENT=1 prevents reaching here.
    # When called for standalone task_assigned, this is the only send.
    if [[ "$effective_cli" == "codex" || "$effective_cli" == "opencode" || "$effective_cli" == "cursor" ]]; then
        # Dismiss suggestion UI (Codex only) + send reset command
        if [[ "$effective_cli" == "codex" ]]; then
            wk_send_soft "x" || return 1
            sleep 0.3
        fi
        if [[ "$effective_cli" != "cursor" ]]; then
            wk_send_soft C-u || return 1
            sleep 0.3
        fi
        wk_send_soft "$reset_cmd" || return 1
        sleep 0.3
        wk_send_soft Enter || return 1
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
    wk_send_soft "$reset_cmd" || return 1
    # Longer gap for /clear — CLI prompt rendering needs time
    sleep 1.0
    wk_send_soft Enter || return 1
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
    [ "$rc" -ne 1 ] && return 0
    # cmd_231 / 殿命S-19: idle判定が idleフラグ由来だと、画面が働き中でも idle と読まれ得る
    # (watcher自身が未読0のtickごとにフラグを置き直し、PreToolUseが消すまで残るため)。
    # /clear系の破壊的動作では、フラグがidleでも画面が働き中なら busy とする(陽性の働き中証拠を優先)。
    # 画面が idle / 観測不能のときは従来どおり(フラグのidleを尊重)。
    local effective_cli pane_rc=0
    effective_cli=$(get_effective_cli_type)
    agent_is_busy_check "$PANE_TARGET" "$effective_cli" || pane_rc=$?
    if [ "$pane_rc" -eq 0 ]; then
        echo "[$(date)] [BUSY-GUARD] agent=$AGENT_ID idle verdict overridden: pane shows working — busy for /clear" >&2
        return 0
    fi
    return 1
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

    # cmd_231 工程B / 殿命 S-19 追補: 起こし(nudge)も、画面が『待機中のプロンプト』と言い切れるときだけ送る。
    # 旧: idle flag(または未観測)だけを根拠に送り、確認画面・作業中の足軽にも inboxN+Enter が入った(今宵 20件)。
    # 見送ったら throttle も記帳しない(待機に戻った最初の周期で送る)。長く言い切れぬときは busy_guard_tick が殿へ知らせる。
    if ! wk_gate "nudge"; then
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
    if [[ "$effective_cli_for_nudge" == "opencode" ]] || [[ "$effective_cli_for_nudge" == "gemini" ]] || [[ "$effective_cli_for_nudge" == "antigravity" ]]; then
        nudge="queue/inbox/${AGENT_ID}.yaml と queue/tasks/${AGENT_ID}.yaml を Read してタスクを実行せよ。完了後 scripts/inbox_write.sh で軍師に報告すること。"
    fi

    # 非Claudeエージェント（gemini/opencode）は inbox を自律的に read:true にできない
    # inbox_watcher 側で自動既読にすることで重複 nudge を防ぐ
    if [[ "$effective_cli_for_nudge" == "gemini" ]] || [[ "$effective_cli_for_nudge" == "antigravity" ]] || [[ "$effective_cli_for_nudge" == "opencode" ]]; then
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
        wk_send_soft "x" || return 0
        sleep 0.3
        wk_send_soft C-u || return 0
        sleep 0.3
    fi

    # 行クリア（残存テキスト除去）→ nudge送信 → Enter → 確認 → 最大2回リトライ
    local max_retries=2
    local attempt=0
    while [ $attempt -le $max_retries ]; do
        # C-u で行をクリア(見送ったら以降のキーも送らず終える)
        wk_send_soft C-u || return 0
        sleep 0.3
        # nudge 送信
        if ! wk_send_keys "$nudge"; then
            if [ "$WK_REFUSED" -eq 1 ]; then return 0; fi
            echo "[$(date)] WARNING: send-keys nudge failed for $AGENT_ID (attempt $((attempt+1)))" >&2
            attempt=$((attempt+1))
            continue
        fi
        sleep 0.3
        wk_send_soft Enter || return 0
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
            wk_send_soft C-u || return 0
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
    if [[ "$effective_cli" == "opencode" || "$effective_cli" == "antigravity" ]]; then
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

    # cmd_231 工程B: Escape も『待機中のプロンプト』と言い切れる画面にだけ送る
    if ! wk_gate "escape-nudge"; then return 0; fi

    echo "[$(date)] [SEND-KEYS] ESCALATION Phase 2: Escape×2 + nudge for $AGENT_ID (cli=$effective_cli)" >&2
    # Escape×2 to exit any mode
    wk_send_soft Escape Escape || return 0
    sleep 0.5
    if [[ "$effective_cli" == "copilot" || "$effective_cli" == "kimi" ]]; then
        wk_send_soft C-c || return 0
        sleep 0.5
    fi
    if wk_send_keys "$nudge"; then
        sleep 0.3
        wk_send_soft Enter || return 0
        echo "[$(date)] Escape+nudge sent to $AGENT_ID (${unread_count} unread, cli=$effective_cli)" >&2
        return 0
    fi
    if [ "$WK_REFUSED" -eq 1 ]; then return 0; fi

    echo "[$(date)] WARNING: send-keys failed for Escape+nudge ($AGENT_ID)" >&2
    return 0  # Never return 1 — set -euo pipefail would kill the watcher daemon
}

# ─── Busy guard: 待機と言い切れぬ状態が長く続くときの知らせ (cmd_231 / 殿命 S-19・追補 00:20) ───
# キー(/clear・nudge ほか)は送らず、殿へ ntfy で知らせる。足軽ごとの状態ファイル(<BUSYGUARD_STATE_DIR>/<agent>.state,
# key=value)に「待機と言い切れぬ画面が連続して観測された開始時刻」を持つ。idle が1度観測されたら止まる。
#   busy_since        待機と言い切れぬ画面(作業中・確認画面・判別不能)が観測され続けている開始時刻
#   unread_since      その間に未読が残り続けている開始時刻
#   last_seen         最後に観測した時刻(途切れたら数え直す)
#   unread_notified / long_notified   各知らせを最後に出した時刻   *_attempt  最後に試みた時刻
#   confirm_since / confirm_sig / confirm_notified / confirm_attempt   確認画面(同じ画面の署名=末尾8行の cksum)
# 判定は wk_screen_class(画面のみ)。idleフラグは watcher が置き直すので『待機』の証拠に使えない。
# 画面を取れなかった(failed)ときは、連続を始めも止めもしない(保持)。
_bg_state_file() { echo "${BUSYGUARD_STATE_DIR}/${AGENT_ID}.state"; }

_bg_load() {
    BG_BUSY_SINCE=0; BG_UNREAD_SINCE=0; BG_LAST_SEEN=0
    BG_UNREAD_NOTIFIED=0; BG_LONG_NOTIFIED=0; BG_UNREAD_ATTEMPT=0; BG_LONG_ATTEMPT=0
    BG_CONFIRM_SINCE=0; BG_CONFIRM_SIG=0; BG_CONFIRM_NOTIFIED=0; BG_CONFIRM_ATTEMPT=0
    local f k v
    f=$(_bg_state_file)
    [ -f "$f" ] || return 0
    while IFS='=' read -r k v; do
        case "$v" in ''|*[!0-9]*) continue ;; esac
        case "$k" in
            busy_since) BG_BUSY_SINCE=$v ;;
            unread_since) BG_UNREAD_SINCE=$v ;;
            last_seen) BG_LAST_SEEN=$v ;;
            unread_notified) BG_UNREAD_NOTIFIED=$v ;;
            long_notified) BG_LONG_NOTIFIED=$v ;;
            unread_attempt) BG_UNREAD_ATTEMPT=$v ;;
            long_attempt) BG_LONG_ATTEMPT=$v ;;
            confirm_since) BG_CONFIRM_SINCE=$v ;;
            confirm_sig) BG_CONFIRM_SIG=$v ;;
            confirm_notified) BG_CONFIRM_NOTIFIED=$v ;;
            confirm_attempt) BG_CONFIRM_ATTEMPT=$v ;;
        esac
    done < "$f"
    return 0
}

_bg_save() {
    local f tmp
    f=$(_bg_state_file)
    mkdir -p "$BUSYGUARD_STATE_DIR" 2>/dev/null || return 0
    tmp="${f}.tmp.$$"
    {
        echo "busy_since=$BG_BUSY_SINCE"
        echo "unread_since=$BG_UNREAD_SINCE"
        echo "last_seen=$BG_LAST_SEEN"
        echo "unread_notified=$BG_UNREAD_NOTIFIED"
        echo "long_notified=$BG_LONG_NOTIFIED"
        echo "unread_attempt=$BG_UNREAD_ATTEMPT"
        echo "long_attempt=$BG_LONG_ATTEMPT"
        echo "confirm_since=$BG_CONFIRM_SINCE"
        echo "confirm_sig=$BG_CONFIRM_SIG"
        echo "confirm_notified=$BG_CONFIRM_NOTIFIED"
        echo "confirm_attempt=$BG_CONFIRM_ATTEMPT"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
}

_bg_reset_confirm() { BG_CONFIRM_SINCE=0; BG_CONFIRM_SIG=0; BG_CONFIRM_NOTIFIED=0; BG_CONFIRM_ATTEMPT=0; }

_bg_reset_run() {
    BG_BUSY_SINCE=0; BG_UNREAD_SINCE=0
    BG_UNREAD_NOTIFIED=0; BG_LONG_NOTIFIED=0; BG_UNREAD_ATTEMPT=0; BG_LONG_ATTEMPT=0
    _bg_reset_confirm
}

# 足軽の現在の task_id(取れなければ "不明")。秘匿値は載らぬ値のみ。
_bg_task_id() {
    local tf="${SCRIPT_DIR}/queue/tasks/${AGENT_ID}.yaml" t=""
    if [ -f "$tf" ]; then
        t=$(grep -m1 -E '^[[:space:]]*task_id:' "$tf" 2>/dev/null | sed -E 's/^[[:space:]]*task_id:[[:space:]]*//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//; s/[[:space:]]+#.*$//' || true)
    fi
    echo "${t:-不明}"
}

# _bg_notify <種別> <本文> — 0=送れた。送り先は BUSYGUARD_NOTIFY_CMD(試験の写し)、無ければ scripts/ntfy.sh。
# cmd_231 工程B(軍師指摘1): 戻り値(終了コード)を必ずログに残す。失敗は [NOTIFY-FAIL] で見えるようにし、黙って捨てぬ。
# ログに載せるのは 種別・足軽名・終了コード・失敗の分類のみ(本文・topic・認証・ntfy.sh の生のエラー文は載せない)。
# 失敗しても watcher は落とさぬ(戻り値で返すだけ)。再試行は呼び側が BUSYGUARD_RETRY_SEC 間隔で行う。
_bg_notify() {
    local kind="$1" msg="$2" rc=0 err="" reason="unclassified"
    # 標準出力は捨て、標準エラーだけを分類のために受ける(生の文言はログに載せない)
    if [ -n "$BUSYGUARD_NOTIFY_CMD" ]; then
        err=$({ timeout 20 "$BUSYGUARD_NOTIFY_CMD" "$msg" >/dev/null; } 2>&1) || rc=$?
    else
        err=$({ timeout 20 bash "${SCRIPT_DIR}/scripts/ntfy.sh" "$msg" >/dev/null; } 2>&1) || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        echo "[$(date)] [NOTIFY-OK] kind=$kind agent=$AGENT_ID rc=0" >&2
        return 0
    fi
    if [ "$rc" -eq 124 ]; then
        reason="timeout"
    else
        case "$err" in
            *"secrets.env not found"*) reason="secrets_file_missing" ;;
            *"NTFY_TOPIC is not set"*) reason="topic_unset" ;;
            *"curl exit"*) reason="curl_error" ;;
            *"HTTP status"*) reason="http_error" ;;
        esac
    fi
    echo "[$(date)] [NOTIFY-FAIL] kind=$kind agent=$AGENT_ID rc=$rc reason=$reason — 殿に届いていない。${BUSYGUARD_RETRY_SEC}秒後に再試行する" >&2
    return "$rc"
}

# _bg_screen_sig — 確認画面の署名(末尾8行の cksum・数字のみ)。同じ確認画面かどうかの判定用。
_bg_screen_sig() {
    local sig
    sig=$(timeout 2 tmux capture-pane -t "$PANE_TARGET" -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -8 | cksum | cut -d' ' -f1) || sig=""
    case "$sig" in ''|*[!0-9]*) sig=1 ;; esac
    echo "$sig"
}

# busy_guard_tick <未読件数(不明なら空)>
# 1サイクルに1回呼ぶ。画面を観測して状態ファイルを更新し、目安を超えていれば殿へ知らせる。
busy_guard_tick() {
    local unread="${1:-}"
    # shogun は殿の操作する pane。見張り役はここへ手を出さぬ(従来どおり)。
    [ "$AGENT_ID" = "shogun" ] && return 0

    local now cls
    now=$(_now_epoch)
    cls=$(wk_screen_class empty)

    _bg_load
    # 観測が長く途切れていた(見張り役が止まっていた等)なら、古い連続は信用せず数え直す
    if [ "$BG_LAST_SEEN" -gt 0 ] && [ "$((now - BG_LAST_SEEN))" -gt "$BUSYGUARD_RESUME_GAP_SEC" ]; then
        _bg_reset_run
    fi

    case "$cls" in
        working|confirm|undetermined)  # 待機と言い切れぬ — 連続の対象
            [ "$BG_BUSY_SINCE" -eq 0 ] && BG_BUSY_SINCE=$now
            if [ "$unread" = "0" ]; then
                BG_UNREAD_SINCE=0; BG_UNREAD_NOTIFIED=0; BG_UNREAD_ATTEMPT=0
            elif [ -n "$unread" ] && [ "$BG_UNREAD_SINCE" -eq 0 ]; then
                BG_UNREAD_SINCE=$now
            fi
            ;;
        idle)  # 待機 — 連続はここで止まる
            _bg_reset_run
            ;;
        *)  : ;;  # failed — 保持
    esac
    BG_LAST_SEEN=$now

    local what="働き中の"
    case "$cls" in
        confirm) what="確認画面で止まった" ;;
        undetermined) what="待機と判じられぬ画面の" ;;
    esac

    if [ "$BG_BUSY_SINCE" -gt 0 ]; then
        local repeat_sec=$((BUSYGUARD_REPEAT_MIN * 60))
        local task_id msg mins busy_mins
        task_id=$(_bg_task_id)

        # ⓪ 確認画面: 待たずにすぐ1回。同じ画面が続く間は BUSYGUARD_CONFIRM_REPEAT_MIN 分ごとに1回(毎tick送らぬ)
        if [ "$cls" = "confirm" ]; then
            local sig
            sig=$(_bg_screen_sig)
            if [ "$BG_CONFIRM_SINCE" -eq 0 ] || [ "$BG_CONFIRM_SIG" != "$sig" ]; then
                # 初めて見た確認画面、または別の確認画面 → 数え直して即時に知らせる
                BG_CONFIRM_SINCE=$now; BG_CONFIRM_SIG=$sig; BG_CONFIRM_NOTIFIED=0; BG_CONFIRM_ATTEMPT=0
            fi
            if { [ "$BG_CONFIRM_NOTIFIED" -eq 0 ] || [ "$((now - BG_CONFIRM_NOTIFIED))" -ge "$((BUSYGUARD_CONFIRM_REPEAT_MIN * 60))" ]; } \
               && { [ "$BG_CONFIRM_ATTEMPT" -eq 0 ] || [ "$((now - BG_CONFIRM_ATTEMPT))" -ge "$BUSYGUARD_RETRY_SEC" ]; }; then
                mins=$(( (now - BG_CONFIRM_SINCE) / 60 ))
                msg="🛑 ${AGENT_ID}が確認画面で止まっている(task=${task_id}、継続${mins}分、未読${unread:-?}件)。キーは一切送っていない。人の手で答えが要る"
                echo "[$(date)] [BUSY-GUARD] notify(confirm) agent=$AGENT_ID confirm_for=${mins}m task=$task_id" >&2
                BG_CONFIRM_ATTEMPT=$now
                if _bg_notify confirm "$msg"; then BG_CONFIRM_NOTIFIED=$now; fi
            fi
        else
            _bg_reset_confirm
        fi

        # ① 待機と言い切れぬまま未読が残る
        if [ "$BG_UNREAD_SINCE" -gt 0 ] && [ "$((now - BG_UNREAD_SINCE))" -ge "$((BUSYGUARD_UNREAD_MIN * 60))" ] \
           && { [ "$BG_UNREAD_NOTIFIED" -eq 0 ] || [ "$((now - BG_UNREAD_NOTIFIED))" -ge "$repeat_sec" ]; } \
           && { [ "$BG_UNREAD_ATTEMPT" -eq 0 ] || [ "$((now - BG_UNREAD_ATTEMPT))" -ge "$BUSYGUARD_RETRY_SEC" ]; }; then
            mins=$(( (now - BG_UNREAD_SINCE) / 60 ))
            busy_mins=$(( (now - BG_BUSY_SINCE) / 60 ))
            msg="⏳ ${AGENT_ID}が${what}まま未読${unread:-?}件が${mins}分残っている(task=${task_id}、待機でない状態${busy_mins}分)。キーは送っていない"
            echo "[$(date)] [BUSY-GUARD] notify(unread) agent=$AGENT_ID screen=$cls unread_for=${mins}m busy_for=${busy_mins}m task=$task_id" >&2
            BG_UNREAD_ATTEMPT=$now
            if _bg_notify unread "$msg"; then BG_UNREAD_NOTIFIED=$now; fi
        fi

        # ② 未読の有無を問わず待機と言い切れぬ状態が連続(判別不能だけは未読が無ければ知らせぬ=無害な見慣れぬ画面で騒がぬ)
        if [ "$cls" != "undetermined" ] \
           && [ "$((now - BG_BUSY_SINCE))" -ge "$((BUSYGUARD_CONTINUOUS_MIN * 60))" ] \
           && { [ "$BG_LONG_NOTIFIED" -eq 0 ] || [ "$((now - BG_LONG_NOTIFIED))" -ge "$repeat_sec" ]; } \
           && { [ "$BG_LONG_ATTEMPT" -eq 0 ] || [ "$((now - BG_LONG_ATTEMPT))" -ge "$BUSYGUARD_RETRY_SEC" ]; }; then
            mins=$(( (now - BG_BUSY_SINCE) / 60 ))
            msg="⏳ ${AGENT_ID}が${what}まま${mins}分連続している(task=${task_id}、未読${unread:-?}件)。キーは送っていない"
            echo "[$(date)] [BUSY-GUARD] notify(continuous) agent=$AGENT_ID screen=$cls busy_for=${mins}m task=$task_id" >&2
            BG_LONG_ATTEMPT=$now
            if _bg_notify continuous "$msg"; then BG_LONG_NOTIFIED=$now; fi
        fi
    fi

    _bg_save
    return 0
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
        fi
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
        reset_nudge_throttle
        # cmd_231: 働き中の連続を数える(未読0の周期も観測する)
        busy_guard_tick 0 || true
        # Ensure idle flag exists (fast-path recovery)
        touch "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" 2>/dev/null || true
        if ! agent_is_busy; then
            # Shogun: only clear input when pane is not active (Lord is away)
            if [ "$AGENT_ID" = "shogun" ] && pane_is_active; then
                : # Lord may be typing — skip C-u
            else
                # cmd_231 工程B: 入力欄の打ち残し掃除の C-u も、待機中のプロンプトと言い切れるときだけ
                wk_begin_seq "clear-input"
                wk_send_soft C-u || true
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
                if send_cli_command "$cmd"; then
                    [ "$msg_type" = "clear_command" ] && clear_sent=1
                fi
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

    # cmd_231: 働き中の連続を観測し、目安を超えたら /clear せず殿へ知らせる(下の経路とは独立)
    busy_guard_tick "$normal_count" || true

    # Check if unread messages include task_assigned (for context reset)
    local has_task_assigned
    has_task_assigned=$(echo "$info" | "$SCRIPT_DIR/.venv/bin/python3" -c "import sys,json; print(1 if json.load(sys.stdin).get('has_task_assigned') else 0)" 2>/dev/null)

    if [ "$normal_count" -gt 0 ] 2>/dev/null; then
        local now
        now=$(_now_epoch)

        # When the agent is busy/thinking, do NOT escalate. Interrupting with Escape or /clear
        # can terminate the current thought. Also pause the escalation timer while busy so we
        # don't immediately jump to Phase 2/3 once it becomes idle.
        # Exception: shogun — ntfy must be delivered immediately.
        #
        # cmd_231 / 殿命S-19: 旧「stale busy recovery」(busyが5分続くと idle フラグを強制作成して
        # 下の nudge/escalation へ落とす)は撤去した。あれは『画面が働き中の足軽』を idle と見なし直し、
        # 続く Phase 3 で /clear を送って作業を壊した(2026-10-12 22:08・23:26 足軽1)。
        # 働き中のまま長く続くときは /clear せず、busy_guard_tick(上)が殿へ ntfy で知らせる。
        if agent_is_busy && [[ "$AGENT_ID" != "shogun" ]]; then
            local busy_cli
            busy_cli=$(get_effective_cli_type)
            # 段階の時計は働き中のあいだ止める(idleに戻った時点から数え直す)。
            FIRST_UNREAD_SEEN=$now
            if [[ "$busy_cli" == "claude" ]]; then
                # Claude Code: Stop hook will catch unread messages when the agent's
                # turn ends. No nudge needed at all — just log and skip completely.
                echo "[$(date)] $normal_count unread for $AGENT_ID but agent is busy (claude) — Stop hook will deliver" >&2
            else
                # Codex/Copilot/Kimi/OpenCode: No Stop hook. Pause escalation timer while busy.
                echo "[$(date)] $normal_count unread for $AGENT_ID but agent is busy ($busy_cli) — pausing escalation timer" >&2
            fi
            return 0
        fi

        # ─── Context reset before new task ───
        # Send /new or /clear once when task_assigned is first detected,
        # to clear stale context from the previous task.
        # Skip if: (1) already sent this batch, (2) clear_command already handled above,
        #          (3) agent is shogun (human-controlled).
        if [ "$has_task_assigned" = "1" ] && [ "$NEW_CONTEXT_SENT" -eq 0 ] && [ "$clear_seen" -eq 0 ]; then
            # cmd_231: 働き中と見えるあいだは見送る(NEW_CONTEXT_SENT を立てず、idleになってから送る)
            if send_context_reset; then
                NEW_CONTEXT_SENT=1
                LAST_ASSIGNMENT_TS=$(date +%s)
            fi
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
                    # cmd_231 / 殿命S-19: 働き中と見えるなら /clear しない。何も記帳せず(時計も cooldown も
                    # 動かさず)次の周期で見直す。長く続けば busy_guard_tick が殿へ知らせる。
                    if agent_is_busy_for_clear; then
                        echo "[$(date)] [BUSY-GUARD] ESCALATION Phase 3 withheld for $AGENT_ID (${age}s): agent working — no /clear" >&2
                        return 0
                    fi
                    echo "[$(date)] ESCALATION Phase 3: Agent $AGENT_ID unresponsive for ${age}s. Sending /clear." >&2
                    # cmd_231 工程B: 画面が待機中のプロンプトと言い切れず見送られた(return 1)ときは、送った扱いにしない
                    # (時計も cooldown も動かさず、次の周期で見直す。長く続けば busy_guard_tick が殿へ知らせる)。
                    if send_cli_command "/clear"; then
                        LAST_CLEAR_TS=$now
                        FIRST_UNREAD_SEEN=0  # Reset — will re-detect on next cycle
                        NEW_CONTEXT_SENT=0
                    fi
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
                wk_begin_seq "clear-input"
                wk_send_soft C-u || true
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
# (so they stay unit-testable via bats; only the main loop itself stays gated — see below)

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
