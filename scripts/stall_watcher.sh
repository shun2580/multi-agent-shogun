#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# stall_watcher.sh — pane出力静止検知・自動復旧watcher v1
# Usage: bash scripts/stall_watcher.sh
#
# cmd_140 (軍師設計 gunshi_design_140 準拠)。
#
# 既存3機構(deadman_watcher.sh/inbox_watcher.sh/stale busy recovery)は
# いずれも「タスクassign済み・未読ゼロ・pane出力静止」という組合せ条件を
# 扱わないため(gunshi_design_140 point1参照)、新規の独立プロセスとして
# 追加する。既存3機構のコードは一切変更しない。
#
# 検知対象: unreadが0件のagentのpane出力が stall_threshold_min 分間
# 変化しない場合、(1)nudge → (2)家老inbox注入 → (3)ntfy の3段カスケードで
# 自動復旧を試みる(karo自身は(2)を経由せず(1)→(3)の2段)。
#
# テスト容易性: BASH_SOURCEガードにより、source時は関数定義のみが読み込まれ、
# main()は実行されない(scripts/deadman_watcher.shと同パターン)。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${SCRIPT_DIR}/lib/agent_registry.sh"
source "${SCRIPT_DIR}/lib/inflight_tasks.sh"
source "${SCRIPT_DIR}/lib/agent_status.sh"

# ─── timeout command compatibility wrapper (deadman_watcher.shから移植) ───
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    timeout() { gtimeout "$@"; }
  else
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

# ─── Overridable paths (env override → bats fixtures point these at tmp dirs) ───
STALL_EVENTS_LOG="${STALL_EVENTS_LOG:-${SCRIPT_DIR}/logs/stall_events.jsonl}"
STALL_SETTINGS="${STALL_SETTINGS:-${SCRIPT_DIR}/config/settings.yaml}"
STALL_INBOX_DIR="${STALL_INBOX_DIR:-${SCRIPT_DIR}/queue/inbox}"
# Test-only override: fixes "now" (epoch seconds) for elapsed-time computation.
STALL_TEST_NOW="${STALL_TEST_NOW:-}"

# 論点3: LAST_HASH/LAST_CHANGE_TSはプロセスメモリの連想配列のみで保持する。
# 起動時(このスクリプトが最初にsourceされた時点)は必ず空であり、永続化しない。
declare -A LAST_HASH
declare -A LAST_CHANGE_TS

# ─── config/settings.yaml readers (deadman_watcher.shの既存慣習に倣う) ───
_read_stall_enabled() {
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${STALL_SETTINGS}', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('features') or {}).get('stall_detection_enabled')
    if v is None:
        v = False
    print(str(v).lower())
except Exception:
    print('false')
" 2>/dev/null
}

_read_stall_setting() {
    local key="$1" default="$2"
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${STALL_SETTINGS}', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('stall_detection') or {}).get('$key')
    if v is None:
        v = '$default'
    print(v)
except Exception:
    print('$default')
" 2>/dev/null
}

_stall_now_epoch() {
    if [ -n "${STALL_TEST_NOW:-}" ]; then
        printf '%s' "$STALL_TEST_NOW"
    else
        date +%s
    fi
}

_stall_now_iso() {
    if [ -n "${STALL_TEST_NOW:-}" ]; then
        date -d "@${STALL_TEST_NOW}" +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null \
            || date -r "${STALL_TEST_NOW}" +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null \
            || printf '%s' "$STALL_TEST_NOW"
    else
        date +%Y-%m-%dT%H:%M:%S%:z
    fi
}

pane_base() {
    if [ -n "${SHOGUN_PANE_BASE:-}" ]; then
        echo "$SHOGUN_PANE_BASE"
        return 0
    fi
    tmux show-options -gv pane-base-index 2>/dev/null || echo 0
}

# get_pane_output_hash <pane>
# 末尾の非空行(状態バー/経過秒数表示)を除外してからハッシュ化する。
# 除外しないとClaude Codeの「Working on task (${seconds}s • esc to
# interrupt)」のような経過秒数表示だけで毎tick必ずハッシュが変化し、
# 真のstallを検知できなくなる(false negative)。除外対象の特定は
# lib/agent_status.shの既存last_line抽出(非空行のtail -1)と同一発想。
get_pane_output_hash() {
    local pane="$1" capture body
    capture=$(timeout 2 tmux capture-pane -t "$pane" -p 2>/dev/null) || return 1
    body=$(printf '%s\n' "$capture" | sed -e '/./!d' | sed '$d' 2>/dev/null || printf '%s' "$capture")
    printf '%s' "$body" | sha256sum | cut -d' ' -f1
}

