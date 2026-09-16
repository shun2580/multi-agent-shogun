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
TIMING_EVENTS_LOG="${YAML_GUARD_TIMING_LOG:-$SCRIPT_DIR/logs/timing_events.jsonl}"
# cmd_161 subtask_161_C: affects_runtime宣言タスクのdone拒否チェックで呼ぶ
# check_runtime_reflection.sh(subtask_161_B成果物)の場所。REPO_ROOTとは独立に
# 実体のあるSCRIPT_DIRを既定値とする(テストでREPO_ROOTを一時dirへ差し替えても
# 本チェッカー自体は実スクリプトを指し続けるため)。
RUNTIME_REFLECTION_SCRIPT="${YAML_GUARD_RUNTIME_REFLECTION_SCRIPT:-$SCRIPT_DIR/scripts/check_runtime_reflection.sh}"

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

# ─── DENY自己修正計測 emitter (cmd_139・受動収集) ───
# 実DENY発生時のみ、logs/timing_events.jsonl へ
# event=yaml_guard_deny_self_correction を1行追記する(計測専用・判定ロジック
# には一切関与しない)。呼び出し元はcheck_repeated_deny_alertと同一の実DENY
# 分岐のみ(WOULD-DENY/FAIL-OPEN/ALLOWでは呼ばない)。書込失敗が判定結果や
# hookの終了コードへ波及しないよう、内部で発生するエラーはすべて握り潰す
# (fail-safe)。取得できないreasonはnull相当のまま記録する(推測で埋めない)。
emit_deny_self_correction_event() {
    local file_path="$1" tool_name="$2" session_id="$3" output_json="$4"
    mkdir -p "$(dirname "$TIMING_EVENTS_LOG")" 2>/dev/null || true
    "$PYTHON_BIN" -c "
import json, sys

ts, event, file_path, tool_name, session_id, output_json = sys.argv[1:7]
try:
    reason = json.loads(output_json).get('hookSpecificOutput', {}).get('permissionDecisionReason')
except Exception:
    reason = None
record = {
    'ts': ts,
    'event': event,
    'file_path': file_path,
    'tool': tool_name,
    'session_id': session_id,
    'reason': reason,
}
print(json.dumps(record, ensure_ascii=False))
" "$(date -Iseconds)" "yaml_guard_deny_self_correction" "$file_path" "$tool_name" "$session_id" "$output_json" \
        >> "$TIMING_EVENTS_LOG" 2>/dev/null || true
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

# ─── 副flag: parent_cmd_done_gate_enabled (cmd_164 subtask_164_B) ───
# yaml_guard_enabledがoff以外(=ここに到達した時点で確定)のときのみ評価する
# 独立の副flag。off|observe|enforceの3値、未知値・空値は必ずoffへ倒す
# fail-safe(yaml_guard_enabledと同方針)。単独でoffへ戻せるよう、既存の
# affects_runtimeチェックとは完全に独立した変数として扱う。
RAW_LINE_PG=$(grep -E '^[[:space:]]*parent_cmd_done_gate_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE_PG=$(printf '%s' "$RAW_LINE_PG" | sed -E \
    -e 's/^[[:space:]]*parent_cmd_done_gate_enabled:[[:space:]]*//' \
    -e 's/[[:space:]]*#.*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\1/")

case "$RAW_VALUE_PG" in
    enforce) PARENT_GATE_MODE="enforce" ;;
    observe) PARENT_GATE_MODE="observe" ;;
    *) PARENT_GATE_MODE="off" ;;  # off/空/未知値はすべてfail-safeでoff
esac

