#!/usr/bin/env bats
# test_dashboard_staleness.bats — cmd_146②・cmd_194実例(b)回帰
#
# 🔴cmd_198工程1(Q59①): dashboard_stale_notifier(check_dashboard_staleness()・
# _read_dashboard_staleness_setting()・dashboard_staleness_suppress_on_startup()、
# 旧①③④⑤a〜e群のテスト)は退役・削除済み(scripts/inbox_watcher.sh参照)。
# 本ファイルはretireの過程で、退役対象と無関係な2つの生存機構のテストのみを
# 残して縮小した(ファイル名は旧名のまま——リネームはashigaru1のtask
# allowed_pathsのスコープ外のため、家老の判断で別途cmdを起こされたし):
#   ②check_urgent_inbox_escalation(): urgent:true未読エントリの閾値超過
#     エスカレーション(cmd_146②・keep対象・独立機構)
#   ⑤-b-2: build_fleet_idle_message()のorphan-bullet型未起票残タスク集計
#     (cmd_194実例(b)の実害再現・keep対象。共有ヘルパー
#     _split_dashboard_blocks()等はcheck_dashboard_staleness()削除後も
#     build_fleet_idle_message()が引き続き使用するため回帰防止に必要)
#
# 本番dashboard.md/logs/timing_events.jsonl/ntfy送信には一切触れない。
# SCRIPT_DIRを隔離TEST_TMPへ差し替えて scripts/inbox_watcher.sh を
# __INBOX_WATCHER_TESTING__=1 でsourceし、対象関数を直接呼び出す。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/logs" "$TEST_TMP/queue/inbox" "$TEST_TMP/config" "$TEST_TMP/scripts"
    ln -s "$PROJECT_ROOT/.venv" "$TEST_TMP/.venv"
    ln -s "$PROJECT_ROOT/scripts/log_timing_event.sh" "$TEST_TMP/scripts/log_timing_event.sh"

    NTFY_LOG="$TEST_TMP/ntfy.log"
    TIMING_LOG="$TEST_TMP/logs/timing_events.jsonl"
    : > "$NTFY_LOG"
    : > "$TIMING_LOG"

    cat > "$TEST_TMP/scripts/ntfy.sh" <<EOF
#!/bin/bash
echo "NTFY \$*" >> "$NTFY_LOG"
EOF
    chmod +x "$TEST_TMP/scripts/ntfy.sh"

    SETTINGS="$TEST_TMP/config/settings.yaml"
    cat > "$SETTINGS" <<'EOF'
urgent_inbox_escalation:
  threshold_minutes: 120
  check_interval_minutes: 0
  cooldown_after_escalation_minutes: 60
EOF
}

teardown() {
    rm -rf "$TEST_TMP"
}

# $1 = 現在から何分前か(小数可)。過去のISOタイムスタンプを返す。
ts_minutes_ago() {
    "$PROJECT_ROOT/.venv/bin/python3" -c "
import datetime, sys
print((datetime.datetime.now() - datetime.timedelta(minutes=float(sys.argv[1]))).isoformat(timespec='seconds'))
" "$1"
}

write_inbox_msg() {
    local agent="$1" id="$2" urgent="$3" read_flag="$4" ts="$5" content="$6"
    local path="$TEST_TMP/queue/inbox/${agent}.yaml"
    if [ ! -f "$path" ]; then
        printf 'messages:\n' > "$path"
    fi
    cat >> "$path" <<EOF
- id: ${id}
  from: gunshi
  urgent: ${urgent}
  read: ${read_flag}
  timestamp: '${ts}'
  content: '${content}'
EOF
}

run_urgent_escalation() {
    run bash -c '
        SCRIPT_DIR="'"$TEST_TMP"'"
        export __INBOX_WATCHER_TESTING__=1
        source "'"$WATCHER_SCRIPT"'" >/dev/null 2>&1
        check_urgent_inbox_escalation
    '
}

run_fleet_idle_message() {
    run bash -c '
        SCRIPT_DIR="'"$TEST_TMP"'"
        export __INBOX_WATCHER_TESTING__=1
        source "'"$WATCHER_SCRIPT"'" >/dev/null 2>&1
        build_fleet_idle_message
    '
}

# ═══════════════════════════════════════════════════════════════
# ② urgent inbox escalation (cmd_146②)
# ═══════════════════════════════════════════════════════════════

@test "②-1: urgent:true かつ read:false で閾値(120分)超過 → ntfy発火する" {
    local old_ts
    old_ts="$(ts_minutes_ago 150)"  # 閾値120分を超過
    write_inbox_msg "karo" "msg_urgent_1" "true" "false" "$old_ts" "緊急未読メッセージ"
    run_urgent_escalation
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "緊急未読メッセージ" "$NTFY_LOG"
}

@test "②-2: urgent:true でも閾値未満(120分未満)では発火しない" {
    local recent_ts
    recent_ts="$(ts_minutes_ago 30)"
    write_inbox_msg "karo" "msg_urgent_2" "true" "false" "$recent_ts" "まだ閾値未満の緊急メッセージ"
    run_urgent_escalation
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "②-3: urgent標識なしの通常未読は閾値超過でも発火しない(過剰発火防止)" {
    local old_ts
    old_ts="$(ts_minutes_ago 300)"
    write_inbox_msg "karo" "msg_normal_1" "false" "false" "$old_ts" "通常の未読メッセージ"
    run_urgent_escalation
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "②-4: urgent:true でも read:true(既読)なら発火しない" {
    local old_ts
    old_ts="$(ts_minutes_ago 300)"
    write_inbox_msg "karo" "msg_urgent_read" "true" "true" "$old_ts" "既読済みの緊急メッセージ"
    run_urgent_escalation
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "②-5: cooldown内の再エスカレーションは抑止される" {
    local old_ts recent_escalation_ts
    old_ts="$(ts_minutes_ago 300)"
    recent_escalation_ts="$(ts_minutes_ago 10)"  # cooldown 60分以内に既にエスカレーション済み
    write_inbox_msg "karo" "msg_urgent_cooldown" "true" "false" "$old_ts" "cooldown中の緊急メッセージ"
    "$PROJECT_ROOT/.venv/bin/python3" -c "
import json, sys
ts = sys.argv[1]
rec = {'ts': ts, 'event': 'urgent_inbox_escalated', 'cmd_id': None, 'task_id': 'msg_urgent_cooldown',
       'agent': 'karo', 'redo_of': None, 'qc_result': None, 'source': 'test', 'extra': None}
print(json.dumps(rec, ensure_ascii=False))
" "$recent_escalation_ts" >> "$TIMING_LOG"
    run_urgent_escalation
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# ⑤-b-2 cmd_194実例(b)回帰: orphan-bullet型のfleet_idle未起票集計
# ═══════════════════════════════════════════════════════════════

@test "⑤-b-2: orphan-bullet型は build_fleet_idle_message() の未起票残タスク件数でも過小集計されず3件とカウントされる(cmd_194実例(b)の実害再現)" {
    local old_ts
    old_ts="$(ts_minutes_ago 100)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 📌 予定事項
<!-- created_at: ${old_ts} -->
- orphan予定事項1(own_marker保持)
- orphan予定事項2(own_markerなし)
- orphan予定事項3(own_markerなし)
EOF
    run_fleet_idle_message
    [ "$status" -eq 0 ]
    grep -qF "未起票残タスク件数: 3件" <<< "$output"
}
