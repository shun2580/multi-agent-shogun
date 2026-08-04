#!/usr/bin/env bash
# PreToolUse hook: 戻せない操作の三値判定 observeモード (cmd_145 Part4)
#
# 「戻せない操作」(push・公開/published:true化・DB破壊的変更・外部送信・
# ファイル削除。cmd_145 Part3の分類を流用)をtool_name+tool_inputパターンで
# 判定し、reversible / irreversible / unknown の三値でログにのみ記録する。
# 判定不能は必ず unknown とし、安易に reversible 側へ倒さない(busy三値化
# subtask_123_a/cmd_126と同型の教訓)。
#
# 本フックは常に exit 0 で終了する(observeモード固定・ブロックしない)。
# enforceモードは未実装(当面の設計スコープ外)。
#
# 既存フック(pretooluse_clear_idle.sh / pretooluse_yaml_guard.sh)への追記は
# 行わず、独立スクリプト+.claude/settings.jsonへの別エントリ登録とすることで、
# 既存フックの動作を一切変更しない(cmd_123教訓: 既存フック内の未改修経路に
# 同種欠陥が残るリスクの回避。軍師分解プラン gunshi_decompose_145 依頼事項5)。
#
# features.reversibility_check_enabled は off|observe の2値:
#   off      … 完全無効化(早期リターン、python起動なし)
#   observe … 判定を実行しログにのみ記録(ブロックしない)
# 未知値・空値・設定ファイル欠落は必ずoffへ倒す(fail-safe。yaml_guard.shと同方針)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REVERSIBILITY_CHECK_SETTINGS:-$SCRIPT_DIR/config/settings.yaml}"
PYTHON_BIN="${REVERSIBILITY_CHECK_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"
LOG_FILE="${REVERSIBILITY_CHECK_LOG:-$SCRIPT_DIR/logs/reversibility_check.log}"

# ─── 早期リターン: feature flag (grep-based, python起動なし) ───
RAW_LINE=$(grep -E '^[[:space:]]*reversibility_check_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE=$(printf '%s' "$RAW_LINE" | sed -E \
    -e 's/^[[:space:]]*reversibility_check_enabled:[[:space:]]*//' \
    -e 's/[[:space:]]*#.*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\1/")

case "$RAW_VALUE" in
    observe) MODE="observe" ;;
    *) MODE="off" ;;  # off/空/未知値はすべてfail-safeでoff
esac

if [ "$MODE" = "off" ]; then
    exit 0
fi

INPUT="$(cat)"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ─── 三値判定 (python側でJSONを正規にパースして判定する) ───
# 出力はASCII Unit Separator(\x1f)区切りの1行:
#   verdict|category|tool_name|session_id|file_path|detail_b64
# (detailにコマンド文字列等の任意テキストが入るため、bash側でのJSON再パース時に
# クォート崩れが起きないようbase64で運ぶ)。
read -r -d '' PYCODE <<'PYEOF' || true
import base64
import json
import re
import sys


def emit(verdict, category, tool_name, session_id, file_path, detail):
    detail_b64 = base64.b64encode(detail[:300].encode("utf-8", "replace")).decode("ascii")
    print("\x1f".join([
        verdict, category, tool_name or "unknown", session_id or "unknown",
        file_path or "NA", detail_b64,
    ]))


try:
    payload = json.load(sys.stdin)
except Exception as e:
    emit("unknown", "parse_error", "unknown", "unknown", "NA", f"{type(e).__name__}: {e}")
    sys.exit(0)

tool_name = payload.get("tool_name") or ""
session_id = payload.get("session_id") or "unknown"
tool_input = payload.get("tool_input") or {}

