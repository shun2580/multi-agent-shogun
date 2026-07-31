#!/usr/bin/env bash
# lib/inflight_tasks.sh — in-flight task判定(agent付き)の共有ライブラリ
#
# cmd_140 (gunshi_design_140 design_spec_for_implementer点2準拠):
# scripts/deadman_watcher.sh の get_in_flight_tasks() と同一の
# timing_events.jsonl パース・in-flight判定ロジック(assigned/redo_dispatched
# でarm、report_submittedで解除)を複製し、出力JSONに"agent"フィールドを
# 追加したもの。既存 deadman_watcher.sh の get_in_flight_tasks() 自体は
# 一切変更しない(DRY原則より両watcherの独立性・既存テストの安全性を優先)。

INFLIGHT_TASKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Overridable path (env override → bats fixtures point this at tmp dir).
# deadman_watcher.shと同じ変数名(TIMING_EVENTS_JSONL)を用いることで、
# 同一fixtureファイルを両watcherで共有できる。
TIMING_EVENTS_JSONL="${TIMING_EVENTS_JSONL:-${INFLIGHT_TASKS_LIB_DIR}/logs/timing_events.jsonl}"

# get_in_flight_tasks_with_agent
# 出力: JSON配列 [{"cmd_id","task_id","last_event_type","last_event_ts","agent"}, ...]
get_in_flight_tasks_with_agent() {
    TIMING_EVENTS_JSONL="$TIMING_EVENTS_JSONL" "$INFLIGHT_TASKS_LIB_DIR/.venv/bin/python3" - <<'PY'
import datetime
import json
import os
from collections import defaultdict

path = os.environ.get("TIMING_EVENTS_JSONL", "")


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
            tasks[tid].append((ts, rec.get("event"), rec.get("cmd_id"), rec.get("agent")))
except FileNotFoundError:
    pass

results = []
for tid, events in tasks.items():
    parsed = [(ts, ev, cid, ag, parse_ts(ts)) for ts, ev, cid, ag in events]
    parsed = [e for e in parsed if e[4] is not None]
    if not parsed:
        continue
    parsed.sort(key=lambda e: e[4])

    arm_idx = None
    for i, (ts, ev, cid, ag, dt) in enumerate(parsed):
        if ev in ("assigned", "redo_dispatched"):
            arm_idx = i
    if arm_idx is None:
        continue
    arm_dt = parsed[arm_idx][4]

    completed = any(
        ev == "report_submitted" and dt > arm_dt for ts, ev, cid, ag, dt in parsed
    )
    if completed:
        continue

    last_ts, last_event, _, _, _ = parsed[-1]
    cmd_id = None
    agent = None
    for ts, ev, cid, ag, dt in reversed(parsed):
        if cid and cmd_id is None:
            cmd_id = cid
        if ag and agent is None:
            agent = ag
        if cmd_id is not None and agent is not None:
            break

    results.append(
        {
            "cmd_id": cmd_id,
            "task_id": tid,
            "last_event_type": last_event,
            "last_event_ts": last_ts,
            "agent": agent,
        }
    )

print(json.dumps(results, ensure_ascii=False))
PY
}
