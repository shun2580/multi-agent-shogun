#!/usr/bin/env bash
# ntfy_auth.sh — ntfy秘匿値(topic/認証)ヘルパーライブラリ
# FR-066: ntfy認証対応 / cmd_213: 秘匿値をリポジトリ外 secrets.env へ移設
#
# 提供関数:
#   ntfy_secrets_file                   → secrets.env のパスを出力
#   ntfy_secret_get KEY [secrets_file]  → secrets.env から KEY の値だけを出力 (0=あり, 1=なし/空)
#   ntfy_get_topic [secrets_file]       → NTFY_TOPIC を出力 (fail-loud: 無ければstderrに理由+return 1)
#   ntfy_get_auth_args [secrets_file]   → curl認証フラグを出力
#   ntfy_validate_topic [topic]         → 0=OK, 1=弱いトピック名
#
# 認証方式:
#   - token: Bearer token (自己ホスト ntfy用)        — NTFY_TOKEN
#   - basic: ユーザー名+パスワード (自己ホスト ntfy用) — NTFY_USER / NTFY_PASS
#   - none: 認証なし (公開ntfy.sh、後方互換)
#
# 秘匿値の置場: ~/.config/multi-agent-shogun/secrets.env (リポジトリ外・`KEY=value`形式)
#   環境変数 SHOGUN_SECRETS_FILE で上書き可 (テスト・隔離用)。
#   `source` はしない: 行をパースして必要なキーだけ取り出す (余計な式は実行されない)。
#   旧 config/ntfy_auth.env / settings.yaml の ntfy_topic への fallback は無い。

# --- ntfy_secrets_file ---
ntfy_secrets_file() {
    printf '%s\n' "${SHOGUN_SECRETS_FILE:-$HOME/.config/multi-agent-shogun/secrets.env}"
}

# --- ntfy_secret_get ---
# 引数: KEY [secrets_file] — 省略時は ntfy_secrets_file
# 出力: 値のみ (クォート除去・末尾空白/CR除去・クォートなし値の行末 ` #...` コメント除去)。同一キーが複数あれば最後が勝つ。
# 戻り値: 0=非空の値あり, 1=ファイル不可読 or キー無し or 空
ntfy_secret_get() {
    local key="${1:-}"
    local file="${2:-}"
    [ -n "$file" ] || file="$(ntfy_secrets_file)"
    [ -n "$key" ] && [ -r "$file" ] && [ -f "$file" ] || return 1

    local line value="" re='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ $re ]] || continue
        [ "${BASH_REMATCH[2]}" = "$key" ] || continue
        value="${BASH_REMATCH[3]}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
            # クォートなし値の行末コメント(空白+#以降)は値に含めない (pre-push hookと同じ解釈)
            value="${BASH_REMATCH[1]}"
        fi
    done < "$file"

    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# --- ntfy_get_topic ---
# fail-loud: secrets.env が無い/NTFY_TOPIC が空なら stderr に理由(パスのみ・値は出さない)を出して return 1
ntfy_get_topic() {
    local file="${1:-}"
    [ -n "$file" ] || file="$(ntfy_secrets_file)"
    if [ ! -f "$file" ]; then
        echo "ERROR: secrets.env not found: $file (NTFY_TOPIC cannot be read; create it from config/secrets.env.sample)" >&2
        return 1
    fi
    local topic
    topic="$(ntfy_secret_get NTFY_TOPIC "$file")" || topic=""
    if [ -z "$topic" ]; then
        echo "ERROR: NTFY_TOPIC is not set in $file" >&2
        return 1
    fi
    printf '%s\n' "$topic"
}

# --- ntfy_get_auth_args ---
# curl用の認証引数を標準出力に返す
# 引数: [secrets_file] — 秘匿値ファイルのパス（省略時は ntfy_secrets_file）
# 優先順: secrets.env の値 > 呼出し元環境の NTFY_TOKEN/NTFY_USER/NTFY_PASS
# 出力: curl引数文字列 (例: "-H" "Authorization: Bearer tk_xxx")
#        認証設定なしの場合は空文字列（後方互換）
ntfy_get_auth_args() {
    local auth_file="${1:-}"
    [ -n "$auth_file" ] || auth_file="$(ntfy_secrets_file)"

    local token user pass
    token="$(ntfy_secret_get NTFY_TOKEN "$auth_file")" || token="${NTFY_TOKEN:-}"
    user="$(ntfy_secret_get NTFY_USER "$auth_file")" || user="${NTFY_USER:-}"
    pass="$(ntfy_secret_get NTFY_PASS "$auth_file")" || pass="${NTFY_PASS:-}"

    # Bearer token認証（優先）
    if [ -n "$token" ]; then
        printf '%s\n' "-H" "Authorization: Bearer ${token}"
        return 0
    fi

    # Basic認証（フォールバック）
    if [ -n "$user" ] && [ -n "$pass" ]; then
        printf '%s\n' "-u" "${user}:${pass}"
        return 0
    fi

    # 認証なし（後方互換: 公開ntfy.shではこちら）
    return 0
}

# --- ntfy_validate_topic ---
# トピック名のセキュリティ強度を検証
# 引数: topic — トピック名
# 戻り値: 0=OK(十分な長さ+ランダム性), 1=弱い(短すぎる or 推測可能)
# 標準エラー: 警告メッセージ
ntfy_validate_topic() {
    local topic="${1:-}"

    # 空チェック
    if [ -z "$topic" ]; then
        echo "ERROR: ntfy topic is empty" >&2
        return 1
    fi

    # 長さチェック（8文字未満は危険）
    if [ "${#topic}" -lt 8 ]; then
        echo "WARNING: ntfy topic is too short (${#topic} chars). Recommend 12+ chars for security." >&2
        return 1
    fi

    # 一般的な弱いトピック名チェック
    local weak_topics="test mytopic notifications alerts messages my-topic default ntfy"
    local lower_topic
    lower_topic=$(echo "$topic" | tr '[:upper:]' '[:lower:]')
    for weak in $weak_topics; do
        if [ "$lower_topic" = "$weak" ]; then
            echo "WARNING: ntfy topic is a commonly used name. Use a random string." >&2
            return 1
        fi
    done

    return 0
}
