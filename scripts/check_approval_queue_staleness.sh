#!/bin/bash
set -euo pipefail

# scripts/check_approval_queue_staleness.sh (cmd_165 subtask_165_A)
#
# Purpose: On-demand tool invoked during 陣仕舞い (safe-stop) processing.
# Scans mandate/approval_queue.md for pending AQ entries using the same
# 消去法 (approved/rejected 以外は pending系) judgment logic already
# implemented in scripts/inbox_watcher.sh build_fleet_idle_message()
# (duplicated here rather than shared, per the task's "相乗り、新設せず"
# scope — this script is a separate on-demand tool, not a library import).
#
# For each pending entry:
#   - Reports staleness (days since the entry's 日付: field).
#   - If the entry body mentions "未push" or "commit", re-measures the
#     current unpushed-commit count via `git log origin/main..HEAD` and
#     compares it against the most recent "(\d+)件" figure recorded in the
#     entry body. On mismatch, appends a 🔴STALE line to the END of that
#     entry in mandate/approval_queue.md (append-only — existing text is
#     never rewritten, per原則5 fail-loud / no silent rewrite).
#   - Otherwise reports "再実測対象なし(手動確認要)" without comparing.
#   - Reports any doubt-section mention of downstream-blocked count
#     ("下流...件"), or "下流件数: 未記入" if none is present. This field
#     is free text with no structured format, so it is never guessed.
#
# This is a manually-invoked, on-demand tool (no daemon, no flag-gated
# on/off/observe/enforce — see cmd_165 subtask_165_A gunshi decomposition
# 依頼事項4). It performs no destructive operations; the only file mutation
# is an append-only STALE annotation to mandate/approval_queue.md.
#
# Usage: bash scripts/check_approval_queue_staleness.sh
# Exit codes: 0 = ran to completion (regardless of STALE detections)
#             1 = mandate/approval_queue.md not found

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AQ_FILE="$REPO_ROOT/mandate/approval_queue.md"
PY="$REPO_ROOT/.venv/bin/python3"
[ -x "$PY" ] || PY="python3"

if [ ! -f "$AQ_FILE" ]; then
    echo "ERROR: $AQ_FILE not found" >&2
    exit 1
fi

NOW_STAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
TODAY="$(date '+%Y-%m-%d')"

# 未pushコミット数の実測(全pending中に該当キーワードを含むエントリが
# あれば使い回す。git状態はスクリプト実行中に変化しないため、エントリ毎に
# 再フェッチする必要は無い)。
cd "$REPO_ROOT"
git fetch origin main >/dev/null 2>&1 || echo "WARN: git fetch origin main failed (network unavailable?) — unpushed-commit comparison may use a stale local view" >&2
ACTUAL_UNPUSHED_COUNT="$(git log origin/main..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')"

echo "=== check_approval_queue_staleness.sh ($NOW_STAMP) ==="
echo "実測: 未pushコミット数 = ${ACTUAL_UNPUSHED_COUNT}件 (git fetch origin main && git log origin/main..HEAD --oneline | wc -l)"
echo ""

"$PY" - "$AQ_FILE" "$TODAY" "$NOW_STAMP" "$ACTUAL_UNPUSHED_COUNT" <<'PYEOF'
import re
import sys
from datetime import date

aq_path, today_str, now_stamp, actual_count_str = sys.argv[1:5]
actual_count = int(actual_count_str)
today = date.fromisoformat(today_str)

with open(aq_path, encoding='utf-8') as f:
    text = f.read()

# エントリ境界: build_fleet_idle_message() (scripts/inbox_watcher.sh) と
# 同一の正規表現・消去法判定を複製(依頼事項2の指示どおり車輪の再発明を避けつつ
# 独立スクリプトとして複製)。
entries = list(re.finditer(r'^- ID: (AQ-\d+)', text, re.MULTILINE))

appends = []  # list of (insert_pos, stale_line_text) — applied bottom-to-top

for i, m in enumerate(entries):
    aq_id = m.group(1)
    start = m.end()
    end = entries[i + 1].start() if i + 1 < len(entries) else len(text)
    body = text[start:end]

    status_m = re.search(r'^\s*状態:\s*(.+)$', body, re.MULTILINE)
    if status_m is None:
        continue
    status_val = status_m.group(1)
    # 消去法判定(build_fleet_idle_message()と同一ロジック: approved/rejected
    # 以外は全てpending系とみなす。将来の状態語彙追加で誤判定し得る既知の
    # 脆さも同様に継承する)。
    if 'approved' in status_val or 'rejected' in status_val:
        continue

    date_m = re.search(r'日付:\s*(\d{4}-\d{2}-\d{2})', body)
    age_str = '不明(日付欄なし)'
    if date_m:
        entry_date = date.fromisoformat(date_m.group(1))
        age_days = (today - entry_date).days
        age_str = f'{age_days}日'

    print(f'--- {aq_id} ---')
    print(f'  滞留日数: {age_str}')

    has_keyword = ('未push' in body) or ('commit' in body)
    if has_keyword:
        nums = re.findall(r'(\d+)件', body)
        if nums:
            recorded = int(nums[-1])
            if recorded != actual_count:
                stale_line = (
                    f'  🔴STALE(自動再実測不一致・{now_stamp}・軍師/家老が要再確認): '
                    f'記載値={recorded}件、実測値={actual_count}件\n'
                )
                print(f'  {stale_line.strip()}')
                appends.append((end, stale_line))
            else:
                print(f'  再実測: 一致(記載値={recorded}件, 実測値={actual_count}件)')
        else:
            print('  再実測: キーワード該当だが「(数字)件」パターンが本文中に見つからず比較不可')
    else:
        print('  再実測対象なし(手動確認要)')

    downstream_m = re.search(r'下流[^\n]*?\d+件[^\n]*', body)
    if downstream_m:
        print(f'  下流件数: {downstream_m.group(0).strip()}')
    else:
        print('  下流件数: 未記入')
    print('')

if appends:
    # 末尾側から挿入(先頭側の挿入でオフセットが崩れるのを防ぐため逆順)。
    new_text = text
    for pos, line in sorted(appends, key=lambda x: x[0], reverse=True):
        new_text = new_text[:pos] + line + new_text[pos:]
    with open(aq_path, 'w', encoding='utf-8') as f:
        f.write(new_text)
    print(f'{aq_path} へSTALE行を{len(appends)}件追記した(追記専用・既存記載は変更なし)。')
else:
    print('STALE行の追記は発生しなかった(全pendingエントリが実測と一致、または再実測対象外)。')
PYEOF
