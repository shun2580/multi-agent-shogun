#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# model_update_check.sh — 新モデル版の検知・通知ラッパー（自動適用なし）
#
# 同ティアで新しいモデル版が公式に出ていれば、ntfy（殿へ）＋家老inbox で通知。
# settings.yaml の書き換えや switch_cli.sh は行わない（適用は殿の承認後、人間が実施）。
#
# Usage:
#   bash scripts/model_update_check.sh            # 検知→新規候補があれば通知
#   bash scripts/model_update_check.sh --dry-run  # 表示のみ（通知しない）
#   bash scripts/model_update_check.sh --json      # 候補をJSON出力
#
# cron例（毎日9:15）:
#   15 9 * * * bash <repo>/scripts/model_update_check.sh >> <repo>/logs/model_update_check.log 2>&1
# ═══════════════════════════════════════════════════════════════
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/model_update_check.py" "$@"