# ─── 副flag: notify_on_done_required_enabled (cmd_192 工程7-guard) ───
# PARENT_GATE_MODEと同型の独立副flag。yaml_guard_enabledがoff以外(=ここに
# 到達した時点で確定)のときのみ評価される。off|observe|enforceの3値、
# 未知値・空値は必ずoffへ倒すfail-safe。queue/shogun_to_karo.yamlへ新規
# 追記されるcmdエントリに`notify_on_done`が無い場合を検知する(既存
# エントリの読み取り・status更新には一切影響しない)。
RAW_LINE_NDR=$(grep -E '^[[:space:]]*notify_on_done_required_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE_NDR=$(printf '%s' "$RAW_LINE_NDR" | sed -E \
    -e 's/^[[:space:]]*notify_on_done_required_enabled:[[:space:]]*//' \
    -e 's/[[:space:]]*#.*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\1/")

case "$RAW_VALUE_NDR" in
    enforce) NOTIFY_REQUIRED_MODE="enforce" ;;
    observe) NOTIFY_REQUIRED_MODE="observe" ;;
    *) NOTIFY_REQUIRED_MODE="off" ;;  # off/空/未知値はすべてfail-safeでoff
esac

# ─── 副flag: parent_cmd_evidence_gate_enabled (cmd_194 工程3) ───
# check_parent_cmd_done_gate()内、status=doneのsubtaskについてもreport YAMLが
# stop_hook_evidence.sh由来のevidence a〜d判定(lib/evidence_checks.py共有)を
# 通過していることを追加確認する副flag。既存parent_cmd_done_gate_enabled
# (全subtask done確認・既にenforce稼働中)とは共有しない独立フラグ——
# cmd_194 acceptance_criteria(iii)「工程3・4・5で追加したflagは既定observe」
# の明示要求による確定事項。off|observe|enforceの3値、未知値・空値・欠落は
# 必ずoffへ倒すfail-safe(既存副flag群と同方針)。
RAW_LINE_PEG=$(grep -E '^[[:space:]]*parent_cmd_evidence_gate_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE_PEG=$(printf '%s' "$RAW_LINE_PEG" | sed -E \
    -e 's/^[[:space:]]*parent_cmd_evidence_gate_enabled:[[:space:]]*//' \
    -e 's/[[:space:]]*#.*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\1/")

case "$RAW_VALUE_PEG" in
    enforce) PARENT_EVIDENCE_GATE_MODE="enforce" ;;
    observe) PARENT_EVIDENCE_GATE_MODE="observe" ;;
    *) PARENT_EVIDENCE_GATE_MODE="off" ;;  # off/空/未知値はすべてfail-safeでoff
esac

# ─── 副flag: verified_evidence_required_enabled (cmd_194 工程3) ───
# queue/reports/gunshi_report.yamlへの書込のうち、result.type ==
# "quality_check" のドキュメントにverified_evidence(検分したreportパスと
# 確認したevidence項目)が非空で存在することを要求する副flag。
# parent_cmd_evidence_gate_enabledとは独立(単独でoffへ戻せる)。
# off|observe|enforceの3値、未知値・空値・欠落は必ずoffへ倒すfail-safe。
RAW_LINE_VER=$(grep -E '^[[:space:]]*verified_evidence_required_enabled:' "$SETTINGS" 2>/dev/null | head -1)
RAW_VALUE_VER=$(printf '%s' "$RAW_LINE_VER" | sed -E \
    -e 's/^[[:space:]]*verified_evidence_required_enabled:[[:space:]]*//' \
    -e 's/[[:space:]]*#.*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\1/")

case "$RAW_VALUE_VER" in
    enforce) VERIFIED_EVIDENCE_MODE="enforce" ;;
    observe) VERIFIED_EVIDENCE_MODE="observe" ;;
    *) VERIFIED_EVIDENCE_MODE="off" ;;  # off/空/未知値はすべてfail-safeでoff
esac

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
import glob
import json
import os
import subprocess
import sys

import yaml

# cmd_161 subtask_161_C: check_runtime_reflection.sh の絶対パス(argv経由で
# bash側から渡す。REPO_ROOT差し替えの影響を受けないSCRIPT_DIR基準)。
RUNTIME_REFLECTION_SCRIPT = sys.argv[1] if len(sys.argv) > 1 else None

