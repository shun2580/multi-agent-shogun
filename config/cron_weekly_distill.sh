#!/bin/bash
# cron_weekly_distill.sh
#
# Weekly distillation のcron/スケジュール設定スクリプト。
# 実行することで定期実行の登録が完了する。
#
# 使用法:
#   bash config/cron_weekly_distill.sh setup    # cron登録
#   bash config/cron_weekly_distill.sh remove   # cron解除
#   bash config/cron_weekly_distill.sh status   # 登録状況確認
#
# 🔴初回実行について（保留）:
# 本スクリプトが登録するcron/スケジュール設定は、初回実行を保留としている。
# 殿からの明示指示があるまで、実際には起動しない。
#
# スクリプト側の保留フラグ(scripts/weekly_distill.sh:FIRST_RUN_DEFERRED=true)と
# 本設定ファイルの保留表記の双方が揃うことで、うっかりな初回実行を防ぐ。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${REPO_ROOT}/scripts/weekly_distill.sh"
LOG_PATH="${REPO_ROOT}/logs/weekly_distill.log"

# Cron job definition
# 毎週日曜 09:00 実行
CRON_SCHEDULE="0 9 * * 0"
CRON_COMMAND="cd ${REPO_ROOT} && bash ${SCRIPT_PATH} >> ${LOG_PATH} 2>&1"

# ========================================
# Functions
# ========================================

setup_cron() {
    echo "Setting up weekly distillation cron job..."
    echo ""
    echo "🔴 DEFERRED: Initial execution is on hold."
    echo "   Reason: Waiting for sufficient decisions_journal.md volume."
    echo "   The following cron entry is ready but will not execute until Lord's command."
    echo ""
    echo "Schedule: ${CRON_SCHEDULE} (Every Sunday 09:00)"
    echo "Command: ${CRON_COMMAND}"
    echo ""

    # Check if entry already exists
    if crontab -l 2>/dev/null | grep -q "${SCRIPT_PATH}"; then
        echo "⚠️  Cron entry already registered. Skipping."
        return 0
    fi

    # Add new cron entry
    (crontab -l 2>/dev/null || echo "") | {
        cat
        echo ""
        echo "# Weekly distillation (cmd_145 Part5)"
        echo "# DEFERRED FIRST RUN - Waiting for Lord's explicit command"
        echo "${CRON_SCHEDULE} ${CRON_COMMAND}"
    } | crontab -

    echo "✅ Cron entry registered."
    echo ""
    echo "To activate, edit scripts/weekly_distill.sh and set:"
    echo "  FIRST_RUN_DEFERRED=false"
    echo "AND edit this file to remove the DEFERRED comment lines."
    echo ""
}

remove_cron() {
    echo "Removing weekly distillation cron job..."

    if ! crontab -l 2>/dev/null | grep -q "${SCRIPT_PATH}"; then
        echo "⚠️  Cron entry not found. Nothing to remove."
        return 0
    fi

    crontab -l 2>/dev/null | grep -v "${SCRIPT_PATH}" | \
        grep -v "Weekly distillation" | \
        grep -v "DEFERRED FIRST RUN" | \
        crontab -

    echo "✅ Cron entry removed."
}

status_cron() {
    echo "Weekly distillation cron status:"
    echo ""

    if crontab -l 2>/dev/null | grep -q "${SCRIPT_PATH}"; then
        echo "✅ Cron entry is registered:"
        crontab -l 2>/dev/null | grep -A1 "${SCRIPT_PATH}" || true
        echo ""
        echo "Status: DEFERRED (will not run until Lord's explicit command)"
        echo ""
        echo "To activate:"
        echo "  1. Edit scripts/weekly_distill.sh"
        echo "  2. Set FIRST_RUN_DEFERRED=false"
        echo "  3. Run: bash config/cron_weekly_distill.sh setup"
    else
        echo "❌ Cron entry is NOT registered."
        echo ""
        echo "To register:"
        echo "  bash config/cron_weekly_distill.sh setup"
    fi
}

# ========================================
# Main
# ========================================

COMMAND="${1:-status}"

case "${COMMAND}" in
    setup)
        setup_cron
        ;;
    remove)
        remove_cron
        ;;
    status)
        status_cron
        ;;
    *)
        echo "Usage: bash config/cron_weekly_distill.sh {setup|remove|status}"
        echo ""
        echo "Commands:"
        echo "  setup   - Register cron job (DEFERRED - will not run until activated)"
        echo "  remove  - Remove cron job"
        echo "  status  - Check registration status"
        exit 1
        ;;
esac
