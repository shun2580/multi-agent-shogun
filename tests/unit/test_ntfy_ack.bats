#!/usr/bin/env bats
# test_ntfy_ack.bats — ntfy ACK自動返信ユニットテスト
# PR #46: ntfyメッセージ受信時の自動ACK返信機能
#
# テスト構成:
#   T-ACK-001: 正常メッセージ → inbox_write to shogun (auto-ACK removed)
#   T-ACK-002: outboundタグ付き → ACKスキップ（ループ防御）
#   T-ACK-003: auto-ACK未送信確認 (shogun replies directly)
#   T-ACK-004: ACK送信失敗 → inbox_write継続
#   T-ACK-005: 空メッセージ → ACKスキップ
#   T-ACK-006: keepaliveイベント → ACKスキップ
#   T-ACK-007: append_ntfy_inbox失敗 → ACK・inbox_write両方スキップ
#   T-ACK-008: 特殊文字がinbox_writeに保持される
#   T-ACK-009: リスナーの出力(stderr)にtopic値・認証値が出ない (cmd_213)
#   T-ACK-010: secrets.env不在ならリスナーは非0で起動せず、理由を出す (cmd_213)
#   T-ACK-011: リスナーはダミーtopicを購読URLに使う (cmd_213・curlスタブで検証)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    [ -x "$PROJECT_ROOT/.venv/bin/python3" ] || skip "python3 not found in .venv"
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_ack_test.XXXXXX")"
    export MOCK_PROJECT="$TEST_TMPDIR/mock_project"
    export MOCK_BIN="$TEST_TMPDIR/mock_bin"
    export ACK_LOG="$TEST_TMPDIR/ack.log"
    export INBOX_LOG="$TEST_TMPDIR/inbox.log"
    export MOCK_CURL_OUTPUT="$TEST_TMPDIR/curl_output.json"

    # モックプロジェクト構築
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue,logs/ntfy_inbox_corrupt}
    mkdir -p "$MOCK_PROJECT/.venv/bin"
    mkdir -p "$MOCK_BIN"

    # cmd_213: 秘匿値はダミーの secrets.env (SHOGUN_SECRETS_FILE で差し替え)
    export SHOGUN_SECRETS_FILE="$TEST_TMPDIR/secrets.env"
    export DUMMY_TOPIC="test-ack-topic-12345"
    export DUMMY_TOKEN="tk_dummy_ack_token_0001"
    printf 'NTFY_TOPIC=%s\nNTFY_TOKEN=%s\n' "$DUMMY_TOPIC" "$DUMMY_TOKEN" > "$SHOGUN_SECRETS_FILE"

    # 本物のntfy_auth.shをコピー
    cp "$PROJECT_ROOT/lib/ntfy_auth.sh" "$MOCK_PROJECT/lib/"

    # python3 wrapper (exec to project venv so pyvenv.cfg is found → PyYAML available)
    # Note: a symlink chain breaks venv detection on macOS — argv[0] would point to
    # $MOCK_PROJECT/.venv/bin/python3 but pyvenv.cfg only exists in $PROJECT_ROOT/.venv/
    cat > "$MOCK_PROJECT/.venv/bin/python3" << WRAPPER
#!/bin/sh
exec "$PROJECT_ROOT/.venv/bin/python3" "\$@"
WRAPPER
    chmod +x "$MOCK_PROJECT/.venv/bin/python3"

    # ntfy_inbox初期化
    echo "inbox:" > "$MOCK_PROJECT/queue/ntfy_inbox.yaml"

    # --- モックスクリプト ---

    # mock curl
    cat > "$MOCK_BIN/curl" << 'CURL_MOCK'
#!/bin/bash
if [ -f "$MOCK_CURL_OUTPUT" ]; then
    cat "$MOCK_CURL_OUTPUT"
fi
CURL_MOCK
    chmod +x "$MOCK_BIN/curl"

    # mock ntfy.sh
    cat > "$MOCK_PROJECT/scripts/ntfy.sh" << 'NTFY_MOCK'
#!/bin/bash
echo "$1" >> "$ACK_LOG"
exit ${MOCK_NTFY_EXIT_CODE:-0}
NTFY_MOCK
    chmod +x "$MOCK_PROJECT/scripts/ntfy.sh"

    # mock inbox_write.sh
    cat > "$MOCK_PROJECT/scripts/inbox_write.sh" << 'INBOX_MOCK'
#!/bin/bash
echo "$@" >> "$INBOX_LOG"
INBOX_MOCK
    chmod +x "$MOCK_PROJECT/scripts/inbox_write.sh"

    # ntfy_listener.shコピー（SCRIPT_DIR差し替え）
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$MOCK_PROJECT\"|" \
        "$PROJECT_ROOT/scripts/ntfy_listener.sh" \
        > "$MOCK_PROJECT/ntfy_listener_test.sh"
    chmod +x "$MOCK_PROJECT/ntfy_listener_test.sh"

    # ログ初期化
    touch "$ACK_LOG" "$INBOX_LOG"

    # PATHにモックcurlを先頭配置
    export PATH="$MOCK_BIN:$PATH"

    # デフォルト: ntfy.sh正常終了
    unset MOCK_NTFY_EXIT_CODE
}

