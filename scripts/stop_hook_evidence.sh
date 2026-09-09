#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# stop_hook_evidence.sh — Claude Code Stop Hook: 完了ゲート(cmd_192 工程8)
# ═══════════════════════════════════════════════════════════════
# scripts/stop_hook_inbox.sh とは別エントリで .claude/settings.json の
# Stop hook配列へ登録する(stop_hook_inbox.sh 自体は無変更)。
#
# 対象: 足軽・軍師・家老。将軍(AGENT_ID=shogun)は対象外。
#
# 判定条件(すべて機械的。いずれか不成立ならenforce時にdecision:blockを返す):
#   (a) 自分の担当タスク(queue/tasks/{agent}.yaml のstatusが「実施中」を
#       示す値)に対応するreport YAMLエントリ(queue/reports/{agent}_report.yaml、
#       task_idで照合)が存在する。
#       🔴指示文原本(cmd_192 工程8)は「statusがin_progressのもの」と書くが、
#       `grep -rh "status:" queue/tasks/*.yaml` で実データを確認したところ
#       `in_progress` という値の実例は0件で、「実施中」を示す実際の値は
#       `status: assigned` である(`done`/`done_with_caveat`/`cancelled`/`idle`
#       は完了・非活動)。本スクリプトは実データに基づき`assigned`を用いる。
#   (b) 上記reportエントリに、実行コマンドと戻り値またはテスト出力を示す
#       非空の証跡フィールドがある。
#       🔴指示文は「evidence:」という単一フィールド名を想定するが、実際の
#       report YAML(例: queue/reports/ashigaru5_report.yaml)には
#       `syntax_evidence`/`commit_evidence`/`test_evidence`等、末尾
#       `_evidence`のフィールド名が使われ、リテラル`evidence:`というキーは
#       存在しない。本スクリプトは`[\w]*evidence\s*:`(末尾一致)で検出する。
#   (c) reportが`committed: true`またはcommitハッシュを主張していれば、
#       そのハッシュが`git rev-parse --verify`で実在する。
#   (d) reportの`test_results:`または`tests:`配下の文字列に、SKIPの
#       非ゼロ件数を示す記述が含まれていない(SKIP=FAIL則の機械化)。
#       test_results/tests自体が無いエントリ(ドキュメントのみの作業等)は
#       本条件を評価対象外とする(vacuous pass)。
#
# 工程8-2(8回連続block対策): Claude Codeは8回連続blockでセッションを
# 強制終了する。実際にblock(enforceモード時のみ)が発生した回数を
# logs/stop_hook_evidence_blocks/{agent}.count へ永続化し、6回目のblockで
# 殿へntfy送信する(強制終了の前に届かせる)。非block(pass)でカウンタを
# リセットする。observeモードは実際にblockしない(セッション強制終了の
# リスクが無い)ため、カウンタ増減の対象外とする。
#
# Usage: Stop hookとして登録。stdinにJSON(last_assistant_message等)を
#   受け取り、必要ならJSON({"decision":"block","reason":"..."})を返す。
#
# Environment (production defaults / testing overrides):
#   STOP_HOOK_EVIDENCE_SETTINGS         — config/settings.yaml path
#   STOP_HOOK_EVIDENCE_AGENT_ID         — agent id override (tmux解決の代替)
#   STOP_HOOK_EVIDENCE_TASKS_DIR        — queue/tasks/ dir override
#   STOP_HOOK_EVIDENCE_REPORTS_DIR      — queue/reports/ dir override
#   STOP_HOOK_EVIDENCE_LOG              — log file override
#   STOP_HOOK_EVIDENCE_PYTHON           — python3 binary override
#   STOP_HOOK_EVIDENCE_BLOCK_COUNT_DIR  — block連続カウンタ永続化dir override
#   STOP_HOOK_EVIDENCE_NTFY_SCRIPT      — ntfy.sh path override(テスト時はstub)
#   STOP_HOOK_EVIDENCE_NOTIFY_THRESHOLD — 通知閾値(既定6、テスト用上書き)
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS="${STOP_HOOK_EVIDENCE_SETTINGS:-$REPO_ROOT/config/settings.yaml}"
PYTHON_BIN="${STOP_HOOK_EVIDENCE_PYTHON:-$REPO_ROOT/.venv/bin/python3}"
LOG_FILE="${STOP_HOOK_EVIDENCE_LOG:-$REPO_ROOT/logs/stop_hook_evidence.log}"
TASKS_DIR="${STOP_HOOK_EVIDENCE_TASKS_DIR:-$REPO_ROOT/queue/tasks}"
REPORTS_DIR="${STOP_HOOK_EVIDENCE_REPORTS_DIR:-$REPO_ROOT/queue/reports}"
BLOCK_COUNT_DIR="${STOP_HOOK_EVIDENCE_BLOCK_COUNT_DIR:-$REPO_ROOT/logs/stop_hook_evidence_blocks}"
NTFY_SCRIPT="${STOP_HOOK_EVIDENCE_NTFY_SCRIPT:-$REPO_ROOT/scripts/ntfy.sh}"
NOTIFY_THRESHOLD="${STOP_HOOK_EVIDENCE_NOTIFY_THRESHOLD:-6}"

