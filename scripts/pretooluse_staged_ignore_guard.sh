#!/usr/bin/env bash
# PreToolUse hook: staging中のgit-ignore対象パス機械ブロック (Q33(b)・cmd_171)
#
# `git add`/`git commit -a|-am|--all` をPreToolUseで検査し、staging対象に
# `git check-ignore` 陽性(=.gitignoreに意図的に除外指定されている)パスが
# 含まれていればdenyする。dashboard.md誤追跡(cmd_166・commit 4a27ad7)・
# config/settings.yaml誤追跡(cmd_158-B)がいずれも「既にtrackedだが
# ignore指定されているファイルが`git add .`/`-A`/`git commit -a`で暗黙に
# 再staging された」構造であったため、明示パス指定だけでなくワイルドカード
# staging(`.`/`-A`/`-a`系)も対象とする(tracked済みignoreファイルの再検出、
# 及び明示ファイル名指定+`-f`強制staging双方を捕捉する)。
#
# features.staged_ignore_guard_enabled は off|observe|enforce の3値
# (pretooluse_git_push_block.shと同方針):
#   off      … 完全無効化(早期リターン、python/git起動なし)
#   observe … 検証は完全実行するがdenyせず、WOULD-DENYをlogs/へ記録して通す
#   enforce … ignore陽性のstagingを実際にdeny
# 未知値・空値・設定ファイル欠落は必ずoffへ倒す(fail-safe)。
#
# cmd_186根治(3欠陥):
#   欠陥1(cwd誤判定): 対象リポジトリの解決先を、hook入力JSONのcwdから
#     `git rev-parse --show-toplevel`で解決するよう修正(解決失敗時のみ
#     fail-safeでexit 0=通す)。従来はSCRIPT_DIR固定=常にmulti-agent-shogun
#     の.gitignoreで判定していたため、他リポジトリでのgit addが無条件denyに
#     なっていた。
#   欠陥2(heredoc/散文誤検知): pretooluse_git_push_block.sh(cmd_181-A)の
#     mask_non_shell_heredoc_bodies()をそのまま移植。非シェル実行heredoc
#     (cat/tee等の受け側)の本体は実行されない単なるデータであり、そこに
#     「git add」という文字列がリテラルに現れても実コマンドと誤認しない。
#   欠陥3(JSON非エスケープfail-open): denyのJSON出力を手組み文字列展開
#     ではなく`json.dumps`で生成するよう変更。理由文字列に二重引用符が
#     混入してもJSONが壊れず、denyが黙って失効する経路を根絶した。
#   検出・判定ロジック本体をpythonへ一本化(git_push_block.sh/secret_guard.sh
#   と同一アーキテクチャ)。JSON入力パースが従来のgrep素抜きから正規の
#   json.loadへ揃うため、cmd_181-Bで踏んだ引用符エスケープ復元漏れの再発
#   余地も構造的に無くなる。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${STAGED_IGNORE_GUARD_SETTINGS:-$SCRIPT_DIR/config/settings.yaml}"
LOG_FILE="${STAGED_IGNORE_GUARD_LOG:-$SCRIPT_DIR/logs/staged_ignore_guard.log}"
PYTHON_BIN="${STAGED_IGNORE_GUARD_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"
# REPO_DIR(check-ignore評価対象のリポジトリ)の解決は python 側で行う
# (STAGED_IGNORE_GUARD_REPO_DIRのテスト隔離用上書き、またはhook入力cwdからの
# 動的解決)。

INPUT="$(cat)"

# ─── 早期リターン1: feature flag (grep-based, git/python起動なし) ───
RAW_LINE=$(grep -E '^[[:space:]]*staged_ignore_guard_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE=$(printf '%s' "$RAW_LINE" | sed -E \
    -e 's/^[[:space:]]*staged_ignore_guard_enabled:[[:space:]]*//' \
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

# ─── 早期リターン3: "git"文字列を含まないBashコマンドは即通過(python起動
# なし・既存ガードの粗いフィルタと同様の性能最適化)。最終判定はpython側の
# 正規なJSONパースで行うため、ここでの粗いフィルタが誤って対象を除外しても
# 実害は無い("git"を含まないコマンドに`git add`/`git commit`は含まれ得ない)。
case "$INPUT" in
    *git*) ;;
    *) exit 0 ;;
