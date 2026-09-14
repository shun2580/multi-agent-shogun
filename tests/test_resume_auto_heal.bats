#!/usr/bin/env bats
# test_resume_auto_heal.bats — resume_auto_heal.sh unit tests (cmd_194 工程1)
#
# 生成→解除→再生成の1サイクルを検証する。
# テスト専用の架空agent_id(test_agent_194_1)のみを使用し、実agent
# (karo/ashigaru1-7/gunshi/shogun)のauto_heal挙動には一切触れない。

TEST_AGENT="test_agent_194_1"
NONEXISTENT_AGENT="test_agent_194_1_does_not_exist"

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    RESUME_SCRIPT="$PROJECT_ROOT/scripts/resume_auto_heal.sh"
    PAUSED_DIR="$PROJECT_ROOT/logs/auto_heal_paused"
    EVENTS_LOG="$PROJECT_ROOT/logs/auto_heal_events.jsonl"

    mkdir -p "$PAUSED_DIR"
    # Baseline: no dummy flag, no dummy event lines leaked from a prior run.
    rm -f "${PAUSED_DIR}/${TEST_AGENT}"
    EVENTS_LOG_LINES_BEFORE=0
    [ -f "$EVENTS_LOG" ] && EVENTS_LOG_LINES_BEFORE=$(wc -l < "$EVENTS_LOG")
}

teardown() {
    # Leave no dummy flag or dummy event lines behind.
    rm -f "${PAUSED_DIR}/${TEST_AGENT}"
    if [ -f "$EVENTS_LOG" ]; then
        grep -v "\"agent\":\"${TEST_AGENT}\"" "$EVENTS_LOG" > "${EVENTS_LOG}.tmp" || true
        mv "${EVENTS_LOG}.tmp" "$EVENTS_LOG"
    fi
}

@test "a-b: pause flag generated then resumed removes flag and appends resume event" {
    touch "${PAUSED_DIR}/${TEST_AGENT}"
    [ -f "${PAUSED_DIR}/${TEST_AGENT}" ]

    run bash "$RESUME_SCRIPT" "$TEST_AGENT"
    [ "$status" -eq 0 ]

    # (i) flag file is gone
    [ ! -f "${PAUSED_DIR}/${TEST_AGENT}" ]

    # (ii) resume event appended to auto_heal_events.jsonl
    run grep -c "\"agent\":\"${TEST_AGENT}\".*\"event\":\"auto_heal_resumed\".*\"triggered_by\":\"manual\"" "$EVENTS_LOG"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "c: dummy flag can be regenerated after resume (pause is possible again)" {
    touch "${PAUSED_DIR}/${TEST_AGENT}"
    run bash "$RESUME_SCRIPT" "$TEST_AGENT"
    [ "$status" -eq 0 ]
    [ ! -f "${PAUSED_DIR}/${TEST_AGENT}" ]

    # Regenerate the pause flag — must succeed with no leftover state blocking it.
    touch "${PAUSED_DIR}/${TEST_AGENT}"
    [ -f "${PAUSED_DIR}/${TEST_AGENT}" ]
}

@test "d: resume on nonexistent agent flag exits 1" {
    [ ! -f "${PAUSED_DIR}/${NONEXISTENT_AGENT}" ]

    run bash "$RESUME_SCRIPT" "$NONEXISTENT_AGENT"
    [ "$status" -eq 1 ]
}

@test "usage: missing agent_id argument exits 1" {
    run bash "$RESUME_SCRIPT"
    [ "$status" -eq 1 ]
}