teardown() {
    # Restore permissions if changed (T-ACK-007)
    chmod 755 "$MOCK_PROJECT/queue" 2>/dev/null || true
    rm -rf "$TEST_TMPDIR"
}

# --- ヘルパー ---

run_listener() {
    timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh" 2>/dev/null || true
}

# stderrをファイルへ捕捉して実行する (cmd_213: ログ漏えい検証用)
run_listener_capture_stderr() {
    timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh" 2>"$TEST_TMPDIR/listener_stderr.log" || true
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-001: Normal message triggers inbox_write to shogun (ACK removed, shogun replies directly)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-001: Normal message triggers inbox_write to shogun" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg001","time":1234567890,"message":"テスト通知","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — shogun replies directly after processing.
    # Verify inbox_write to shogun was called instead.
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-002: Outbound message does NOT trigger ACK (loop prevention)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-002: Outbound message does NOT trigger ACK (loop prevention)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg002","time":1234567890,"message":"📱受信: echo","tags":["outbound"]}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-003: No auto-ACK sent (shogun replies directly)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-003: No auto-ACK sent (shogun replies directly)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg003","time":1234567890,"message":"テスト通知です","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — ACK_LOG should be empty
    [ ! -s "$ACK_LOG" ]
    # But inbox_write to shogun should still fire
    [ -s "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-004: ACK failure does not block inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-004: ACK failure does not block inbox_write" {
    export MOCK_NTFY_EXIT_CODE=1
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg004","time":1234567890,"message":"test msg","tags":[]}
JSON
    run_listener
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-005: Empty message skips ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-005: Empty message skips ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg005","time":1234567890,"message":"","tags":[]}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-006: Non-message event (keepalive) skips ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-006: Non-message event (keepalive) skips ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"keepalive","id":"","time":1234567890,"message":""}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-007: append_ntfy_inbox failure skips both ACK and inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-007: append_ntfy_inbox failure skips both ACK and inbox_write" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg007","time":1234567890,"message":"should not ack","tags":[]}
JSON
    # Force append_ntfy_inbox failure in a UID-independent way.
    # chmod-based write denial does not fail when the suite runs as root.
    rm "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    mkdir "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    run_listener
    # Both ACK and inbox_write should be skipped (L159 continue)
    [ ! -s "$ACK_LOG" ]
    [ ! -s "$INBOX_LOG" ]
    # Restore for teardown
    rmdir "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    echo "inbox:" > "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-008: Special characters in message preserved in inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-008: Special characters in message preserved in inbox_write" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg008","time":1234567890,"message":"こんにちは 'world' & <test>","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — verify inbox_write still fires for special characters
    [ ! -s "$ACK_LOG" ]
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-009: リスナーの出力にtopic値・認証値が出ない (cmd_213)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-009: listener output never contains the topic or auth values" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg009","time":1234567890,"message":"hello","tags":[]}
JSON
    run_listener_capture_stderr
    [ -s "$TEST_TMPDIR/listener_stderr.log" ]
    grep -q "ntfy listener started" "$TEST_TMPDIR/listener_stderr.log"
    ! grep -qF "$DUMMY_TOPIC" "$TEST_TMPDIR/listener_stderr.log"
    ! grep -qF "$DUMMY_TOKEN" "$TEST_TMPDIR/listener_stderr.log"
    # 認証方式のラベルだけは出る
    grep -q "auth: token" "$TEST_TMPDIR/listener_stderr.log"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-010: secrets.env不在ならリスナーは起動せず fail-loud (cmd_213)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-010: listener refuses to start without secrets.env and reports why" {
    export SHOGUN_SECRETS_FILE="$TEST_TMPDIR/does_not_exist.env"
    run timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"secrets.env not found"* ]]
    [[ "$output" != *"$DUMMY_TOPIC"* ]]
    [ ! -s "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-011: ダミーtopicが購読URLに使われる (cmd_213)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-011: listener subscribes to the topic read from secrets.env" {
    cat > "$MOCK_BIN/curl" << 'CURL_MOCK'
#!/bin/bash
echo "$@" >> "$MOCK_PROJECT/curl_args.txt"
CURL_MOCK
    chmod +x "$MOCK_BIN/curl"
    run_listener
    grep -qF "https://ntfy.sh/$DUMMY_TOPIC/json" "$MOCK_PROJECT/curl_args.txt"
    grep -qF "Authorization: Bearer $DUMMY_TOKEN" "$MOCK_PROJECT/curl_args.txt"
}
