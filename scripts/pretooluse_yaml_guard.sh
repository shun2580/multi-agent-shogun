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
#
# features.yaml_guard_enabled は off|observe|enforce の3値(cmd_120):
#   off      … 完全無効化(早期リターン、python起動なし)
#   observe … 検証は完全実行するがdenyせず、WOULD-DENYをlogs/へ記録して通す
#   enforce … 従来どおりdeny
# 旧bool値(true/false)は true→enforce, false→offへ後方互換で読み替える。
# 未知値・空値・設定ファイル欠落は必ずoffへ倒す(fail-safe)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${YAML_GUARD_SETTINGS:-$SCRIPT_DIR/config/settings.yaml}"
PYTHON_BIN="${YAML_GUARD_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"
NTFY_SCRIPT="${YAML_GUARD_NTFY_SCRIPT:-$SCRIPT_DIR/scripts/ntfy.sh}"
LOG_FILE="${YAML_GUARD_LOG:-$SCRIPT_DIR/logs/yaml_guard.log}"
REPO_ROOT="${YAML_GUARD_REPO_ROOT:-$SCRIPT_DIR}"

# ─── 反復DENY警報 (cmd_134 工程2) ───
# 同一ファイル($FILE_PATH)への実DENYが直近10分以内に3件以上発生した場合、
# deny再試行ループ(deadmanの不活動検知では捕捉できない)の可能性として
# ntfyで警報する。判定対象は実DENY行のみ(WOULD-DENY/FAIL-OPEN/ALLOWは
# 対象外)。実DENYはenforceモードでしか発生しないため、本関数はobserve
# 期間中は実質不活性(呼び出されない)。再警報は同一ファイルにつき10分間
# 抑制する(スパム防止。状態はマーカーファイル1つのみ・常駐プロセスなし)。
check_repeated_deny_alert() {
    local file_path="$1"
    local now_epoch window_start count ts ts_epoch
    now_epoch=$(date +%s)
    window_start=$((now_epoch - 600))
    count=0
    while IFS= read -r ts; do
        ts_epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
        [ "$ts_epoch" -ge "$window_start" ] && count=$((count + 1))
    done < <(grep -F -- " DENY " "$LOG_FILE" 2>/dev/null | grep -F -- "file=$file_path tool=" | sed -E 's/^\[([^]]+)\].*/\1/')

    if [ "$count" -ge 3 ]; then
        local marker="${LOG_FILE}.repeated_deny_alert.$(printf '%s' "$file_path" | tr -c 'A-Za-z0-9' '_')"
        local last_alert=0
        [ -f "$marker" ] && last_alert="$(cat "$marker" 2>/dev/null || echo 0)"
        case "$last_alert" in ''|*[!0-9]*) last_alert=0 ;; esac
        if [ $((now_epoch - last_alert)) -ge 600 ]; then
            echo "$now_epoch" > "$marker" 2>/dev/null || true
            (bash "$NTFY_SCRIPT" "🔁 pretooluse_yaml_guard.sh: 同一ファイルへの実DENYが直近10分で${count}件 file=$file_path — deny再試行ループの可能性" >/dev/null 2>&1 &) || true
        fi
    fi
}

INPUT="$(cat)"

# ─── 早期リターン1: feature flag (grep-based, python起動なし) ───
# flagは3値(off|observe|enforce)。旧bool値(true/false)との後方互換として
# true→enforce, false→offへ読み替える。未知値・空値・ファイル欠落は
# fail-safeで必ずoffへ倒す(cmd_120 Q2-5)。
RAW_LINE=$(grep -E '^[[:space:]]*yaml_guard_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE=$(printf '%s' "$RAW_LINE" | sed -E \
    -e 's/^[[:space:]]*yaml_guard_enabled:[[:space:]]*//' \
    -e 's/[[:space:]]*#.*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\1/")

case "$RAW_VALUE" in
    enforce|true|True|TRUE) MODE="enforce" ;;
    observe) MODE="observe" ;;
    *) MODE="off" ;;  # off/false/空/未知値はすべてfail-safeでoff