# cmd_164 subtask_164_B: check_parent_cmd_done_gate()用の副flag値・
# queue/tasks/*.yaml探索用REPO_ROOT・直接ログ追記用LOG_FILE(いずれも
# argv経由でbash側から渡す。RUNTIME_REFLECTION_SCRIPTと同型のグローバル参照)。
PARENT_GATE_MODE = sys.argv[2] if len(sys.argv) > 2 else "off"
PARENT_GATE_REPO_ROOT = sys.argv[3] if len(sys.argv) > 3 else None
PARENT_GATE_LOG_FILE = sys.argv[4] if len(sys.argv) > 4 else None

# cmd_192 工程7-guard: check_notify_on_done_required()用の副flag値
# (PARENT_GATE_LOG_FILEと同一ファイルへ別タグで直接ログ追記する)。
NOTIFY_REQUIRED_MODE = sys.argv[5] if len(sys.argv) > 5 else "off"

# cmd_194 工程3: check_parent_cmd_done_gate()のevidenceサブチェック・
# check_verified_evidence_required()用の独立副flag値。
PARENT_EVIDENCE_GATE_MODE = sys.argv[6] if len(sys.argv) > 6 else "off"
VERIFIED_EVIDENCE_MODE = sys.argv[7] if len(sys.argv) > 7 else "off"

# cmd_194 工程3: check_parent_cmd_done_gate()のevidenceサブチェックは
# stop_hook_evidence.sh由来の(a)〜(d)判定をlib/evidence_checks.py経由で
# 共有する(二重実装を避ける、選択肢a)。両flagがoffなら未使用のため、
# import失敗時もfail-loud/fail-openどちらにも倒さず単に不可用として扱う
# (評価自体は各関数内でPARENT_EVIDENCE_GATE_MODE=="off"チェックが先に効く)。
EVIDENCE_CHECKS_AVAILABLE = True
try:
    if PARENT_GATE_REPO_ROOT:
        _lib_dir = os.path.join(PARENT_GATE_REPO_ROOT, "lib")
        if _lib_dir not in sys.path:
            sys.path.insert(0, _lib_dir)
    from evidence_checks import check_commit, check_evidence, check_skip, find_report_entry
except Exception:
    EVIDENCE_CHECKS_AVAILABLE = False


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def find_dicts(node):
    """入れ子構造から全dictを再帰的に列挙する(task直下のフィールドを
    深さに依らず拾うため)。"""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from find_dicts(v)
    elif isinstance(node, list):
        for item in node:
            yield from find_dicts(item)


