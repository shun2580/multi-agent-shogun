#!/usr/bin/env bats
# test_log_timing_event_synthetic_guard.bats — cmd_146 ④ 合成/E2Eデータの
# 本番timingログ混入ガード(二重の網: 明示スイッチ + 命名ヒューリスティクス)
#
# 検証対象: scripts/log_timing_event.sh
# 分離手法: LOG_TIMING_EVENT_OUTPUT_DIR で書き込み先ベースディレクトリを
# テスト用tmpdirへ差し替える(venv pythonの実体パスは実SCRIPT_DIRのまま)。
# これにより本番の logs/timing_events.jsonl / tests/fixtures/timing_events_synthetic.jsonl
# を一切汚さずに検証できる。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCRIPT_UNDER_TEST="$PROJECT_ROOT/scripts/log_timing_event.sh"
    [ -f "$SCRIPT_UNDER_TEST" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/log_timing_synth_test.XXXXXX")"
    export LOG_TIMING_EVENT_OUTPUT_DIR="$TEST_TMPDIR"
    PROD_SINK="$TEST_TMPDIR/logs/timing_events.jsonl"
    SYNTH_SINK="$TEST_TMPDIR/tests/fixtures/timing_events_synthetic.jsonl"
    unset TIMING_EVENT_SYNTHETIC
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset LOG_TIMING_EVENT_OUTPUT_DIR TIMING_EVENT_SYNTHETIC
}

# --- 正常系: 合成でも命名該当でもない通常呼び出しは本番sinkへ ---

@test "normal call (no synthetic switch, no synthetic naming) writes to production sink" {
    run bash "$SCRIPT_UNDER_TEST" "task_started" "cmd_146" "subtask_146_b" "ashigaru3"
    [ "$status" -eq 0 ]
    [ -f "$PROD_SINK" ]
    [ ! -f "$SYNTH_SINK" ]
    grep -q '"task_id": "subtask_146_b"' "$PROD_SINK"
    [ -z "$output" ]
}

# --- (a) 明示スイッチ: 宣言ありなら通常データでも合成sinkへ振替、警告なし ---

@test "(a) TIMING_EVENT_SYNTHETIC=1 with ordinary-looking data routes to synthetic sink, no warning" {
    TIMING_EVENT_SYNTHETIC=1 run bash "$SCRIPT_UNDER_TEST" "task_started" "cmd_200" "subtask_200_a" "ashigaru4"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    grep -q '"task_id": "subtask_200_a"' "$SYNTH_SINK"
    [ -z "$output" ]
}

# --- (b) 命名ヒューリスティクス: 宣言なしで合成命名なら合成sinkへ振替 + fail-loud警告 ---

@test "(b) task_id exactly 'test' without declaration routes to synthetic sink AND warns" {
    run bash "$SCRIPT_UNDER_TEST" "task_started" "cmd_054" "test" "ashigaru1"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    grep -q '"task_id": "test"' "$SYNTH_SINK"
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"TIMING_EVENT_SYNTHETIC"* ]]
}

@test "(b) task_id starting with 'task_test' without declaration routes to synthetic sink AND warns" {
    run bash "$SCRIPT_UNDER_TEST" "task_started" "cmd_test" "task_test" "test_agent"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    [[ "$output" == *"WARN"* ]]
}

@test "(b) task_id starting with 'e2e_test_' without declaration routes to synthetic sink AND warns" {
    run bash "$SCRIPT_UNDER_TEST" "task_started" "" "e2e_test_subtask_140" "karo"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    grep -q '"task_id": "e2e_test_subtask_140"' "$SYNTH_SINK"
    [[ "$output" == *"WARN"* ]]
}

@test "(b) task_id starting with generalized 'test_' without declaration routes to synthetic sink AND warns" {
    run bash "$SCRIPT_UNDER_TEST" "task_started" "cmd_300" "test_some_case" "ashigaru5"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [[ "$output" == *"WARN"* ]]
}

@test "(b) cmd_id containing 'test' without declaration routes to synthetic sink AND warns" {
    run bash "$SCRIPT_UNDER_TEST" "task_started" "cmd_test" "subtask_301" "ashigaru6"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    [[ "$output" == *"WARN"* ]]
}

@test "(b) agent exactly 'test_agent' without declaration routes to synthetic sink AND warns" {
    run bash "$SCRIPT_UNDER_TEST" "task_started" "cmd_400" "subtask_400" "test_agent"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    [[ "$output" == *"WARN"* ]]
}

# --- 二重の網の相互作用: (a)宣言 + (b)ヒューリスティクス一致 → sink振替はされるが警告は出ない ---

@test "(a)+(b) both match: routes to synthetic sink but warning is suppressed (declared intentionally)" {
    TIMING_EVENT_SYNTHETIC=1 run bash "$SCRIPT_UNDER_TEST" "task_started" "cmd_test" "test" "test_agent"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    [ -z "$output" ]
}

@test "TIMING_EVENT_SYNTHETIC=true (word form) also declares and suppresses warning under heuristic match" {
    TIMING_EVENT_SYNTHETIC=true run bash "$SCRIPT_UNDER_TEST" "task_started" "" "e2e_test_foo" "karo"
    [ "$status" -eq 0 ]
    [ -f "$SYNTH_SINK" ]
    [ -z "$output" ]
}

# --- 既知の実インシデントデータ3件の再現確認(stall_watcher_incident) ---

@test "known incident record 1 (cmd_054/test/ashigaru1) is now caught by the guard" {
    run bash "$SCRIPT_UNDER_TEST" "e2e_test" "cmd_054" "test" "ashigaru1"
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    [[ "$output" == *"WARN"* ]]
}

@test "known incident record 2 (cmd_test/task_test/test_agent) is now caught by the guard" {
    run bash "$SCRIPT_UNDER_TEST" "e2e_test" "cmd_test" "task_test" "test_agent"
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    [[ "$output" == *"WARN"* ]]
}

@test "known incident record 3 (empty cmd_id/e2e_test_subtask_140/karo) is now caught by the guard" {
    run bash "$SCRIPT_UNDER_TEST" "e2e_test" "" "e2e_test_subtask_140" "karo"
    [ -f "$SYNTH_SINK" ]
    [ ! -f "$PROD_SINK" ]
    [[ "$output" == *"WARN"* ]]
}