esac

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ─── ここから先はcommandのフルJSONパース+heredocマスク+検出+対象リポジトリ
# 解決+check-ignore評価+deny JSON生成(pythonを起動) ───
read -r -d '' PYCODE <<'PYEOF' || true
import json
import os
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
cwd = payload.get("cwd") or ""

# ─── heredoc本体マスキング(cmd_181-Aをpretooluse_git_push_block.shから移植・
# cmd_186欠陥2根治): heredocの受け側コマンドがシェル実行系でない場合
# (`cat`/`tee`/リダイレクト等)、heredoc本体は実行されない単なるデータで
# ある。そこに「git add」という文字列がリテラルに(地の文・commitメッセージ
# 等として)現れても実コマンドと誤認してはならない。受け側がシェル実行系の
# 場合(`bash <<'EOF' ... EOF`)はheredoc本体が実際に実行されるため、その
# 場合は本体を保持しマスクしない。
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

# ─── コマンド分割: 改行・`;`・`&&`・`||`の境界で分割し、各断片へ`git add`/
# `git commit -a系`を適用する(既存ガードと同水準の字句分割。command
# substitution境界での分割は本ガードの対象外・過剰な精緻化として見送る)。
SPLIT_RE = re.compile(r"\n|;|&&|\|\|")
segments = SPLIT_RE.split(command_for_detection)

GIT_ADD_RE = re.compile(r"\bgit\s+add\b")
GIT_COMMIT_RE = re.compile(r"\bgit\s+commit\b")
A_FLAG_RE = re.compile(r"(^|\s)(-a|--all|-am|-a[a-zA-Z]*m)(\s|$)")


def strip_quotes(tok):
    # 引用符除去(cmd_181-B踏襲): 先頭・末尾が一致する引用符(ダブル/
    # シングル)のみ除去する(過剰な精緻化回避のためエスケープ引用符等は
    # 非対応)。
    if len(tok) >= 2 and (
        (tok[0] == '"' and tok[-1] == '"') or (tok[0] == "'" and tok[-1] == "'")
    ):
        return tok[1:-1]
    return tok


def is_wildcard_commit_a(seg):
    if not GIT_COMMIT_RE.search(seg):
        return False
    return bool(A_FLAG_RE.search(seg))


triggered = False
staged_paths = []
for seg in segments:
    if not seg:
        continue

    if GIT_ADD_RE.search(seg):
        triggered = True
        after = GIT_ADD_RE.split(seg, maxsplit=1)[-1]
        seg_tokens = [strip_quotes(t) for t in after.split() if not t.startswith("-")]
        staged_paths.extend(seg_tokens)
        # 明示パス無し(素の`git add`は通常起きないが念のため)はリポジトリ
        # ルート扱い。
        if not staged_paths:
            staged_paths.append(".")

    if is_wildcard_commit_a(seg):
        triggered = True
        staged_paths.append(".")

if not triggered:
    sys.exit(0)

# ─── cmd_186欠陥1根治: 対象リポジトリの解決 ───
# STAGED_IGNORE_GUARD_REPO_DIR(テスト隔離用の明示上書き)が設定されていれば
# 最優先で尊重する。未設定の場合、hook入力JSONのcwd(Claude Codeのhook契約で
# 実行時作業ディレクトリとして渡される)から`git rev-parse --show-toplevel`
# で実際にgitコマンドが走ったリポジトリを解決する。
repo_dir = os.environ.get("STAGED_IGNORE_GUARD_REPO_DIR") or ""
if not repo_dir:
    if cwd:
        try:
            r = subprocess.run(
                ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, timeout=5,
            )
            if r.returncode == 0:
                repo_dir = r.stdout.strip()
        except Exception:
            repo_dir = ""
    if not repo_dir:
        # fail-safe(原則2・stagingは非破壊): 対象リポジトリを解決できない
        # 場合はdenyせず通す。誤検知で正当な作業を止める損失の方が、この
        # 経路での見逃しより大きい。この分岐はcwd解決の失敗専用であり、
        # 下記のdeny JSON生成失敗(欠陥3根治対象)とは別物——混同しない。
        print(f"UNRESOLVED_REPO\t{cwd}")
        sys.exit(0)

