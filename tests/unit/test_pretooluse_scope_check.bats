#!/usr/bin/env bats
# cmd_192 工程5(scope_check接続): scripts/pretooluse_scope_check.sh の
# ユニットテスト。scope_check.sh本体は改修せず、薄いアダプタhookが
# stdin JSON経由のEdit/Write呼び出しをその場でagentのtask YAML
# allowed_pathsと照合することを検証する。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GUARD_SCRIPT="$PROJECT_ROOT/scripts/pretooluse_scope_check.sh"
    PYTHON_BIN="$PROJECT_ROOT/.venv/bin/python3"

    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/logs" "$TEST_TMP/tasks"
    LOG_FILE="$TEST_TMP/logs/pretooluse_scope_check.log"
    TASKS_DIR="$TEST_TMP/tasks"

    SETTINGS_OFF="$TEST_TMP/settings_off.yaml"
    SETTINGS_OBSERVE="$TEST_TMP/settings_observe.yaml"
    SETTINGS_ENFORCE="$TEST_TMP/settings_enforce.yaml"
    SETTINGS_MISSING="$TEST_TMP/settings_missing.yaml"
    SETTINGS_UNKNOWN="$TEST_TMP/settings_unknown.yaml"

    cat > "$SETTINGS_OFF" <<'EOF'
features:
  scope_check_hook_enabled: off
EOF
    cat > "$SETTINGS_OBSERVE" <<'EOF'
features:
  scope_check_hook_enabled: observe
EOF
    cat > "$SETTINGS_ENFORCE" <<'EOF'
features:
  scope_check_hook_enabled: enforce
EOF
    cat > "$SETTINGS_UNKNOWN" <<'EOF'
features:
  scope_check_hook_enabled: banana
EOF
    : > "$SETTINGS_MISSING"

    # allowed_paths内に本テストのFILE_PATHが収まるよう、実プロジェクト配下の
    # 架空パス(実ファイルは作らない・match_pattern()は文字列比較のみ)を使う。
    ALLOWED_FILE="$PROJECT_ROOT/scripts/fake_scope_check_target.sh"
    OTHER_FILE="$PROJECT_ROOT/scripts/fake_scope_check_other.sh"

    cat > "$TASKS_DIR/ashigaruX.yaml" <<EOF
task:
  task_id: subtask_fake
  allowed_paths:
    - $ALLOWED_FILE
EOF

    cat > "$TASKS_DIR/ashigaruY_empty.yaml" <<'EOF'
task:
  task_id: subtask_fake_empty
  status: assigned
EOF

    cat > "$TASKS_DIR/ashigaruZ_unreadable_placeholder.yaml" <<'EOF'
placeholder: true
EOF
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_hook() {
    local settings_file="$1"
    local payload="$2"
    local agent_id="${3:-}"
    run env \
        SCOPE_CHECK_HOOK_SETTINGS="$settings_file" \
        SCOPE_CHECK_HOOK_LOG="$LOG_FILE" \
        SCOPE_CHECK_HOOK_PYTHON="$PYTHON_BIN" \
        SCOPE_CHECK_HOOK_TASKS_DIR="$TASKS_DIR" \
        SCOPE_CHECK_HOOK_AGENT_ID="$agent_id" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
}

make_payload() {
    local tool_name="$1" file_path="$2" session_id="$3"
    "$PYTHON_BIN" -c '
import json, sys
tool_name, file_path, session_id = sys.argv[1:4]
print(json.dumps({
    "session_id": session_id,
    "tool_name": tool_name,
    "tool_input": {"file_path": file_path},
}))
' "$tool_name" "$file_path" "$session_id"
}

# --- flag=off: 検証ロジックに一切入らず即exit 0 ---

@test "flag off (explicit): exits 0 with no output, no log written" {
    local payload
    payload="$(make_payload Edit "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-off)"
    run_hook "$SETTINGS_OFF" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "flag off (missing settings file): fail-safe to off, no log" {
    local payload
    payload="$(make_payload Edit "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-missing)"
    run_hook "$TEST_TMP/does_not_exist.yaml" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "flag off (unknown value): fail-safe to off, no log" {
    local payload
    payload="$(make_payload Edit "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-unknown)"
    run_hook "$SETTINGS_UNKNOWN" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# --- allowed_paths内: ALLOW相当(WOULD-DENYされない) ---

@test "observe mode: file_path within allowed_paths is ALLOW, not WOULD-DENY" {
    local payload
    payload="$(make_payload Edit "$PROJECT_ROOT/scripts/fake_scope_check_target.sh" s-allow)"
    run_hook "$SETTINGS_OBSERVE" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW mode=observe session=s-allow agent=ashigaruX" "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-DENY" "$LOG_FILE"
    [ "$output" -eq 0 ]
}

# --- allowed_paths外: observeでWOULD-DENYがログされ、denyはされない(exit 0) ---

