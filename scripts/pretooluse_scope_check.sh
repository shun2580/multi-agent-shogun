#!/usr/bin/env bash
# PreToolUse hook: allowed_paths scope をEdit/Write呼び出しの直前に検査する
# 薄いアダプタ (cmd_192 工程5)。
#
# scripts/scope_check.sh 本体は「task YAML($1) + git baseline($2)」を引数に
# 取り `git diff --name-only` で事後差分検証する設計であり、PreToolUseが
# 必要とする「stdin JSON経由で個別tool呼出をその場で判定する」インター
# フェースを持たない。🔴殿裁可: scope_check.sh 本体は改修せず、本アダプタを
# 新設し match_pattern()/normalize_to_repo_relative() を source して流用する。
#
# features.scope_check_hook_enabled は off|observe|enforce の3値
# (既存ガード群と同方針):
#   off      … 完全無効化(早期リターン、stdin読取・python起動なし)
#   observe … 検証は完全実行するがdenyせず、WOULD-DENYをlogs/へ記録して通す
#             (🔴cmd_192禁止事項により既定はobserve。enforceでの登録を禁ずる)
#   enforce … 実際にdeny(ロジックのみ用意。config側でのenforce登録は
#             現時点で行わない)
# 未知値・空値・設定ファイル欠落は必ずoffへ倒す(fail-safe)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS="${SCOPE_CHECK_HOOK_SETTINGS:-$REPO_ROOT/config/settings.yaml}"
PYTHON_BIN="${SCOPE_CHECK_HOOK_PYTHON:-$REPO_ROOT/.venv/bin/python3}"
LOG_FILE="${SCOPE_CHECK_HOOK_LOG:-$REPO_ROOT/logs/pretooluse_scope_check.log}"
TASKS_DIR="${SCOPE_CHECK_HOOK_TASKS_DIR:-$REPO_ROOT/queue/tasks}"

# ─── 早期リターン1: feature flag (grep-based, stdin読取・python起動なし) ───
RAW_LINE=$(grep -E '^[[:space:]]*scope_check_hook_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE=$(printf '%s' "$RAW_LINE" | sed -E \
    -e 's/^[[:space:]]*scope_check_hook_enabled:[[:space:]]*//' \
    -e 's/[[:space:]]*#.*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\1/")

case "$RAW_VALUE" in
    enforce) MODE="enforce" ;;
    observe) MODE="observe" ;;
    *) MODE="off" ;;  # off/空/未知値はすべてfail-safeでoff
esac

if [ "$MODE" = "off" ]; then
    exit 0
fi

# ─── stdin JSON読取(🔴cmd_186教訓: 正規のJSONパーサのみ使用。grepでの
# 文字列素抜き・heredoc展開による手組み抽出は禁止——JSON非エスケープに
# よるfail-open事故がcmd_186で実害を出した族のため)。 ───
INPUT="$(cat)"

PARSE_OUT="$(printf '%s' "$INPUT" | "$PYTHON_BIN" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(3)

tool_name = payload.get("tool_name") or ""
tool_input = payload.get("tool_input") or {}
file_path = tool_input.get("file_path") or ""
session_id = payload.get("session_id") or "unknown"

print(tool_name)
print(file_path)
print(session_id)
' 2>/dev/null)"
PARSE_EXIT=$?

# JSON解析失敗・想定外形式はfail-safeで通す(判定不能=何もしない)。
if [ "$PARSE_EXIT" -ne 0 ]; then
    exit 0
fi

TOOL_NAME="$(printf '%s\n' "$PARSE_OUT" | sed -n '1p')"
FILE_PATH="$(printf '%s\n' "$PARSE_OUT" | sed -n '2p')"
SESSION_ID="$(printf '%s\n' "$PARSE_OUT" | sed -n '3p')"

case "$TOOL_NAME" in
    Edit|Write) ;;
    *) exit 0 ;;
esac

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# ─── 対象範囲の限定(🔴cmd_187教訓): allowed_pathsによる統制は本プロジェクト
# 配下にのみ意味を持つ。file_path自体が本プロジェクトのREPO_ROOT配下でなければ
# (別リポジトリ・/tmp配下等の全く無関係なパス)無条件でexit 0・ログ無出力とする。
# git repo解決(cwdからの `git -C "$cwd" rev-parse --show-toplevel` 等)を経由
# しないため、非gitディレクトリ・存在しないcwd相手でもクラッシュする余地が
# 構造的に無い。
case "$FILE_PATH" in
    "$REPO_ROOT"/*) ;;
    *) exit 0 ;;
esac

# ─── agent_id解決(scripts/pretooluse_clear_idle.shの既存パターンに倣う)。
# テスト隔離用にSCOPE_CHECK_HOOK_AGENT_IDでの上書きを許容する。
# 解決不能(非tmux環境・@agent_id未設定等)はfail-safeでexit 0。 ───
AGENT_ID="${SCOPE_CHECK_HOOK_AGENT_ID:-}"
if [ -z "$AGENT_ID" ]; then
    AGENT_ID=$(tmux display-message -t "${TMUX_PANE:-}" -p '#{@agent_id}' 2>/dev/null || true)
fi

if [ -z "$AGENT_ID" ]; then
    exit 0
fi

TASK_YAML="$TASKS_DIR/${AGENT_ID}.yaml"

if [ ! -r "$TASK_YAML" ]; then
    exit 0
fi

# ─── scope_check.sh の既存関数(match_pattern()/normalize_to_repo_relative())
# を source して流用する(本体は一切改修しない・呼ぶだけ)。
# 🔴scope_check.shは source 時に REPO_ROOT="" をトップレベルで実行するため、
# 本スクリプトのREPO_ROOTを退避してから復元する。
_SELF_REPO_ROOT="$REPO_ROOT"
# shellcheck source=scope_check.sh
source "$SCRIPT_DIR/scope_check.sh"
REPO_ROOT="$_SELF_REPO_ROOT"

readarray -t ALLOWED_PATHS < <(parse_yaml_array "$TASK_YAML" "allowed_paths")

if [ ${#ALLOWED_PATHS[@]} -eq 0 ]; then
    exit 0
fi

IS_ALLOWED=0
for allowed_pattern in "${ALLOWED_PATHS[@]}"; do
    if match_pattern "$FILE_PATH" "$allowed_pattern"; then
        IS_ALLOWED=1
        break
    fi
done

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

if [ "$IS_ALLOWED" -eq 1 ]; then
    echo "[$(date -Iseconds)] ALLOW mode=$MODE session=$SESSION_ID agent=$AGENT_ID file=$FILE_PATH tool=$TOOL_NAME" >> "$LOG_FILE"
    exit 0
fi

REASON="scope_check(cmd_192 工程5): file_path='$FILE_PATH' はagent=${AGENT_ID}のallowed_paths(${TASK_YAML})に一致しません"

if [ "$MODE" = "enforce" ]; then
    echo "[$(date -Iseconds)] DENY mode=$MODE session=$SESSION_ID agent=$AGENT_ID file=$FILE_PATH tool=$TOOL_NAME" >> "$LOG_FILE"
    REASON="$REASON" "$PYTHON_BIN" -c '
import json
import os

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": os.environ["REASON"],
    }
}))
'
    exit 0
fi

echo "[$(date -Iseconds)] WOULD-DENY mode=$MODE session=$SESSION_ID agent=$AGENT_ID file=$FILE_PATH tool=$TOOL_NAME reason=$REASON" >> "$LOG_FILE"
exit 0
