#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# resume_auto_heal.sh — auto_heal_paused解除スクリプト(cmd_194 工程1)
#
# 🔴殿または将軍が手動実行すること。家老・足軽・軍師からの自動呼び出しは禁止。
# 🔴scripts/配下の他スクリプト(watcher・cron等)からこのスクリプトを呼び出す
#   経路を一切作らないこと(時間経過による自動解除の禁止)。本スクリプトは
#   実行者を検証できないため、この運用制約は使用者の遵守にのみ依存する。
#
# Usage: bash scripts/resume_auto_heal.sh <agent_id>
#
# 動作: logs/auto_heal_paused/<agent_id> フラグファイルを削除し、
#       logs/auto_heal_events.jsonl へ auto_heal_resumed イベントを記帳する。
#       フラグが存在しなければエラー終了(exit 1)。
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AGENT_ID="${1:-}"
if [ -z "$AGENT_ID" ]; then
    echo "Usage: bash scripts/resume_auto_heal.sh <agent_id>" >&2
    echo "殿または将軍が手動実行すること。家老・足軽・軍師からの自動呼び出しは禁止。" >&2
    exit 1
fi

FLAG_PATH="${SCRIPT_DIR}/logs/auto_heal_paused/${AGENT_ID}"

if [ ! -f "$FLAG_PATH" ]; then
    echo "ERROR: pause flag not found for agent '${AGENT_ID}' (${FLAG_PATH})" >&2
    exit 1
fi

rm -f "$FLAG_PATH"

EVENTS_LOG="${SCRIPT_DIR}/logs/auto_heal_events.jsonl"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true

TS="$(date +%Y-%m-%dT%H:%M:%S%:z)"
printf '{"ts":"%s","agent":"%s","event":"auto_heal_resumed","triggered_by":"manual"}\n' \
    "$TS" "$AGENT_ID" >> "$EVENTS_LOG"

echo "[$(date)] auto_heal resumed for agent '${AGENT_ID}'." >&2