# ─── 早期リターン1: feature flag (grep-based, stdin読取・python起動なし) ───
RAW_LINE=$(grep -E '^[[:space:]]*evidence_gate_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE=$(printf '%s' "$RAW_LINE" | sed -E \
    -e 's/^[[:space:]]*evidence_gate_enabled:[[:space:]]*//' \
    -e 's/[[:space:]]*#.*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\1/")

case "$RAW_VALUE" in
    enforce) MODE="enforce" ;;
    observe) MODE="observe" ;;
    *) MODE="off" ;;  # off/空/未知値/欠落はすべてfail-safeでoff
esac

if [ "$MODE" = "off" ]; then
    exit 0
fi

# ─── agent_id解決(stop_hook_inbox.shの既存パターンに倣う)。
# テスト隔離用にSTOP_HOOK_EVIDENCE_AGENT_IDでの上書きを許容する。
# 解決不能・shogunはfail-safeでexit 0(将軍は対象外)。 ───
AGENT_ID="${STOP_HOOK_EVIDENCE_AGENT_ID:-}"
if [ -z "$AGENT_ID" ] && [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
fi

if [ -z "$AGENT_ID" ] || [ "$AGENT_ID" = "shogun" ]; then
    exit 0
fi

# ─── stdin JSON読取(🔴cmd_186教訓: 正規のJSONパーサのみ使用。grepでの
# 文字列素抜き・heredoc展開による手組み抽出は禁止)。 ───
INPUT="$(cat)"

STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | "$PYTHON_BIN" -c "
import json, sys
try:
    print(json.load(sys.stdin).get('stop_hook_active', False))
except Exception:
    print(False)
" 2>/dev/null || echo "False")

# stop_hook_inbox.shと同じループ防止方針: 一度この停止サイクルで
# 継続済み(stop_hook_active=true)なら、二重blockでの無限ループを避けて
# 今回は素通りする。
if [ "$STOP_HOOK_ACTIVE" = "True" ]; then
    exit 0
fi

TASK_YAML="$TASKS_DIR/${AGENT_ID}.yaml"
REPORT_FILE="$REPORTS_DIR/${AGENT_ID}_report.yaml"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ─── (a)〜(d) 判定本体。単一のpython呼出にまとめ、判定結果をJSON1行で
# stdoutへ返す(bash側での文字列組立を避けるcmd_186教訓の徹底)。 ───
RESULT_JSON="$("$PYTHON_BIN" - "$TASK_YAML" "$REPORT_FILE" "$REPO_ROOT" <<'PYEOF' 2>/dev/null
import json
import re
import subprocess
import sys

task_yaml_path, report_file_path, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    import yaml
except Exception:
    print(json.dumps({"gate": "skip", "why": "pyyaml-unavailable"}))
    sys.exit(0)


def load_task():
    try:
        with open(task_yaml_path, "r") as f:
            data = yaml.safe_load(f)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    task = data.get("task")
    if not isinstance(task, dict):
        return None
    return task


def find_report_entry(task_id):
    try:
        with open(report_file_path, "r") as f:
            raw = f.read()
    except Exception:
        return None, None
    # queue/reports/*.yaml は複数YAMLドキュメントを行単独の "---" で区切る
    # 実運用形式(通常のYAML `---`ドキュメント区切りと同じ記法)。
    chunks = re.split(r"(?m)^---[ \t]*$", raw)
    for chunk in chunks:
        if "task_id:" not in chunk:
            continue
        try:
            doc = yaml.safe_load(chunk)
        except Exception:
            continue
        if not isinstance(doc, dict):
            continue
        entry = doc.get("report") if isinstance(doc.get("report"), dict) else doc
        if not isinstance(entry, dict):
            continue
        if entry.get("task_id") == task_id:
            return chunk, entry
    return None, None


def collect_strings(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from collect_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from collect_strings(v)
    elif isinstance(node, str):
        yield node


def check_evidence(raw_chunk):
    # 🔴実データではリテラル`evidence:`ではなく`*_evidence:`系の
    # フィールド名が使われる(scripts本体コメント参照)。末尾一致で検出する。
    for m in re.finditer(r"(?im)^[ \t]*[\w]*evidence[ \t]*:[ \t]*(.*)$", raw_chunk):
        inline = m.group(1).strip()
        if inline and inline not in ("|", ">", "|-", ">-"):
            return True
        # ブロックスカラ(| / >)の場合、後続の字下げ行に非空内容があるか確認
        if inline in ("|", ">", "|-", ">-"):
            lines = raw_chunk[m.end():].splitlines()
            key_indent = len(m.group(0)) - len(m.group(0).lstrip())
            for line in lines:
                if line.strip() == "":
                    continue
                indent = len(line) - len(line.lstrip())
                if indent <= key_indent:
                    break
                if line.strip():
                    return True
    return False


def check_commit(raw_chunk):
    # committed: true の明示、または commit文脈での7〜40桁hexトークンの
    # 主張を抽出する。主張が無ければ本条件は評価対象外(vacuous pass)。
    claims = []
    if re.search(r"(?i)^\s*committed\s*:\s*true\s*$", raw_chunk, re.MULTILINE):
        claims.append(True)
    for line in raw_chunk.splitlines():
        if re.search(r"(?i)commit", line):
            for hexmatch in re.finditer(r"\b[0-9a-f]{7,40}\b", line, re.IGNORECASE):
                claims.append(hexmatch.group(0))
    if not claims:
        return True, None  # 主張なし → vacuous pass
    hashes = [c for c in claims if c is not True]
    if not hashes:
        # committed: true はあるがハッシュ主張が無い → git側で検証できない
        # ため、ここでは主張の存在のみで不成立とはしない(vacuous pass扱い)。
        return True, None
    for h in hashes:
        try:
            subprocess.run(
                ["git", "rev-parse", "--verify", "--quiet", f"{h}^{{commit}}"],
                cwd=repo_root,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )
            return True, None
        except Exception:
            continue
    return False, f"commit hash(es) not found in git log: {hashes}"


def check_skip(entry):
    test_node = entry.get("test_results")
    if test_node is None:
        test_node = entry.get("tests")
    if test_node is None:
        return True, None  # test_results/tests自体が無い → 評価対象外
    for s in collect_strings(test_node):
        for m in re.finditer(r"(?i)skip", s):
            tail = s[m.end():m.end() + 8]
            # 🔴「0件」のように直後がCJK文字だと\bが単語境界と判定しない
            # (Python re の既定Unicodeモードでは表意文字も\w扱いのため)。
            # 「0」の直後が数字でなければ0件扱いとする(?!\d)を使う。
            if re.match(r"^\s*[:=]?\s*0(?!\d)", tail):
                continue
            return False, f"SKIP indication found: ...{s[max(0, m.start()-20):m.end()+20]}..."
    return True, None


task = load_task()
if task is None:
    print(json.dumps({"gate": "skip", "why": "task-yaml-unreadable"}))
    sys.exit(0)

status = task.get("status")
if status != "assigned":
    print(json.dumps({"gate": "skip", "why": f"status={status!r} is not the in-progress marker (assigned)"}))
    sys.exit(0)

task_id = task.get("task_id")
if not task_id:
    print(json.dumps({"gate": "skip", "why": "task_id missing"}))
    sys.exit(0)

raw_chunk, entry = find_report_entry(task_id)
if entry is None:
    print(json.dumps({"gate": "block", "reason": f"(a) no report entry for task_id={task_id} in {report_file_path}"}))
    sys.exit(0)

if not check_evidence(raw_chunk):
    print(json.dumps({"gate": "block", "reason": f"(b) no non-empty *evidence field in report entry task_id={task_id}"}))
    sys.exit(0)

commit_ok, commit_reason = check_commit(raw_chunk)
if not commit_ok:
    print(json.dumps({"gate": "block", "reason": f"(c) {commit_reason}"}))
    sys.exit(0)

skip_ok, skip_reason = check_skip(entry)
if not skip_ok:
    print(json.dumps({"gate": "block", "reason": f"(d) {skip_reason}"}))
    sys.exit(0)

print(json.dumps({"gate": "pass"}))
PYEOF
)"

# python呼出自体が異常終了(構文エラー等)した場合はfail-safeで通す
# (判定不能=何もしない。scope_check.shの既定方針と同型)。
if [ -z "$RESULT_JSON" ]; then
    exit 0
fi

GATE="$(printf '%s' "$RESULT_JSON" | "$PYTHON_BIN" -c "
import json, sys
try:
    print(json.load(sys.stdin).get('gate', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"

REASON="$(printf '%s' "$RESULT_JSON" | "$PYTHON_BIN" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('reason') or d.get('why') or '')
except Exception:
    print('')
" 2>/dev/null || echo "")"

TIMESTAMP="$(date -Iseconds)"

if [ "$GATE" = "skip" ]; then
    # 対象タスクなし(status不一致・task YAML欠落等) → ゲート対象外。
    # ログ無出力(scope_check.shのfail-safe時の既定方針に倣う)。
    exit 0
fi

if [ "$GATE" = "pass" ]; then
    echo "[$TIMESTAMP] ALLOW-STOP mode=$MODE agent=$AGENT_ID" >> "$LOG_FILE"
    if [ "$MODE" = "enforce" ]; then
        # 連続block対策カウンタをリセット(成功で解除)。
        mkdir -p "$BLOCK_COUNT_DIR" 2>/dev/null || true
        echo 0 > "$BLOCK_COUNT_DIR/${AGENT_ID}.count" 2>/dev/null || true
    fi
    exit 0
fi

if [ "$GATE" != "block" ]; then
    # 想定外のgate値(判定不能) → fail-safeで通す。
    exit 0
fi

# ─── ここから gate=block ───
if [ "$MODE" = "observe" ]; then
    echo "[$TIMESTAMP] WOULD-BLOCK mode=$MODE agent=$AGENT_ID reason=$REASON" >> "$LOG_FILE"
    # observeは実際にはblockしない(セッション強制終了リスクが無いため
    # 工程8-2のカウンタ対象外)。
    exit 0
fi

# MODE = enforce: 実際にblockし、工程8-2の連続block対策を作動させる。
echo "[$TIMESTAMP] BLOCK mode=$MODE agent=$AGENT_ID reason=$REASON" >> "$LOG_FILE"

mkdir -p "$BLOCK_COUNT_DIR" 2>/dev/null || true
COUNT_FILE="$BLOCK_COUNT_DIR/${AGENT_ID}.count"
PREV_COUNT="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
case "$PREV_COUNT" in
    ''|*[!0-9]*) PREV_COUNT=0 ;;
esac
NEW_COUNT=$((PREV_COUNT + 1))
echo "$NEW_COUNT" > "$COUNT_FILE" 2>/dev/null || true

if [ "$NEW_COUNT" -eq "$NOTIFY_THRESHOLD" ]; then
    # 🔴工程8-2: Claude Codeは8回連続blockでセッションを強制終了する。
    # 強制終了の前に届かせるため、6回目のblockで殿へntfyを送る。
    NTFY_MSG="⚠️ ${AGENT_ID}: stop_hook_evidence.shが${NOTIFY_THRESHOLD}回連続block中。8回連続で強制終了リスクあり。reason=${REASON}"
    bash "$NTFY_SCRIPT" "$NTFY_MSG" >/dev/null 2>&1 &
    echo "[$TIMESTAMP] NOTIFY-THRESHOLD mode=$MODE agent=$AGENT_ID count=$NEW_COUNT" >> "$LOG_FILE"
fi

REASON="$REASON" "$PYTHON_BIN" -c "
import json, os
print(json.dumps({'decision': 'block', 'reason': os.environ['REASON']}, ensure_ascii=False))
" 2>/dev/null || echo "{\"decision\":\"block\",\"reason\":\"stop_hook_evidence.sh gate failed\"}"

exit 0
