#!/usr/bin/env bats
# test_ntfy_sh.bats — ntfy.sh fail-loud化 ユニットテスト
# T-NTFY-001: 正常系 (HTTP 200) → exit 0 + ntfy.log に OK記録
# T-NTFY-002: 異常系 (HTTP 400) → exit 1 + stderr出力 + ntfy.log に FAIL記録
# T-NTFY-003: curl通信失敗 → exit 1 + stderr出力 + ntfy.log に FAIL記録
# T-NTFY-004: NTFY_DRY_RUN=1 → curl未実行・実送信なし・DRY-RUN記録・exit 0 (cmd_119)
# T-NTFY-005: NTFY_DRY_RUN未設定(既定) → 従来どおり実送信される (cmd_119)
# T-NTFY-006: __PREFLIGHT_TESTING__=1継承 → 自動でdry-run抑止される (cmd_119)
# T-NTFY-007: __INBOX_WATCHER_TESTING__=1継承 → 自動でdry-run抑止される (cmd_119)
#
# cmd_122: 設計反転(マーカー列挙→本番リポジトリ外からの呼び出しは既定で抑止)。
# 上記T-NTFY-001/002/003/005/006/007は「本番リポジトリ内(MOCK_PROJECT配下)から
# 呼ばれた」ことを`env -C "$MOCK_PROJECT"`で固定して検証する(cmd_122で追加した
# CWD判定ロジックが誤って本来の送信まで抑止しないことの回帰確認)。
# T-NTFY-008: 隔離パス(リポジトリ外CWD)から呼ぶと、マーカー未設定でも自動でdry-run抑止される (cmd_122)
# T-NTFY-009: 本番リポジトリ配下のCWDから呼ぶと、従来どおり実送信される (cmd_122)
#
# cmd_213: topic/認証は ~/.config/multi-agent-shogun/secrets.env (テストでは
# SHOGUN_SECRETS_FILE でダミー値の一時ファイルに差し替え) から読む。
# T-NTFY-010: secrets.env 不在 → 非0 + stderrに理由 + topic値/パスの秘匿値を出さない
# T-NTFY-011: NTFY_TOPIC 空 → 非0 + stderrに理由
# T-NTFY-012: ダミーtopicが通知先URLに使われる(curlスタブで検証)・ntfy.logにtopic値は出ない
# T-NTFY-013: 余計な式を含む secrets.env を実行しない(sourceでなくパース)
# T-NTFY-014: settings.yaml の ntfy_topic は読まれない(旧方式への fallback なし)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_sh_test.XXXXXX")"
    export MOCK_PROJECT="$TEST_TMPDIR/mock_project"
    export MOCK_BIN="$TEST_TMPDIR/mock_bin"

    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,logs}
    mkdir -p "$MOCK_BIN"

    # cmd_213: 秘匿値はダミーの secrets.env (SHOGUN_SECRETS_FILE で差し替え)
    export SHOGUN_SECRETS_FILE="$TEST_TMPDIR/secrets.env"
    export DUMMY_TOPIC="test-ntfy-topic-xyz"
    printf 'NTFY_TOPIC=%s\n' "$DUMMY_TOPIC" > "$SHOGUN_SECRETS_FILE"

    # 本物のntfy_auth.shをコピー
    cp "$PROJECT_ROOT/lib/ntfy_auth.sh" "$MOCK_PROJECT/lib/"

    # ntfy.shをコピーしてSCRIPT_DIRをMOCK_PROJECTに差し替え
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$MOCK_PROJECT\"|" \
        "$PROJECT_ROOT/scripts/ntfy.sh" \
        > "$MOCK_PROJECT/scripts/ntfy.sh"
    chmod +x "$MOCK_PROJECT/scripts/ntfy.sh"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# T-NTFY-001: 正常系 — HTTP 200 → exit 0 + ntfy.log に OK記録