def check_affects_runtime_done_gate(docs, file_path):
    """queue/tasks/*.yamlへのstatus: done遷移のうち、同一task内に
    affects_runtime: trueが宣言されているものだけを対象に、
    check_runtime_reflection.shでの反映確認を要求する(cmd_161 Q20(b))。
    affects_runtime宣言の無いtaskは対象外(従来どおり通過)。"""
    if "/queue/tasks/" not in file_path.replace("\\", "/"):
        return
    for doc in docs:
        for d in find_dicts(doc):
            if not isinstance(d, dict):
                continue
            if d.get("status") != "done":
                continue
            if not d.get("affects_runtime"):
                continue

            rrc = d.get("runtime_reflection_check")
            if not isinstance(rrc, dict):
                deny(
                    "affects_runtime宣言タスクの反映未確認: "
                    "runtime_reflection_check宣言(pid_source/search_string)が"
                    "見つかりません"
                )
            pid_source = str(rrc.get("pid_source") or "")
            search_string = str(rrc.get("search_string") or "")
            if not pid_source or not search_string:
                deny(
                    "affects_runtime宣言タスクの反映未確認: "
                    "runtime_reflection_check.pid_source/search_stringが空です"
                )

            if pid_source.isdigit():
                pid = pid_source
            else:
                try:
                    pgrep_out = subprocess.run(
                        ["pgrep", "-f", pid_source],
                        capture_output=True, text=True, timeout=2,
                    )
                    pids = [l for l in pgrep_out.stdout.splitlines() if l.strip()]
                except Exception:
                    pids = []
                if len(pids) != 1:
                    deny(
                        "affects_runtime宣言タスクの反映未確認: "
                        f"pid_source='{pid_source}' からPIDを一意に解決できません"
                        f"(該当{len(pids)}件)"
                    )
                pid = pids[0]

            if not RUNTIME_REFLECTION_SCRIPT:
                deny(
                    "affects_runtime宣言タスクの反映未確認: "
                    "check_runtime_reflection.shの場所が未設定です"
                )
            try:
                result = subprocess.run(
                    ["bash", RUNTIME_REFLECTION_SCRIPT, pid, search_string],
                    capture_output=True, text=True, timeout=4,
                )
                lines = result.stdout.strip().splitlines()
                verdict = lines[0].strip() if lines else "UNKNOWN"
            except Exception:
                verdict = "UNKNOWN"

            if verdict != "REFLECTED":
                deny(
                    "affects_runtime宣言タスクの反映未確認"
                    f"(check_runtime_reflection.sh判定={verdict}, pid={pid}, "
                    f"search='{search_string}')"
                )


