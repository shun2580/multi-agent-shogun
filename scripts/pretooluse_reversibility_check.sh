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


def emit(verdict, category, tool_name, session_id, file_path, detail,
         matched_verb="", rationale=""):
    detail_b64 = base64.b64encode(detail[:300].encode("utf-8", "replace")).decode("ascii")
    rationale_b64 = base64.b64encode(rationale.encode("utf-8", "replace")).decode("ascii")
    print("\x1f".join([
        verdict, category, tool_name or "unknown", session_id or "unknown",
        file_path or "NA", detail_b64, matched_verb or "NA", rationale_b64,
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
    # `[^\n]*`のまま(改行=別文の区切りとして正しく非マッチ)だが、bashの行継続
    # (`\`直後の改行)は同一論理コマンドであるため`\\\n`のみ横断を許す(cmd_153。
    # 素の改行での非マッチは「curl url\n-d yesterday」のような無関係な別文の
    # 誤検知回避という元設計を維持しつつ、`curl url \` + 改行 + `-X POST`という
    # 一体のcurl呼出しの見逃しだけを是正する)。
    ("external_send", re.compile(
        r"\b(curl|wget)\b(?:[^\n]|\\\n)*(-X\s*POST|--data|-d\s|--post-data)",
        re.IGNORECASE)),
    # `re.MULTILINE`追加+アンカー文字集合へ`(`・バッククォートを追加(cmd_153)。
    # 元の`(^|[;&|]\s*)`は改行後(re.MULTILINE無し)やコマンド置換内の`rm`を
    # 取り逃していた(将軍実機検証)。
    ("file_delete", re.compile(r"(^|[;&|(`]\s*)rm\s", re.MULTILINE)),
]

# ─── push category専用: help/dry-run除外 (cmd_194 工程6・gunshi_design_194_6) ───
# 「git push --help」「git push --dry-run」等は実際にはpushしないため誤検知だが、
# 判定はマッチした"git push"に続く同一invocation範囲内のみに厳密に限定する
# (コマンド全体のどこかに--helpがあれば除外、という単純化は禁止——
# `echo "for --help info" && git push origin main`のような抜け道を作らないため)。
# 除外時はreversibleへ昇格させず、既存のフォールスルーでunknownへ帰着させる
# (判定材料不足はunknown側へ倒す、既存コードの哲学を踏襲)。他category
# (publish/db_destructive/external_send/file_delete)のロジックは無改造。
_CMD_BOUNDARY_RE = re.compile(r"[;&|\n]")


def _is_help_or_dryrun_push(command, match):
    boundary = _CMD_BOUNDARY_RE.search(command, match.end())
    scope_end = boundary.start() if boundary else len(command)
    scope = command[match.end():scope_end]
    tokens = scope.split()
    return any(tok in ("--help", "-h", "--dry-run") for tok in tokens)


# 「戻せる操作(ローカル編集・ブランチコミット・テスト実行・docs生成)」
# (cmd_145 Part3分類)に該当する明示的安全パターンのみreversible判定する。
REVERSIBLE_BASH = [
    re.compile(r"\bgit\s+(add|commit|status|diff|log|show|branch)\b"),
    re.compile(r"\b(pytest|bats|go\s+test|npm\s+test|npm\s+run\s+test)\b"),
]

# ─── 読取専用コマンドのreversible分類 (cmd_152) ───
# コマンド名だけでは判定しない。以下の条件を"すべて"満たす場合のみreversible:
#   1. 先頭verbが読取専用ホワイトリストに一致する
#   2. リダイレクト(> >> <)・パイプ(|)・連結(; && ||)・tee・xargsが
#      コマンド全体のどこにも現れない(複合コマンドは一律unknownへ倒す。
#      パイプ/連結先の安全性を再帰検証するコストとリスクに見合わないため)
#   3. findの場合は -delete / -exec を伴わない
# 一つでも満たさなければNoneを返し、呼び出し側はunknownへ倒す
# (judgment_model原則1・原則2: 判定材料不足時は安全側=unknown)。
#
# sed/awk/perl/ruby等の編集能力を持つコマンドはホワイトリストに含めない
# (対象外・cmd_152指示)。in-placeフラグの有無だけを見る設計は、
# 例えば `grep -i`(大小文字無視、無害)のような無関係な-iとの誤認や、
# GNU awkの`-i inplace`のようにフラグ表記がツールごとに異なる網羅漏れの
# リスクを抱える。読取専用verbホワイトリストからこれらを丸ごと除外する
# ことで、フラグ単位の判定ロジックそのものを不要にし、誤分類の攻撃面を
# 減らす(unknown率の低下幅が小さくなっても正しさを優先する、という
# cmd_152の指示に沿う設計判断)。
READONLY_VERBS = {
    "grep", "cat", "tail", "head", "wc", "ls", "ps", "date", "which", "type",
    "env", "printenv", "tree", "file", "stat", "du", "df", "pwd", "whoami",
    "less", "more", "diff", "sleep", "echo", "cd", "find",
}
# 改行(\n)とコマンド置換($(...)・バッククォート)も危険指標に含める(cmd_153)。
# Bashでは改行は`;`と同じコマンド区切りであり、コマンド置換は元コマンドの
# 文字列に含まれない別コマンドを実行し得るため、いずれも文字クラスだけの
# 判定(元の`[><;|&]`)では見逃していた(将軍実機検証で発覚)。
_DANGER_CHARS_RE = re.compile(r"[><;|&\n]|\$\(|`")
_FIND_DANGEROUS_RE = re.compile(r"(?<!\S)-(?:delete|exec)\b")


def classify_readonly_bash(command):
    stripped = command.strip()
    if not stripped:
        return None
    if _DANGER_CHARS_RE.search(stripped):
        return None
    if "tee" in stripped or "xargs" in stripped:
        return None
    verb = stripped.split(None, 1)[0]
    if verb not in READONLY_VERBS:
        return None
    if verb == "find" and _FIND_DANGEROUS_RE.search(stripped):
        return None
    return verb, (
        f"verb={verb} matched read-only whitelist; "
        "no redirect/pipe/chain/tee/xargs indicators found in command"
    )


if tool_name == "Bash":
    command = tool_input.get("command") or ""
    for category, pattern in IRREVERSIBLE_BASH:
        match = pattern.search(command)
        if match is None:
            continue
        if category == "push" and _is_help_or_dryrun_push(command, match):
            continue
        emit("irreversible", category, tool_name, session_id, "NA", command)
        sys.exit(0)
    for pattern in REVERSIBLE_BASH:
        if pattern.search(command):
            emit("reversible", "local_or_test", tool_name, session_id, "NA", command)
            sys.exit(0)
    readonly_match = classify_readonly_bash(command)
    if readonly_match is not None:
        matched_verb, rationale = readonly_match
        emit("reversible", "read_only_command", tool_name, session_id, "NA", command,
             matched_verb=matched_verb, rationale=rationale)
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

# ─── 非Bashツールの追加分類 (cmd_175) ───
# cmd_148実測でcategory=tool_unclassifiedの内訳上位を占めた非Bashツールのうち、
# ツール名の意味(harness側の機能定義)だけから確信を持って副作用の性質を判定
# できるもののみを個別列挙で分類する。verbホワイトリスト方式(cmd_152の
# READONLY_VERBS)と異なりプレフィックス一致は行わない——例えばmcp__memory__
# 名前空間には削除・書込系ツール(delete_entities等)も同居しており、
# プレフィックスで束ねるとそれらまで誤ってreversible化するリスクがあるため、
# 個々のツール名を明示列挙する(判定に迷うものは対象外とし、既存の
# tool_unclassifiedへフォールスルーさせる。cmd_152のsed/awk対象外判断と同型)。
#
# TaskCreate/TaskUpdate: 既存コードが既にTodoWrite(同種のセッション内タスク
# 管理・外部副作用なし)をreversible/read_onlyへ分類している前例に倣う。
# ToolSearch/mcp__memory__read_graph/Monitor/AskUserQuestion: いずれも
# 読取専用または単なるUI応答であり、ファイルシステム・外部システムへの
# 書込/削除/送信能力を持たない。
#
# Agent/ScheduleWakeup等は、委譲先の挙動やスケジュール後の実処理まで
# 本ツール呼出し単体からは判定できないため、意図的に対象外のまま
# tool_unclassifiedへフォールスルーさせる(保守的側=unknown)。
NONBASH_TASK_TRACKING = {"TaskCreate", "TaskUpdate"}
NONBASH_READONLY = {"ToolSearch", "mcp__memory__read_graph", "Monitor", "AskUserQuestion"}

if tool_name in NONBASH_TASK_TRACKING:
    emit("reversible", "nonbash_task_tracking", tool_name, session_id, "NA", tool_name)
    sys.exit(0)

if tool_name in NONBASH_READONLY:
    emit("reversible", "nonbash_read_only", tool_name, session_id, "NA", tool_name)
    sys.exit(0)

# 上記いずれにも該当しないツール(WebFetch/Agent/ScheduleWakeup/mcp__*の
# 他ツール等)は判定不能として unknownに倒す(安全側)。
emit("unknown", "tool_unclassified", tool_name, session_id, "NA", tool_name)
PYEOF

OUTPUT="$(printf '%s' "$INPUT" | timeout 4 "$PYTHON_BIN" -c "$PYCODE" 2>/dev/null)"
PY_EXIT=$?

if [ "$PY_EXIT" -ne 0 ] || [ -z "$OUTPUT" ]; then
    echo "[$(date -Iseconds)] WOULD-UNKNOWN mode=$MODE session=unknown file=NA tool=unknown category=hook_internal_error detail=" >> "$LOG_FILE"
    exit 0
fi

IFS=$'\x1f' read -r VERDICT CATEGORY TOOL_NAME SESSION_ID FILE_PATH DETAIL_B64 MATCHED_VERB RATIONALE_B64 <<< "$OUTPUT"
DETAIL="$(printf '%s' "$DETAIL_B64" | base64 -d 2>/dev/null)"
RATIONALE="$(printf '%s' "$RATIONALE_B64" | base64 -d 2>/dev/null)"

case "$VERDICT" in
    irreversible) LOGTOKEN="WOULD-BLOCK" ;;
    reversible) LOGTOKEN="WOULD-ALLOW" ;;
    *) LOGTOKEN="WOULD-UNKNOWN" ;;
