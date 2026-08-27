#!/usr/bin/env bash
# PreToolUse hook: 秘匿値pre-commitガード (cmd_183-2・殿裁可・フィーチャー
# フリーズ〈cmd_138〉のカーブアウト)
#
# `git commit`(`-a`/`-am`/`--all`等の派生含む)をPreToolUseで検出し、これから
# commitされる差分の**追加行のみ**(`+`で始まる行。`+++`ヘッダ行・削除行・
# 文脈行は対象外——cmd_180のような秘匿値"除去"commitを誤ってdenyしない
# ため)を、既知の秘匿値形状パターン(P1〜P4、subtask_181_F材料)で走査する。
#
# 検出時はサイレントに書き換えず**拒否**し、denyメッセージには
# (a)該当ファイルパス (b)該当行番号 (c)マッチしたパターンID(P1〜P4)のみを
# 含める。🔴値そのものは画面(denyメッセージ・ログ)へ一切出力しない
# (ガード自身が露出源になっては本末転倒——既存ガードのREASON変数が
# 非秘匿情報のみを含む構成に倣う)。
#
# features.secret_guard_enabled は off|observe|enforce の3値
# (既存3ガードと同方針):
#   off      … 完全無効化(早期リターン、python起動なし)
#   observe … 検証は完全実行するがdenyせず、WOULD-DENYをlogs/へ記録して通す
#   enforce … 検出時に実際にdeny
# 未知値・空値・設定ファイル欠落は必ずoffへ倒す(fail-safe)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${SECRET_GUARD_SETTINGS:-$SCRIPT_DIR/config/settings.yaml}"
LOG_FILE="${SECRET_GUARD_LOG:-$SCRIPT_DIR/logs/secret_guard.log}"
REPO_DIR="${SECRET_GUARD_REPO_DIR:-$SCRIPT_DIR}"
PYTHON_BIN="${SECRET_GUARD_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"

INPUT="$(cat)"

# ─── 早期リターン1: feature flag (grep-based, python起動なし) ───
RAW_LINE=$(grep -E '^[[:space:]]*secret_guard_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE=$(printf '%s' "$RAW_LINE" | sed -E \
    -e 's/^[[:space:]]*secret_guard_enabled:[[:space:]]*//' \
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

# ─── 早期リターン2: tool_nameの軽量抽出(python起動なし) ───
TOOL_NAME=$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"tool_name"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')

SESSION_ID=$(printf '%s' "$INPUT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/^"session_id"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')
SESSION_ID="${SESSION_ID:-unknown}"

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# ─── 早期リターン3: "commit"文字列を含まないBashコマンドは即通過(python
# 起動なし・既存ガードの粗いフィルタと同様の性能最適化)。最終判定はpython側
# の正規なJSONパース+分割で行うため、ここでの粗いフィルタが誤って対象を
# 除外しても実害は無い("commit"を含まないコマンドに`git commit`は含まれ
# 得ない)。
case "$INPUT" in
    *commit*) ;;
    *) exit 0 ;;
esac

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ─── ここから先はcommandのフルJSONパース+commit検出+staged diff走査
# (pythonを起動) ───
read -r -d '' PYCODE <<'PYEOF' || true
import json
import re
import subprocess
import sys