@test "T-NTFY-001: HTTP 200 response exits 0 and logs OK" {
    # mock curl: HTTP 200を返す
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
# -w "%{http_code}" オプションの出力を模倣
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_PROJECT/logs/ntfy.log" ]
    grep -q "OK" "$MOCK_PROJECT/logs/ntfy.log"
    grep -q "HTTP 200" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-002: 異常系 — HTTP 400 → exit 1 + stderr + ntfy.log に FAIL記録
@test "T-NTFY-002: HTTP 400 response exits 1 and logs FAIL" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
echo "400"
CURL
    chmod +x "$MOCK_BIN/curl"

    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 1 ]
    [ -f "$MOCK_PROJECT/logs/ntfy.log" ]
    grep -q "FAIL" "$MOCK_PROJECT/logs/ntfy.log"
    grep -q "HTTP 400" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-003: curl通信失敗 → exit 1 + stderr + ntfy.log に FAIL記録
@test "T-NTFY-003: curl failure exits 1 and logs FAIL" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
exit 6
CURL
    chmod +x "$MOCK_BIN/curl"

    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 1 ]
    [ -f "$MOCK_PROJECT/logs/ntfy.log" ]
    grep -q "FAIL" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-004: NTFY_DRY_RUN=1 → curl未実行・DRY-RUN記録・exit 0
@test "T-NTFY-004: NTFY_DRY_RUN=1 suppresses real send" {
    # curlが呼ばれたら即座に検知できるよう、呼ばれた場合はマーカーファイルを作成して失敗させる
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
touch "$MOCK_PROJECT/CURL_WAS_CALLED"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    NTFY_DRY_RUN=1 run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    [ ! -f "$MOCK_PROJECT/CURL_WAS_CALLED" ]
    [ -f "$MOCK_PROJECT/logs/ntfy.log" ]
    grep -q "DRY-RUN" "$MOCK_PROJECT/logs/ntfy.log"
    ! grep -q "OK (HTTP" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-005: NTFY_DRY_RUN未設定(既定) → 従来どおり実送信される(回帰なし確認)
@test "T-NTFY-005: no dry-run env vars set → real send still happens as before" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    unset NTFY_DRY_RUN __PREFLIGHT_TESTING__ __INBOX_WATCHER_TESTING__
    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_PROJECT/logs/ntfy.log" ]
    grep -q "OK (HTTP 200)" "$MOCK_PROJECT/logs/ntfy.log"
    ! grep -q "DRY-RUN" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-006: __PREFLIGHT_TESTING__=1 継承(preflight_check.shのテストからの実漏出経路) → 自動dry-run
@test "T-NTFY-006: inherited __PREFLIGHT_TESTING__=1 auto-suppresses real send" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
touch "$MOCK_PROJECT/CURL_WAS_CALLED"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    __PREFLIGHT_TESTING__=1 run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    [ ! -f "$MOCK_PROJECT/CURL_WAS_CALLED" ]
    grep -q "DRY-RUN" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-007: __INBOX_WATCHER_TESTING__=1 継承 → 自動dry-run
@test "T-NTFY-007: inherited __INBOX_WATCHER_TESTING__=1 auto-suppresses real send" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
touch "$MOCK_PROJECT/CURL_WAS_CALLED"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    __INBOX_WATCHER_TESTING__=1 run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    [ ! -f "$MOCK_PROJECT/CURL_WAS_CALLED" ]
    grep -q "DRY-RUN" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-008: 隔離パス(リポジトリ外CWD)から呼ぶと、マーカー未設定でも自動でdry-run抑止される(cmd_122)
@test "T-NTFY-008: called from outside the repo (isolated CWD) auto-suppresses even without markers" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
touch "$MOCK_PROJECT/CURL_WAS_CALLED"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    # yaml_guardの隔離セッション試験を模す: CWDがMOCK_PROJECT(本番相当)の外
    # (TEST_TMPDIR直下、mktemp -dで作った一時ディレクトリ相当)にある状態で
    # ntfy.shを呼ぶ。マーカーは一切設定しない。
    unset NTFY_DRY_RUN __PREFLIGHT_TESTING__ __INBOX_WATCHER_TESTING__
    run env -C "$TEST_TMPDIR" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    [ ! -f "$MOCK_PROJECT/CURL_WAS_CALLED" ]
    [ -f "$MOCK_PROJECT/logs/ntfy.log" ]
    grep -q "DRY-RUN" "$MOCK_PROJECT/logs/ntfy.log"
    ! grep -q "OK (HTTP" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-009: 本番リポジトリ配下のCWDから呼ぶと、従来どおり実送信される(cmd_122・回帰確認)
@test "T-NTFY-009: called from within the repo root (production CWD) still sends for real" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
touch "$MOCK_PROJECT/CURL_WAS_CALLED"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    unset NTFY_DRY_RUN __PREFLIGHT_TESTING__ __INBOX_WATCHER_TESTING__
    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    [ -f "$MOCK_PROJECT/CURL_WAS_CALLED" ]
    grep -q "OK (HTTP 200)" "$MOCK_PROJECT/logs/ntfy.log"
    ! grep -q "DRY-RUN" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-010: secrets.env が無い → 非0 + stderrに理由(値は出さない)・curl未実行
@test "T-NTFY-010: missing secrets.env fails loud (non-zero, reason on stderr, no secret values)" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
touch "$MOCK_PROJECT/CURL_WAS_CALLED"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    export SHOGUN_SECRETS_FILE="$TEST_TMPDIR/does_not_exist.env"
    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -ne 0 ]
    [[ "$output" == *"secrets.env not found"* ]]
    [[ "$output" != *"$DUMMY_TOPIC"* ]]
    [ ! -f "$MOCK_PROJECT/CURL_WAS_CALLED" ]
}

