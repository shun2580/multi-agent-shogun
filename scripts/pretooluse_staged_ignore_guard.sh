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
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${STAGED_IGNORE_GUARD_SETTINGS:-$SCRIPT_DIR/config/settings.yaml}"
LOG_FILE="${STAGED_IGNORE_GUARD_LOG:-$SCRIPT_DIR/logs/staged_ignore_guard.log}"
REPO_DIR="${STAGED_IGNORE_GUARD_REPO_DIR:-$SCRIPT_DIR}"
PYTHON_BIN="${STAGED_IGNORE_GUARD_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"

INPUT="$(cat)"

# ─── 早期リターン1: feature flag (grep-based, git起動なし) ───
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

# cmd_181-B根治: 従来はgrep/sedでJSON文字列を素抜きしていたため、値の中の
# `\"`(JSONエスケープされた引用符)が復元されずそのままCOMMANDへ残っていた
# (実測: `git add "f1" "f2"`は生JSON上`\"f1\" \"f2\"`と表現されるため、
# 素抜きしたCOMMANDにも`\"`が残る)。これが後段のトークン分割で引用符文字が
# パスに付着する誤動作(gunshi_qc_maint_gendrift_A所見)の一因であるため、
# `pretooluse_git_push_block.sh`(cmd_159)と同方針でjson.loadによる正規の
# JSONパース・エスケープ復元へ切替える(過剰な精緻化=完全シェル構文解析器
# の新設ではなく、既存踏襲パターンの必要箇所のみpython化)。python起動不可・
# JSONパース失敗時はCOMMANDが空文字となり、後続の早期リターン3
# (`*git*`非含有)で従来通りfail-safeにexit 0する。
COMMAND=$(printf '%s' "$INPUT" | "$PYTHON_BIN" -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sys.stdout.write((payload.get("tool_input") or {}).get("command") or "")
' 2>/dev/null) || true

# ─── 早期リターン3: "git"文字列を含まないBashコマンドは即通過 ───
case "$COMMAND" in
    *git*) ;;
    *) exit 0 ;;
esac

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ─── コマンド分割(pretooluse_git_push_block.shと同方針): 改行・`;`・`&&`・
# `||`・コマンド置換境界で分割し、各断片へ `git add` / `git commit -a系` を
# 適用する ───
IFS=$'\n' read -r -d '' -a SEGMENTS < <(printf '%s' "$COMMAND" | sed -E 's/(;|&&|\|\|)/\n/g') || true

STAGED_PATHS=()
TRIGGERED=0

is_wildcard_commit_a() {
    # `git commit` に -a/--all/-am/-a<msgflag結合> が含まれるか(簡易判定)
    local seg="$1"
    if printf '%s' "$seg" | grep -qE '\bgit[[:space:]]+commit\b'; then
        printf '%s' "$seg" | grep -qE '(^|[[:space:]])(-a|--all|-am|-a[a-zA-Z]*m)([[:space:]]|$)'
        return $?
    fi
    return 1
}

for seg in "${SEGMENTS[@]:-}"; do
    [ -z "$seg" ] && continue

    if printf '%s' "$seg" | grep -qE '\bgit[[:space:]]+add\b'; then
        TRIGGERED=1
        # `git add` 以降のトークンを抽出し、フラグ(-で始まる)を除外
        AFTER=$(printf '%s' "$seg" | sed -E 's/^.*\bgit[[:space:]]+add\b//')
        for tok in $AFTER; do
            case "$tok" in
                -*) continue ;;
            esac
            # 引用符除去(cmd_181-B): 単語分割はシェルの引用符解釈を行わない
            # ため、`git add "f1" "f2"` のような引用符付き複数パス指定では
            # 引用符文字がトークンに残存し、実パスと不一致になってignore
            # 判定を誤らせる(gunshi_qc_maint_gendrift_A所見)。先頭・末尾が
            # 一致する引用符(ダブル/シングル)のみ除去する
            # (over-engineering回避のためエスケープ引用符等は非対応)。
            case "$tok" in
                \"*\") tok="${tok#\"}"; tok="${tok%\"}" ;;
                \'*\') tok="${tok#\'}"; tok="${tok%\'}" ;;
            esac
            STAGED_PATHS+=("$tok")
        done
        # 明示パス無し(素の `git add` は通常起きないが念のため)はリポジトリ
        # ルート扱い
        [ ${#STAGED_PATHS[@]} -eq 0 ] && STAGED_PATHS+=(".")
    fi

    if is_wildcard_commit_a "$seg"; then
        TRIGGERED=1
        STAGED_PATHS+=(".")
    fi
done

if [ "$TRIGGERED" -eq 0 ]; then
    exit 0
fi

# ─── 対象パスのignore判定 ───
# 明示ファイル指定はそのまま check-ignore。ディレクトリ指定(`.` 含む)は、
# 既にtracked済みのファイルのうちignore陽性のものを列挙する
# (`git add .`/`-A`/`git commit -a` は新規untracked-ignoredファイルを暗黙に
# 拾わないが、tracked済みignoreファイルの変更は暗黙に再stagingするため)。
HIT_PATHS=()

cd "$REPO_DIR" || exit 0

for p in "${STAGED_PATHS[@]}"; do
    if [ -d "$p" ] || [ "$p" = "." ]; then
        while IFS= read -r tracked; do
            [ -z "$tracked" ] && continue
            # --no-index必須: `git check-ignore`はデフォルトでは既にtracked
            # (indexに存在)なパスを常に「非ignore」として扱う(index優先の
            # 既定挙動)ため、tracked-but-ignoredファイルの検出には
            # `--no-index`でindexを無視したパターン純評価が必要
            # (実機検証で確認: 素の`git check-ignore`はtracked済みignore
            # ファイルをnot-ignored扱いしてしまい検出漏れとなった)。
            if git check-ignore -q --no-index -- "$tracked" 2>/dev/null; then
                HIT_PATHS+=("$tracked")
            fi
        done < <(git ls-files -- "$p" 2>/dev/null)
    else
        if git check-ignore -q --no-index -- "$p" 2>/dev/null; then
            HIT_PATHS+=("$p")
        fi
    fi
done

if [ ${#HIT_PATHS[@]} -eq 0 ]; then
    echo "[$(date -Iseconds)] ALLOW mode=$MODE session=$SESSION_ID tool=$TOOL_NAME" >> "$LOG_FILE"
    exit 0
fi

REASON="ignored path(s) in staging target: ${HIT_PATHS[*]}"

if [ "$MODE" = "observe" ]; then
    echo "[$(date -Iseconds)] WOULD-DENY mode=$MODE session=$SESSION_ID tool=$TOOL_NAME reason=$REASON" >> "$LOG_FILE"
    exit 0
fi

echo "[$(date -Iseconds)] DENY mode=$MODE session=$SESSION_ID tool=$TOOL_NAME reason=$REASON" >> "$LOG_FILE"
printf '%s\n' "$(cat <<EOF
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "staged ignore guard (Q33(b)/cmd_171): $REASON"}}
EOF
)"
exit 0
