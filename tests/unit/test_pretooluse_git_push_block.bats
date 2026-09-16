#!/usr/bin/env bats
# cmd_181-A: scripts/pretooluse_git_push_block.sh のheredoc誤検知根治テスト
# heredoc本体が非シェル実行シンク(cat/tee等)へのデータに過ぎない場合、そこに
# 「git push」という文字列がリテラルに現れてもDENYしないこと(失報側)、かつ
# 実際の未承認git pushコマンドは引き続きDENYされること(検出側)の双方を検証する。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GUARD_SCRIPT="$PROJECT_ROOT/scripts/pretooluse_git_push_block.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/logs"
    SETTINGS_ENFORCE="$TEST_TMP/settings_enforce.yaml"
    SETTINGS_OFF="$TEST_TMP/settings_off.yaml"
    LOG_FILE="$TEST_TMP/logs/git_push_block.log"
    NTFY_LOG="$TEST_TMP/ntfy.log"
    NTFY_STUB="$TEST_TMP/ntfy_stub.sh"
    APPROVAL_QUEUE="$TEST_TMP/approval_queue.md"

    cat > "$SETTINGS_ENFORCE" <<'EOF'
features:
  git_push_block_enabled: enforce
EOF
    cat > "$SETTINGS_OFF" <<'EOF'
features:
  git_push_block_enabled: off
EOF
    cat > "$APPROVAL_QUEUE" <<'EOF'
- ID: AQ-999 | 日付: 2026-08-27 | 操作内容: test entry
  状態: approved(2026-08-27・承認者: test)
- ID: AQ-998 | 日付: 2026-08-27 | 操作内容: not approved entry
  状態: 条件付きpending据置
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

run_guard_json() {
    local json_file="$1"
    local settings="${2:-$SETTINGS_ENFORCE}"
    run env \
        GIT_PUSH_BLOCK_SETTINGS="$settings" \
        GIT_PUSH_BLOCK_LOG="$LOG_FILE" \
        GIT_PUSH_BLOCK_APPROVAL_QUEUE="$APPROVAL_QUEUE" \
        GIT_PUSH_BLOCK_NTFY_SCRIPT="$NTFY_STUB" \
        bash -c "cat '$json_file' | bash '$GUARD_SCRIPT'"
}

write_payload() {
    local out_file="$1"
    local session_id="$2"
    local command="$3"
    "$PROJECT_ROOT/.venv/bin/python3" -c "
import json, sys
payload = {'session_id': sys.argv[1], 'tool_name': 'Bash', 'tool_input': {'command': sys.argv[2]}}
with open(sys.argv[3], 'w') as f:
    json.dump(payload, f)
" "$session_id" "$command" "$out_file"
}

# --- 早期リターン ---

