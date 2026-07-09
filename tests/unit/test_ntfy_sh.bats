#!/usr/bin/env bats
# test_ntfy_sh.bats — ntfy.sh fail-loud化 ユニットテスト
# T-NTFY-001: 正常系 (HTTP 200) → exit 0 + ntfy.log に OK記録
# T-NTFY-002: 異常系 (HTTP 400) → exit 1 + stderr出力 + ntfy.log に FAIL記録
# T-NTFY-003: curl通信失敗 → exit 1 + stderr出力 + ntfy.log に FAIL記録

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

    run bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
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

    run bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
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

    run bash "$MOCK_PROJECT/scripts/ntfy.sh" "テスト通知"
    [ "$status" -eq 1 ]
    [ -f "$MOCK_PROJECT/logs/ntfy.log" ]
    grep -q "FAIL" "$MOCK_PROJECT/logs/ntfy.log"
}
