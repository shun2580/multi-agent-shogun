#!/usr/bin/env python3
"""
model_update_check.py — 新モデル版の自動「検知・通知」（自動適用はしない）

方針（危険回避のための設計）:
  * LLMを介さない決定論スクリプト。Web内容を解釈させないためインジェクション経路にならない。
  * 情報源は第一者Anthropic公式ドキュメントの .md（HTTPS）のみ。任意URLは踏まない。
  * "Claude API (ID|alias)" を含む行だけから抽出し、日付/-vN を除去、厳格正規表現で検証。
    → Bedrock/Google列の脚注混入（例 claude-sonnet-53 = -5 + 脚注3）を排除。
  * 同ティア（同ファミリー）内で「より新しいバージョン」がある場合のみ候補化。
    ティア横断（haiku→sonnet 等）は原理的に提案しない。
  * settings.yaml は絶対に書き換えない。switch_cli.sh も呼ばない。適用は殿の承認後、人間が行う。
  * fixed: true のエージェントはスキップ。重複通知は state ファイルで抑制。

Usage:
  python3 scripts/model_update_check.py            # 検知→新規候補があれば通知
  python3 scripts/model_update_check.py --dry-run  # 検知して表示のみ（通知・state更新なし）
  python3 scripts/model_update_check.py --json      # 候補をJSONで出力（通知はしない）
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

# --- 第一者ソース（ハードコード。任意URLは踏まない） ---
SOURCE_URL = "https://platform.claude.com/docs/en/about-claude/models/overview.md"
FAMILIES = ("opus", "sonnet", "haiku", "fable", "mythos")

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETTINGS = os.path.join(PROJECT_ROOT, "config", "settings.yaml")
POLICY = os.path.join(PROJECT_ROOT, "config", "model_autoupdate.yaml")
STATE_FILE = os.path.join(PROJECT_ROOT, "logs", "model_update_check.state.json")
LOG_FILE = os.path.join(PROJECT_ROOT, "logs", "model_update_check.log")
NTFY = os.path.join(PROJECT_ROOT, "scripts", "ntfy.sh")
INBOX_WRITE = os.path.join(PROJECT_ROOT, "scripts", "inbox_write.sh")

# 正規ID: claude-<family>-<major>[-<minor>]（日付/-vN 除去後に検証）
CANON_RE = re.compile(r"^claude-(%s)-(\d+)(?:-(\d+))?$" % "|".join(FAMILIES))
RAW_RE = re.compile(r"claude-(?:%s)-[0-9][0-9a-z-]*" % "|".join(FAMILIES))


def log(msg: str) -> None:
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [model_update_check] {msg}"
    sys.stderr.write(line + "\n")
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def normalize(token: str) -> str | None:
    """raw token → 正規ID。日付/-vN を除去し検証。合致しなければ None。"""
    t = re.sub(r"-v\d+$", "", token)
    t = re.sub(r"-\d{8}$", "", t)
    return t if CANON_RE.match(t) else None


def version_of(model_id: str) -> tuple[str, tuple[int, int]] | None:
    m = CANON_RE.match(model_id)
    if not m:
        return None
    family = m.group(1)
    major = int(m.group(2))
    minor = int(m.group(3)) if m.group(3) is not None else 0
    return family, (major, minor)


def fetch_available() -> dict[str, tuple[str, tuple[int, int]]]:
    """公式ドキュメントから、ファミリーごとの最新ID/バージョンを取得。"""
    req = urllib.request.Request(
        SOURCE_URL, headers={"User-Agent": "multi-agent-shogun-model-check/1.0"}
    )
    with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310 (host固定)
        text = resp.read().decode("utf-8", "replace")

    best: dict[str, tuple[str, tuple[int, int]]] = {}
    for line in text.splitlines():
        if not re.search(r"Claude API (ID|alias)", line, re.I):
            continue
        for raw in RAW_RE.findall(line):
            canon = normalize(raw)
            if not canon:
                continue
            parsed = version_of(canon)
            if not parsed:
                continue
            family, ver = parsed
            if family not in best or ver > best[family][1]:
                best[family] = (canon, ver)
    return best


def load_policy() -> dict:
    if not os.path.exists(POLICY):
        return {}
    try:
        import yaml
        with open(POLICY, encoding="utf-8") as fh:
            return yaml.safe_load(fh) or {}
    except Exception as exc:  # noqa: BLE001
        log(f"policy読込失敗（既定動作で続行）: {exc}")
        return {}


def load_fleet() -> list[dict]:
    import yaml
    with open(SETTINGS, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    agents = ((data.get("cli") or {}).get("agents") or {})
    fleet = []
    for name, cfg in agents.items():
        cfg = cfg or {}
        fleet.append(
            {
                "name": name,
                "type": cfg.get("type", ""),
                "model": cfg.get("model", ""),
                "fixed": bool(cfg.get("fixed", False)),
            }
        )
    return fleet


def find_candidates(
    fleet: list[dict], available: dict, policy: dict
) -> list[dict]:
    exclude = set(policy.get("exclude_agents") or [])
    allowed_families = policy.get("families")  # None = 全ファミリー
    candidates = []
    for a in fleet:
        if a["type"] != "claude":
            continue  # opencode/ollama等は対象外
        if a["fixed"]:
            continue  # fixed: true は尊重してスキップ
        if a["name"] in exclude:
            continue
        cur = version_of(re.sub(r"-\d{8}$", "", a["model"]))
        if not cur:
            continue
        family, cur_ver = cur
        if allowed_families and family not in allowed_families:
            continue
        if family not in available:
            continue
        best_id, best_ver = available[family]
        if best_ver > cur_ver:  # 同ティアでより新しい版
            candidates.append(
                {
                    "agent": a["name"],
                    "current": a["model"],
                    "latest": best_id,
                    "family": family,
                }
            )
    return candidates


def load_state() -> dict:
    if not os.path.exists(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=2)


def build_message(new_candidates: list[dict]) -> str:
    lines = ["🆕 新手の刃（モデル）参上！ 同ティアにて更なる強者現る（要承認・自動適用はせぬ）"]
    for c in new_candidates:
        lines.append(f"- {c['agent']}: {c['current']} → {c['latest']}（新手）")
    lines.append("")
    lines.append("御意あらば、以下にて陣替えせよ:")
    for c in new_candidates:
        lines.append(
            f"  bash scripts/switch_cli.sh {c['agent']} --type claude --model {c['latest']}"
        )
    lines.append("")
    lines.append("※陣替え前に価格（導入価格の期限切れ含む）と破壊的変更、しかと見極められよ。")
    return "\n".join(lines)


def notify(message: str) -> None:
    # 1) ntfy（殿へ即時プッシュ）
    try:
        subprocess.run(["bash", NTFY, message], check=False, timeout=30)
    except Exception as exc:  # noqa: BLE001
        log(f"ntfy送信失敗: {exc}")
    # 2) 家老へ inbox（Action Required Rule 経由で dashboard 🚨要対応 へ）
    karo_msg = (
        "新手のモデル、参上仕った（要承認）。dashboard.md 🚨要対応 に掲載し、殿の御裁可を仰がれたし。"
        "自動適用は一切いたしておらぬ。委細以下の通り:\n" + message
    )
    try:
        subprocess.run(
            ["bash", INBOX_WRITE, "karo", karo_msg, "model_update", "model_update_check"],
            check=False,
            timeout=30,
        )
    except Exception as exc:  # noqa: BLE001
        log(f"inbox_write失敗: {exc}")


def main() -> int:
    ap = argparse.ArgumentParser(description="新モデル版の検知・通知（自動適用なし）")
    ap.add_argument("--dry-run", action="store_true", help="検知して表示のみ（通知・state更新なし）")
    ap.add_argument("--json", action="store_true", help="候補をJSONで出力（通知しない）")
    args = ap.parse_args()

    policy = load_policy()
    if policy.get("enabled") is False:
        log("policyでenabled:false。何もしない。")
        return 0

    try:
        available = fetch_available()
    except Exception as exc:  # noqa: BLE001
        log(f"モデル一覧取得失敗（通知せず終了）: {exc}")
        return 0  # cronを壊さない

    if not available:
        log("公式ドキュメントからモデルIDを抽出できず（フォーマット変更の可能性）。通知せず終了。")
        return 0

    fleet = load_fleet()
    candidates = find_candidates(fleet, available, policy)

    if args.json:
        print(json.dumps({"available": {k: v[0] for k, v in available.items()},
                          "candidates": candidates}, ensure_ascii=False, indent=2))
        return 0

    if not candidates:
        log("同ティアの新モデルなし。全エージェント最新。")
        return 0

    if args.dry_run:
        log("dry-run: 候補あり（通知・state更新なし）")
        print(build_message(candidates))
        return 0

    # 重複抑制: (agent, latest) が未通知の候補のみ
    state = load_state()
    new_candidates = [
        c for c in candidates if state.get(c["agent"]) != c["latest"]
    ]
    if not new_candidates:
        log(f"候補{len(candidates)}件は全て通知済み。何もしない。")
        return 0

    message = build_message(new_candidates)
    log(f"新規候補{len(new_candidates)}件を通知:\n{message}")
    notify(message)

    now = datetime.now(timezone.utc).isoformat()
    for c in new_candidates:
        state[c["agent"]] = c["latest"]
    state["_last_notified_at"] = now
    save_state(state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
