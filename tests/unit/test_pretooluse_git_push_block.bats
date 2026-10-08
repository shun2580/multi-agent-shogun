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
    SETTINGS_OBSERVE="$TEST_TMP/settings_observe.yaml"
    LOG_FILE="$TEST_TMP/logs/git_push_block.log"
    NTFY_LOG="$TEST_TMP/ntfy.log"
    NTFY_STUB="$TEST_TMP/ntfy_stub.sh"
    APPROVAL_LEDGER="$TEST_TMP/decisions_journal.md"

    cat > "$SETTINGS_ENFORCE" <<'EOF'
features:
  git_push_block_enabled: enforce
EOF
    cat > "$SETTINGS_OFF" <<'EOF'
features:
  git_push_block_enabled: off
EOF
    cat > "$SETTINGS_OBSERVE" <<'EOF'
features:
  git_push_block_enabled: observe
EOF
    # cmd_210: 承認台帳はもはや判定に使われない。「在っても判定が変わらない」
    # ことを検証するため、旧方式で承認扱いになっていたエントリ入りの台帳を置く。
    cat > "$APPROVAL_LEDGER" <<'EOF'
2026-01-01T00:00:00 | PUSH-APPROVED | P-999 | test fixture | 出典: test
2026-01-01T00:00:00 | RULE | some rule that happens to mention P-01 in its body text | 出典: test
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
        GIT_PUSH_BLOCK_NTFY_SCRIPT="$NTFY_STUB" \
        bash -c "cat '$json_file' | bash '$GUARD_SCRIPT'"
}