def fail_open(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


try:
    payload = json.load(sys.stdin)
except Exception as e:
    fail_open(f"failed to parse hook stdin JSON: {type(e).__name__}: {e}")

tool_name = payload.get("tool_name")
tool_input = payload.get("tool_input") or {}

if tool_name != "Bash":
    sys.exit(0)

command = tool_input.get("command") or ""

# ─── heredoc本体マスキング(pretooluse_git_push_block.sh cmd_181-A実装を
# 流用): heredocの受け側コマンドがシェル実行系でない場合(`cat`/`tee`/
# リダイレクト等)、heredoc本体は実行されない単なるデータであり、そこに
# 「git commit」という文字列がMarkdown引用等の形でリテラルに現れても実
# コマンドと誤認してはならない。
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

# ─── 複合コマンド分割: 改行・`;`・`&&`・`||`・コマンド置換境界で分割し、
# 各断片へ `git commit` を適用する(既存ガードと同水準の字句分割)。
SPLIT_RE = re.compile(r"\n|;|&&|\|\||\$\(|\)|`")
segments = SPLIT_RE.split(command_for_detection)

GIT_COMMIT_RE = re.compile(r"\bgit\s+commit\b")
A_FLAG_RE = re.compile(r"(^|\s)(-a|--all|-am|-a[a-zA-Z]*m)(\s|$)")

triggered = False
use_working_diff = False  # -a系検出時はgit diff HEAD(未staged含む)を使う
for seg in segments:
    if GIT_COMMIT_RE.search(seg):
        triggered = True
        if A_FLAG_RE.search(seg):
            use_working_diff = True

if not triggered:
    sys.exit(0)

# ─── staged diffの取得(対応事項1: 追加行のみを走査対象とする) ───
diff_args = ["git", "diff", "HEAD"] if use_working_diff else ["git", "diff", "--cached"]
try:
    diff_out = subprocess.run(
        diff_args,
        cwd="__REPO_DIR__",
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout
except Exception as e:
    fail_open(f"failed to run git diff: {type(e).__name__}: {e}")

# ─── 検出パターン(subtask_181_F材料。P1〜P4)───
P1_KNOWN_PREFIX_RE = re.compile(
    r"\b(AKIA|ghp_|gho_|ghu_|ghs_|sk-ant-|sk-proj-|xox[baprs]-)[A-Za-z0-9_-]{10,}\b"
)
P2_HIGH_ENTROPY_RE = re.compile(
    r"\b[a-f0-9]{32,64}\b|\b[A-Za-z0-9+/]{40,}={0,2}\b"
)
P3_ASSIGNMENT_CONTEXT_RE = re.compile(
    r"(?i)\b(api[_-]?key|secret|token|password|bearer|ntfy_topic|access[_-]?key)"
    r"\s*[:=]\s*['\"]?([A-Za-z0-9/+_.-]{8,})"
)
P4_URL_EMBEDDED_RE = re.compile(
    r"https?://[^\s]*[?&](token|key|topic)=[A-Za-z0-9%_-]{8,}"
)

P1_FULL_RE = re.compile(
    r"^(AKIA|ghp_|gho_|ghu_|ghs_|sk-ant-|sk-proj-|xox[baprs]-)[A-Za-z0-9_-]{10,}$"
)
P2_HEX_FULL_RE = re.compile(r"^[a-f0-9]{32,64}$")
P2_B64_FULL_RE = re.compile(r"^[A-Za-z0-9+/]{40,}={0,2}$")


def is_known_hash_format(val):
    # commitハッシュ(40桁16進)・sha256チェックサム(64桁16進)等、非秘匿の
    # 既知16進フォーマットを除外する簡易チェック(subtask_181_F指摘対応)。
    return bool(re.fullmatch(r"[a-f0-9]+", val)) and len(val) in (40, 64)


def value_has_secret_shape(val):
    if P1_FULL_RE.match(val):
        return True
    if P2_HEX_FULL_RE.match(val) and not is_known_hash_format(val):
        return True
    if P2_B64_FULL_RE.match(val):
        return True
    return False


def scan_line(content):
    # P1: 既知プレフィックス系
    if P1_KNOWN_PREFIX_RE.search(content):
        return "P1"
    # P2: 高エントロピー16進/base64系(commitハッシュ等は除外)
    for m in P2_HIGH_ENTROPY_RE.finditer(content):
        if not is_known_hash_format(m.group(0)):
            return "P2"
    # P4: URL埋め込み系
    if P4_URL_EMBEDDED_RE.search(content):
        return "P4"
    # P3: 鍵/token代入文脈系(右辺の値部分がP1/P2形状条件も満たす場合のみ
    # 発火するAND条件——単純な変数宣言・型注釈・None等の誤検知回避)
    m3 = P3_ASSIGNMENT_CONTEXT_RE.search(content)
    if m3 and value_has_secret_shape(m3.group(2)):
        return "P3"
    return None


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")

current_file = None
new_line = None
in_hunk = False
findings = []  # [(file, line_no, pattern_id), ...]

for line in diff_out.splitlines():
    if line.startswith("diff --git "):
        current_file = None
        in_hunk = False
        continue
    if line.startswith("+++ "):
        path = line[4:].strip()
        current_file = None if path == "/dev/null" else (path[2:] if path.startswith("b/") else path)
        in_hunk = False
        continue
    if line.startswith("--- "):
        continue
    hunk_m = HUNK_RE.match(line)
    if hunk_m:
        new_line = int(hunk_m.group(1))
        in_hunk = True
        continue
    if not in_hunk:
        continue
    if line.startswith("\\"):
        continue  # "\ No newline at end of file"
    if line.startswith("+") and not line.startswith("+++"):
        pid = scan_line(line[1:])
        if pid:
            findings.append((current_file or "?", new_line, pid))
        new_line = (new_line or 0) + 1
    elif line.startswith("-") and not line.startswith("---"):
        pass  # 削除行は対象外・new_lineは進めない
    else:
        new_line = (new_line or 0) + 1  # 文脈行(走査対象外だが行番号は進める)

if not findings:
    sys.exit(0)

# 🔴値そのものは一切出力しない。ファイルパス・行番号・パターンIDのみ。
locs = "; ".join(f"{f}:{ln} ({pid})" for f, ln, pid in findings[:5])
more = "" if len(findings) <= 5 else f" (+{len(findings) - 5} more)"
reason = f"secret-shaped content detected in staged diff: {locs}{more}"

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": f"secret guard (cmd_183-2): {reason}",
    }
}))
sys.exit(0)
PYEOF