# unread_count_for_agent <agent>
# queue/inbox/{agent}.yamlの未読数を返す。read/parse失敗はfail-safe側
# (=unreadありとみなしスキップ)に倒す(cmd_126の教訓と同じ方向性:
# 失敗をunread=0と同一視しない)。
unread_count_for_agent() {
    local agent="$1"
    local inbox="${STALL_INBOX_DIR}/${agent}.yaml"
    AGENT_INBOX_PATH="$inbox" "$SCRIPT_DIR/.venv/bin/python3" -c "
import os
import yaml

path = os.environ.get('AGENT_INBOX_PATH', '')
try:
    with open(path, encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    messages = data.get('messages', []) or []
    print(sum(1 for m in messages if not m.get('read', False)))
except FileNotFoundError:
    print(0)
except Exception:
    print(1)
" 2>/dev/null
}

# nudge_count_for_task <task_id>
# 論点2: nudge回数はプロセスメモリに持たせず、STALL_EVENTS_LOGを都度
# 読み直してtask_id一致のnudge_sentエントリ数を数える(1セッション=
# 1task_idの生存期間全体が対象。episode境界では区切らない)。
nudge_count_for_task() {
    local task_id="$1"
    STALL_EVENTS_LOG="$STALL_EVENTS_LOG" TASK_ID="$task_id" "$SCRIPT_DIR/.venv/bin/python3" -c "
import json
import os

path = os.environ.get('STALL_EVENTS_LOG', '')
task_id = os.environ.get('TASK_ID', '')
count = 0
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
            if rec.get('event') == 'nudge_sent' and rec.get('task_id') == task_id:
                count += 1
except FileNotFoundError:
    pass
print(count)
" 2>/dev/null
}

# highest_stage_this_episode <task_id> <episode_start_epoch>
# 論点1のカスケード管理: episode_start_epoch(直近のoutput_changedまたは
# 初観測の時刻)以降に記録されたnudge_sent/escalated_to_karo/
# escalated_to_ntfyの中で最も進んだ段階を返す(0=未着手,1=nudge済,
# 2=karo済,3=ntfy済)。ログから都度算出し、プロセスメモリには持たせない。
highest_stage_this_episode() {
    local task_id="$1" episode_start_epoch="$2"
    STALL_EVENTS_LOG="$STALL_EVENTS_LOG" TASK_ID="$task_id" EPISODE_START="$episode_start_epoch" \
        "$SCRIPT_DIR/.venv/bin/python3" -c "
import datetime
import json
import os

path = os.environ.get('STALL_EVENTS_LOG', '')
task_id = os.environ.get('TASK_ID', '')
try:
    episode_start = float(os.environ.get('EPISODE_START', '0') or 0)
except Exception:
    episode_start = 0.0

stage_map = {'nudge_sent': 1, 'escalated_to_karo': 2, 'escalated_to_ntfy': 3}
best = 0
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
            if rec.get('task_id') != task_id:
                continue
            ev = rec.get('event')
            if ev not in stage_map:
                continue
            ts = rec.get('ts') or ''
            try:
                dt = datetime.datetime.fromisoformat(ts)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=datetime.timezone.utc)
                epoch = dt.timestamp()
            except Exception:
                continue
            if epoch < episode_start:
                continue
            best = max(best, stage_map[ev])
except FileNotFoundError:
    pass

print(best)
" 2>/dev/null
}

