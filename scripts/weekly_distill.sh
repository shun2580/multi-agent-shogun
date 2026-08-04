#!/bin/bash
# weekly_distill.sh — 週次蒸留スクリプト
# mandate/decisions_journal.md の新規エントリから原則候補を抽出し、
# judgment_model.md または approval_queue.md へ反映する。

set -euo pipefail

# ========================================
# Configuration
# ========================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOURNAL_FILE="${REPO_ROOT}/mandate/decisions_journal.md"
MODEL_FILE="${REPO_ROOT}/mandate/judgment_model.md"
QUEUE_FILE="${REPO_ROOT}/mandate/approval_queue.md"
LOG_FILE="${REPO_ROOT}/logs/weekly_distill.log"
LOG_DIR="$(dirname "${LOG_FILE}")"

# 初回実行保留フラグ
FIRST_RUN_DEFERRED=true

# ========================================
# Functions
# ========================================

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

log_info() { log_msg "INFO" "$@"; }
log_warn() { log_msg "WARN" "$@"; }
log_error() { log_msg "ERROR" "$@"; }

check_deferred() {
    if [[ "${FIRST_RUN_DEFERRED}" == "true" ]]; then
        log_warn "初回実行は保留中です。殿からの実行指示を待ってください。"
        echo ""
        echo "保留理由: decisions_journal.md が十分なボリュームに達するまで実行すると、"
        echo "偽陽性の原則化を招く。殿が明示指示するまで延期。"
        exit 0
    fi
}

ensure_log_dir() {
    mkdir -p "${LOG_DIR}"
}

# ========================================
# Pre-flight checks
# ========================================

ensure_log_dir

log_info "=== Weekly distillation started ==="
log_info "Repo root: ${REPO_ROOT}"

# Check required files
if [[ ! -f "${JOURNAL_FILE}" ]]; then
    log_error "decisions_journal.md not found: ${JOURNAL_FILE}"
    exit 1
fi

if [[ ! -f "${MODEL_FILE}" ]]; then
    log_error "judgment_model.md not found: ${MODEL_FILE}"
    exit 1
fi

if [[ ! -f "${QUEUE_FILE}" ]]; then
    log_error "approval_queue.md not found: ${QUEUE_FILE}"
    exit 1
fi

log_info "Required files verified."

# ========================================
# Deferred first run check
# ========================================

check_deferred

# ========================================
# Step 1: Extract new entries since last distillation
# ========================================

log_info "[STEP1] Extracting new journal entries..."

# Look for the last distillation record in the journal
last_distill_date=$(grep -E '^\d{4}-\d{2}-\d{2}.*CORRECT.*週次蒸留' "${JOURNAL_FILE}" | tail -1 | cut -d'|' -f1 | xargs || echo "")

if [[ -z "${last_distill_date}" ]]; then
    log_info "No previous distillation found. Using git history."
    # Use git to find the date range
    git_log=$(cd "${REPO_ROOT}" && git log --oneline --format="%ai %s" -- "${JOURNAL_FILE}" | head -1 || echo "")
    if [[ -z "${git_log}" ]]; then
        start_date="2026-07-27"  # cmd_145 Q1-Q19初期化日
        log_info "Using default start date: ${start_date}"
    else
        start_date=$(echo "${git_log}" | cut -d' ' -f1)
        log_info "Using git commit date as start: ${start_date}"
    fi
else
    log_info "Last distillation: ${last_distill_date}"
    start_date="${last_distill_date}"
fi

end_date=$(date '+%Y-%m-%d')
log_info "Date range: ${start_date} to ${end_date}"

# ========================================
# Step 2-4: Placeholder for principle extraction
# ========================================

# Note: Full extraction logic would require parsing the journal YAML format
# and matching against existing principles. This is complex and typically
# performed manually or with a more sophisticated tool.
# For now, we log the detection and prompt manual review.

log_info "[STEP2-4] Principle extraction requires manual review."
log_info "Please review new entries in decisions_journal.md from ${start_date} to ${end_date}:"
log_info "  File: ${JOURNAL_FILE}"
log_info "  Existing principles: ${MODEL_FILE}"
log_info "  Queue for new principles: ${QUEUE_FILE}"

# ========================================
# Step 5: Record distillation execution
# ========================================

log_info "[STEP5] Recording distillation execution..."

distill_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
entry="$(date '+%Y-%m-%d') | CORRECT | 週次蒸留実行(${start_date}～${end_date}) | 開始 ${distill_timestamp}, 自動スクリプト実行(manual_review必須). 原則候補抽出は手動レビューを待機中 | 自動実行"

# Append to journal (only if not in deferred mode, but deferred check happened earlier)
echo "" >> "${JOURNAL_FILE}"
echo "${entry}" >> "${JOURNAL_FILE}"

log_info "Distillation record added to decisions_journal.md"

# ========================================
# Step 6: Quality checks
# ========================================

log_info "[STEP6] Quality checks..."

# Check model line count
line_count=$(wc -l < "${MODEL_FILE}")
log_info "judgment_model.md line count: ${line_count}/160"

if (( line_count > 160 )); then
    log_warn "⚠️  judgment_model.md exceeds 160 lines! Consolidation required."
fi

# Check git diff
log_info "Checking changes..."
cd "${REPO_ROOT}"
if git diff --quiet mandate/; then
    log_info "No changes detected."
else
    log_info "Changes detected in mandate/ directory. Please review:"
    git diff mandate/ | head -30 >> "${LOG_FILE}"
fi

# ========================================
# Completion
# ========================================

log_info "[COMPLETE] Weekly distillation finished."
log_info "Log file: ${LOG_FILE}"
log_info ""
log_info "Next steps:"
log_info "1. Review new entries in ${JOURNAL_FILE}"
log_info "2. Update ${MODEL_FILE} with unified principles or"
log_info "3. Add new principle entries to ${QUEUE_FILE} with doubt欄"
log_info "4. Commit changes after manual review"
log_info ""

exit 0