# ─── 戻せない操作パターン (cmd_145 Part3分類「push・公開・published:true化・
#      DB破壊的変更・外部送信・ファイル削除」を流用) ───
IRREVERSIBLE_BASH = [
    ("push", re.compile(r"\bgit\s+push\b")),
    ("publish", re.compile(
        r"\b(npm\s+publish|cargo\s+publish|twine\s+upload|gh\s+release\s+create|"
        r"docker\s+push|vercel\s+[^\n]*--prod)\b")),
    ("db_destructive", re.compile(
        r"\b(DROP\s+TABLE|TRUNCATE\s+TABLE|DELETE\s+FROM)\b", re.IGNORECASE)),
    ("external_send", re.compile(
        r"\b(curl|wget)\b[^\n]*(-X\s*POST|--data|-d\s|--post-data)", re.IGNORECASE)),
    ("file_delete", re.compile(r"(^|[;&|]\s*)rm\s")),
]

# 「戻せる操作(ローカル編集・ブランチコミット・テスト実行・docs生成)」
# (cmd_145 Part3分類)に該当する明示的安全パターンのみreversible判定する。
REVERSIBLE_BASH = [
    re.compile(r"\bgit\s+(add|commit|status|diff|log|show|branch)\b"),
    re.compile(r"\b(pytest|bats|go\s+test|npm\s+test|npm\s+run\s+test)\b"),
]

if tool_name == "Bash":
    command = tool_input.get("command") or ""
    for category, pattern in IRREVERSIBLE_BASH:
        if pattern.search(command):
            emit("irreversible", category, tool_name, session_id, "NA", command)
            sys.exit(0)
    for pattern in REVERSIBLE_BASH:
        if pattern.search(command):
            emit("reversible", "local_or_test", tool_name, session_id, "NA", command)
            sys.exit(0)
    # 判定不能: 安易にreversibleへ倒さずunknownとする(busy三値化と同型の教訓)。
    emit("unknown", "bash_unclassified", tool_name, session_id, "NA", command)
    sys.exit(0)

if tool_name in ("Edit", "Write"):
    file_path = tool_input.get("file_path") or ""
    content = tool_input.get("content")
    if content is None:
        content = tool_input.get("new_string") or ""
    if re.search(r"published\s*:\s*true", content):
        emit("irreversible", "publish_flag", tool_name, session_id, file_path, file_path)
        sys.exit(0)
    emit("reversible", "local_edit", tool_name, session_id, file_path, file_path)
    sys.exit(0)

if tool_name in ("Read", "Grep", "Glob", "TodoWrite"):
    emit("reversible", "read_only", tool_name, session_id, "NA", tool_name)
    sys.exit(0)

# 上記いずれにも該当しないツール(WebFetch/mcp__*等)は判定不能として
# unknownに倒す(安全側)。
emit("unknown", "tool_unclassified", tool_name, session_id, "NA", tool_name)
PYEOF

OUTPUT="$(printf '%s' "$INPUT" | timeout 4 "$PYTHON_BIN" -c "$PYCODE" 2>/dev/null)"
PY_EXIT=$?

if [ "$PY_EXIT" -ne 0 ] || [ -z "$OUTPUT" ]; then
    echo "[$(date -Iseconds)] WOULD-UNKNOWN mode=$MODE session=unknown file=NA tool=unknown category=hook_internal_error detail=" >> "$LOG_FILE"
    exit 0
fi

IFS=$'\x1f' read -r VERDICT CATEGORY TOOL_NAME SESSION_ID FILE_PATH DETAIL_B64 <<< "$OUTPUT"
DETAIL="$(printf '%s' "$DETAIL_B64" | base64 -d 2>/dev/null)"

case "$VERDICT" in
    irreversible) LOGTOKEN="WOULD-BLOCK" ;;
    reversible) LOGTOKEN="WOULD-ALLOW" ;;
    *) LOGTOKEN="WOULD-UNKNOWN" ;;
esac

echo "[$(date -Iseconds)] $LOGTOKEN mode=$MODE session=$SESSION_ID file=$FILE_PATH tool=$TOOL_NAME category=$CATEGORY detail=$DETAIL" >> "$LOG_FILE"

exit 0