# log_stall_event <event> <agent> <task_id> <cmd_id> [elapsed_min] [nudge_count]
# ログスキーマ(gunshi_design_140 log_schema節)どおりに1行追記する。
# pane_target/stall_threshold_minは呼び出し元check_stall_tickのローカル
# 変数($pane/$threshold)をbashの動的スコープでそのまま参照する
# (擬似コードの呼び出しシグネチャを変えないための実装上の工夫。
# check_stall_tick側でthresholdをどの分岐でも同一ループ内で必ず最新化
# してから呼ぶことで、値の取り違えが起きないようにしてある)。
log_stall_event() {
    local event="$1" agent="$2" task_id="$3" cmd_id="$4" elapsed_min="${5:-}" nudge_count="${6:-}"
    mkdir -p "$(dirname "$STALL_EVENTS_LOG")" 2>/dev/null || true
    EVENT="$event" AGENT="$agent" TASK_ID="$task_id" CMD_ID="$cmd_id" \
        ELAPSED_MIN="$elapsed_min" NUDGE_COUNT="$nudge_count" \
        PANE_TARGET="${pane:-}" STALL_THRESHOLD_MIN="${threshold:-}" \
        TS="$(_stall_now_iso)" \
        "$SCRIPT_DIR/.venv/bin/python3" -c "
import json
import os


def none_if_empty(v):
    return v if v not in ('', None) else None


def int_or_none(v):
    try:
        return int(v)
    except Exception:
        return None


record = {
    'ts': none_if_empty(os.environ.get('TS')),
    'event': none_if_empty(os.environ.get('EVENT')),
    'agent': none_if_empty(os.environ.get('AGENT')),
    'task_id': none_if_empty(os.environ.get('TASK_ID')),
    'cmd_id': none_if_empty(os.environ.get('CMD_ID')),
    'pane_target': none_if_empty(os.environ.get('PANE_TARGET')),
    'elapsed_min': int_or_none(os.environ.get('ELAPSED_MIN')),
    'nudge_count_this_task': int_or_none(os.environ.get('NUDGE_COUNT')),
    'stall_threshold_min': int_or_none(os.environ.get('STALL_THRESHOLD_MIN')),
}
print(json.dumps(record, ensure_ascii=False))
" >> "$STALL_EVENTS_LOG" 2>/dev/null || true
}

# send_nudge_to_pane <pane> <agent>
# inbox_watcher.shのsend_wakeup()と同じ「テキストとEnterを分離送信」
# パターンを流用する新規の小関数(別プロセスの内部関数への依存を避け、
# 同一パターンをここに複製するに留める)。
send_nudge_to_pane() {
    local pane="$1" agent="$2"
    timeout 5 tmux send-keys -t "$pane" C-u 2>/dev/null || true
    sleep 0.3
    timeout 5 tmux send-keys -t "$pane" "stall_watcher: 応答なし、状況を確認されたし" 2>/dev/null || true
    sleep 0.3
    timeout 5 tmux send-keys -t "$pane" Enter 2>/dev/null || true
}

# inbox_write_karo <agent> <task_id> <elapsed_min>
# 既存のCommunication Protocolに完全準拠し、新規IPC経路を作らない。
inbox_write_karo() {
    local agent="$1" task_id="$2" elapsed_min="$3"
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo \
        "stall検知: ${agent}のtask_id=${task_id}が${elapsed_min}分間pane出力なし。確認されたし。" \
        task_assigned stall_watcher --task_id="$task_id" >/dev/null 2>&1 || true
}

# ntfy_fire <agent> <task_id> <elapsed_min> <reason>
ntfy_fire() {
    local agent="$1" task_id="$2" elapsed_min="$3" reason="$4"
    bash "$SCRIPT_DIR/scripts/ntfy.sh" \
        "🚨 stall: agent=${agent} task_id=${task_id} elapsed=${elapsed_min}min reason=${reason}" >/dev/null 2>&1 || true
}

# _inflight_to_tsv: get_in_flight_tasks_with_agentのJSON配列をTSVへ変換する。
_inflight_to_tsv() {
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import json
import sys

data = json.loads(sys.stdin.read() or '[]')
for t in data:
    print('\t'.join([t.get('agent') or '', t.get('task_id') or '', t.get('cmd_id') or '']))
"
}