# ─── 対象パスのignore判定 ───
# 明示ファイル指定はそのまま check-ignore。ディレクトリ指定(`.` 含む)は、
# 既にtracked済みのファイルのうちignore陽性のものを列挙する
# (`git add .`/`-A`/`git commit -a` は新規untracked-ignoredファイルを暗黙に
# 拾わないが、tracked済みignoreファイルの変更は暗黙に再stagingするため)。
hit_paths = []

for p in staged_paths:
    is_dir_like = (p == ".") or os.path.isdir(os.path.join(repo_dir, p))
    if is_dir_like:
        try:
            r = subprocess.run(
                ["git", "ls-files", "--", p],
                cwd=repo_dir, capture_output=True, text=True, timeout=10,
            )
            tracked_files = [line for line in r.stdout.splitlines() if line]
        except Exception:
            tracked_files = []
        for tracked in tracked_files:
            try:
                # --no-index必須: `git check-ignore`はデフォルトでは既に
                # tracked(indexに存在)なパスを常に「非ignore」として扱う
                # (index優先の既定挙動)ため、tracked-but-ignoredファイルの
                # 検出には`--no-index`でindexを無視したパターン純評価が
                # 必要(実機検証で確認済み)。
                ci = subprocess.run(
                    ["git", "check-ignore", "-q", "--no-index", "--", tracked],
                    cwd=repo_dir, timeout=5,
                )
                if ci.returncode == 0:
                    hit_paths.append(tracked)
            except Exception:
                pass
    else:
        try:
            ci = subprocess.run(
                ["git", "check-ignore", "-q", "--no-index", "--", p],
                cwd=repo_dir, timeout=5,
            )
            if ci.returncode == 0:
                hit_paths.append(p)
        except Exception:
            pass

if not hit_paths:
    sys.exit(0)

reason_msg = "ignored path(s) in staging target: " + " ".join(hit_paths)

# ─── cmd_186欠陥3根治: JSON非エスケープによるfail-openの根絶 ───
# `json.dumps`による正規なJSON生成へ切替え、理由文字列に二重引用符等が
# 混入してもJSONが壊れないようにする。それでも出力生成自体が何らかの理由で
# 失敗した場合(通常起こり得ないが)、fail-safeで「通す」設計にはせず、
# 理由を簡略化した固定文字列(補間なし・壊れようがない)で必ずdenyを
# 成立させる——denyの意思が黙って消える経路を残さない(原則5)。
try:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"staged ignore guard (Q33(b)/cmd_171): {reason_msg}",
        }
    }))
except Exception:
    print(
        '{"hookSpecificOutput": {"hookEventName": "PreToolUse", '
        '"permissionDecision": "deny", "permissionDecisionReason": '
        '"staged ignore guard (Q33(b)/cmd_171): ignored path(s) detected '
        '(reason unavailable due to output error)"}}'
    )
sys.exit(0)
PYEOF

ERR_TMP="$(mktemp)"
trap 'rm -f "$ERR_TMP"' EXIT

OUTPUT="$(printf '%s' "$INPUT" | timeout 8 "$PYTHON_BIN" -c "$PYCODE" 2>"$ERR_TMP")"
PY_EXIT=$?

# ─── ログ形式(既存ガードに倣う): 1評価1行・追記型・grep -cで機械集計可能な
# 形式。VERDICT ∈ {ALLOW, ALLOW(unresolved-repo), WOULD-DENY, DENY,
# FAIL-OPEN}。
if [ "$PY_EXIT" -ne 0 ]; then
    ERR_MSG="$(tail -1 "$ERR_TMP" 2>/dev/null)"
    echo "[$(date -Iseconds)] FAIL-OPEN mode=$MODE session=$SESSION_ID tool=$TOOL_NAME exit=$PY_EXIT err=$ERR_MSG" >> "$LOG_FILE"
    exit 0
fi

case "$OUTPUT" in
    "UNRESOLVED_REPO"$'\t'*)
        CWD_INFO="${OUTPUT#UNRESOLVED_REPO$'\t'}"
        echo "[$(date -Iseconds)] ALLOW(unresolved-repo) mode=$MODE session=$SESSION_ID tool=$TOOL_NAME cwd=$CWD_INFO" >> "$LOG_FILE"
        exit 0
        ;;
esac

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
