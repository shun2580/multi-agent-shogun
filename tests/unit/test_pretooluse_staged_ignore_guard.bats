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

    # cmd_186根治検証用: 「他リポジトリ」を模した第2の隔離git repo。
    # whitelist型ではなく通常型(ignoreパスのみ列挙)の.gitignoreを持つ点が
    # REPO_DIR(shogun模擬)との違い。
    OTHER_REPO_DIR="$TEST_TMP/other_repo"
    mkdir -p "$OTHER_REPO_DIR/docs"
    git -C "$OTHER_REPO_DIR" init -q
    cat > "$OTHER_REPO_DIR/.gitignore" <<'EOF'
docs/
EOF
    echo "own-ignored" > "$OTHER_REPO_DIR/docs/notes.md"
    echo "own-allowed" > "$OTHER_REPO_DIR/allowed_other.md"
    git -C "$OTHER_REPO_DIR" add -f .gitignore allowed_other.md
    git -C "$OTHER_REPO_DIR" add -f docs/notes.md

    NOT_A_REPO_DIR="$TEST_TMP/not_a_repo"
    mkdir -p "$NOT_A_REPO_DIR"
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

# cmd_186根治検証用: STAGED_IGNORE_GUARD_REPO_DIRを設定せず、payloadのcwdから
# 実リポジトリを解決させる経路を通す(本番のhook呼び出しを模す)。
run_guard_cwd() {
    local settings_file="$1"
    local payload="$2"
    run env \
        STAGED_IGNORE_GUARD_SETTINGS="$settings_file" \
        STAGED_IGNORE_GUARD_LOG="$LOG_FILE" \
        STAGED_IGNORE_GUARD_PYTHON="$PYTHON_BIN" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
}

