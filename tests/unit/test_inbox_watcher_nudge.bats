#!/usr/bin/env bats
# test_inbox_watcher_nudge.bats — inbox_watcher.sh nudge text tests
#
# T-NUDGE-001: opencode CLI のとき nudge テキストに "queue/inbox/" と "yaml を読んで" が含まれること
# T-NUDGE-002: claude CLI のとき nudge テキストが "inbox" + 数字 の形式であること
# T-NUDGE-003: gemini CLI のとき nudge テキストが "inbox" + 数字 の形式であること
#
# ─── cmd_123 Part A: busy判定の三値化(busy/idle/unknown) ───
# Fable裁定20260728 Q8: unknownの既定動作は動作の破壊性で分岐する。
#   T-TRI-001〜004: agent_is_busy_tri() の観測(3値)そのものを検証
#   T-TRI-005〜010: 3値×破壊性2種(非破壊=nudge/破壊的=clear)の既定動作(計6ケース)
#   T-TRI-011〜012: unknown原因種別のログ記録
#   T-NUDGE-IDEMPOTENT-001: 重複nudgeが二重処理を生まないこと(既読フラグ設計)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# nudge 生成ロジックをインラインで再現するヘルパー
# 引数: $1=effective_cli_type, $2=unread_count, $3=agent_id
compute_nudge() {
    local effective_cli_for_nudge="$1"
    local unread_count="$2"
    local AGENT_ID="$3"
    local nudge="inbox${unread_count}"

    if [[ "$effective_cli_for_nudge" == "opencode" ]] || [[ "$effective_cli_for_nudge" == "gemini" ]]; then
        nudge="queue/inbox/${AGENT_ID}.yaml と queue/tasks/${AGENT_ID}.yaml を Read してタスクを実行せよ。完了後 scripts/inbox_write.sh で軍師に報告すること。"
    fi

    echo "$nudge"
}

@test "T-NUDGE-001: opencode CLI のとき nudge テキストに queue/inbox/ と Read が含まれる" {
    result=$(compute_nudge "opencode" "1" "ashigaru4")
    echo "nudge: $result"
    echo "$result" | grep -q "queue/inbox/"
    echo "$result" | grep -q "Read して"
}

@test "T-NUDGE-002: claude CLI のとき nudge テキストが inbox + 数字 の形式" {
    result=$(compute_nudge "claude" "2" "ashigaru1")
    echo "nudge: $result"
    echo "$result" | grep -qE "^inbox[0-9]+$"
}

@test "T-NUDGE-003: gemini CLI のとき nudge テキストに queue/inbox/ と Read が含まれる" {
    result=$(compute_nudge "gemini" "1" "ashigaru3")
    echo "nudge: $result"
    echo "$result" | grep -q "queue/inbox/"
    echo "$result" | grep -q "Read して"
}

# ═══════════════════════════════════════════════════════════════
# cmd_123 Part A: 三値化(busy/idle/unknown) × fail-safe方向 テスト
#
# Sources the REAL scripts/inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1
# (skips arg parsing / inotifywait check / main loop — only function defs load).
# tmux is mocked so capture-pane and display-message can simulate a genuine
# OBSERVATION FAILURE (non-zero exit), distinct from a genuine negative
# observation (blank pane / idle prompt).
# ═══════════════════════════════════════════════════════════════

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/tri_busy_test.XXXXXX")"
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Mock control variables:
    #   MOCK_CAPTURE_PANE       — capture-pane stdout
    #   MOCK_CAPTURE_PANE_RC    — capture-pane exit code (non-zero = observation failure)
    #   MOCK_DISPLAY_PANEID_RC  — display-message '#{pane_id}' exit code (non-zero = pane absent)
    #   MOCK_PANE_CLI           — show-options @agent_cli stdout
    export MOCK_CAPTURE_PANE=""
    export MOCK_CAPTURE_PANE_RC=0
    export MOCK_DISPLAY_PANEID_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_SENDKEYS_RC=0

    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="opencode"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        echo "\${MOCK_CAPTURE_PANE:-}"
        return \${MOCK_CAPTURE_PANE_RC:-0}
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo "\${MOCK_PANE_CLI:-}"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        if echo "\$*" | grep -q "pane_id"; then
            return \${MOCK_DISPLAY_PANEID_RC:-0}
        fi
        if echo "\$*" | grep -q "pane_active"; then
            echo "0"
            return 0
        fi
        echo "mock_session"
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"

    touch "$TEST_TMPDIR/shogun_idle_test_agent"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ── raw 3-value observation ──

@test "T-TRI-001: agent_is_busy_tri returns 0 (busy) — pane-based, Working detected" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE="Thinking (esc to interrupt)"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_tri
    '
    [ "$status" -eq 0 ]
}

@test "T-TRI-002: agent_is_busy_tri returns 1 (idle) — pane-based, idle prompt detected" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE="› ready
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_tri
    '
    [ "$status" -eq 1 ]
}

@test "T-TRI-003: agent_is_busy_tri returns 2 (unknown) — capture-pane exits non-zero (observation failure)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE_RC=1
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_tri
    '
    [ "$status" -eq 2 ]
}

