#!/usr/bin/env bats
# cmd_194 工程2: lib/inflight_tasks.sh の get_in_flight_tasks_with_agent() テスト
# 軍師設計(gunshi_design_194_2) bats_test_cases T1〜T8準拠。
# Q52(c)裁定: in-flight判定をtiming_events.jsonlの事象列依存から
# queue/tasks/*.yaml(現在のstatus)・queue/reports/(reportの実在)という
# 一次資料中心へ転換した改修の検証。
#
# 実本番のqueue/tasks/*.yaml・queue/reports/*.yaml・logs/timing_events.jsonlは
# 一切使わない(全てmktemp -d隔離+env var上書き。test_stall_watcher.bats・
# test_deadman_watcher.batsの「実本番ログは一切使わない」方針を踏襲)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    INFLIGHT_LIB="$PROJECT_ROOT/lib/inflight_tasks.sh"
    PY="$PROJECT_ROOT/.venv/bin/python3"
    TEST_TMP="$(mktemp -d)"
    TASKS_DIR="$TEST_TMP/queue_tasks"
    REPORTS_DIR="$TEST_TMP/queue_reports"
    TIMING_LOG="$TEST_TMP/timing_events.jsonl"
    ERROR_LOG="$TEST_TMP/inflight_tasks_errors.log"
    mkdir -p "$TASKS_DIR" "$REPORTS_DIR"
}

teardown() {
    rm -rf "$TEST_TMP"
}

write_task_yaml() {
    local agent="$1" task_id="$2" status="$3" cmd_id="${4:-cmd_test}"
    cat > "$TASKS_DIR/${agent}.yaml" <<EOF
task:
  task_id: $task_id
  parent_cmd: $cmd_id
  status: $status
EOF
}

write_report() {
    local file="$1" task_id="$2"
    cat > "$file" <<EOF
worker_id: test
task_id: "$task_id"
status: done
EOF
}

run_inflight() {
    run env \
        TIMING_EVENTS_JSONL="$TIMING_LOG" \
        INFLIGHT_TASKS_DIR="$TASKS_DIR" \
        INFLIGHT_REPORTS_DIR="$REPORTS_DIR" \
        INFLIGHT_TASKS_ERROR_LOG="$ERROR_LOG" \
        bash -c '
            source "'"$INFLIGHT_LIB"'"
            get_in_flight_tasks_with_agent
        '
}

assert_task_id_present() {
    local task_id="$1"
    printf '%s' "$output" | "$PY" -c "
import json, sys
data = json.load(sys.stdin)
ids = [d.get('task_id') for d in data]
assert '$task_id' in ids, ids
"
}

assert_task_id_absent() {
    local task_id="$1"
    printf '%s' "$output" | "$PY" -c "
import json, sys
data = json.load(sys.stdin)
ids = [d.get('task_id') for d in data]
assert '$task_id' not in ids, ids
"
}

assert_agent_absent() {
    local agent="$1"
    printf '%s' "$output" | "$PY" -c "
import json, sys
data = json.load(sys.stdin)
agents = [d.get('agent') for d in data]
assert '$agent' not in agents, agents
"
}

# --- T1: report実在でdisarm ---

@test "(T1) task with matching report in queue/reports/{agent}_report.yaml is disarmed" {
    write_task_yaml "ashigaru1" "task_t1" "in_progress"
    write_report "$REPORTS_DIR/ashigaru1_report.yaml" "task_t1"

    run_inflight
    [ "$status" -eq 0 ]
    assert_task_id_absent "task_t1"
}

# --- T2: ★1プレフィクス衝突 ---

@test "(T2) prefix collision: report text for the longer task_id does not falsely disarm the shorter one" {
    write_task_yaml "ashigaru2" "subtask_194_1" "assigned"
    write_report "$REPORTS_DIR/ashigaru2_report.yaml" "subtask_194_1_gitignore"

    run_inflight
    [ "$status" -eq 0 ]
    assert_task_id_present "subtask_194_1"
}

# --- T3: karo構造的除外 ---

@test "(T3) karo has no queue/tasks/karo.yaml -> never appears as agent even with karo timing events" {
    write_task_yaml "ashigaru1" "task_t3" "assigned"
    printf '{"ts": "2026-09-14T10:00:00+09:00", "event": "assigned", "cmd_id": "cmd_t3", "task_id": "task_t3_karo_evt", "agent": "karo"}\n' >> "$TIMING_LOG"
    # queue/tasks/karo.yaml は意図的に作らない

    run_inflight
    [ "$status" -eq 0 ]
    assert_agent_absent "karo"
}

# --- T4: ★2規約外ファイル名 ---

@test "(T4) report file with a non-standard suffix (glob match, e.g. ashigaru6_report_cmd192_2_memory_3.yaml) still disarms" {
    write_task_yaml "ashigaru6" "task_t4" "in_progress"
    write_report "$REPORTS_DIR/ashigaru6_report_cmd192_2_memory_3.yaml" "task_t4"

    run_inflight
    [ "$status" -eq 0 ]
    assert_task_id_absent "task_t4"
}

# --- T5: clear_command(--redo_of無し)相当・timing_events空でもarm ---

@test "(T5) status=assigned with zero timing_events still counts as in-flight (clear_command w/o --redo_of)" {
    write_task_yaml "ashigaru3" "task_t5" "assigned"
    : > "$TIMING_LOG"

    run_inflight
    [ "$status" -eq 0 ]
    assert_task_id_present "task_t5"
}

# --- T6: reportファイル自体が存在しなくてもエラーにならずarm ---

@test "(T6) agent with no report file at all still counts as in-flight without error" {
    write_task_yaml "ashigaru4" "task_t6" "in_progress"
    # $REPORTS_DIR に ashigaru4 関連の報告ファイルを一切置かない

    run_inflight
    [ "$status" -eq 0 ]
    assert_task_id_present "task_t6"
    [ ! -s "$ERROR_LOG" ]
}

# --- T7: 取り残し4件相当の再現(現在のtask YAMLに無いtask_idはtiming_events未解消でも現れない) ---

@test "(T7) stale timing_events for a task_id no longer present in the current task YAML never appears" {
    write_task_yaml "ashigaru2" "task_t7_current" "assigned"
    printf '{"ts": "2020-01-01T00:00:00+09:00", "event": "assigned", "cmd_id": "cmd_old", "task_id": "task_t7_orphan", "agent": "ashigaru2"}\n' >> "$TIMING_LOG"

    run_inflight
    [ "$status" -eq 0 ]
    assert_task_id_absent "task_t7_orphan"
    assert_task_id_present "task_t7_current"
}

# --- T8: 既存consumer(_inflight_to_tsv)互換性(agent/task_id/cmd_idのみで動作) ---

@test "(T8) output JSON keeps agent/task_id/cmd_id populated for the existing _inflight_to_tsv consumer" {
    write_task_yaml "ashigaru5" "task_t8" "in_progress" "cmd_t8"

    run_inflight
    [ "$status" -eq 0 ]
    printf '%s' "$output" | "$PY" -c "
import json, sys
data = json.load(sys.stdin)
match = [d for d in data if d.get('task_id') == 'task_t8']
assert match, data
d = match[0]
assert d.get('agent') == 'ashigaru5', d
assert d.get('cmd_id') == 'cmd_t8', d
"
}