esac

if [ "$MODE" = "off" ]; then
    exit 0
fi

# ─── 早期リターン2: tool_name/file_pathの軽量抽出(python起動なし) ───
# 抽出はここでは「対象パスか否か」の判定のみに使う。実際の検証はpython側で
# stdinのJSONを正規にパースし直して行うため、ここでの抽出精度が甘くても
# (誤って対象外と判定しても)fail-open側に倒れるだけで安全側に働く。
# 正規表現はコロン前後の空白(整形JSON)を許容する(cmd_120 Q2-6是正:
# 従来は非対応で整形JSONが無検証で素通りするfail-open族のバグがあった)。
TOOL_NAME=$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"tool_name"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')

# session_id: 実CLI実測(cmd_120 Q7隔離検証)で全PreToolUse呼び出しに含まれる
# ことを確認済み。enforce移行判定条件(cmd_121 A-1(2): セッション2回以上に跨る)
# の機械集計に使うためログへ記録する(判定ロジック自体には使わない、参考情報)。
SESSION_ID=$(printf '%s' "$INPUT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"session_id"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')
SESSION_ID="${SESSION_ID:-unknown}"

case "$TOOL_NAME" in
    Edit|Write) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"file_path"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')

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
        # safe_load_all(): 単一ドキュメントも1文書ストリームとして通る。
        # ガードの責務は構文であり、スキーマ適合(ドキュメント数・キー構造等)は
        # 消費者側の責務のため、ここでは全ドキュメントの構文消費のみ行う。
        for _ in yaml.safe_load_all(simulated):
            pass
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

# ─── ログ形式(cmd_121 A-2): 1評価1行・追記型・grep -cで機械集計可能な形式。
# 全行 "[timestamp] VERDICT mode=<off|observe|enforce> file=<path> tool=<Edit|Write> ..."
# で始める。VERDICT ∈ {ALLOW, WOULD-DENY, DENY, FAIL-OPEN}。
if [ "$PY_EXIT" -ne 0 ]; then
    ERR_MSG="$(tail -1 "$ERR_TMP" 2>/dev/null)"
    echo "[$(date -Iseconds)] FAIL-OPEN mode=$MODE session=$SESSION_ID file=$FILE_PATH tool=$TOOL_NAME exit=$PY_EXIT err=$ERR_MSG" >> "$LOG_FILE"
    (bash "$NTFY_SCRIPT" "⚠️ pretooluse_yaml_guard.sh fail-open: $FILE_PATH ($TOOL_NAME) exit=$PY_EXIT err=$ERR_MSG" >/dev/null 2>&1 &) || true
    exit 0
fi

if [ -n "$OUTPUT" ]; then
    if [ "$MODE" = "observe" ]; then
        # observeモード: 検証は完全実行するがdenyせず、WOULD-DENYとしてログのみ
        # 記録して通す(cmd_120 Q2-5)。理由詳細はOUTPUT(python生成JSON)ごと記録。
        echo "[$(date -Iseconds)] WOULD-DENY mode=$MODE session=$SESSION_ID file=$FILE_PATH tool=$TOOL_NAME reason=$OUTPUT" >> "$LOG_FILE"
        exit 0
    fi
    echo "[$(date -Iseconds)] DENY mode=$MODE session=$SESSION_ID file=$FILE_PATH tool=$TOOL_NAME reason=$OUTPUT" >> "$LOG_FILE"
    check_repeated_deny_alert "$FILE_PATH"
    printf '%s\n' "$OUTPUT"
    exit 0
fi

# 検証完了・YAMLとして妥当(許可)。この行がenforce移行判定の分母
# (評価総数=ALLOW+WOULD-DENY+DENY件数)の一部を構成する。
echo "[$(date -Iseconds)] ALLOW mode=$MODE session=$SESSION_ID file=$FILE_PATH tool=$TOOL_NAME" >> "$LOG_FILE"
exit 0
