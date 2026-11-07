#!/usr/bin/env bash
# model_audit.sh - 各エージェントが「実際に」どのモデルで動いているかを、セッション記録(jsonl)の実測値で確かめる。
#
# 殿が手で実行するコマンド。hook・watcher・settings.json には配線しない(番兵を増やさない・cmd_264)。
# 読み取り専用: ~/.claude/projects/ と logs/audit/ は読むだけで、書き換え・移動・削除はしない。
# モデルの自己申告(エージェントに名前を聞くこと)は一切使わない。会話の本文は読まず、表にも写さない。
#
# 使い方:
#   bash scripts/model_audit.sh
#   (試験用) --settings FILE --projects-dir DIR --audit-dir DIR --days N --window SEC
#
# 判定:
#   期待 = config/settings.yaml の cli.agents.<id>.model / .effort
#   実測 = 各エージェントの最新セッションの「type=assistant かつ message.usage を持つ最後の記録」の
#          message.model と effort(記録に項目があるときだけ)
#   比べる前に、別名(opus/sonnet/haiku/fable 等)を下の対応表で正式IDに揃える。
#   対応表に無い名前は「対応不明」と出し、一致にも不一致にも数えない。
#   effort が記録から読めぬときは「effort: 未検証」と出す(黙って一致扱いにしない)。
#   effort が読めて期待と違えば不一致に数える(甘い側に倒さぬ)。
#
# エージェント→セッションの対応(jsonl に agent id は残らないため推定する):
#   logs/audit/<月>/<agent>.jsonl(mods/audit)の直近の tool.call のうち file_path を持つもの
#   (tool 名・file_path・時刻±WINDOW 秒)が、セッション jsonl の tool_use と一致したセッションを候補にし、
#   候補のうち最後の記録が最も新しいものを「最新セッション」とする。
#   一致が無い・2体が同じセッションに当たる場合は「対応取れず」として名前を出す(推測で埋めない)。
#
# サブエージェント: <セッション>/subagents/*.jsonl は別の行(<agent>/sub:<ファイル名>)で出し、
#   親の判定・終了コードには混ぜない。
#
# 終了コード(S-44 ②・重なったときの優先順位):
#   1 = 不一致が1件でもある(該当行を stderr に出す)
#   3 = 不一致は無いが、判定できぬ者(対応不明/記録なし/対応取れず)が1人でもいる(人数を出す)
#   0 = 全員一致
#   2 = 使い方・入力の誤り(settings が読めない等)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SETTINGS="${MODEL_AUDIT_SETTINGS:-$ROOT_DIR/config/settings.yaml}"
PROJECTS_DIR="${MODEL_AUDIT_PROJECTS_DIR:-$HOME/.claude/projects}"
AUDIT_DIR="${MODEL_AUDIT_AUDIT_DIR:-$ROOT_DIR/logs/audit}"
DAYS="${MODEL_AUDIT_DAYS:-3}"
WINDOW="${MODEL_AUDIT_WINDOW:-3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --settings) SETTINGS="${2:-}"; shift 2 ;;
    --projects-dir) PROJECTS_DIR="${2:-}"; shift 2 ;;
    --audit-dir) AUDIT_DIR="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --window) WINDOW="${2:-}"; shift 2 ;;
    -h|--help) sed -n 2,40p "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "model_audit.sh: 不明な引数: $1" >&2; exit 2 ;;
  esac
done

exec python3 -I - "$SETTINGS" "$PROJECTS_DIR" "$AUDIT_DIR" "$DAYS" "$WINDOW" <<'PYEOF'
import datetime
import glob
import json
import os
import re
import sys

import yaml

settings_path, projects_dir, audit_dir, days_s, window_s = sys.argv[1:6]
DAYS = float(days_s)
WINDOW = float(window_s)
RECENT = 40  # 直近何件の file_path つき tool.call で突き合わせるか

