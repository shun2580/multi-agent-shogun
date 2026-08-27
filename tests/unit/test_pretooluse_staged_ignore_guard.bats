#!/usr/bin/env bats
# Q33(b)ガード(scripts/pretooluse_staged_ignore_guard.sh、cmd_171/177建造)の
# ユニットテスト。cmd_181-Bで根治したトークン解析バグ(引用符付き複数パス
# `git add "f1" "f2"` で引用符文字がパスに付着し誤ってignore判定される
# 問題。原因はJSON生文字列のエスケープ復元漏れ+単語分割の引用符非対応の
# 複合。gunshi_qc_maint_gendrift_A所見)の回帰防止を主眼に、既存の真陽性
# 検出(tracked-but-ignoredパスのdeny)が後退していないことも合わせて検証する。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GUARD_SCRIPT="$PROJECT_ROOT/scripts/pretooluse_staged_ignore_guard.sh"
    PYTHON_BIN="$PROJECT_ROOT/.venv/bin/python3"

    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/logs"
    LOG_FILE="$TEST_TMP/logs/staged_ignore_guard.log"

    SETTINGS_ENFORCE="$TEST_TMP/settings_enforce.yaml"
    SETTINGS_OBSERVE="$TEST_TMP/settings_observe.yaml"
    SETTINGS_OFF="$TEST_TMP/settings_off.yaml"

    cat > "$SETTINGS_ENFORCE" <<'EOF'
features:
  staged_ignore_guard_enabled: enforce
EOF
    cat > "$SETTINGS_OBSERVE" <<'EOF'
features:
  staged_ignore_guard_enabled: observe
EOF
    cat > "$SETTINGS_OFF" <<'EOF'
features:
  staged_ignore_guard_enabled: off
EOF

    # 検証用git repo(whitelist型.gitignore: allowed.md のみ許可、
    # ignored.md はdefault-deny(`*`)のままtracked-but-ignoredとして残す)
    REPO_DIR="$TEST_TMP/repo"
    mkdir -p "$REPO_DIR"
    git -C "$REPO_DIR" init -q
    cat > "$REPO_DIR/.gitignore" <<'EOF'
*
!.gitignore
!allowed.md
EOF
    echo "allowed" > "$REPO_DIR/allowed.md"
    echo "ignored" > "$REPO_DIR/ignored.md"
    git -C "$REPO_DIR" add -f .gitignore allowed.md ignored.md
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_guard() {
    local settings_file="$1"
    local payload="$2"
    run env \
        STAGED_IGNORE_GUARD_SETTINGS="$settings_file" \
        STAGED_IGNORE_GUARD_LOG="$LOG_FILE" \
        STAGED_IGNORE_GUARD_REPO_DIR="$REPO_DIR" \
        STAGED_IGNORE_GUARD_PYTHON="$PYTHON_BIN" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
}

# --- 早期リターン ---

@test "feature flag off: exits 0 with no output, no log written" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"git add ignored.md"}}'
    run_guard "$SETTINGS_OFF" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "non-Bash tool: exits 0 with no log" {
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"ignored.md"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ ! -s "$LOG_FILE" ]
}

@test "Bash command without 'git' substring: exits 0 with no log" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ ! -s "$LOG_FILE" ]
}

# --- 真陽性(regression baseline): 引用符なし単一パス ---

@test "true positive: unquoted single ignored path is denied" {
    local payload='{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"git add ignored.md"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"ignored.md"* ]]
    run grep -c "DENY.*session=s1.*ignored.md" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "true positive: unquoted single allowed path is allowed (no deny)" {
    local payload='{"session_id":"s2","tool_name":"Bash","tool_input":{"command":"git add allowed.md"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW.*session=s2" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- cmd_181-B根治対象: 引用符付き複数パス ---

@test "cmd_181-B fix: double-quoted multi-file git add of ONLY allowed paths is allowed (previously false-DENY)" {
    local payload='{"session_id":"s3","tool_name":"Bash","tool_input":{"command":"git add \"allowed.md\" \".gitignore\""}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW.*session=s3" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_181-B fix: single-quoted multi-file git add of ONLY allowed paths is allowed (previously false-DENY)" {
    local payload="{\"session_id\":\"s4\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add 'allowed.md' '.gitignore'\"}}"
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW.*session=s4" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "true positive preserved under quoting: double-quoted multi-file git add with one ignored path is still denied" {
    local payload='{"session_id":"s5","tool_name":"Bash","tool_input":{"command":"git add \"ignored.md\" \"allowed.md\""}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"ignored.md"* ]]
    [[ "$output" != *"allowed.md"* ]]
}

@test "true positive preserved under quoting: single-quoted multi-file git add with one ignored path is still denied" {
    local payload="{\"session_id\":\"s6\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add 'ignored.md' 'allowed.md'\"}}"
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"ignored.md"* ]]
    [[ "$output" != *"allowed.md"* ]]
}

# --- git commit -a系(ワイルドカード): tracked-but-ignoredの再検出 ---

@test "wildcard git commit -am detects tracked-but-ignored path and denies" {
    local payload='{"session_id":"s7","tool_name":"Bash","tool_input":{"command":"git commit -am wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"ignored.md"* ]]
}

# --- observeモード: denyせずWOULD-DENYを記録するのみ ---

@test "observe mode: quoted true positive is logged as WOULD-DENY but not blocked" {
    local payload='{"session_id":"s8","tool_name":"Bash","tool_input":{"command":"git add \"ignored.md\" \"allowed.md\""}}'
    run_guard "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY.*session=s8.*ignored.md" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- 実配線の確認(cmd_091標準) ---

@test "wiring: pretooluse_staged_ignore_guard.sh is registered in .claude/settings.json PreToolUse array" {
    run grep -n "pretooluse_staged_ignore_guard.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}