# cmd_210: 殿が環境(フックのプロセス環境)に PUSH_APPROVED=1 を立てた実行。
run_guard_json_approved() {
    local json_file="$1"
    local settings="${2:-$SETTINGS_ENFORCE}"
    run env \
        PUSH_APPROVED=1 \
        GIT_PUSH_BLOCK_SETTINGS="$settings" \
        GIT_PUSH_BLOCK_LOG="$LOG_FILE" \
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
    [[ "$output" == *"PUSH_APPROVED=1 is not set in the hook process environment"* ]]
    run grep -c "^\[.*\] DENY .*session=s2 " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "legacy PUSH_APPROVED_ID=P-998 prefix (no journal entry): DENY" {
    write_payload "$TEST_TMP/p.json" "s2b" "PUSH_APPROVED_ID=P-998 git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"PUSH_APPROVED=1 is not set in the hook process environment"* ]]
}

@test "legacy PUSH_APPROVED_ID=P-999 prefix even though the journal has a matching PUSH-APPROVED entry: DENY (journal no longer consulted)" {
    write_payload "$TEST_TMP/p.json" "s3" "PUSH_APPROVED_ID=P-999 git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    run grep -c "^\[.*\] DENY .*session=s3 " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "PUSH_APPROVED=1 set in the hook process environment: git push ALLOW" {
    write_payload "$TEST_TMP/p.json" "s3b" "git push origin main"
    run_guard_json_approved "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "^\[.*\] ALLOW .*session=s3b " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "PUSH_APPROVED=1 prefixed on the command string only (not in environment): DENY" {
    write_payload "$TEST_TMP/p.json" "s3c" "PUSH_APPROVED=1 git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "export/env-style command-string forms of PUSH_APPROVED=1 (export ...; / env ...): DENY" {
    write_payload "$TEST_TMP/p.json" "s3d" "export PUSH_APPROVED=1; git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    write_payload "$TEST_TMP/p2.json" "s3e" "env PUSH_APPROVED=1 git push origin main"
    run_guard_json "$TEST_TMP/p2.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "environment PUSH_APPROVED set to a value other than 1 (0 / empty / true / yes): DENY" {
    write_payload "$TEST_TMP/p.json" "s3f" "git push origin main"
    for v in 0 "" true yes; do
        run env PUSH_APPROVED="$v" \
            GIT_PUSH_BLOCK_SETTINGS="$SETTINGS_ENFORCE" \
            GIT_PUSH_BLOCK_LOG="$LOG_FILE" \
            GIT_PUSH_BLOCK_NTFY_SCRIPT="$NTFY_STUB" \
            bash -c "cat '$TEST_TMP/p.json' | bash '$GUARD_SCRIPT'"
        [ "$status" -eq 0 ]
        [[ "$output" == *'"permissionDecision": "deny"'* ]]
    done
}

@test "git push in a compound command, no env approval: DENY" {
    write_payload "$TEST_TMP/p.json" "s3g" "git status && git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "git push in a compound command, with env approval: ALLOW" {
    write_payload "$TEST_TMP/p.json" "s3h" "git status && git push origin main"
    run_guard_json_approved "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "non-push compound command with no env approval: ALLOW (unaffected)" {
    write_payload "$TEST_TMP/p.json" "s3i" "git status && git log --oneline | head -3"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- off|observe|enforce の3値 ---

@test "observe mode: unapproved git push is NOT denied, logged WOULD-DENY" {
    write_payload "$TEST_TMP/p.json" "so1" "git push origin main"
    run_guard_json "$TEST_TMP/p.json" "$SETTINGS_OBSERVE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "^\[.*\] WOULD-DENY .*session=so1 " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "observe mode: env-approved git push is ALLOW (no WOULD-DENY)" {
    write_payload "$TEST_TMP/p.json" "so2" "git push origin main"
    run_guard_json_approved "$TEST_TMP/p.json" "$SETTINGS_OBSERVE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY .*session=so2 " "$LOG_FILE"
    [ "$output" -eq 0 ]
}

@test "off mode: env-less git push passes through untouched" {
    write_payload "$TEST_TMP/p.json" "so3" "git push origin main"
    run_guard_json "$TEST_TMP/p.json" "$SETTINGS_OFF"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- 承認台帳(decisions_journal.md)非依存 ---

@test "ledger absent: verdict unchanged (unapproved DENY / env-approved ALLOW)" {
    rm -f "$APPROVAL_LEDGER"
    write_payload "$TEST_TMP/p.json" "sl1" "git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    run_guard_json_approved "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "ledger present with a PUSH-APPROVED entry: verdict unchanged (unapproved still DENY, env-approved ALLOW)" {
    grep -q "PUSH-APPROVED" "$APPROVAL_LEDGER"
    write_payload "$TEST_TMP/p.json" "sl2" "git push origin main"
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    run_guard_json_approved "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "script no longer contains any approval-ledger code" {
    run grep -c -E "APPROVAL_LEDGER|journal_text|entry_re|PUSH-APPROVED" "$GUARD_SCRIPT"
    [ "$output" -eq 0 ]
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

# (f) PUSH_APPROVED_ID prefix付き素push: 旧方式の接頭辞は承認として効かない
#     (cmd_210: 環境変数方式へ単純化)。検出自体は従来どおり行われDENY。
@test "(f) PUSH_APPROVED_ID=P-999 git push origin main: still detected, DENY (legacy prefix no longer approves)" {
    write_payload "$TEST_TMP/p.json" "qf" 'PUSH_APPROVED_ID=P-999 git push origin main'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
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

# --- cmd_198 S-05 → cmd_210: 台帳非依存化に伴う書き換え ---

# 新規1(旧: 台帳が読めない→fail-safe deny): 台帳は判定に使われないため、
# 台帳が読めなくても環境変数承認ならALLOW、承認なしならDENYのまま。
@test "(new-1) decisions_journal.md unreadable (permission denied): verdict unchanged (DENY unapproved / ALLOW env-approved)" {
    chmod 000 "$APPROVAL_LEDGER"
    write_payload "$TEST_TMP/p.json" "qn1" 'git push origin main'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" != *"failed to read decisions_journal.md"* ]]
    run_guard_json_approved "$TEST_TMP/p.json"
    chmod 644 "$APPROVAL_LEDGER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# 新規2(旧: 本文言及のみのトークンは承認と誤判定しない): 旧接頭辞はそもそも
# 無視されるためDENY。
@test "(new-2) legacy token PUSH_APPROVED_ID=P-01 (mentioned only in prose in the ledger): DENY" {
    write_payload "$TEST_TMP/p.json" "qn2" 'PUSH_APPROVED_ID=P-01 git push origin main'
    run_guard_json "$TEST_TMP/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}
