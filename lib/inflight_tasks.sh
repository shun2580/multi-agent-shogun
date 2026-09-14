#!/usr/bin/env bash
# lib/inflight_tasks.sh — in-flight task判定(agent付き)の共有ライブラリ
#
# cmd_194 工程2 (Fable裁定Q52(c)・gunshi_design_194_2 algorithm_spec準拠):
# in-flightの定義を「timing_events.jsonlの事象列(assigned/redo_dispatchedでarm・
# report_submittedで解除)」から「queue/tasks/{agent}.yamlの現在のstatusが
# assigned/in_progressで、かつ対応するreportがqueue/reports/に無いこと」へ
# 一次資料中心に転換する。timing_events.jsonlはlast_event_type/last_event_ts
# 表示用の付帯情報としてのみ残し、in-flight判定(arm/disarm)には一切用いない。
#
# 既存 scripts/deadman_watcher.sh の get_in_flight_tasks()(agent無し版)は
# 本cmdのスコープ外につき一切変更しない(DRY原則より両watcherの独立性・
# 既存テストの安全性を優先。統合要否は別途判断)。

INFLIGHT_TASKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Overridable paths (env override → bats fixtures point these at tmp dirs).
# TIMING_EVENTS_JSONLはdeadman_watcher.shと同じ変数名で、付帯情報(last_event_*)
# 取得のみに用いる。INFLIGHT_TASKS_DIR/INFLIGHT_REPORTS_DIRは本cmdで新設した
# 判定の一次資料パスで、batsが本番queue/tasks・queue/reportsに一切触れずに
# 済むよう同じ流儀で上書き可能にしてある。
TIMING_EVENTS_JSONL="${TIMING_EVENTS_JSONL:-${INFLIGHT_TASKS_LIB_DIR}/logs/timing_events.jsonl}"
INFLIGHT_TASKS_DIR="${INFLIGHT_TASKS_DIR:-${INFLIGHT_TASKS_LIB_DIR}/queue/tasks}"
INFLIGHT_REPORTS_DIR="${INFLIGHT_REPORTS_DIR:-${INFLIGHT_TASKS_LIB_DIR}/queue/reports}"
INFLIGHT_TASKS_ERROR_LOG="${INFLIGHT_TASKS_ERROR_LOG:-${INFLIGHT_TASKS_LIB_DIR}/logs/inflight_tasks_errors.log}"

# get_in_flight_tasks_with_agent
# 出力: JSON配列 [{"cmd_id","task_id","last_event_type","last_event_ts","agent"}, ...]
get_in_flight_tasks_with_agent() {
    TIMING_EVENTS_JSONL="$TIMING_EVENTS_JSONL" \
    INFLIGHT_TASKS_DIR="$INFLIGHT_TASKS_DIR" \
    INFLIGHT_REPORTS_DIR="$INFLIGHT_REPORTS_DIR" \
    INFLIGHT_TASKS_ERROR_LOG="$INFLIGHT_TASKS_ERROR_LOG" \
    "$INFLIGHT_TASKS_LIB_DIR/.venv/bin/python3" - <<'PY'
import datetime
import glob
import json
import os
import re

import yaml

TASKS_DIR = os.environ.get("INFLIGHT_TASKS_DIR", "")
REPORTS_DIR = os.environ.get("INFLIGHT_REPORTS_DIR", "")
TIMING_PATH = os.environ.get("TIMING_EVENTS_JSONL", "")
ERROR_LOG = os.environ.get("INFLIGHT_TASKS_ERROR_LOG", "")


def _task_id_pattern(task_id):
    # 行末(または行末コメント直前)でのみ一致させる。境界を厳密化しないと
    # "subtask_194_1" が "subtask_194_1_gitignore" のtask_id行に誤って
    # 部分一致してしまう(本コードベース実例のプレフィクス衝突)。
    return re.compile(
        r'task_id:\s*["\']?' + re.escape(task_id) + r'["\']?\s*(#.*)?$',
        re.MULTILINE,
    )


def _has_matching_report(agent, task_id):
    pattern = _task_id_pattern(task_id)
    # {agent}_report.yaml だけでなく {agent}_report*.yaml をglobする。
    # ashigaru6が過去にqueue/reports/ashigaru6_report_cmd192_2_memory_3.yaml
    # という規約外ファイル名で報告を書いた実例があるため。
    for report_file in sorted(glob.glob(os.path.join(REPORTS_DIR, f"{agent}_report*.yaml"))):
        try:
            with open(report_file, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except FileNotFoundError:
            continue
        if pattern.search(text):
            return True
    return False


def _log_parse_error(task_file, exc):
    if not ERROR_LOG:
        return
    try:
        os.makedirs(os.path.dirname(ERROR_LOG), exist_ok=True)
        rec = {
            "ts": datetime.datetime.now().astimezone().isoformat(),
            "task_file": task_file,
            "error": str(exc),
        }
        with open(ERROR_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        # エラーログ自体の書込失敗で全体を止めない(fail-loudの主目的は
        # 「壊れたYAML1件で監視が止まらないこと」であり、ログ書込失敗まで
        # 致命化しては本末転倒)。
        pass


def _parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s)
    except Exception:
        return None


def _lookup_last_timing_event(task_id):
    # 付帯情報のみ。timing_events.jsonlはQ52(c)裁定どおり時刻取得にのみ用い、
    # in-flight判定(arm/disarm)には一切使わない。見つからなければ(None, None)。
    if not TIMING_PATH:
        return None, None
    best_ts = None
    best_event = None
    best_dt = None
    try:
        with open(TIMING_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("task_id") != task_id:
                    continue
                ts = rec.get("ts")
                dt = _parse_ts(ts) if ts else None
                if dt is None:
                    continue
                if best_dt is None or dt > best_dt:
                    best_dt = dt
                    best_ts = ts
                    best_event = rec.get("event")
    except FileNotFoundError:
        pass
    return best_ts, best_event


def get_in_flight_tasks_with_agent():
    results = []
    for task_file in sorted(glob.glob(os.path.join(TASKS_DIR, "*.yaml"))):
        agent = os.path.basename(task_file)[: -len(".yaml")]
        try:
            with open(task_file, encoding="utf-8") as f:
                doc = yaml.safe_load(f)
            task = (doc or {}).get("task") or {}
        except Exception as exc:
            # 壊れたYAML(パース失敗・想定外構造)はfail-loudでログに残し、
            # 当該ファイルはスキップして処理を継続する(1件の壊れたYAMLで
            # 全体の監視が止まらないようにするため)。
            _log_parse_error(task_file, exc)
            continue

        status = task.get("status")
        if status not in ("assigned", "in_progress"):
            continue
        task_id = task.get("task_id")
        if not task_id:
            continue
        cmd_id = task.get("parent_cmd")

        if _has_matching_report(agent, task_id):
            continue  # report実在 → 誤報回避のためdisarm

        last_ts, last_event = _lookup_last_timing_event(task_id)
        results.append(
            {
                "cmd_id": cmd_id,
                "task_id": task_id,
                "last_event_type": last_event,
                "last_event_ts": last_ts,
                "agent": agent,
            }
        )
    return results


print(json.dumps(get_in_flight_tasks_with_agent(), ensure_ascii=False))
PY
}