@test "feature flag off: exits 0 with no output even for real git push command" {
    write_payload "$TEST_TMP/p.json" "s0" "git push origin main"
    run_guard_json "$TEST_TMP/p.json" "$SETTINGS_OFF"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- (i) heredoc誤検知の根治: 非シェル実行シンクへのheredoc本体は無視 ---

@test "heredoc to non-shell sink (cat) containing literal 'git push' text: ALLOW (no deny output)" {
    write_payload "$TEST_TMP/p.json" "s1" "$(printf "cat > /tmp/x.md <<'EOF'\ngit pushについて記す\nEOF")"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "^\[.*\] ALLOW .*session=s1 " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "heredoc to non-shell sink (cat >>) containing backtick-quoted 'git push --force' (cmd_180実例の再現): ALLOW" {
    write_payload "$TEST_TMP/p.json" "s1b" "$(printf "cat >> queue/shogun_to_karo.yaml <<'YAMLEOF'\n\`git push --force\`はD003で絶対禁止であり、履歴書換は統治判断である\nYAMLEOF")"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "heredoc to non-shell sink (tee) containing literal 'git push': ALLOW" {
    write_payload "$TEST_TMP/p.json" "s1c" "$(printf "tee /tmp/y.md <<'EOF'\ngit push memo\nEOF")"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- (ii) 失報側を守る: 真の未承認git pushは依然DENY ---

@test "real unapproved git push command (no heredoc involved): DENY" {
    write_payload "$TEST_TMP/p.json" "s2" "git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"no AQ_APPROVED_ID prefix found"* ]]
    run grep -c "^\[.*\] DENY .*session=s2 " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "real unapproved git push with unrelated AQ id not approved: DENY" {
    write_payload "$TEST_TMP/p.json" "s2b" "AQ_APPROVED_ID=AQ-998 git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"does not contain 'approved'"* ]]
}

@test "real git push with valid approved AQ id: ALLOW (regression check, unchanged behavior)" {
    write_payload "$TEST_TMP/p.json" "s3" "AQ_APPROVED_ID=AQ-999 git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "^\[.*\] ALLOW .*session=s3 " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "shell-exec heredoc (bash <<EOF) actually containing git push: still DENY (heredoc body IS executed here)" {
    write_payload "$TEST_TMP/p.json" "s4" "$(printf "bash <<'EOF'\ngit push origin main\nEOF")"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "command with no 'push' substring at all: exits 0 with no output (early return, no python startup)" {
    write_payload "$TEST_TMP/p.json" "s5" "echo hello world"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- cmd_194 工程5: 引用符内非実行文字列の偽陽性是正 ---

# (a) 実被弾repro: メッセージ引数の地の文にgit pushという語句が含まれる
#     だけのinbox_write.sh呼び出しはALLOWされる(是正確認・必須)。
@test "(a) inbox_write.sh with 'git push' mentioned in prose message argument: ALLOW (fix confirmation)" {
    write_payload "$TEST_TMP/p.json" "qa" 'bash scripts/inbox_write.sh shogun "git push --force はD003で絶対禁止である旨を家老へ再確認させたい" report_received karo'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "^\[.*\] ALLOW .*session=qa " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# (i) 安全な引用符の後に実push連結: 引用符マスクが後続の実コマンドまで
#     巻き添えで隠さないことの確認(最重要回帰ケース・必須)。
@test "(i) echo \"safe\" && git push origin main: DENY still triggers on the real push after a safe quoted arg" {
    write_payload "$TEST_TMP/p.json" "qi" 'echo "safe" && git push origin main'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# (e) 素のgit push(引用符関与なし): 回帰なくDENY維持(必須)。
@test "(e) plain unquoted git push origin main: DENY (no regression)" {
    write_payload "$TEST_TMP/p.json" "qe" 'git push origin main'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# (b) bash -c "git push ...": 実行される経路の引数は保護され続けDENY維持
#     (必須)。
@test "(b) bash -c \"git push origin main\": DENY (executed -c argument still detected)" {
    write_payload "$TEST_TMP/p.json" "qb" 'bash -c "git push origin main"'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# (c) sh -c 'git push': シングルクォート版でも同様にDENY維持。
@test "(c) sh -c 'git push': DENY (executed -c argument, single-quoted)" {
    write_payload "$TEST_TMP/p.json" "qc" "sh -c 'git push'"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# (d) eval "git push ...": evalの引数もDENY維持。
@test "(d) eval \"git push origin main\": DENY (eval argument still detected)" {
    write_payload "$TEST_TMP/p.json" "qd" 'eval "git push origin main"'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# (f) AQ_APPROVED_ID prefix付き素push: 承認判定レイヤーに影響しないこと
#     (未承認AQなのでDENY維持、回帰なし)。
@test "(f) AQ_APPROVED_ID=AQ-999 git push origin main: still detected then ALLOW via approval (regression check)" {
    write_payload "$TEST_TMP/p.json" "qf" 'AQ_APPROVED_ID=AQ-999 git push origin main'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# (h) 同一segment内に複数の引用符引数、片方にgit push含む: ALLOW。
@test "(h) multiple quoted args in one segment, one mentions git push in prose: ALLOW" {
    write_payload "$TEST_TMP/p.json" "qh" 'bash scripts/inbox_write.sh shogun "safe text" "git push is mentioned here in prose" report_received karo'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# (j) -cの前に無関係フラグ: bash --norc -c "git push"はそれでもDENY維持。
@test "(j) bash --norc -c \"git push\": DENY (unrelated flag before -c does not break arming)" {
    write_payload "$TEST_TMP/p.json" "qj" 'bash --norc -c "git push"'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# (k) curl -c cookiejar.txt "...git push...": shell-exec系でないコマンドの
#     -cで誤ってarmしない(過剰保護の誤りが無いことの確認)。
@test "(k) curl -c cookiejar.txt \"...git push...\": ALLOW (curl's -c must not falsely arm exec protection)" {
    write_payload "$TEST_TMP/p.json" "qk" 'curl -c cookiejar.txt "please do not git push this, just a data string"'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
