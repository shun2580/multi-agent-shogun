#!/usr/bin/env bats
# 秘匿値pre-commitガード(scripts/pretooluse_secret_guard.sh、cmd_183-2建造)の
# ユニットテスト。subtask_181_F材料(検出パターンP1〜P4・誤検知リスク評価)に
# 基づく真陽性(合成ダミー値でDENY)・偽陽性回避(伏字プレースホルダ・命名例・
# 変数宣言・commitハッシュでALLOW)の双方向を、追加行のみを走査対象とする
# 挙動(削除行のみのcommitはALLOW)と合わせて検証する。
#
# 🔴実在の秘匿値は一切使わない。すべて無効な合成ダミー値。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GUARD_SCRIPT="$PROJECT_ROOT/scripts/pretooluse_secret_guard.sh"
    PYTHON_BIN="$PROJECT_ROOT/.venv/bin/python3"

    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/logs"
    LOG_FILE="$TEST_TMP/logs/secret_guard.log"

    SETTINGS_ENFORCE="$TEST_TMP/settings_enforce.yaml"
    SETTINGS_OBSERVE="$TEST_TMP/settings_observe.yaml"
    SETTINGS_OFF="$TEST_TMP/settings_off.yaml"

    cat > "$SETTINGS_ENFORCE" <<'EOF'
features:
  secret_guard_enabled: enforce
EOF
    cat > "$SETTINGS_OBSERVE" <<'EOF'
features:
  secret_guard_enabled: observe
EOF
    cat > "$SETTINGS_OFF" <<'EOF'
features:
  secret_guard_enabled: off
EOF

    REPO_DIR="$TEST_TMP/repo"
    mkdir -p "$REPO_DIR"
    git -C "$REPO_DIR" init -q
    git -C "$REPO_DIR" config user.email test@example.com
    git -C "$REPO_DIR" config user.name test
    printf 'base\n' > "$REPO_DIR/foo.txt"
    git -C "$REPO_DIR" add foo.txt
    git -C "$REPO_DIR" commit -qm base
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_guard() {
    local settings_file="$1"
    local payload="$2"
    run env \
        SECRET_GUARD_SETTINGS="$settings_file" \
        SECRET_GUARD_LOG="$LOG_FILE" \
        SECRET_GUARD_REPO_DIR="$REPO_DIR" \
        SECRET_GUARD_PYTHON="$PYTHON_BIN" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
}

stage_content() {
    # $1: file content to write (staged via git add)
    printf '%s\n' "$1" > "$REPO_DIR/foo.txt"
    git -C "$REPO_DIR" add foo.txt
}

# --- 早期リターン ---

@test "feature flag off: exits 0 with no output, no log written" {
    stage_content $'base\nDUMMY=sk-ant-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    local payload='{"tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_OFF" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "non-Bash tool: exits 0 with no log" {
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"foo.txt"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ ! -s "$LOG_FILE" ]
}

@test "Bash command without 'commit' substring: exits 0 with no log" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ ! -s "$LOG_FILE" ]
}

# --- 真陽性: 合成ダミー秘匿値形状 ---

@test "true positive P1: known-prefix dummy token in staged diff is denied" {
    stage_content $'base\nDUMMY_KEY="sk-ant-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'
    local payload='{"session_id":"tp1","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"foo.txt:2 (P1)"* ]]
    run grep -c "DENY.*session=tp1.*foo.txt:2 (P1)" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "true positive P2: high-entropy hex dummy value in staged diff is denied" {
    stage_content $'base\nleaked=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c'
    local payload='{"session_id":"tp2","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"(P2)"* ]]
}

@test "true positive P4: URL-embedded dummy token is denied" {
    stage_content $'base\ncurl "https://ntfy.sh/publish?topic=abcd1234efgh5678"'
    local payload='{"session_id":"tp4","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"(P4)"* ]]
}

@test "true positive: value never appears in deny message or log" {
    stage_content $'base\nDUMMY_KEY="sk-ant-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'
    local payload='{"session_id":"tpv","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" != *"sk-ant-AAAA"* ]]
    run grep -c "sk-ant-AAAA" "$LOG_FILE"
    [ "$output" -eq 0 ]
}

# --- 偽陽性回避: 伏字プレースホルダ・命名例・変数宣言・commitハッシュ ---

@test "false positive avoidance: bracketed placeholder <ntfy_topic旧値> is allowed" {
    stage_content $'base\nntfy_topic=<ntfy_topic旧値>'
    local payload='{"session_id":"fp1","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "false positive avoidance: bare variable declaration (no value) is allowed" {
    stage_content $'base\nconst apiKey: string = config.token'
    local payload='{"session_id":"fp2","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "false positive avoidance: default-argument declaration is allowed" {
    stage_content $'base\ndef get(self, token=None):'
    local payload='{"session_id":"fp3","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "false positive avoidance: 40-hex commit hash mention is allowed" {
    stage_content $'base\ncommit b1775d7dcb7d2e6f5a1c9e3b7f0a2d4c6e8f9a1b fixed the leak'
    local payload='{"session_id":"fp4","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "false positive avoidance: prose discussing the word 'token' is allowed" {
    stage_content $'base\nこのセクションでは秘匿値 token の記述禁止則について議論する'
    local payload='{"session_id":"fp5","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- 追加行のみ走査(対応事項1): 削除行のみのcommitはALLOW ---

@test "removal-only commit (secret being deleted) is allowed, not denied" {
    stage_content $'base\nDUMMY_KEY="sk-ant-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'
    git -C "$REPO_DIR" commit -qm "add secret for del test"
    stage_content 'base'
    local payload='{"session_id":"del1","tool_name":"Bash","tool_input":{"command":"git commit -m rmsecret"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- git commit -a系(ワイルドカード): working tree(未staged)差分も走査 ---

@test "wildcard git commit -am scans unstaged tracked changes and denies" {
    printf 'base\nDUMMY=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' > "$REPO_DIR/foo.txt"
    local payload='{"session_id":"am1","tool_name":"Bash","tool_input":{"command":"git commit -am wip"}}'
    run_guard "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"(P1)"* ]]
}

# --- observeモード: denyせずWOULD-DENYを記録するのみ ---

@test "observe mode: true positive is logged as WOULD-DENY but not blocked" {
    stage_content $'base\nDUMMY_KEY="sk-ant-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'
    local payload='{"session_id":"obs1","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_guard "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY.*session=obs1" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- 実配線の確認(cmd_091標準) ---

@test "wiring: pretooluse_secret_guard.sh is registered in .claude/settings.json PreToolUse array" {
    run grep -n "pretooluse_secret_guard.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}