# cmd_186_2根治検証用(欠陥2・欠陥3): payloadにシェル引用符の衝突を起こしうる
# 文字(二重引用符・改行を含むheredoc本体等)が含まれるケースは、bats単一行
# 文字列へのエスケープ埋め込みでは事故りやすいため、python3のjson.dumpsで
# JSONファイルへ正規に書き出してから読み込ませる。
run_guard_command_file() {
    local settings_file="$1"
    local command="$2"
    local session_id="$3"
    local extra_cwd="${4:-}"
    local payload_file="$TEST_TMP/payload_$session_id.json"
    COMMAND="$command" SESSION_ID="$session_id" EXTRA_CWD="$extra_cwd" "$PYTHON_BIN" -c '
import json, os
payload = {
    "session_id": os.environ["SESSION_ID"],
    "tool_name": "Bash",
    "tool_input": {"command": os.environ["COMMAND"]},
}
if os.environ.get("EXTRA_CWD"):
    payload["cwd"] = os.environ["EXTRA_CWD"]
print(json.dumps(payload))
' > "$payload_file"
    run env \
        STAGED_IGNORE_GUARD_SETTINGS="$settings_file" \
        STAGED_IGNORE_GUARD_LOG="$LOG_FILE" \
        STAGED_IGNORE_GUARD_REPO_DIR="$REPO_DIR" \
        STAGED_IGNORE_GUARD_PYTHON="$PYTHON_BIN" \
        bash -c "cat '$payload_file' | bash '$GUARD_SCRIPT'"
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

# --- cmd_186根治: cwdからのREPO_DIR解決(常にmulti-agent-shogunの.gitignoreで
# 判定していた欠陥の回帰防止) ---

@test "cmd_186 fix (i): cwd-resolved 'home' repo still denies its own intentionally-ignored tracked path (no regression)" {
    local payload="{\"session_id\":\"cmd186-i\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add ignored.md\"},\"cwd\":\"$REPO_DIR\"}"
    run_guard_cwd "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"ignored.md"* ]]
}

@test "cmd_186 fix (ii): cwd-resolved other repo allows its own legitimate staging (previously false-DENY via shogun .gitignore)" {
    local payload="{\"session_id\":\"cmd186-ii\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add allowed_other.md\"},\"cwd\":\"$OTHER_REPO_DIR\"}"
    run_guard_cwd "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW.*session=cmd186-ii" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_186 fix (iii): cwd-resolved other repo denies a path ignored by ITS OWN .gitignore (not shogun's)" {
    local payload="{\"session_id\":\"cmd186-iii\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add docs/notes.md\"},\"cwd\":\"$OTHER_REPO_DIR\"}"
    run_guard_cwd "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"docs/notes.md"* ]]
}

@test "cmd_186 fix: unresolvable repo (cwd not inside any git repo) fails safe and allows (does not deny)" {
    local payload="{\"session_id\":\"cmd186-failsafe\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add whatever.md\"},\"cwd\":\"$NOT_A_REPO_DIR\"}"
    run_guard_cwd "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW(unresolved-repo).*session=cmd186-failsafe" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- cmd_186_2根治(欠陥2): heredoc/散文誤検知 ---
# 実インシデント(logs/staged_ignore_guard.log 2026-08-27T23:07:57/23:10:45):
# `MSG=$(cat <<'EOF' ... EOF)` のような非シェル実行sink(cat)向けheredoc本体
# 中の地の文(インシデント説明文等)に「git add」という文字列がリテラルに
# 現れただけで誤ってdenyされていた。

@test "cmd_186_2 fix (defect2): heredoc body piped to non-shell sink (cat) containing literal 'git add' prose text is allowed (regression: 2026-08-27 23:07/23:10 false-DENY)" {
    local cmd
    cmd=$'MSG=$(cat <<\'EOF\'\nincident notes: running \'git add somefile.txt\' failed with a permission error, see log.\nEOF\n)\nbash scripts/inbox_write.sh karo "$MSG" cmd_new shogun'
    run_guard_command_file "$SETTINGS_ENFORCE" "$cmd" "defect2-allow"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW.*session=defect2-allow" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "cmd_186_2 fix (defect2 regression guard): heredoc body actually executed by a shell sink (bash <<EOF) still triggers real 'git add' detection and denies" {
    local cmd
    cmd=$'bash <<\'EOF\'\ncd '"$REPO_DIR"$'\ngit add ignored.md\nEOF'
    run_guard_command_file "$SETTINGS_ENFORCE" "$cmd" "defect2-deny"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"ignored.md"* ]]
}

# --- cmd_186_2根治(欠陥3): JSON非エスケープによるfail-open ---
# 是正前は理由文字列をシェルのheredocで手組み展開していたため、staged path
# 名に二重引用符が混入するとJSON構文が壊れ、hookの出力パーサがdeny決定を
# 読み取れず黙ってfail-openする経路があった(denyの意思が消える)。

@test "cmd_186_2 fix (defect3): staged path containing a double-quote still denies AND produces valid, parseable JSON (no silent fail-open)" {
    run_guard_command_file "$SETTINGS_ENFORCE" 'git add '"'"'weird"quote.md'"'"'' "defect3"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    # $outputをpythonソースへ文字列リテラルとして埋め込むと二重エスケープ
    # 事故(バックスラッシュがpython側の文字列リテラル解釈で先に剥がれ、JSON
    # パーサに渡る前にエスケープが壊れる)を起こすため、stdin経由の
    # json.load(生バイト読み込み)で渡す。
    printf '%s' "$output" > "$TEST_TMP/defect3_output.json"
    run "$PYTHON_BIN" -c "
import json, sys
with open('$TEST_TMP/defect3_output.json') as f:
    d = json.load(f)
assert d['hookSpecificOutput']['permissionDecision'] == 'deny'
assert 'weird\"quote.md' in d['hookSpecificOutput']['permissionDecisionReason']
print('PARSE_OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PARSE_OK"* ]]
}

# --- 実配線の確認(cmd_091標準) ---

@test "wiring: pretooluse_staged_ignore_guard.sh is registered in .claude/settings.json PreToolUse array" {
    run grep -n "pretooluse_staged_ignore_guard.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}