# --- 別名 → 正式ID の対応表(ここに無い名前は「対応不明」)。新しいモデルが出たらここへ足す ---
ALIASES = {
    "opus": "claude-opus-5-5",
    "sonnet": "claude-sonnet-5-5",
    "haiku": "claude-haiku-5-5",
    "fable": "claude-fable-5-1",
}
CANONICAL = {
    "claude-opus-5-5",
    "claude-sonnet-5-5",
    "claude-haiku-5-5",
    "claude-fable-5-1",
    "claude-haiku-4-5",
    "claude-haiku-4-5-20251001",
}


def normalize(name):
    """別名・表記ゆれを正式IDに揃える。表に無ければ None(対応不明)。"""
    if not isinstance(name, str) or not name.strip():
        return None
    n = re.sub(r"\[[^\]]*\]$", "", name.strip()).lower()  # 'claude-opus-5-5[1m]' 等の接尾辞
    if n in ALIASES:
        return ALIASES[n]
    if n in CANONICAL:
        return n
    return None


def to_epoch(s):
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def fmt_time(ts):
    e = to_epoch(ts)
    if e is None:
        return "-"
    return datetime.datetime.fromtimestamp(e).astimezone().strftime("%Y-%m-%d %H:%M:%S")


def iter_jsonl(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    yield json.loads(line)
                except Exception:
                    continue
    except OSError:
        return


def scan_session(path):
    """会話の本文は保持しない。tool_use の(時刻,名,file_path)と、最後の assistant+usage 記録だけ。"""
    uses = []
    last = None
    for d in iter_jsonl(path):
        if d.get("type") != "assistant":
            continue
        m = d.get("message") or {}
        ts = d.get("timestamp")
        e = to_epoch(ts)
        content = m.get("content")
        if e is not None and isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    inp = c.get("input") or {}
                    fp = inp.get("file_path") if isinstance(inp, dict) else None
                    uses.append((e, c.get("name"), fp))
        if isinstance(m, dict) and m.get("usage"):
            last = {
                "model": m.get("model"),
                "ts": ts,
                "effort": d.get("effort") if d.get("effort") is not None else d.get("perTurnEffort"),
            }
    return uses, last


# --- 期待(settings.yaml) ---
try:
    with open(settings_path, encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
    agents = (cfg.get("cli") or {}).get("agents") or {}
    if not agents:
        raise ValueError("cli.agents が空")
except Exception as ex:
    print("model_audit.sh: settings を読めない: %s (%s)" % (settings_path, ex), file=sys.stderr)
    sys.exit(2)

expected = {}
for aid, a in agents.items():
    a = a or {}
    expected[aid] = (a.get("model"), a.get("effort"))

# --- セッション jsonl(親のみ。subagents/ は別に扱う) ---
import time

cutoff = time.time() - DAYS * 86400
sessions = {}  # path -> dict
for p in glob.glob(os.path.join(projects_dir, "*", "*.jsonl")):
    try:
        if os.path.getmtime(p) < cutoff:
            continue
    except OSError:
        continue
    uses, last = scan_session(p)
    sessions[p] = {"uses": uses, "last": last}

# --- audit ログ: エージェントごとの直近の file_path つき tool.call ---
def audit_records(aid):
    files = sorted(glob.glob(os.path.join(audit_dir, "*", aid + ".jsonl")))
    recs = []
    for fpath in reversed(files):  # 新しい月から
        month = []
        for d in iter_jsonl(fpath):
            if d.get("event") == "tool.call" and d.get("file_path") and d.get("sub") is not True:
                e = to_epoch(d.get("ts"))
                if e is not None:
                    month.append((e, d.get("tool"), d.get("file_path")))
        recs = month + recs
        if len(recs) >= RECENT:
            break
    return recs[-RECENT:], bool(files)


def match_count(recs, uses):
    n = 0
    for t, tool, fp in recs:
        for u, un, ufp in uses:
            if un == tool and ufp == fp and abs(u - t) <= WINDOW:
                n += 1
                break
    return n


assigned = {}  # agent -> session path or None
reason = {}
for aid in expected:
    recs, has_log = audit_records(aid)
    if not has_log:
        assigned[aid] = None
        reason[aid] = "記録なし(audit ログ無し)"
        continue
    if not recs:
        assigned[aid] = None
        reason[aid] = "対応取れず(audit に file_path つき記録が無い)"
        continue
    cands = []
    for p, s in sessions.items():
        n = match_count(recs, s["uses"])
        if n >= 1 and s["last"]:
            cands.append((to_epoch(s["last"]["ts"]) or 0, p, n))
    if not cands:
        assigned[aid] = None
        reason[aid] = "対応取れず(audit と一致するセッション無し)"
        continue
    cands.sort(reverse=True)
    assigned[aid] = cands[0][1]

# 2体が同じセッションに当たったら、どちらも推測で採らない
by_session = {}
for aid, p in assigned.items():
    if p:
        by_session.setdefault(p, []).append(aid)
for p, ids in by_session.items():
    if len(ids) > 1:
        for aid in ids:
            assigned[aid] = None
            reason[aid] = "対応取れず(%s が同じセッションに当たった)" % "/".join(sorted(ids))

# --- 判定 ---
rows = []  # (agent, expect, actual, time, effort_note, status, session_name)
mismatch_lines = []
undecidable = []
for aid in sorted(expected, key=lambda x: (x != "shogun", x)):
    exp_model, exp_effort = expected[aid]
    exp_norm = normalize(exp_model)
    p = assigned.get(aid)
    if not p:
        rows.append((aid, str(exp_model), "-", "-", "effort: 未検証", reason.get(aid, "記録なし"), "-"))
        undecidable.append(aid)
        continue
    last = sessions[p]["last"]
    act_model = last["model"]
    act_norm = normalize(act_model)
    act_effort = last["effort"]
    if exp_norm is None or act_norm is None:
        status = "対応不明"
    elif exp_norm != act_norm:
        status = "不一致(モデル)"
    else:
        status = "一致"
    if act_effort is None or act_effort == "":
        effort_note = "effort: 未検証"
    else:
        effort_note = "effort: %s(期待 %s)" % (act_effort, exp_effort)
        if status == "一致" and exp_effort is not None and str(act_effort) != str(exp_effort):
            status = "不一致(effort)"
    if status.startswith("不一致"):
        mismatch_lines.append(
            "MISMATCH %s: 期待=%s/%s 実測=%s/%s 記録=%s (%s)"
            % (aid, exp_model, exp_effort, act_model, act_effort, fmt_time(last["ts"]), os.path.basename(p))
        )
    elif status == "対応不明":
        undecidable.append(aid)
    rows.append((aid, str(exp_model), str(act_model), fmt_time(last["ts"]), effort_note, status, os.path.basename(p)))

# --- サブエージェント(別行・親の判定に混ぜない) ---
sub_rows = []
for aid, p in assigned.items():
    if not p:
        continue
    sdir = os.path.join(os.path.splitext(p)[0], "subagents")
    for sp in sorted(glob.glob(os.path.join(sdir, "*.jsonl"))):
        _, last = scan_session(sp)
        if last:
            sub_rows.append((aid + "/sub:" + os.path.basename(sp), "-", str(last["model"]), fmt_time(last["ts"]),
                             "effort: 未検証" if last["effort"] in (None, "") else "effort: %s" % last["effort"],
                             "参考(判定外)", os.path.basename(p)))

header = ("エージェント", "期待", "実測", "記録の時刻", "effort", "判定", "セッション")
table = [header] + rows + sub_rows
widths = [max(len(r[i]) for r in table) for i in range(len(header))]
for r in table:
    print("  ".join(r[i].ljust(widths[i]) for i in range(len(header))).rstrip())

for line in mismatch_lines:
    print(line, file=sys.stderr)

if mismatch_lines:
    print("結果: 不一致 %d 件(終了コード 1)" % len(mismatch_lines))
    sys.exit(1)
if undecidable:
    print("結果: 判定できぬ者 %d 人: %s(終了コード 3)" % (len(undecidable), ", ".join(undecidable)))
    sys.exit(3)
print("結果: 全員一致(終了コード 0)")
sys.exit(0)
PYEOF
