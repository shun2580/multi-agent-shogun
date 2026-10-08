#!/usr/bin/env bats
# test_ntfy_auth.bats — ntfy認証ユニットテスト
# FR-066: ntfy認証対応
#
# テスト構成:
#   T-AUTH-001: ntfy_get_auth_args — Bearer token認証
#   T-AUTH-002: ntfy_get_auth_args — Basic認証
#   T-AUTH-003: ntfy_get_auth_args — 認証なし (後方互換)
#   T-AUTH-004: ntfy_get_auth_args — token優先 (token+basic両方設定時)
#   T-AUTH-005: ntfy_get_auth_args — 環境変数ファイル読み込み
#   T-AUTH-006: ntfy_get_auth_args — 存在しないauth_envファイル
#   T-AUTH-007: ntfy_validate_topic — 正常トピック名
#   T-AUTH-008: ntfy_validate_topic — 短すぎるトピック名
#   T-AUTH-009: ntfy_validate_topic — 弱いトピック名 (推測可能)
#   T-AUTH-010: ntfy_validate_topic — 空トピック名
#   T-AUTH-011: ntfy.sh — 認証ありで送信 (モック)
#   T-AUTH-012: ntfy_listener.sh — 認証ありでストリーミング (モック)
#   T-AUTH-013: secrets.env.sample — サンプルファイル存在確認 (cmd_213: ntfy_auth.env.sampleから改称)
#   T-AUTH-014: secrets.env / ntfy_auth.env — git非追跡確認
#   T-AUTH-015: ntfy_secret_get / ntfy_get_topic — secrets.envのパース (cmd_213)
#   T-AUTH-016: ntfy_validate_topic — 警告にtopic値を出さない (cmd_213)
#   T-AUTH-017: ntfy_get_auth_args — 余計な式を含むsecrets.envを実行しない (cmd_213)

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export NTFY_AUTH_LIB="$PROJECT_ROOT/lib/ntfy_auth.sh"

    # ライブラリ存在確認
    [ -f "$NTFY_AUTH_LIB" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_auth_test.XXXXXX")"

    # 環境変数をクリア（テスト間の干渉防止）
    unset NTFY_TOKEN
    unset NTFY_USER
    unset NTFY_PASS
    unset SHOGUN_SECRETS_FILE

    # ライブラリ読み込み
    source "$NTFY_AUTH_LIB"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- T-AUTH-001: Bearer token認証 ---

@test "T-AUTH-001: ntfy_get_auth_args returns Bearer header when NTFY_TOKEN is set" {
    export NTFY_TOKEN="tk_test1234567890abcdef"

    local result
    result=$(ntfy_get_auth_args /dev/null)

    echo "$result" | grep -q -- '-H'
    echo "$result" | grep -q 'Authorization: Bearer tk_test1234567890abcdef'
}

# --- T-AUTH-002: Basic認証 ---

@test "T-AUTH-002: ntfy_get_auth_args returns -u flag when NTFY_USER and NTFY_PASS are set" {
    export NTFY_USER="testuser"
    export NTFY_PASS="testpass"

    local result
    result=$(ntfy_get_auth_args /dev/null)

    echo "$result" | grep -q -- '-u'
    echo "$result" | grep -q 'testuser:testpass'
}

# --- T-AUTH-003: 認証なし (後方互換) ---

@test "T-AUTH-003: ntfy_get_auth_args returns empty when no auth configured" {
    local result
    result=$(ntfy_get_auth_args /dev/null)

    [ -z "$result" ]
}

# --- T-AUTH-004: token優先 ---

@test "T-AUTH-004: ntfy_get_auth_args prefers token over basic auth" {
    export NTFY_TOKEN="tk_priority_token"
    export NTFY_USER="should_not_use"
    export NTFY_PASS="should_not_use"

    local result
    result=$(ntfy_get_auth_args /dev/null)

    echo "$result" | grep -q 'Bearer tk_priority_token'
    ! echo "$result" | grep -q 'should_not_use'
}

# --- T-AUTH-005: env file読み込み ---

@test "T-AUTH-005: ntfy_get_auth_args loads credentials from env file" {
    local auth_file="$TEST_TMPDIR/secrets.env"
    cat > "$auth_file" << 'EOF'
NTFY_TOKEN=tk_from_file_12345
EOF

    local result
    result=$(ntfy_get_auth_args "$auth_file")

    echo "$result" | grep -q 'Bearer tk_from_file_12345'
}

# --- T-AUTH-006: 存在しないファイル ---

@test "T-AUTH-006: ntfy_get_auth_args handles missing auth file gracefully" {
    local result
    result=$(ntfy_get_auth_args "$TEST_TMPDIR/nonexistent.env")

    # エラーなし、空結果（認証なしフォールバック）
    [ -z "$result" ]
}

# --- T-AUTH-007: 正常トピック名 ---

@test "T-AUTH-007: ntfy_validate_topic accepts secure topic name" {
    run ntfy_validate_topic "sample-topic-secret123"
    [ "$status" -eq 0 ]
}

# --- T-AUTH-008: 短すぎるトピック名 ---

@test "T-AUTH-008: ntfy_validate_topic rejects short topic name" {
    run ntfy_validate_topic "abc"
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "too short"
}

# --- T-AUTH-009: 弱いトピック名 ---

@test "T-AUTH-009: ntfy_validate_topic rejects commonly used topic names" {
    run ntfy_validate_topic "notifications"
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "commonly used"
}

# --- T-AUTH-010: 空トピック名 ---

@test "T-AUTH-010: ntfy_validate_topic rejects empty topic" {
    run ntfy_validate_topic ""
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "empty"
}

# --- T-AUTH-011: ntfy.sh送信（モック） ---

@test "T-AUTH-011: ntfy.sh includes auth header in curl when token configured" {
    # テスト用のモック環境を構築
    local mock_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_dir/scripts" "$mock_dir/lib" "$mock_dir/logs" "$mock_dir/bin"

    # secrets.env (ダミー値) を SHOGUN_SECRETS_FILE で差し替え
    export SHOGUN_SECRETS_FILE="$TEST_TMPDIR/secrets.env"
    cat > "$SHOGUN_SECRETS_FILE" << 'EOF'
NTFY_TOPIC=test-topic-12345
NTFY_TOKEN=tk_mock_token_test
EOF

    # lib/ntfy_auth.sh をコピー
    cp "$PROJECT_ROOT/lib/ntfy_auth.sh" "$mock_dir/lib/"

    # curlモック: 引数をファイルに記録
    local curl_log="$TEST_TMPDIR/curl_args.log"
    cat > "$mock_dir/bin/curl" << MOCK
#!/bin/bash
echo "\$@" > "$curl_log"
echo "200"
MOCK
    chmod +x "$mock_dir/bin/curl"

    # 本物のntfy.shをコピーしてSCRIPT_DIRをmock_dirに差し替え
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$mock_dir\"|" \
        "$PROJECT_ROOT/scripts/ntfy.sh" > "$mock_dir/scripts/ntfy.sh"

    run env -C "$mock_dir" PATH="$mock_dir/bin:$PATH" bash "$mock_dir/scripts/ntfy.sh" "hello"
    [ "$status" -eq 0 ]

    # curlに認証ヘッダーと(ダミー)topicが渡されたことを確認
    [ -f "$curl_log" ]
    grep -q "Bearer tk_mock_token_test" "$curl_log"
    grep -q "test-topic-12345" "$curl_log"
}

# --- T-AUTH-012: ntfy_listener.sh認証確認（モック） ---

@test "T-AUTH-012: ntfy_get_auth_args output can be used as curl arguments" {
    export NTFY_TOKEN="tk_listener_test"

    # 認証引数を取得
    local auth_args
    auth_args=$(ntfy_get_auth_args /dev/null)

    # curlの引数として使える形式か確認
    # -H と Authorization: Bearer の2行が出力される
    local line_count
    line_count=$(echo "$auth_args" | wc -l)
    [ "$line_count" -eq 2 ]

    local first_line
    first_line=$(echo "$auth_args" | head -1)
    [ "$first_line" = "-H" ]

    local second_line
    second_line=$(echo "$auth_args" | tail -1)
    [ "$second_line" = "Authorization: Bearer tk_listener_test" ]
}

# --- T-AUTH-013: サンプルファイル存在確認 ---

@test "T-AUTH-013: secrets.env.sample exists with configuration instructions" {
    local sample="$PROJECT_ROOT/config/secrets.env.sample"
    [ -f "$sample" ]
    grep -q "NTFY_TOPIC" "$sample"
    grep -q "NTFY_TOKEN" "$sample"
    grep -q "NTFY_USER" "$sample"
    grep -q "NTFY_PASS" "$sample"
    grep -q "multi-agent-shogun/secrets.env" "$sample"
    grep -q "chmod 600" "$sample"
    # サンプルに実値(NTFY_TOPICの値)を書かない
    ! grep -Eq '^NTFY_TOPIC=.+' "$sample"
}

# --- T-AUTH-014: git非追跡確認 ---

@test "T-AUTH-014: secrets.env and ntfy_auth.env are not tracked by git (whitelist .gitignore)" {
    # .gitignoreがホワイトリスト方式（*で全除外→!で許可）
    # 秘匿値本体はホワイトリストに含まれていないことを確認
    # (.sample は追跡OK、本体は追跡NG)
    cd "$PROJECT_ROOT"

    # git check-ignoreで実際に無視されることを確認（最も信頼性の高い方法）
    run git check-ignore config/secrets.env
    [ "$status" -eq 0 ]
    run git check-ignore config/ntfy_auth.env
    [ "$status" -eq 0 ]
}

# --- T-AUTH-015: secrets.envのパース (cmd_213) ---

@test "T-AUTH-015: ntfy_secret_get / ntfy_get_topic parse KEY=value lines from secrets.env" {
    local f="$TEST_TMPDIR/secrets.env"
    cat > "$f" << 'EOF'
# comment line
NTFY_TOPIC="dummy-topic-quoted"
export NTFY_USER='dummy_user'
NTFY_PASS=dummy_pass   
EOF
    [ "$(ntfy_secret_get NTFY_TOPIC "$f")" = "dummy-topic-quoted" ]
    [ "$(ntfy_secret_get NTFY_USER "$f")" = "dummy_user" ]
    [ "$(ntfy_secret_get NTFY_PASS "$f")" = "dummy_pass" ]
    run ntfy_secret_get NTFY_TOKEN "$f"
    [ "$status" -eq 1 ]

    [ "$(ntfy_get_topic "$f")" = "dummy-topic-quoted" ]

    # クォートなし値の行末コメントは除かれ、クォート内の # は残る
    printf 'NTFY_TOPIC=dummy-topic-c # my topic\r\nNTFY_USER="has # hash"\n' > "$f"
    [ "$(ntfy_get_topic "$f")" = "dummy-topic-c" ]
    [ "$(ntfy_secret_get NTFY_USER "$f")" = "has # hash" ]

    # 同一キーは最後が勝つ
    printf 'NTFY_TOPIC=first\nNTFY_TOPIC=second-topic\n' > "$f"
    [ "$(ntfy_get_topic "$f")" = "second-topic" ]

    # SHOGUN_SECRETS_FILE が既定パスを上書きする
    export SHOGUN_SECRETS_FILE="$f"
    [ "$(ntfy_secrets_file)" = "$f" ]
    [ "$(ntfy_get_topic)" = "second-topic" ]
    unset SHOGUN_SECRETS_FILE
    [ "$(ntfy_secrets_file)" = "$HOME/.config/multi-agent-shogun/secrets.env" ]

    # 不在/空は fail-loud (return 1 + stderr)
    run ntfy_get_topic "$TEST_TMPDIR/none.env"
    [ "$status" -eq 1 ]
    [[ "$output" == *"secrets.env not found"* ]]
    printf 'NTFY_TOPIC=\n' > "$f"
    run ntfy_get_topic "$f"
    [ "$status" -eq 1 ]
    [[ "$output" == *"NTFY_TOPIC is not set"* ]]
}

# --- T-AUTH-016: 警告にtopic値を出さない (cmd_213) ---

@test "T-AUTH-016: ntfy_validate_topic warnings never echo the topic value" {
    run ntfy_validate_topic "abc"
    [[ "$output" != *"'abc'"* ]]
    run ntfy_validate_topic "notifications"
    [ "$status" -eq 1 ]
    [[ "$output" != *"notifications"* ]]
}

# --- T-AUTH-017: 余計な式を実行しない (cmd_213) ---

@test "T-AUTH-017: ntfy_get_auth_args reads auth from secrets.env without executing extra expressions" {
    local f="$TEST_TMPDIR/secrets.env" marker="$TEST_TMPDIR/PWNED"
    cat > "$f" << EOF
touch "$marker"
NTFY_TOKEN=tk_parsed_not_sourced
\$(touch "$marker")
EOF
    local result
    result=$(ntfy_get_auth_args "$f")
    [ ! -e "$marker" ]
    echo "$result" | grep -q 'Bearer tk_parsed_not_sourced'

    # 既定パスは SHOGUN_SECRETS_FILE 経由
    export SHOGUN_SECRETS_FILE="$f"
    result=$(ntfy_get_auth_args)
    echo "$result" | grep -q 'Bearer tk_parsed_not_sourced'
}
