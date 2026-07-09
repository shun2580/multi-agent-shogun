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

for arg in "$@"; do
    case "$arg" in
        --redo_of=*) redo_of="${arg#--redo_of=}" ;;
        --qc_result=*) qc_result="${arg#--qc_result=}" ;;
        --source=*) source_name="${arg#--source=}" ;;
    esac
done

ts="$(date +%Y-%m-%dT%H:%M:%S%:z)"

mkdir -p "${SCRIPT_DIR}/logs" 2>/dev/null || true

"${SCRIPT_DIR}/.venv/bin/python3" -c "
import json, sys

ts, event, cmd_id, task_id, agent, redo_of, qc_result, source = sys.argv[1:9]

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
}
print(json.dumps(record, ensure_ascii=False))
" "$ts" "$event" "$cmd_id" "$task_id" "$agent" "$redo_of" "$qc_result" "$source_name" \
    >> "${SCRIPT_DIR}/logs/timing_events.jsonl" 2>/dev/null || true

exit 0
