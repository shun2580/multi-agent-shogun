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

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_sh_test.XXXXXX")"
    export MOCK_PROJECT="$TEST_TMPDIR/mock_project"
    export MOCK_BIN="$TEST_TMPDIR/mock_bin"

    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,logs}
    mkdir -p "$MOCK_BIN"

    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
ntfy_topic: "test-ntfy-topic-xyz"
YAML

    touch "$MOCK_PROJECT/config/ntfy_auth.env"

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
