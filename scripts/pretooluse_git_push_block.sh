#!/usr/bin/env bash
# PreToolUse hook: git push機械ブロック (cmd_159)
#
# `git push` をPreToolUseでdenyし、mandate/decisions_journal.md の
# PUSH-APPROVEDエントリを明示指定(PUSH_APPROVED_ID環境変数)で消化する場合
# のみ通す。承認状態が判定不能(環境変数なし・該当PUSH-APPROVEDエントリ不在・
# decisions_journal.md自体が読めない)は必ずdeny側へ倒す
# (judgment_model原則2: 破壊的操作はunknown時に保留)。
#
# 🔴適用範囲の限界: 本フックが検査するのはBashツール経由のトップレベル
# コマンド文字列のみである。scripts/*.sh内部から呼ばれる`git push`
# (例: 将来的な自動化スクリプトが内部でpushする場合)は検査対象外
# (gunshi_audit_144議題1・CLAUDE.md D006注記と同型の限界)。
# 「pushは機械的に不可能になった」という意味ではない。
#
# 🔴D003との関係: `--force`/`-f`付きpushは既に`.claude/settings.json`の
# 静的permission deny(`Bash(git push --force*)`・`Bash(git push -f *)`)で
# 別レイヤーとして塞がれている。本フックはforce系の再実装を行わず、
# force無しの通常pushを承認キュー経由でのみ通す機構にとどめる
# (D003の迂回路を新設しない)。
#
# features.git_push_block_enabled は off|observe|enforce の3値
# (pretooluse_yaml_guard.shと同方針):
#   off      … 完全無効化(早期リターン、python起動なし)
#   observe … 検証は完全実行するがdenyせず、WOULD-DENYをlogs/へ記録して通す
#   enforce … 未承認push・判定不能pushを実際にdeny
# 未知値・空値・設定ファイル欠落は必ずoffへ倒す(fail-safe)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${GIT_PUSH_BLOCK_SETTINGS:-$SCRIPT_DIR/config/settings.yaml}"
PYTHON_BIN="${GIT_PUSH_BLOCK_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"
NTFY_SCRIPT="${GIT_PUSH_BLOCK_NTFY_SCRIPT:-$SCRIPT_DIR/scripts/ntfy.sh}"
LOG_FILE="${GIT_PUSH_BLOCK_LOG:-$SCRIPT_DIR/logs/git_push_block.log}"
APPROVAL_LEDGER="${GIT_PUSH_BLOCK_APPROVAL_LEDGER:-$SCRIPT_DIR/mandate/decisions_journal.md}"

# ─── 反復DENY警報 (pretooluse_yaml_guard.sh check_repeated_deny_alert()の
# 一般化流用) ───
# git pushには「同一ファイル」という対象概念が無いため、判定軸を
# 「直近600秒間の実DENY総数」という汎用カウンタへ一般化する。3件以上で
# ntfy警報(10分に1回まで抑制)。
check_repeated_deny_alert() {
    local now_epoch window_start count ts ts_epoch
    now_epoch=$(date +%s)
    window_start=$((now_epoch - 600))
    count=0
    while IFS= read -r ts; do
        ts_epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
        [ "$ts_epoch" -ge "$window_start" ] && count=$((count + 1))
    done < <(grep -F -- " DENY " "$LOG_FILE" 2>/dev/null | sed -E 's/^\[([^]]+)\].*/\1/')

    if [ "$count" -ge 3 ]; then
        local marker="${LOG_FILE}.repeated_deny_alert"
        local last_alert=0
        [ -f "$marker" ] && last_alert="$(cat "$marker" 2>/dev/null || echo 0)"
        case "$last_alert" in ''|*[!0-9]*) last_alert=0 ;; esac
        if [ $((now_epoch - last_alert)) -ge 600 ]; then
            echo "$now_epoch" > "$marker" 2>/dev/null || true
            (bash "$NTFY_SCRIPT" "🔁 pretooluse_git_push_block.sh: 直近10分で実DENYが${count}件 — 未承認push試行の反復の可能性" >/dev/null 2>&1 &) || true
        fi
    fi
}

INPUT="$(cat)"

# ─── 早期リターン1: feature flag (grep-based, python起動なし) ───
RAW_LINE=$(grep -E '^[[:space:]]*git_push_block_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE=$(printf '%s' "$RAW_LINE" | sed -E \
    -e 's/^[[:space:]]*git_push_block_enabled:[[:space:]]*//' \
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
    echo "[$(date -Iseconds)] OFF mode=off" >> "$LOG_FILE" 2>/dev/null || true
    exit 0
fi

# ─── 早期リターン2: tool_nameの軽量抽出(python起動なし) ───
TOOL_NAME=$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"tool_name"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')

SESSION_ID=$(printf '%s' "$INPUT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"session_id"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')
SESSION_ID="${SESSION_ID:-unknown}"

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# ─── 早期リターン3: "push"文字列を含まないBashコマンドは即通過(python起動
# なし・yaml_guard.shの対象パスフィルタと同様の性能最適化)。最終判定は
# python側の正規なJSONパース+正規表現マッチで行うため、ここでの粗い
# フィルタが誤って対象を除外しても実害は無い(pushという文字列を含まない
# コマンドに`git push`は含まれ得ない)。
case "$INPUT" in
    *push*) ;;
    *) exit 0 ;;