@test "observe mode: file_path outside allowed_paths logs WOULD-DENY but does not deny (exit 0, no stdout)" {
    local payload
    payload="$(make_payload Edit "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-wouldeny)"
    run_hook "$SETTINGS_OBSERVE" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY mode=observe session=s-wouldeny agent=ashigaruX" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "enforce mode: file_path outside allowed_paths actually denies with valid JSON" {
    local payload
    payload="$(make_payload Write "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-deny)"
    run_hook "$SETTINGS_ENFORCE" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    run grep -c "DENY mode=enforce session=s-deny agent=ashigaruX" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- flag=off(未設定含む)は検証ロジックに一切入らない(cmd_190標準化に倣う) ---

@test "non-Edit/Write tool: exits 0 with no log" {
    local payload
    payload="$(make_payload Bash "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-nonedit)"
    run_hook "$SETTINGS_OBSERVE" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# --- fail-safe: agent_id解決不能・task YAML読取不能・allowed_paths欠落 ---

@test "fail-safe: agent_id unresolved exits 0 with no log" {
    local payload
    payload="$(make_payload Edit "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-noagent)"
    run_hook "$SETTINGS_OBSERVE" "$payload" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "fail-safe: task YAML unreadable (unknown agent_id) exits 0 with no log" {
    local payload
    payload="$(make_payload Edit "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-notask)"
    run_hook "$SETTINGS_OBSERVE" "$payload" ashigaru_does_not_exist
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "fail-safe: allowed_paths missing from task YAML exits 0 with no log" {
    local payload
    payload="$(make_payload Edit "$PROJECT_ROOT/scripts/fake_scope_check_other.sh" s-noallowed)"
    run_hook "$SETTINGS_OBSERVE" "$payload" ashigaruY_empty
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# --- JSON非エスケープ攻撃面: file_pathに特殊文字を含む入力でもクラッシュ・
# 不正なログ出力をしない ---

@test "JSON escaping: file_path containing double-quote does not crash and logs safely" {
    local payload
    payload="$("$PYTHON_BIN" -c '
import json
print(json.dumps({
    "session_id": "s-quote",
    "tool_name": "Edit",
    "tool_input": {"file_path": "'"$PROJECT_ROOT"'/scripts/weird\"quote.sh"},
}))
')"
    run env \
        SCOPE_CHECK_HOOK_SETTINGS="$SETTINGS_ENFORCE" \
        SCOPE_CHECK_HOOK_LOG="$LOG_FILE" \
        SCOPE_CHECK_HOOK_PYTHON="$PYTHON_BIN" \
        SCOPE_CHECK_HOOK_TASKS_DIR="$TASKS_DIR" \
        SCOPE_CHECK_HOOK_AGENT_ID="ashigaruX" \
        bash -c "cat <<'PAYLOAD_EOF' | bash '$GUARD_SCRIPT'
$payload
PAYLOAD_EOF"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    printf '%s' "$output" > "$TEST_TMP/quote_output.json"
    run "$PYTHON_BIN" -c "
import json
with open('$TEST_TMP/quote_output.json') as f:
    d = json.load(f)
assert d['hookSpecificOutput']['permissionDecision'] == 'deny'
assert 'weird\"quote.sh' in d['hookSpecificOutput']['permissionDecisionReason']
print('PARSE_OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PARSE_OK"* ]]
}

@test "malformed stdin JSON does not crash, exits 0 with no log" {
    run env \
        SCOPE_CHECK_HOOK_SETTINGS="$SETTINGS_OBSERVE" \
        SCOPE_CHECK_HOOK_LOG="$LOG_FILE" \
        SCOPE_CHECK_HOOK_PYTHON="$PYTHON_BIN" \
        SCOPE_CHECK_HOOK_TASKS_DIR="$TASKS_DIR" \
        SCOPE_CHECK_HOOK_AGENT_ID="ashigaruX" \
        bash -c "printf '{not valid json' | bash '$GUARD_SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# --- 本プロジェクト外と思われるfile_pathに対しクラッシュしないこと ---

@test "file_path outside the project (unrelated /tmp path): exits 0 with no log at all (cmd_187 spirit)" {
    local payload
    payload="$(make_payload Edit "/tmp/totally_unrelated_$$_file.txt" s-unrelated)"
    run_hook "$SETTINGS_ENFORCE" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "file_path in another project directory: exits 0 with no log at all" {
    local payload
    payload="$(make_payload Edit "/home/nishikawa/projects/some-other-repo/file.py" s-otherrepo)"
    run_hook "$SETTINGS_ENFORCE" "$payload" ashigaruX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# --- 実配線の確認(cmd_091標準) ---

@test "wiring: pretooluse_scope_check.sh is registered in .claude/settings.json PreToolUse array" {
    run grep -n "pretooluse_scope_check.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "wiring: scope_check_hook_enabled is present in config/settings.yaml and defaults to observe" {
    run grep -E '^\s*scope_check_hook_enabled:\s*observe' "$PROJECT_ROOT/config/settings.yaml"
    [ "$status" -eq 0 ]
}