esac

# 既存ログ本体のフォーマットは変更しない(cmd_152: 既存ログの読者を壊さない)。
echo "[$(date -Iseconds)] $LOGTOKEN mode=$MODE session=$SESSION_ID file=$FILE_PATH tool=$TOOL_NAME category=$CATEGORY detail=$DETAIL" >> "$LOG_FILE"

# ─── 検知機構 (cmd_152・cmd_151のexclusion effectログを踏襲) ───
# cmd_152で新設した読取専用verb判定パス(category=read_only_command)による
# reversible分類のみを対象に、分類根拠(matched_verb・raw_command・rationale)を
# 別ログへ事後追跡できる形で記録する。既存のgit/testパターン(local_or_test)は
# cmd_145から不変でありこのcmdのリスク導入源ではないため対象外とする
# (スコープを新規判定ロジックに絞ることで、既存経路への影響ゼロを保つ)。
if [ "$VERDICT" = "reversible" ] && [ "$CATEGORY" = "read_only_command" ]; then
    DETAIL_LOG="${REVERSIBILITY_CLASSIFICATION_LOG:-$SCRIPT_DIR/logs/reversibility_classification_detail.jsonl}"
    mkdir -p "$(dirname "$DETAIL_LOG")" 2>/dev/null || true
    PY_JSON="$(TS="$(date -Iseconds)" V_CATEGORY="$CATEGORY" V_TOOL="$TOOL_NAME" \
        V_SESSION="$SESSION_ID" V_VERB="$MATCHED_VERB" V_DETAIL="$DETAIL" V_RATIONALE="$RATIONALE" \
        timeout 4 "$PYTHON_BIN" -c '
import json, os
print(json.dumps({
    "timestamp": os.environ.get("TS"),
    "verdict": "reversible",
    "category": os.environ.get("V_CATEGORY"),
    "tool_name": os.environ.get("V_TOOL"),
    "session_id": os.environ.get("V_SESSION"),
    "matched_verb": os.environ.get("V_VERB"),
    "raw_command": os.environ.get("V_DETAIL"),
    "rationale": os.environ.get("V_RATIONALE"),
}))
' 2>/dev/null)"
    if [ -n "$PY_JSON" ]; then
        printf '%s\n' "$PY_JSON" >> "$DETAIL_LOG"
    fi
fi

exit 0
