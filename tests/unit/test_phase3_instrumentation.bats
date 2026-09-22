#!/usr/bin/env bats
# test_phase3_instrumentation.bats — Phase3 instrumentation tests (cmd_087 Part B)
#
# Tests the state capture and logging when Phase3 escalation fires (/clear after 4+ min unread).
# Verifies that phase3_fired event logs agent state (busy, pane_cmd, age_sec) via --extra parameter.

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export LOG_TIMING_EVENT_SCRIPT="$PROJECT_ROOT/scripts/log_timing_event.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    [ -f "$LOG_TIMING_EVENT_SCRIPT" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/phase3_test.XXXXXX")"
    mkdir -p "$TEST_TMPDIR/logs"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- T-P3-001: Phase3 instrumentation code exists in inbox_watcher.sh ---

@test "T-P3-001: Phase3 instrumentation code is present in inbox_watcher.sh" {
    grep -q "cmd_087 Part B: Phase3発火時の状態計装" "$WATCHER_SCRIPT"
    grep -q "phase3_fired" "$WATCHER_SCRIPT"
    grep -q 'extra_json=.*printf' "$WATCHER_SCRIPT"
    grep -q 'inbox_watcher.sh:phase3' "$WATCHER_SCRIPT"
}

# --- T-P3-002: log_timing_event.sh supports --extra parameter ---

@test "T-P3-002: log_timing_event.sh has --extra option support" {
    grep -q 'extra=""' "$LOG_TIMING_EVENT_SCRIPT"
    grep -q 'arg.*extra' "$LOG_TIMING_EVENT_SCRIPT"
    grep -q 'extra.*arg#' "$LOG_TIMING_EVENT_SCRIPT"
    grep -q "'extra': none_if_empty(extra)" "$LOG_TIMING_EVENT_SCRIPT"
}

# --- T-P3-003: extra parameter handling in log_timing_event.sh ---

@test "T-P3-003: log_timing_event.sh parses --extra correctly" {
    # Verify the case statement for --extra
    grep -q 'case "\$arg" in' "$LOG_TIMING_EVENT_SCRIPT"
    grep -q 'extra=.*arg#' "$LOG_TIMING_EVENT_SCRIPT"

    # Verify sys.argv handles 9 elements
    grep -q 'sys.argv\[1:10\]' "$LOG_TIMING_EVENT_SCRIPT"
}

# --- T-P3-005: extra field properly nulled when not provided ---

@test "T-P3-005: log_timing_event.sh has none_if_empty() for extra field" {
    # Verify backward compatibility: extra is processed through none_if_empty
    grep -q "def none_if_empty" "$LOG_TIMING_EVENT_SCRIPT"
    grep -q "'extra': none_if_empty(extra)" "$LOG_TIMING_EVENT_SCRIPT"
}

# --- T-P3-006: Phase3 state variables are local (no side effects) ---

@test "T-P3-006: Phase3 instrumentation uses local variables (no pollution)" {
    # Verify that Phase3 block declares p3_* variables as local
    grep -q "local p3_busy p3_pane_cmd p3_age p3_content p3_cmd_id p3_task_id p3_ids" "$WATCHER_SCRIPT"
    # Verify extra_json is local or scoped properly
    grep -A 2 "extra_json=" "$WATCHER_SCRIPT" | grep -q "phase3_fired"
}

# --- T-P3-007: Phase3 code is placed only once (no duplication) ---

@test "T-P3-007: Phase3 instrumentation appears exactly once in inbox_watcher.sh" {
    local count=$(grep -c "cmd_087 Part B: Phase3発火時の状態計装" "$WATCHER_SCRIPT")
    [ "$count" -eq 1 ]
}

# --- T-P3-008: resolve_timing_ids is used in Phase3 block ---

@test "T-P3-008: Phase3 uses resolve_timing_ids to extract cmd_id/task_id" {
    grep -q "p3_ids=\$(resolve_timing_ids" "$WATCHER_SCRIPT"
}