def _emit_would_deny_parent_gate(reason, file_path):
    """副flag=observe時、既存deny()(=外側yaml_guard_enabled MODEのDENY/
    WOULD-DENY機構に載る)を呼ばずに、LOG_FILEへ識別可能なタグ
    (WOULD-DENY-PARENT-GATE)を付けて直接1行追記する(cmd_164 subtask_164_B)。
    スクリプトの終了コード・標準出力には一切影響させない。書込失敗は
    握り潰す(fail-safe、判定結果に波及させない)。"""
    if not PARENT_GATE_LOG_FILE:
        return
    try:
        import os
        os.makedirs(os.path.dirname(PARENT_GATE_LOG_FILE), exist_ok=True)
        ts_result = subprocess.run(
            ["date", "-Iseconds"], capture_output=True, text=True, timeout=2,
        )
        ts = ts_result.stdout.strip() or "unknown-time"
        with open(PARENT_GATE_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(
                f"[{ts}] WOULD-DENY-PARENT-GATE mode={PARENT_GATE_MODE} "
                f"file={file_path} reason={reason}\n"
            )
    except Exception:
        pass


def _evaluate_subtask_evidence(tf, task):
    """cmd_194 工程3: status=doneのsubtask 1件についてevidence a〜dを評価し、
    不成立ならreason文字列を、成立なら None を返す。agentはtask YAML自身の
    フィールドではなくファイル名から導出する(lib/inflight_tasks.shの既存
    導出方式と同一・より頑健)。agent=="shogun"は将軍対象外の維持のため
    呼び出し元でスキップ済みの前提。report探索パスは現行+archive/を両方
    globし、更新時刻降順で走査する(archive探索が必須である理由は本タスクの
    設計報告(1-補)参照——gunshi過去subtaskのreportがarchive/にしか
    存在しない実例で実証済み)。"""
    task_id_v = task.get("task_id")
    report_globs = glob.glob(f"{PARENT_GATE_REPO_ROOT}/queue/reports/{os.path.basename(tf)[:-len('.yaml')]}_report*.yaml")
    report_globs += glob.glob(f"{PARENT_GATE_REPO_ROOT}/queue/reports/archive/{os.path.basename(tf)[:-len('.yaml')]}_report*.yaml")
    try:
        report_paths = sorted(report_globs, key=os.path.getmtime, reverse=True)
    except Exception:
        report_paths = report_globs

    raw_chunk, entry = find_report_entry(report_paths, task_id_v)
    if entry is None:
        return f"(evidence) task_id={task_id_v}: (a) no report entry found in {report_paths}"
    if not check_evidence(raw_chunk):
        return f"(evidence) task_id={task_id_v}: (b) no non-empty *_evidence field"
    commit_ok, commit_reason = check_commit(raw_chunk, PARENT_GATE_REPO_ROOT)
    if not commit_ok:
        return f"(evidence) task_id={task_id_v}: (c) {commit_reason}"
    skip_ok, skip_reason = check_skip(entry)
    if not skip_ok:
        return f"(evidence) task_id={task_id_v}: (d) {skip_reason}"
    return None


def _emit_would_deny_parent_evidence_gate(reason, file_path):
    """副flag PARENT_EVIDENCE_GATE_MODE=observe時、既存deny()を呼ばずに
    LOG_FILEへ識別可能なタグ(WOULD-DENY-PARENT-EVIDENCE-GATE)を付けて直接
    1行追記する(cmd_194 工程3、_emit_would_deny_parent_gateと同型の
    独立副flag。既存WOULD-DENY-PARENT-GATEとはタグのみ別)。終了コード・
    標準出力には一切影響させない。書込失敗は握り潰す。"""
    if not PARENT_GATE_LOG_FILE:
        return
    try:
        os.makedirs(os.path.dirname(PARENT_GATE_LOG_FILE), exist_ok=True)
        ts_result = subprocess.run(
            ["date", "-Iseconds"], capture_output=True, text=True, timeout=2,
        )
        ts = ts_result.stdout.strip() or "unknown-time"
        with open(PARENT_GATE_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(
                f"[{ts}] WOULD-DENY-PARENT-EVIDENCE-GATE mode={PARENT_EVIDENCE_GATE_MODE} "
                f"file={file_path} reason={reason}\n"
            )
    except Exception:
        pass


def check_parent_cmd_done_gate(docs, file_path):
    """queue/shogun_to_karo.yaml上であるcmdのstatusをdoneへ変更しようと
    したとき、queue/tasks/*.yaml中のparent_cmd一致エントリの全statusが
    doneであることを機械確認するゲート(cmd_164 subtask_164_B・stale
    assigned放置の再発防止)。独立の副flag PARENT_GATE_MODE
    (off|observe|enforce)で段階導入し、yaml_guard_enabled本体とは
    別にoffへ戻せる。

    cmd_194 工程3(Q51): status=doneのsubtaskについても、配下report YAMLが
    stop_hook_evidence.sh由来のevidence a〜d判定を通過していることを
    追加で確認する。この追加判定の実施可否は既存PARENT_GATE_MODEとは
    別の独立副flag PARENT_EVIDENCE_GATE_MODE(既定observe)で制御し、
    ログタグ・deny/observe経路も既存の全subtask doneチェックとは別系統
    (WOULD-DENY-PARENT-EVIDENCE-GATE)として扱う——
    parent_cmd_done_gate_enabledは既にenforce稼働中であり、evidence
    サブチェックを同一flagに相乗りさせるとobserve期間ゼロでenforce評価が
    始まってしまうため(cmd_194 acceptance_criteria(iii)違反)。"""
    if PARENT_GATE_MODE == "off" and PARENT_EVIDENCE_GATE_MODE == "off":
        return
    if "/queue/shogun_to_karo.yaml" not in file_path.replace("\\", "/"):
        return
    if not PARENT_GATE_REPO_ROOT:
        return

    for doc in docs:
        for d in find_dicts(doc):
            if not isinstance(d, dict):
                continue
            if d.get("status") != "done":
                continue
            cmd_id = d.get("id")
            if not isinstance(cmd_id, str) or not cmd_id:
                continue

            incomplete = []
            evidence_incomplete = []
            found_any = False
            try:
                task_files = glob.glob(f"{PARENT_GATE_REPO_ROOT}/queue/tasks/*.yaml")
            except Exception as e:
                task_files = []
                incomplete.append(f"queue/tasks/*.yaml 探索失敗(判定不能): {e}")

            for tf in task_files:
                try:
                    with open(tf, "r", encoding="utf-8") as f:
                        tdocs = list(yaml.safe_load_all(f))
                except Exception as e:
                    incomplete.append(f"{tf}: 読取/パース失敗・判定不能({e})")
                    continue
                for tdoc in tdocs:
                    if not isinstance(tdoc, dict):
                        continue
                    task = tdoc.get("task")
                    if not isinstance(task, dict):
                        continue
                    if task.get("parent_cmd") != cmd_id:
                        continue
                    found_any = True
                    tstatus = task.get("status")
                    if tstatus != "done":
                        incomplete.append(
                            f"{tf}: task_id={task.get('task_id')} status={tstatus}"
                        )
                        continue

                    if PARENT_EVIDENCE_GATE_MODE == "off" or not EVIDENCE_CHECKS_AVAILABLE:
                        continue

                    agent = os.path.basename(tf)
                    if agent.endswith(".yaml"):
                        agent = agent[:-len(".yaml")]
                    if agent == "shogun":
                        # 将軍対象外の維持(構造上queue/tasks/shogun.yamlは
                        # 存在しないため現状は到達しないが、明示スキップに
                        # 格上げする——cmd_194設計(3)節)。
                        continue

                    ev_reason = _evaluate_subtask_evidence(tf, task)
                    if ev_reason:
                        evidence_incomplete.append(f"{tf}: {ev_reason}")

            # 該当parent_cmdを持つtaskが1件も無く、探索自体も失敗していなければ
            # 検査対象なし=ALLOW(無関係なcmdの誤denyを避ける。全滅解釈にしない)。
            if not found_any and not incomplete and not evidence_incomplete:
                continue

            if incomplete:
                reason = (
                    f"cmd_id={cmd_id}のdone遷移拒否: 配下subtaskに未完了/判定不能が"
                    "あります — " + "; ".join(incomplete)
                )
                if PARENT_GATE_MODE == "enforce":
                    deny(reason)
                else:
                    _emit_would_deny_parent_gate(reason, file_path)

            if evidence_incomplete:
                reason = (
                    f"cmd_id={cmd_id}のdone遷移拒否: 配下subtaskのevidence判定"
                    "(a)〜(d)不成立があります — " + "; ".join(evidence_incomplete)
                )
                if PARENT_EVIDENCE_GATE_MODE == "enforce":
                    deny(reason)
                else:
                    _emit_would_deny_parent_evidence_gate(reason, file_path)


def _emit_would_deny_notify_required(reason, file_path):
    """副flag NOTIFY_REQUIRED_MODE=observe時、既存deny()を呼ばずに
    LOG_FILEへ識別可能なタグ(WOULD-DENY-NOTIFY-REQUIRED)を付けて直接1行
    追記する(cmd_192 工程7-guard、_emit_would_deny_parent_gateと同型)。
    終了コード・標準出力には一切影響させない。書込失敗は握り潰す。"""
    if not PARENT_GATE_LOG_FILE:
        return
    try:
        import os
        os.makedirs(os.path.dirname(PARENT_GATE_LOG_FILE), exist_ok=True)
        ts_result = subprocess.run(
            ["date", "-Iseconds"], capture_output=True, text=True, timeout=2,
        )
        ts = ts_result.stdout.strip() or "unknown-time"
        with open(PARENT_GATE_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(
                f"[{ts}] WOULD-DENY-NOTIFY-REQUIRED mode={NOTIFY_REQUIRED_MODE} "
                f"file={file_path} reason={reason}\n"
            )
    except Exception:
        pass


def check_notify_on_done_required(docs, file_path):
    """queue/shogun_to_karo.yamlへ新規追記されるcmdエントリに
    notify_on_doneフィールドが無い場合を検知する(cmd_192 工程7-guard、
    工程7(d))。🔴殿の明示指定: observeから開始・既定値補完はしない
    ——値が無ければ書けない、でfail-loudにする(推測でtrue等を補わない)。
    独立副flag NOTIFY_REQUIRED_MODE(off|observe|enforce)、既定off
    (PARENT_GATE_MODEと同型のfail-safe設計)。
    🔴既存cmdエントリ(追記前から存在するid)のstatus更新等には一切影響
    しない——変更前のファイル内容をここで読み直し、そこに無かったidのみ
    を『新規追記』として扱う。変更前内容を読めない/パースできない場合は
    新規判定が不能なため何もしない(fail-open、既存動作を壊さない)。"""
    if NOTIFY_REQUIRED_MODE == "off":
        return
    if "/queue/shogun_to_karo.yaml" not in file_path.replace("\\", "/"):
        return

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            before_docs = list(yaml.safe_load_all(f))
    except Exception:
        return

    existing_ids = set()
    for doc in before_docs:
        for d in find_dicts(doc):
            if not isinstance(d, dict):
                continue
            cmd_id = d.get("id")
            if isinstance(cmd_id, str) and cmd_id.startswith("cmd_"):
                existing_ids.add(cmd_id)

    for doc in docs:
        for d in find_dicts(doc):
            if not isinstance(d, dict):
                continue
            cmd_id = d.get("id")
            if not isinstance(cmd_id, str) or not cmd_id.startswith("cmd_"):
                continue
            if cmd_id in existing_ids:
                continue  # 既存エントリ(新規追記ではない)は対象外
            if "notify_on_done" in d:
                continue  # フィールドは存在する(値の真偽は問わない)

            reason = (
                f"新規cmdエントリ(id={cmd_id})にnotify_on_doneフィールドが"
                "ありません。既定値の自動補完はせずfail-loudに検知します"
                "(cmd_192 工程7-guard)"
            )
            if NOTIFY_REQUIRED_MODE == "enforce":
                deny(reason)
            else:
                _emit_would_deny_notify_required(reason, file_path)


def _emit_would_deny_verified_evidence(reason, file_path):
    """副flag VERIFIED_EVIDENCE_MODE=observe時、既存deny()を呼ばずに
    LOG_FILEへ識別可能なタグ(WOULD-DENY-VERIFIED-EVIDENCE)を付けて直接1行
    追記する(cmd_194 工程3、_emit_would_deny_notify_requiredと同型)。
    終了コード・標準出力には一切影響させない。書込失敗は握り潰す。"""
    if not PARENT_GATE_LOG_FILE:
        return
    try:
        os.makedirs(os.path.dirname(PARENT_GATE_LOG_FILE), exist_ok=True)
        ts_result = subprocess.run(
            ["date", "-Iseconds"], capture_output=True, text=True, timeout=2,
        )
        ts = ts_result.stdout.strip() or "unknown-time"
        with open(PARENT_GATE_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(
                f"[{ts}] WOULD-DENY-VERIFIED-EVIDENCE mode={VERIFIED_EVIDENCE_MODE} "
                f"file={file_path} reason={reason}\n"
            )
    except Exception:
        pass


def check_verified_evidence_required(docs, file_path):
    """queue/reports/gunshi_report.yamlへの書込のうち、result.type ==
    "quality_check" のドキュメント(軍師のQC報告)に限り、トップレベル
    キーverified_evidence(検分したreportパスと確認したevidence項目)が
    存在し、かつ空でないことを要求する(cmd_194 工程3・Q51「軍師の完了
    主張はQC PASS」)。strategy/design/analysis/evaluation等の非QC報告
    (軍師のCategory1報告、本関数自身の設計タスクもその一例)は対象外——
    QC対象のashigaru report自体が存在しないため、要求すると恒常的な
    過検知になる(過検知防止のスコープ限定)。

    🔴check_notify_on_done_requiredは「フィールドは存在する(値の真偽は
    問わない)」方針だが、本チェックは意図的に非対称にする——
    verified_evidenceは「検分した項目の列挙」が本質であり、
    `verified_evidence: []`という空の充足は原則5(fail-loudな拒否)が
    禁じる「サイレントな形骸化」の典型例にあたるため、非空であることまで
    要求する(list/str/dictいずれの型でもfalsy値は不成立)。

    独立副flag VERIFIED_EVIDENCE_MODE(off|observe|enforce)、既定observe。"""
    if VERIFIED_EVIDENCE_MODE == "off":
        return
    if "/queue/reports/gunshi_report.yaml" not in file_path.replace("\\", "/"):
        return

    for doc in docs:
        if not isinstance(doc, dict):
            continue
        result = doc.get("result")
        if not isinstance(result, dict):
            continue
        if result.get("type") != "quality_check":
            continue
        if doc.get("verified_evidence"):
            continue  # 存在しかつ非空

        reason = (
            "QC報告(result.type=quality_check)にverified_evidenceフィールドが"
            "無い、または空です。検分したreportパスと確認したevidence項目を"
            "明記してください(cmd_194 工程3・Q51)"
        )
        if VERIFIED_EVIDENCE_MODE == "enforce":
            deny(reason)
        else:
            _emit_would_deny_verified_evidence(reason, file_path)


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
        # 消費者側の責務のため、構文検証自体はここで完結させる。
        docs = list(yaml.safe_load_all(simulated))
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

    # cmd_161 subtask_161_C: 構文的に妥当なqueue/tasks/*.yamlに限り、
    # affects_runtime宣言によるdone拒否チェックを実施(該当が無ければ何もしない)。
    check_affects_runtime_done_gate(docs, file_path)
    # cmd_164 subtask_164_B: queue/shogun_to_karo.yamlに限り、親cmdのdone
    # 遷移時に配下subtaskの全status doneを機械確認するゲートを実施
    # (副flag PARENT_GATE_MODE=off時は関数内で即return)。
    check_parent_cmd_done_gate(docs, file_path)
    # cmd_192 工程7-guard: queue/shogun_to_karo.yamlに限り、新規追記される
    # cmdエントリのnotify_on_done欠落を検知する(副flag
    # NOTIFY_REQUIRED_MODE=off時は関数内で即return)。
    check_notify_on_done_required(docs, file_path)
    # cmd_194 工程3: queue/reports/gunshi_report.yamlに限り、QC報告の
    # verified_evidence欠落を検知する(副flag VERIFIED_EVIDENCE_MODE=off
    # 時は関数内で即return)。
    check_verified_evidence_required(docs, file_path)
    sys.exit(0)
except SystemExit:
    raise
except Exception as e:
    fail_open(f"internal validator exception: {type(e).__name__}: {e}")
PYEOF

ERR_TMP="$(mktemp)"
trap 'rm -f "$ERR_TMP"' EXIT

OUTPUT="$(printf '%s' "$INPUT" | timeout 8 "$PYTHON_BIN" -c "$PYCODE" "$RUNTIME_REFLECTION_SCRIPT" "$PARENT_GATE_MODE" "$REPO_ROOT" "$LOG_FILE" "$NOTIFY_REQUIRED_MODE" "$PARENT_EVIDENCE_GATE_MODE" "$VERIFIED_EVIDENCE_MODE" 2>"$ERR_TMP")"
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
    emit_deny_self_correction_event "$FILE_PATH" "$TOOL_NAME" "$SESSION_ID" "$OUTPUT"
    printf '%s\n' "$OUTPUT"
    exit 0
fi

# 検証完了・YAMLとして妥当(許可)。この行がenforce移行判定の分母
# (評価総数=ALLOW+WOULD-DENY+DENY件数)の一部を構成する。
echo "[$(date -Iseconds)] ALLOW mode=$MODE session=$SESSION_ID file=$FILE_PATH tool=$TOOL_NAME" >> "$LOG_FILE"
exit 0