esac

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ─── ここから先はcommandのフルJSONパース+検出+承認判定(pythonを起動) ───
read -r -d '' PYCODE <<'PYEOF' || true
import json
import re
import sys


def fail_open(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


# cmd_194 工程6'(a): mask_quoted_nonexec_stringsはpretooluse_reversibility_
# check.shと共有するためlib/quote_masking.pyへ抽出した(lib/evidence_checks.py
# と同型、二重実装を避ける)。
sys.path.insert(0, "__LIB_DIR__")
try:
    from quote_masking import mask_quoted_nonexec_strings
except Exception as e:
    fail_open(f"failed to import quote_masking module: {type(e).__name__}: {e}")


try:
    payload = json.load(sys.stdin)
except Exception as e:
    fail_open(f"failed to parse hook stdin JSON: {type(e).__name__}: {e}")

tool_name = payload.get("tool_name")
tool_input = payload.get("tool_input") or {}

if tool_name != "Bash":
    sys.exit(0)

command = tool_input.get("command") or ""

# ─── heredoc本体マスキング(cmd_181-A): heredocの受け側コマンドが
# `bash`/`sh`/`zsh`等のシェル実行系でない場合(`cat`/`tee`/リダイレクト等)、
# heredoc本体は実行されない単なるデータである。そこに「git push」という
# 文字列が(バッククォートによるMarkdown引用等の形で)リテラルに現れても、
# 下記SPLIT_REがバッククォートを分割境界として扱うため誤って独立断片化され
# 実コマンドと誤認DENYされる(実例: cmd_180下達コマンドの
# `` `git push --force`はD003で絶対禁止 `` というheredoc内の地の文)。
# 受け側がシェル実行系の場合(`bash <<'EOF' ... EOF`)はheredoc本体が実際に
# 実行されるため、その場合は本体を保持しマスクしない。
HEREDOC_START_RE = re.compile(r"<<(-|~)?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
SHELL_EXEC_BASENAMES = {"bash", "sh", "zsh", "dash", "ksh", "eval"}
CMD_BOUNDARY_RE = re.compile(r"[;\n]|&&|\|\|?")


def mask_non_shell_heredoc_bodies(cmd):
    out = []
    pos = 0
    search_start = 0
    while True:
        m = HEREDOC_START_RE.search(cmd, search_start)
        if m is None:
            out.append(cmd[pos:])
            break
        prefix = cmd[pos:m.start()]
        segs = CMD_BOUNDARY_RE.split(prefix)
        words = segs[-1].strip().split()
        sink = words[0].rsplit("/", 1)[-1] if words else ""
        delim = m.group(3)
        strip_tabs = m.group(1) == "-"
        nl = cmd.find("\n", m.end())
        if nl == -1:
            out.append(cmd[pos:])
            break
        body_start = nl + 1
        term_pattern = (r"^\t*" if strip_tabs else r"^") + re.escape(delim) + r"[ \t]*$"
        term_m = re.compile(term_pattern, re.MULTILINE).search(cmd, body_start)
        if term_m is None:
            out.append(cmd[pos:])
            break
        body_end = term_m.start()
        out.append(cmd[pos:body_start])
        if sink not in SHELL_EXEC_BASENAMES:
            out.append("\n" * cmd.count("\n", body_start, body_end))
        else:
            out.append(cmd[body_start:body_end])
        pos = body_end
        search_start = term_m.end()
    return "".join(out)


command_for_detection = mask_non_shell_heredoc_bodies(command)

# ─── 引用符内非実行文字列マスキング(cmd_194 工程5、工程6'(a)でlib/
# quote_masking.pyへ抽出): heredocマスキングでは救えない偽陽性(`bash
# scripts/inbox_write.sh <agent> "地の文にgit pushという語句を含む
# メッセージ"`等、実行されないただの引数文字列内のリテラル「git push」)を、
# 実行される経路(bash -c/sh -c/evalの引数)は保護したまま是正する。既存の
# mask_non_shell_heredoc_bodies・後続のsplit+GIT_PUSH_RE検出ロジックは
# 一切変更しない(本ブロックはその間に追加する専用ステップ)。実装は
# scripts/pretooluse_reversibility_check.shと共有するためlib/quote_
# masking.pyへ抽出した(import箇所は本ファイル冒頭)。挙動は抽出前と不変。
command_for_detection = mask_quoted_nonexec_strings(command_for_detection)

# ─── 複合コマンド分割(pretooluse_reversibility_check.shの_DANGER_CHARS_RE型
# 分割ロジックを一般化): 改行・`;`・`&&`・`||`・コマンド置換($( ) とバック
# クォート)の境界で分割し、各断片に対し\bgit\s+push\bを適用する。分割自体は
# 単純な字句分割であり、クォート内文字列の除外等の高度な構文解析は行わない
# (既存reversibility_check.shと同水準、過剰な精緻化はscope超過と判断)。
SPLIT_RE = re.compile(r"\n|;|&&|\|\||\$\(|\)|`")
segments = SPLIT_RE.split(command_for_detection)

GIT_PUSH_RE = re.compile(r"\bgit\s+push\b")

if not any(GIT_PUSH_RE.search(seg) for seg in segments):
    sys.exit(0)

# ─── 承認判定 ───
# `PUSH_APPROVED_ID=P-<数字>` という環境変数プレフィックスパターンをcommand
# 文字列全体から探し、対応するPUSH-APPROVEDエントリが decisions_journal.md
# に行頭アンカー付きで実在するかを確認する。両方が真の場合のみ承認扱い。
approved = False
reason = "no PUSH_APPROVED_ID prefix found in command"

m = re.search(r"PUSH_APPROVED_ID=(P-\d+)", command)
if m:
    token = m.group(1)
    try:
        with open("__APPROVAL_LEDGER__", "r", encoding="utf-8") as f:
            journal_text = f.read()
    except OSError as e:
        journal_text = None
        reason = f"failed to read decisions_journal.md: {type(e).__name__}: {e}"

    if journal_text is not None:
        entry_re = re.compile(
            rf"^\S+\s*\|\s*PUSH-APPROVED\s*\|\s*{re.escape(token)}\b",
            re.MULTILINE,
        )
        if entry_re.search(journal_text):
            approved = True
            reason = f"decisions_journal.md contains PUSH-APPROVED entry for {token}"
        else:
            reason = f"no PUSH-APPROVED entry for {token} found in decisions_journal.md"

if approved:
    sys.exit(0)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": f"git push blocked (cmd_159): {reason}",
    }
}))
sys.exit(0)
PYEOF

