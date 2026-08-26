#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# deadman_watcher.sh — 停滞警報(デッドマンスイッチ)v1
# Usage: bash scripts/deadman_watcher.sh
#
# cmd_092 (Fable正典 fable_directive_deadman.md / 軍師設計 subtask_092_design 準拠)。
# v1スコープ: 検出・通知・証拠保全のみ。自動復旧(send-keys/nudge/再起動)は行わない。
#
# in-flight判定: logs/timing_events.jsonl のライフサイクルイベント(assigned/
# redo_dispatched〜report_submitted)を対象task_idの権威ソースとし、task_id粒度で
# 判定する(cmd_doneイベントは実質未運用のため使わない)。
# 活動時刻(elapsed計算の基準)は cmd_179 (2026-08-26) により、timing_events.jsonl の
# ライフサイクルイベント ∪ logs/stall_events.jsonl の output_changed イベント の
# うちより新しい方(union・max)を採用する。ライフサイクルイベントのみを見ると、
# 実際には毎分output_changedを記録しつつ稼働中の足軽を「無活動」と誤判定する
# (観測の不在を停止の観測に潰す・cmd_175 subtask_175_A 2026-08-26T21:35:11実例)。
#
# 統合: inbox_watcher.shと同型のinotifywait+timeoutパターンを流用した専用1プロセス。
# 起動・生存監視は watcher_supervisor.sh へ委譲。
#
# テスト容易性: BASH_SOURCEガードにより、source時は関数定義のみが読み込まれ、
# main()は実行されない(scripts/scope_check.shと同パターン)。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${SCRIPT_DIR}/lib/agent_registry.sh"

# ─── timeout command compatibility wrapper (macOS support, inbox_watcher.shから移植) ───
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
TIMING_EVENTS_JSONL="${TIMING_EVENTS_JSONL:-${SCRIPT_DIR}/logs/timing_events.jsonl}"
STALL_EVENTS_LOG="${STALL_EVENTS_LOG:-${SCRIPT_DIR}/logs/stall_events.jsonl}"
DEADMAN_ALERTS_LOG="${DEADMAN_ALERTS_LOG:-${SCRIPT_DIR}/logs/deadman_alerts.log}"
DEADMAN_INCIDENTS_DIR="${DEADMAN_INCIDENTS_DIR:-${SCRIPT_DIR}/logs/incidents}"
DEADMAN_SETTINGS="${DEADMAN_SETTINGS:-${SCRIPT_DIR}/config/settings.yaml}"
DEADMAN_NTFY_SCRIPT="${DEADMAN_NTFY_SCRIPT:-${SCRIPT_DIR}/scripts/ntfy.sh}"
# Test-only override: fixes "now" for elapsed-time computation (ISO8601 w/ offset).
DEADMAN_TEST_NOW="${DEADMAN_TEST_NOW:-}"

# ─── config/settings.yaml readers (auto_heal系の既存慣習に倣う) ───
_read_deadman_enabled() {
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${DEADMAN_SETTINGS}', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('features') or {}).get('deadman_enabled')
    if v is None:
        v = False
    print(str(v).lower())
except Exception:
    print('false')
" 2>/dev/null
}

