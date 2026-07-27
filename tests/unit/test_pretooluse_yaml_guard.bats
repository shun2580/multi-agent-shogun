#!/usr/bin/env bats
# cmd_113 Part2: scripts/pretooluse_yaml_guard.sh のテスト
# deny判定ロジック・fail-open経路・非対象パス早期リターンをユニットテストレベルで
# 検証する(実CLI起動は伴わない。実CLI起動を伴う受け入れ検証は隔離サンドボックスで
# 別途実施し、報告書に実出力を記録する)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GUARD_SCRIPT="$PROJECT_ROOT/scripts/pretooluse_yaml_guard.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/queue/tasks" "$TEST_TMP/queue/reports" "$TEST_TMP/logs"
    SETTINGS_ON="$TEST_TMP/settings_on.yaml"
    SETTINGS_OFF="$TEST_TMP/settings_off.yaml"
    LOG_FILE="$TEST_TMP/logs/yaml_guard.log"
    NTFY_LOG="$TEST_TMP/ntfy.log"
    NTFY_STUB="$TEST_TMP/ntfy_stub.sh"

    cat > "$SETTINGS_ON" <<'EOF'
features:
  yaml_guard_enabled: true
EOF
    cat > "$SETTINGS_OFF" <<'EOF'
features:
  yaml_guard_enabled: false
EOF
    cat > "$NTFY_STUB" <<EOF
#!/usr/bin/env bash
echo "NOTIFIED \$1" >> "$NTFY_LOG"
EOF
    chmod +x "$NTFY_STUB"
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_guard() {
    local payload="$1"
    local python_bin="${2:-$PROJECT_ROOT/.venv/bin/python3}"
    run env \
        YAML_GUARD_SETTINGS="$SETTINGS_ON" \
        YAML_GUARD_REPO_ROOT="$TEST_TMP" \
        YAML_GUARD_LOG="$LOG_FILE" \
        YAML_GUARD_PYTHON="$python_bin" \
        YAML_GUARD_NTFY_SCRIPT="$NTFY_STUB" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
}

# --- 早期リターン: feature flag無効 ---

@test "feature flag disabled: exits 0 with no output even for target path + broken YAML" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":": broken : ["}}'
    run env \
        YAML_GUARD_SETTINGS="$SETTINGS_OFF" \
        YAML_GUARD_REPO_ROOT="$TEST_TMP" \
        YAML_GUARD_LOG="$LOG_FILE" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- 早期リターン: 非対象パス ---

@test "non-target path: exits 0 with no output even with broken content" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/README.md","content":": broken : ["}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "non-target tool_name (Read): exits 0 with no output" {
    local payload='{"tool_name":"Read","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- Write検証 ---

@test "Write target path with valid YAML: allowed silently" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  status: idle\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Write target path with invalid YAML: denied with reason" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"YAML parse failure"* ]]
}

@test "Write target path (queue/inbox): invalid YAML denied" {
    mkdir -p "$TEST_TMP/queue/inbox"
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/inbox/ashigaru9.yaml","content":"messages: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "Write target path (saytask): invalid YAML denied" {
    mkdir -p "$TEST_TMP/saytask"
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/saytask/tasks.yaml","content":"a: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# --- Edit検証(cmd_110事故の再現: 未クォートコロン) ---

@test "Edit simulated replacement introduces unquoted colon: denied" {
    printf 'task:\n  status: idle\n  note: original\n' > "$TEST_TMP/queue/reports/ashigaru9_report.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/ashigaru9_report.yaml","old_string":"note: original","new_string":"note: bad: unquoted: colon","replace_all":false}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "Edit simulated replacement stays valid YAML: allowed silently" {
    printf 'task:\n  status: idle\n  note: original\n' > "$TEST_TMP/queue/reports/ashigaru9_report.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/ashigaru9_report.yaml","old_string":"note: original","new_string":"note: updated","replace_all":false}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Edit replace_all=true across multiple occurrences: validated on final result" {
    printf 'a: x\nb: x\nc: x\n' > "$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","old_string":"x","new_string":"y","replace_all":true}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Edit replace_all=true introducing broken YAML across all occurrences: denied" {
    printf 'a: x\nb: x\n' > "$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","old_string":"x","new_string":"[unclosed","replace_all":true}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# --- fail-open経路 ---

@test "internal error (python binary missing): fails open (allow) and fires ntfy warning" {
    printf 'a: 1\n' > "$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"a: 1\nb: 2\n"}}'
    run_guard "$payload" "/nonexistent/python3"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run cat "$NTFY_LOG"
    [[ "$output" == *"NOTIFIED"* ]]
    run grep -c "FAIL-OPEN" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "internal error (Edit target file unreadable): fails open (allow) and fires ntfy warning" {
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/does_not_exist.yaml","old_string":"a","new_string":"b","replace_all":false}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run cat "$NTFY_LOG"
    [[ "$output" == *"NOTIFIED"* ]]
}

# --- cmd_091標準: 実配線の確認(実settings.jsonへの登録実在) ---

@test "wiring: pretooluse_yaml_guard.sh is registered in .claude/settings.json PreToolUse array" {
    run grep -n "pretooluse_yaml_guard.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "wiring: existing pretooluse_clear_idle.sh entry is still present unchanged" {
    run grep -n "pretooluse_clear_idle.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}