@test "T-TRI-004: agent_is_busy_tri returns 2 (unknown) — display-message pane_id query fails (pane absent)" {
    run bash -c '
        MOCK_DISPLAY_PANEID_RC=1
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_tri
    '
    [ "$status" -eq 2 ]
}

# ── 3値 × 破壊性2種 の既定動作(計6ケース) ──
# agent_is_busy()          = 非破壊(nudge/配達喚起)方向: unknown → 実行する(not busy扱い)
# agent_is_busy_for_clear() = 破壊的(/clear・強制リセット類)方向: unknown → 実行しない(busy扱い)

@test "T-TRI-005: known BUSY × nudge-direction → busy (skip nudge)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE="Thinking (esc to interrupt)"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy
    '
    [ "$status" -eq 0 ]  # 0 = busy → nudge skipped by callers
}

@test "T-TRI-006: known BUSY × clear-direction → busy (block /clear)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE="Thinking (esc to interrupt)"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_for_clear
    '
    [ "$status" -eq 0 ]  # 0 = busy → /clear blocked
}

@test "T-TRI-007: known IDLE × nudge-direction → not busy (send nudge)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE="› ready
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy
    '
    [ "$status" -eq 1 ]  # 1 = not busy → nudge proceeds
}

@test "T-TRI-008: known IDLE × clear-direction → not busy (allow /clear)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE="› ready
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_for_clear
    '
    [ "$status" -eq 1 ]  # 1 = not busy → /clear allowed
}

@test "T-TRI-009: UNKNOWN(observation failure) × nudge-direction → not busy (deliver nudge anyway)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE_RC=1
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy
    '
    # Fable裁定20260728 Q8: 非破壊動作はunknown時に実行する(反転承認)
    [ "$status" -eq 1 ]  # 1 = not busy → nudge proceeds despite unknown observation
}

@test "T-TRI-010: UNKNOWN(observation failure) × clear-direction → busy (block /clear)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE_RC=1
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_for_clear
    '
    # Fable裁定20260728 Q8: 破壊的動作はunknown時に実行しない(現行の保守側を維持)
    [ "$status" -eq 0 ]  # 0 = busy → /clear blocked despite unknown observation
}

# ── unknown原因種別のログ記録 ──

@test "T-TRI-011: unknown reason logged for capture-pane failure" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE_RC=1
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_tri
    '
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi "capture_pane_failed"
}

@test "T-TRI-012: unknown reason logged for pane-absent (display-message failure)" {
    run bash -c '
        MOCK_DISPLAY_PANEID_RC=1
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_is_busy_tri
    '
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi "pane_absent"
}

# ── send_cli_command("/clear") への統合確認: 観測失敗時は/clearを送らない ──

@test "T-TRI-013: send_cli_command /clear is blocked when busy observation fails (unknown)" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE_RC=1
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "\[SKIP\] Agent is busy — /clear deferred"
    ! grep -q "send-keys.*/new" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

@test "T-TRI-014: send_cli_command /clear proceeds when agent is known idle" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        MOCK_CAPTURE_PANE="› ready
  ? for shortcuts                100% context left"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]
    grep -q "send-keys.*/new" "$MOCK_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-NUDGE-IDEMPOTENT: 重複nudgeが二重処理を生まないこと
# (unknown時にnudgeを実行する設計の前提。既読フラグ設計上、二重nudgeは
#  自明にno-opであるはずだが、opencode/geminiの自動既読化パスは実際に
#  YAMLを書き換えるため、二重発火してもメッセージ件数・既読状態が
#  破壊されないことを固定する)
# ═══════════════════════════════════════════════════════════════

@test "T-NUDGE-IDEMPOTENT-001: two consecutive send_wakeup calls do not duplicate or corrupt inbox messages" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="opencode"
        cat > "$INBOX" << "YAML"
messages:
- id: msg_001
  from: karo
  type: task_assigned
  content: some task
  read: false
  timestamp: "2026-07-27T22:00:00"
YAML
        send_wakeup 1
        send_wakeup 1
        "$VENV_PYTHON" - << "PY" "$INBOX"
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
messages = data.get("messages", []) or []
assert len(messages) == 1, f"expected 1 message, got {len(messages)}"
assert messages[0]["read"] is True
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
    # Nudge text was sent at least once each call (duplicate delivery is a
    # harmless no-op on the receiving side — this is the property under test)
    [ "$(grep -cE 'send-keys.*queue/inbox/' "$MOCK_LOG")" -ge 1 ]
}

@test "T-NUDGE-IDEMPOTENT-002: re-marking already-read messages via send_wakeup is a no-op (no state flip)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="opencode"
        cat > "$INBOX" << "YAML"
messages:
- id: msg_001
  from: karo
  type: task_assigned
  content: some task
  read: true
  timestamp: "2026-07-27T22:00:00"
YAML
        send_wakeup 0
        "$VENV_PYTHON" - << "PY" "$INBOX"
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
messages = data.get("messages", []) or []
assert len(messages) == 1
assert messages[0]["read"] is True
assert messages[0]["id"] == "msg_001"
print("OK")
PY
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK"
}