# check_stall_tick: 1ティック分の判定・発火処理。
check_stall_tick() {
    local now; now=$(_stall_now_epoch)
    local pane_base_val; pane_base_val=$(pane_base)

    local agent task_id cmd_id
    while IFS=$'\t' read -r agent task_id cmd_id; do
        [ -z "$task_id" ] && continue
        # (対象外1) shogunは人間操作paneのため明示除外
        [ "$agent" = "shogun" ] && continue

        # (対象外2) unreadがあるagentはinbox_watcher側の担当のため対象外
        local unread
        unread=$(unread_count_for_agent "$agent")
        [ "${unread:-0}" -gt 0 ] 2>/dev/null && continue

        local pane
        pane=$(agent_registry_pane_for_agent "$agent" "$pane_base_val") || continue
        local hash
        hash=$(get_pane_output_hash "$pane") || continue
        local key="${agent}:${task_id}"
        local threshold
        threshold=$(_read_stall_setting stall_threshold_min 10)

        if [ "${LAST_HASH[$key]:-__unset__}" != "$hash" ]; then
            # 出力に変化あり(または今回が初観測) → 基準点を更新するのみ。
            # 論点3: 初回はここで判定終了。stall/nudgeは一切発火しない。
            if [ -n "${LAST_HASH[$key]:-}" ]; then
                log_stall_event output_changed "$agent" "$task_id" "$cmd_id"
            fi
            LAST_HASH[$key]="$hash"
            LAST_CHANGE_TS[$key]="$now"
            continue
        fi

        local elapsed_min=$(( (now - LAST_CHANGE_TS[$key]) / 60 ))
        [ "$elapsed_min" -lt "$threshold" ] && continue

        local stage
        stage=$(highest_stage_this_episode "$task_id" "${LAST_CHANGE_TS[$key]}")
        local nudge_limit
        nudge_limit=$(_read_stall_setting nudge_limit_per_task 3)
        local nudges_used
        nudges_used=$(nudge_count_for_task "$task_id")

        if [ "$nudges_used" -ge "$nudge_limit" ]; then
            # 上限到達 → 家老inbox注入を経由せず即ntfy
            if [ "$stage" -lt 3 ]; then
                ntfy_fire "$agent" "$task_id" "$elapsed_min" "budget_exhausted"
                log_stall_event escalated_to_ntfy "$agent" "$task_id" "$cmd_id" "$elapsed_min"
            fi
            continue
        fi

        local karo_wait ntfy_wait
        karo_wait=$(_read_stall_setting karo_escalation_wait_min 10)
        ntfy_wait=$(_read_stall_setting ntfy_escalation_wait_min 10)

        if [ "$stage" -lt 1 ]; then
            send_nudge_to_pane "$pane" "$agent"
            log_stall_event nudge_sent "$agent" "$task_id" "$cmd_id" "$elapsed_min" "$((nudges_used + 1))"
        elif [ "$stage" -eq 1 ] && [ "$elapsed_min" -ge "$((threshold + karo_wait))" ]; then
            if [ "$agent" = "karo" ]; then
                # karo自身のstallは家老inbox注入が自己矛盾のため直接ntfyへ短絡
                ntfy_fire "$agent" "$task_id" "$elapsed_min" "karo_self_stall"
                log_stall_event escalated_to_ntfy "$agent" "$task_id" "$cmd_id" "$elapsed_min"
            else
                inbox_write_karo "$agent" "$task_id" "$elapsed_min"
                log_stall_event escalated_to_karo "$agent" "$task_id" "$cmd_id" "$elapsed_min"
            fi
        elif [ "$stage" -eq 2 ] && [ "$elapsed_min" -ge "$((threshold + karo_wait + ntfy_wait))" ]; then
            ntfy_fire "$agent" "$task_id" "$elapsed_min" "unresolved"
            log_stall_event escalated_to_ntfy "$agent" "$task_id" "$cmd_id" "$elapsed_min"
        fi
    done < <(get_in_flight_tasks_with_agent | _inflight_to_tsv)
}

# ─── 1ティック分の処理(stall_detection_enabledを毎回再読込。
#     deadman_watcher.shのrun_deadman_tick()と同型) ───
run_stall_tick() {
    local stall_enabled
    stall_enabled=$(_read_stall_enabled)
    if [ "$stall_enabled" = "true" ]; then
        check_stall_tick
    fi
}

# ─── Main loop: event-driven via inotifywait + tick_secタイムアウトフォールバック ───
main() {
    if ! command -v inotifywait &>/dev/null; then
        echo "[stall_watcher] ERROR: inotifywait not found. Install: sudo apt install inotify-tools" >&2
        exit 1
    fi

    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/queue/reports" "${SCRIPT_DIR}/queue/inbox" 2>/dev/null || true
    echo "[$(date)] stall_watcher started" >&2

    while true; do
        run_stall_tick
        timeout "$(_read_stall_setting tick_sec 60)" inotifywait -e modify -e create \
            "$TIMING_EVENTS_JSONL" "${SCRIPT_DIR}/queue/reports" "${SCRIPT_DIR}/queue/inbox" 2>/dev/null || true
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