_read_deadman_setting() {
    local key="$1" default="$2"
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('${DEADMAN_SETTINGS}', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    v = (data.get('deadman') or {}).get('$key')
    if v is None:
        v = '$default'
    print(v)
except Exception:
    print('$default')
" 2>/dev/null
}

_deadman_now_iso() {
    if [ -n "${DEADMAN_TEST_NOW:-}" ]; then
        printf '%s' "$DEADMAN_TEST_NOW"
    else
        date +%Y-%m-%dT%H:%M:%S%:z
    fi
}

_deadman_elapsed_minutes() {
    local last_event_ts="$1"
    LAST_EVENT_TS="$last_event_ts" NOW_ISO="$(_deadman_now_iso)" "$SCRIPT_DIR/.venv/bin/python3" -c "
import datetime, os
last_raw = os.environ.get('LAST_EVENT_TS', '')
now_raw = os.environ.get('NOW_ISO', '')
try:
    last_dt = datetime.datetime.fromisoformat(last_raw)
    now_dt = datetime.datetime.fromisoformat(now_raw)
    if last_dt.tzinfo is None:
        last_dt = last_dt.replace(tzinfo=datetime.timezone.utc)
    if now_dt.tzinfo is None:
        now_dt = now_dt.replace(tzinfo=datetime.timezone.utc)
    delta = now_dt - last_dt
    print(int(delta.total_seconds() // 60))
except Exception:
    print(0)
"
}

_deadman_pane_base() {
    if [ -n "${SHOGUN_PANE_BASE:-}" ]; then
        echo "$SHOGUN_PANE_BASE"
        return 0
    fi
    tmux show-options -gv pane-base-index 2>/dev/null || echo 0
}

# ─── 論点1: in-flight判定(logs/timing_events.jsonlのライフサイクルイベントを
# 対象task_idの権威ソースとする) ───
# task_id粒度: event in (assigned, redo_dispatched) が存在し、その最新出現より
# 後に event == report_submitted が存在しない task_id を in-flight とみなす。
# cmd_doneイベントには一切依存しない(実質未運用のため)。
# 活動時刻(last_event_ts)は cmd_179 により、上記ライフサイクルイベントの最新ts と
# logs/stall_events.jsonl の output_changed イベント最新ts(同一task_id・cmd_id
# 一致時のみ、誤結合防止の二重キー)の**より新しい方**を採用する(和集合)。
# 出力: JSON配列 [{"cmd_id","task_id","last_event_type","last_event_ts"}, ...]
get_in_flight_tasks() {
    TIMING_EVENTS_JSONL="$TIMING_EVENTS_JSONL" STALL_EVENTS_LOG="$STALL_EVENTS_LOG" \
        "$SCRIPT_DIR/.venv/bin/python3" - <<'PY'
import datetime
import json
import os
from collections import defaultdict

path = os.environ.get("TIMING_EVENTS_JSONL", "")
stall_path = os.environ.get("STALL_EVENTS_LOG", "")


def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s)
    except Exception:
        return None


tasks = defaultdict(list)
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            tid = rec.get("task_id")
            ts = rec.get("ts")
            if not tid or not ts:
                continue
            tasks[tid].append((ts, rec.get("event"), rec.get("cmd_id")))
except FileNotFoundError:
    pass

# output_changed(logs/stall_events.jsonl): task_id粒度で最新tsを蓄積する。
# cmd_idも保持し、timing_events側と一致する場合のみ採用する(誤結合防止)。
output_changed_by_task = defaultdict(list)
try:
    with open(stall_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("event") != "output_changed":
                continue
            tid = rec.get("task_id")
            ts = rec.get("ts")
            if not tid or not ts:
                continue
            dt = parse_ts(ts)
            if dt is None:
                continue
            output_changed_by_task[tid].append((ts, rec.get("cmd_id"), dt))
except FileNotFoundError:
    pass

results = []
for tid, events in tasks.items():
    parsed = [(ts, ev, cid, parse_ts(ts)) for ts, ev, cid in events]
    parsed = [e for e in parsed if e[3] is not None]
    if not parsed:
        continue
    parsed.sort(key=lambda e: e[3])

    arm_idx = None
    for i, (ts, ev, cid, dt) in enumerate(parsed):
        if ev in ("assigned", "redo_dispatched"):
            arm_idx = i
    if arm_idx is None:
        continue
    arm_dt = parsed[arm_idx][3]

    completed = any(
        ev == "report_submitted" and dt > arm_dt for ts, ev, cid, dt in parsed
    )
    if completed:
        continue

    last_ts, last_event, _, last_dt = parsed[-1]
    cmd_id = None
    for ts, ev, cid, dt in reversed(parsed):
        if cid:
            cmd_id = cid
            break

    # 和集合(union): output_changedの最新tsがtiming側より新しければ採用する。
    best_ts, best_event, best_dt = last_ts, last_event, last_dt
    for oc_ts, oc_cid, oc_dt in output_changed_by_task.get(tid, []):
        if cmd_id and oc_cid and oc_cid != cmd_id:
            continue
        if oc_dt > best_dt:
            best_ts, best_event, best_dt = oc_ts, "output_changed", oc_dt

    results.append(
        {
            "cmd_id": cmd_id,
            "task_id": tid,
            "last_event_type": best_event,
            "last_event_ts": best_ts,
        }
    )

print(json.dumps(results, ensure_ascii=False))
PY
}

# ─── 論点4: 重複抑制(logs/deadman_alerts.log自体を状態ストアとして兼用) ───
# 直近のdeadman_firedエントリのlast_event_tsが今回算出したlast_event_tsと
# 同一なら「発報済み(同一エピソード)」→ 0(true)。異なる/存在しないなら 1(false)。
already_alerted() {
    local task_id="$1" last_event_ts="$2"
    TASK_ID="$task_id" LAST_EVENT_TS="$last_event_ts" DEADMAN_ALERTS_LOG="$DEADMAN_ALERTS_LOG" \
        "$SCRIPT_DIR/.venv/bin/python3" - <<'PY'
import json
import os
import sys

path = os.environ.get("DEADMAN_ALERTS_LOG", "")
task_id = os.environ.get("TASK_ID", "")
last_event_ts = os.environ.get("LAST_EVENT_TS", "")

latest = None
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("event") != "deadman_fired":
                continue
            if rec.get("task_id") != task_id:
                continue
            latest = rec
except FileNotFoundError:
    pass

if latest is not None and latest.get("last_event_ts") == last_event_ts:
    sys.exit(0)  # already alerted for this stall episode
sys.exit(1)  # not alerted yet -> fire
PY
}

# 論点5: capture-pane非抵触の明記(以下コメントは正典どおり)
# NOTE (cmd_092): instructions/karo.md L287 "tmux capture-pane FORBIDDEN" は
# 家老が dispatch→sleep→capture-pane を繰り返すポーリング的状態確認(F004違反)を
# 禁じたものであり、対象は日常運用フローでのポーリングに限定される。
# 本呼び出しは inotifywait+timeout により既に stall_threshold_min 分の無活動が
# 確定した「後」の一回限りの診断的証拠採取であり、ポーリングではない
# (instructions/karo.md L1289「詰まった足軽のpaneをcapture-paneで確認」と同種の
# 事後診断ユースケース)。よってF004には抵触しない。
capture_pane_snapshots() {
    local incident_dir="$1"
    mkdir -p "$incident_dir"

    local pane_base
    pane_base=$(_deadman_pane_base)

    local agent pane
    while IFS= read -r agent; do
        [ -z "$agent" ] && continue
        if ! pane=$(agent_registry_pane_for_agent "$agent" "$pane_base"); then
            continue
        fi
        tmux capture-pane -p -S -200 -t "$pane" > "${incident_dir}/${agent}.txt" 2>/dev/null || true
    done < <(agent_registry_agents)
}

# ─── fire_alert: already_alertedでなければ証拠保全→ログ追記→通知 ───
fire_alert() {
    local cmd_id="$1" task_id="$2" last_event_type="$3" last_event_ts="$4" elapsed_min="$5" threshold="$6"

    if already_alerted "$task_id" "$last_event_ts"; then
        echo "[$(date)] [SKIP] deadman: already alerted task_id=$task_id last_event_ts=$last_event_ts" >&2
        return 0
    fi

    local incident_ts incident_dir
    incident_ts=$(date +%Y%m%d_%H%M%S)
    incident_dir="${DEADMAN_INCIDENTS_DIR}/${incident_ts}"

    capture_pane_snapshots "$incident_dir"

    mkdir -p "$(dirname "$DEADMAN_ALERTS_LOG")" 2>/dev/null || true
    CMD_ID="$cmd_id" TASK_ID="$task_id" LAST_EVENT_TYPE="$last_event_type" \
        LAST_EVENT_TS="$last_event_ts" ELAPSED_MIN="$elapsed_min" INCIDENT_DIR="$incident_dir" \
        STALL_THRESHOLD_MIN="$threshold" DEADMAN_ALERTS_LOG="$DEADMAN_ALERTS_LOG" \
        "$SCRIPT_DIR/.venv/bin/python3" - <<'PY'
import datetime
import json
import os

record = {
    "ts": datetime.datetime.now().astimezone().replace(microsecond=0).isoformat(),
    "event": "deadman_fired",
    "cmd_id": os.environ.get("CMD_ID") or None,
    "task_id": os.environ.get("TASK_ID") or None,
    "last_event_type": os.environ.get("LAST_EVENT_TYPE") or None,
    "last_event_ts": os.environ.get("LAST_EVENT_TS") or None,
    "elapsed_min": int(os.environ.get("ELAPSED_MIN") or 0),
    "incident_dir": os.environ.get("INCIDENT_DIR") or None,
    "stall_threshold_min": int(os.environ.get("STALL_THRESHOLD_MIN") or 0),
}
path = os.environ.get("DEADMAN_ALERTS_LOG", "")
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PY

    bash "$DEADMAN_NTFY_SCRIPT" \
        "🚨 停滞警報: cmd_id=${cmd_id} task_id=${task_id} 最終活動=${last_event_type}(${last_event_ts}) 経過${elapsed_min}分" \
        >&2 || true
}

# ─── check_stalls: get_in_flight_tasksの各エントリを閾値判定してfire_alertへ ───
check_stalls() {
    local threshold
    threshold=$(_read_deadman_setting stall_threshold_min 20)
    [ -n "$threshold" ] || threshold=20

    local in_flight_json
    in_flight_json=$(get_in_flight_tasks)

    local cmd_id task_id last_event_type last_event_ts
    while IFS=$'\t' read -r cmd_id task_id last_event_type last_event_ts; do
        [ -z "$task_id" ] && continue
        local elapsed_min
        elapsed_min=$(_deadman_elapsed_minutes "$last_event_ts")
        if [ "${elapsed_min:-0}" -gt "$threshold" ] 2>/dev/null; then
            fire_alert "$cmd_id" "$task_id" "$last_event_type" "$last_event_ts" "$elapsed_min" "$threshold"
        fi
    done < <(printf '%s' "$in_flight_json" | "$SCRIPT_DIR/.venv/bin/python3" -c "
import json, sys
data = json.loads(sys.stdin.read() or '[]')
for t in data:
    print('\t'.join([t.get('cmd_id') or '', t.get('task_id') or '', t.get('last_event_type') or '', t.get('last_event_ts') or '']))
")
}

# ─── 1ティック分の処理(deadman_enabledを毎回再読込) ───
run_deadman_tick() {
    local deadman_enabled
    deadman_enabled=$(_read_deadman_enabled)
    if [ "$deadman_enabled" = "true" ]; then
        check_stalls
    fi
}

# ─── Main loop: event-driven via inotifywait ───
main() {
    if ! command -v inotifywait &>/dev/null; then
        echo "[deadman_watcher] ERROR: inotifywait not found. Install: sudo apt install inotify-tools" >&2
        exit 1
    fi

    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/queue/reports" "${SCRIPT_DIR}/queue/inbox" 2>/dev/null || true
    echo "[$(date)] deadman_watcher started" >&2

    while true; do
        run_deadman_tick
        timeout "${DEADMAN_TICK_SEC:-60}" inotifywait -e modify -e create \
            "$TIMING_EVENTS_JSONL" "${SCRIPT_DIR}/queue/reports" "${SCRIPT_DIR}/queue/inbox" 2>/dev/null || true
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