PYCODE="${PYCODE//__APPROVAL_LEDGER__/$APPROVAL_LEDGER}"
PYCODE="${PYCODE//__LIB_DIR__/$SCRIPT_DIR/lib}"

ERR_TMP="$(mktemp)"
trap 'rm -f "$ERR_TMP"' EXIT

OUTPUT="$(printf '%s' "$INPUT" | timeout 4 "$PYTHON_BIN" -c "$PYCODE" 2>"$ERR_TMP")"
PY_EXIT=$?

# ─── ログ形式(pretooluse_yaml_guard.shに倣う): 1評価1行・追記型・
# grep -cで機械集計可能な形式。VERDICT ∈ {ALLOW, WOULD-DENY, DENY, FAIL-OPEN}。
if [ "$PY_EXIT" -ne 0 ]; then
    ERR_MSG="$(tail -1 "$ERR_TMP" 2>/dev/null)"
    echo "[$(date -Iseconds)] FAIL-OPEN mode=$MODE session=$SESSION_ID tool=$TOOL_NAME exit=$PY_EXIT err=$ERR_MSG" >> "$LOG_FILE"
    (bash "$NTFY_SCRIPT" "⚠️ pretooluse_git_push_block.sh fail-open: exit=$PY_EXIT err=$ERR_MSG" >/dev/null 2>&1 &) || true
    exit 0
fi

if [ -n "$OUTPUT" ]; then
    if [ "$MODE" = "observe" ]; then
        # observeモード: 検証は完全実行するがdenyせず、WOULD-DENYとしてログのみ
        # 記録して通す。
        echo "[$(date -Iseconds)] WOULD-DENY mode=$MODE session=$SESSION_ID tool=$TOOL_NAME reason=$OUTPUT" >> "$LOG_FILE"
        exit 0
    fi
    echo "[$(date -Iseconds)] DENY mode=$MODE session=$SESSION_ID tool=$TOOL_NAME reason=$OUTPUT" >> "$LOG_FILE"
    check_repeated_deny_alert
    printf '%s\n' "$OUTPUT"
    exit 0
fi

# 検証完了・通過(git push検出なし、または承認済みAQエントリで消化)。
echo "[$(date -Iseconds)] ALLOW mode=$MODE session=$SESSION_ID tool=$TOOL_NAME" >> "$LOG_FILE"
exit 0
