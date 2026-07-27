#!/usr/bin/env bash
# PreToolUse hook: YAML書込前ガード (cmd_113 Part2)
#
# 対象パス(queue系YAML/saytask系YAML)へのEdit/Write呼び出しについて、書込が
# 適用された後の内容をこの場でシミュレートしYAMLとしてパースできるか検証する。
# パース失敗が確定した場合のみ deny する。非対象パスは即exit 0(オーバーヘッド
# 最小化)。フック自身の内部エラー(依存欠落・タイムアウト・想定外入力)は
# 「YAML不正と確定」とは厳密に区別し、fail-open(通す)+ntfy警報とする——
# フックのバグ1つで全軍のファイル操作が止まる事態を防ぐため。
#
# 既存のpretooluse_clear_idle.shのロジックは変更しない。本スクリプトは
# .claude/settings.jsonのPreToolUse配列に別エントリとして追加登録する。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${YAML_GUARD_SETTINGS:-$SCRIPT_DIR/config/settings.yaml}"
PYTHON_BIN="${YAML_GUARD_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"
NTFY_SCRIPT="${YAML_GUARD_NTFY_SCRIPT:-$SCRIPT_DIR/scripts/ntfy.sh}"
LOG_FILE="${YAML_GUARD_LOG:-$SCRIPT_DIR/logs/yaml_guard.log}"
REPO_ROOT="${YAML_GUARD_REPO_ROOT:-$SCRIPT_DIR}"

INPUT="$(cat)"

# ─── 早期リターン1: feature flag (grep-based, python起動なし) ───
if ! grep -qE '^[[:space:]]*yaml_guard_enabled:[[:space:]]*true([[:space:]]|#|$)' "$SETTINGS" 2>/dev/null; then
    exit 0
fi

# ─── 早期リターン2: tool_name/file_pathの軽量抽出(python起動なし) ───
# 抽出はここでは「対象パスか否か」の判定のみに使う。実際の検証はpython側で
# stdinのJSONを正規にパースし直して行うため、ここでの抽出精度が甘くても
# (誤って対象外と判定しても)fail-open側に倒れるだけで安全側に働く。
TOOL_NAME=$(printf '%s' "$INPUT" | grep -oE '"tool_name":"[^"]*"' | head -1 | sed -E 's/^"tool_name":"(.*)"$/\1/')

case "$TOOL_NAME" in
    Edit|Write) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | grep -oE '"file_path":"[^"]*"' | head -1 | sed -E 's/^"file_path":"(.*)"$/\1/')

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

case "$FILE_PATH" in
    "$REPO_ROOT"/*) REL_PATH="${FILE_PATH#"$REPO_ROOT"/}" ;;
    *) exit 0 ;;  # リポジトリ外は対象外
esac

case "$REL_PATH" in
    queue/shogun_to_karo.yaml|queue/tasks/*.yaml|queue/reports/*.yaml|queue/inbox/*.yaml|saytask/*.yaml)
        ;;
    *)
        exit 0
        ;;
esac

# ─── ここから先は対象パス: フルJSONパース+YAML検証(pythonを起動) ───
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

read -r -d '' PYCODE <<'PYEOF' || true
import json
import sys

import yaml


def fail_open(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


try:
    payload = json.load(sys.stdin)
except Exception as e:
    fail_open(f"failed to parse hook stdin JSON: {type(e).__name__}: {e}")

tool_name = payload.get("tool_name")
tool_input = payload.get("tool_input") or {}
file_path = tool_input.get("file_path")

if not file_path:
    fail_open("tool_input missing file_path")

try:
    if tool_name == "Write":
        content = tool_input.get("content")
        if content is None:
            fail_open("Write tool_input missing 'content' field")
        simulated = content
    elif tool_name == "Edit":
        old_string = tool_input.get("old_string")
        new_string = tool_input.get("new_string")
        if old_string is None or new_string is None:
            fail_open("Edit tool_input missing old_string/new_string")
        replace_all = bool(tool_input.get("replace_all", False))
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                current = f.read()
        except OSError as e:
            fail_open(f"failed to read current file for simulation: {e}")
        if replace_all:
            simulated = current.replace(old_string, new_string)
        else:
            simulated = current.replace(old_string, new_string, 1)
    else:
        # matcherがEdit|Writeのみを通す前提だが、念のため未知toolは無検証で許可
        sys.exit(0)

    try:
        yaml.safe_load(simulated)
        sys.exit(0)
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        loc = f"line {mark.line + 1}, column {mark.column + 1}" if mark is not None else "unknown location"
        problem = getattr(e, "problem", None) or str(e)
        context = getattr(e, "context", None)
        detail = f"{problem} ({context})" if context else problem
        reason = f"YAML parse failure at {loc}: {detail}"
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }))
        sys.exit(0)
except SystemExit:
    raise
except Exception as e:
    fail_open(f"internal validator exception: {type(e).__name__}: {e}")
PYEOF

ERR_TMP="$(mktemp)"
trap 'rm -f "$ERR_TMP"' EXIT

OUTPUT="$(printf '%s' "$INPUT" | timeout 4 "$PYTHON_BIN" -c "$PYCODE" 2>"$ERR_TMP")"
PY_EXIT=$?

if [ "$PY_EXIT" -ne 0 ]; then
    ERR_MSG="$(tail -1 "$ERR_TMP" 2>/dev/null)"
    echo "[$(date -Iseconds)] FAIL-OPEN file=$FILE_PATH tool=$TOOL_NAME exit=$PY_EXIT err=$ERR_MSG" >> "$LOG_FILE"
    (bash "$NTFY_SCRIPT" "⚠️ pretooluse_yaml_guard.sh fail-open: $FILE_PATH ($TOOL_NAME) exit=$PY_EXIT err=$ERR_MSG" >/dev/null 2>&1 &) || true
    exit 0
fi

if [ -n "$OUTPUT" ]; then
    echo "[$(date -Iseconds)] DENY file=$FILE_PATH tool=$TOOL_NAME" >> "$LOG_FILE"
    printf '%s\n' "$OUTPUT"
    exit 0
fi

exit 0
