#!/bin/bash
# Usage: log_timing_event.sh <event> <cmd_id> <task_id_or_empty> <agent> [--redo_of=X] [--qc_result=pass|fail] [--source=name]
# Appends one JSON line to logs/timing_events.jsonl. Fire-and-forget: never fails
# the caller, always exits 0. JSON construction is delegated entirely to
# python3 json.dumps() (cmd_052c lesson: hand-rolled bash/sed escaping breaks on
# control characters).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

event="${1:-}"
cmd_id="${2:-}"
task_id="${3:-}"
agent="${4:-}"
shift 4 2>/dev/null || true

redo_of=""
qc_result=""
source_name=""
extra=""

for arg in "$@"; do
    case "$arg" in
        --redo_of=*) redo_of="${arg#--redo_of=}" ;;
        --qc_result=*) qc_result="${arg#--qc_result=}" ;;
        --source=*) source_name="${arg#--source=}" ;;
        --extra=*) extra="${arg#--extra=}" ;;
    esac
done

ts="$(date +%Y-%m-%dT%H:%M:%S%:z)"

# --- cmd_146 ④: 合成/E2Eデータの本番timingログ混入ガード(二重の網) ---
# (a)のみでは呼び出し元がTIMING_EVENT_SYNTHETIC宣言を忘れた合成呼び出しが
# そのまま本番ログへ混入する(stall_watcher_incidentで発見された11件の実例が
# このパターン: cmd_id=cmd_054/task_id=test/agent=ashigaru1 等)。
# (b)のみでは命名規則から外れた合成データが素通りする。両方を課すことで
# 「規則に従わない合成」は(a)で、「規則から外れた合成」は(b)で捕捉する。
synthetic_declared=false
case "${TIMING_EVENT_SYNTHETIC:-}" in
    1|true|TRUE|True) synthetic_declared=true ;;
esac

synthetic_heuristic=false
case "$task_id" in
    test|task_test*|e2e_test_*|test_*) synthetic_heuristic=true ;;
esac
case "$cmd_id" in
    *test*) synthetic_heuristic=true ;;
esac
if [ "$agent" = "test_agent" ]; then
    synthetic_heuristic=true
fi

# (a)未宣言での(b)一致こそが「宣言漏れ」の兆候。(a)を明示宣言していれば
# (b)一致は意図通りの合成実行であり警告不要。
if [ "$synthetic_heuristic" = true ] && [ "$synthetic_declared" = false ]; then
    echo "⚠️ WARN: task_id/cmd_id/agent looks synthetic (task_id=${task_id} cmd_id=${cmd_id} agent=${agent}) but TIMING_EVENT_SYNTHETIC not set" >&2
fi

# LOG_TIMING_EVENT_OUTPUT_DIR: テスト分離用オーバーライド(既定はSCRIPT_DIR)。
# venv pythonの実体パスは常に実SCRIPT_DIRを使うため影響を受けない。
OUTPUT_DIR="${LOG_TIMING_EVENT_OUTPUT_DIR:-$SCRIPT_DIR}"

if [ "$synthetic_declared" = true ] || [ "$synthetic_heuristic" = true ]; then
    sink="${OUTPUT_DIR}/tests/fixtures/timing_events_synthetic.jsonl"
else
    sink="${OUTPUT_DIR}/logs/timing_events.jsonl"
fi

mkdir -p "$(dirname "$sink")" 2>/dev/null || true

"${SCRIPT_DIR}/.venv/bin/python3" -c "
import json, sys

ts, event, cmd_id, task_id, agent, redo_of, qc_result, source, extra = sys.argv[1:10]

def none_if_empty(v):
    return v if v != '' else None

record = {
    'ts': ts,
    'event': event,
    'cmd_id': none_if_empty(cmd_id),
    'task_id': none_if_empty(task_id),
    'agent': none_if_empty(agent),
    'redo_of': none_if_empty(redo_of),
    'qc_result': none_if_empty(qc_result),
    'source': none_if_empty(source),
    'extra': none_if_empty(extra),
}
print(json.dumps(record, ensure_ascii=False))
" "$ts" "$event" "$cmd_id" "$task_id" "$agent" "$redo_of" "$qc_result" "$source_name" "$extra" \
    >> "$sink" 2>/dev/null || true

exit 0