# T-NTFY-011: NTFY_TOPIC が空 → 非0 + stderrに理由
@test "T-NTFY-011: empty NTFY_TOPIC fails loud (non-zero, reason on stderr)" {
    printf 'NTFY_TOPIC=\n' > "$SHOGUN_SECRETS_FILE"
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
touch "$MOCK_PROJECT/CURL_WAS_CALLED"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC is not set"* ]]
    [ ! -f "$MOCK_PROJECT/CURL_WAS_CALLED" ]
}

# T-NTFY-012: ダミーtopicがURLに使われ、ntfy.log/画面にtopic値が出ない
@test "T-NTFY-012: dummy topic from secrets.env is used in the target URL but never logged" {
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
echo "$@" > "$MOCK_PROJECT/curl_args.txt"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    unset NTFY_DRY_RUN __PREFLIGHT_TESTING__ __INBOX_WATCHER_TESTING__
    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    grep -qF "https://ntfy.sh/$DUMMY_TOPIC" "$MOCK_PROJECT/curl_args.txt"
    [[ "$output" != *"$DUMMY_TOPIC"* ]]
    ! grep -qF "$DUMMY_TOPIC" "$MOCK_PROJECT/logs/ntfy.log"

    # dry-run経路のログにも出ない
    NTFY_DRY_RUN=1 run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    ! grep -qF "$DUMMY_TOPIC" "$MOCK_PROJECT/logs/ntfy.log"
}

# T-NTFY-013: 余計な式を含む secrets.env は実行されない(source でなくパース)
@test "T-NTFY-013: secrets.env with extra expressions is parsed, never executed" {
    local marker="$TEST_TMPDIR/PWNED"
    cat > "$SHOGUN_SECRETS_FILE" << EOF
touch "$marker"
\$(touch "$marker")
echo injected
NTFY_TOPIC="$DUMMY_TOPIC"
EOF
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
echo "$@" > "$MOCK_PROJECT/curl_args.txt"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    unset NTFY_DRY_RUN __PREFLIGHT_TESTING__ __INBOX_WATCHER_TESTING__
    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 0 ]
    [ ! -e "$marker" ]
    [[ "$output" != *"injected"* ]]
    grep -qF "https://ntfy.sh/$DUMMY_TOPIC" "$MOCK_PROJECT/curl_args.txt"
}

# T-NTFY-014: settings.yaml の ntfy_topic は読まれない(旧方式への fallback なし)
@test "T-NTFY-014: settings.yaml ntfy_topic is ignored (no fallback to the old location)" {
    printf 'ntfy_topic: "legacy-topic-from-settings"\n' > "$MOCK_PROJECT/config/settings.yaml"
    export SHOGUN_SECRETS_FILE="$TEST_TMPDIR/does_not_exist.env"
    cat > "$MOCK_BIN/curl" << 'CURL'
#!/bin/bash
touch "$MOCK_PROJECT/CURL_WAS_CALLED"
echo "200"
CURL
    chmod +x "$MOCK_BIN/curl"

    run env -C "$MOCK_PROJECT" bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -ne 0 ]
    [ ! -f "$MOCK_PROJECT/CURL_WAS_CALLED" ]
}