PYCODE="${PYCODE//__REPO_DIR__/$REPO_DIR}"

ERR_TMP="$(mktemp)"
trap 'rm -f "$ERR_TMP"' EXIT

OUTPUT="$(printf '%s' "$INPUT" | timeout 8 "$PYTHON_BIN" -c "$PYCODE" 2>"$ERR_TMP")"
PY_EXIT=$?

# ─── ログ形式(既存ガードに倣う): 1評価1行・追記型・grep -cで機械集計可能
# な形式。VERDICT ∈ {ALLOW, WOULD-DENY, DENY, FAIL-OPEN}。値そのものは
# ログにも一切出力しない(reasonにはファイルパス・行番号・パターンIDのみ)。
if [ "$PY_EXIT" -ne 0 ]; then
    ERR_MSG="$(tail -1 "$ERR_TMP" 2>/dev/null)"
    echo "[$(date -Iseconds)] FAIL-OPEN mode=$MODE session=$SESSION_ID tool=$TOOL_NAME exit=$PY_EXIT err=$ERR_MSG" >> "$LOG_FILE"
    exit 0
fi

if [ -n "$OUTPUT" ]; then
    if [ "$MODE" = "observe" ]; then
        echo "[$(date -Iseconds)] WOULD-DENY mode=$MODE session=$SESSION_ID tool=$TOOL_NAME reason=$OUTPUT" >> "$LOG_FILE"
        exit 0
    fi
    echo "[$(date -Iseconds)] DENY mode=$MODE session=$SESSION_ID tool=$TOOL_NAME reason=$OUTPUT" >> "$LOG_FILE"
    printf '%s\n' "$OUTPUT"
    exit 0
fi

echo "[$(date -Iseconds)] ALLOW mode=$MODE session=$SESSION_ID tool=$TOOL_NAME" >> "$LOG_FILE"
exit 0
