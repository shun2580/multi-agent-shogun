#!/usr/bin/env bats
# test_dashboard_staleness.bats — cmd_146①②③
#   ①check_dashboard_staleness(): created_at走査を🚨要対応セクション内に限定
#   ②check_urgent_inbox_escalation(): urgent:true未読エントリの閾値超過エスカレーション(新設)
#   ③check_dashboard_staleness(): 再通知を段階的に頻度低下(360分→720分→1440分)
#
# 本番dashboard.md/logs/timing_events.jsonl/ntfy送信には一切触れない。
# SCRIPT_DIRを隔離TEST_TMPへ差し替えて scripts/inbox_watcher.sh を
# __INBOX_WATCHER_TESTING__=1 でsourceし、対象関数を直接呼び出す。
# ntfy.shは隔離ダミーに差し替え、log_timing_event.shは実体をシンボリックリンクして
# 実際に動かす(BASH_SOURCE経由でSCRIPT_DIRが隔離TEST_TMPに解決されるため
# logs/timing_events.jsonlも隔離側へ書かれる)。

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
dashboard_staleness:
  hours: 24
  check_interval_minutes: 0
  cooldown_after_escalation_minutes: 360
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

# timing_events.jsonl へ dashboard_stale_notified 記録を直接1件追記する
# (段階の"前回通知"状態を作るためのテスト専用シード。本番ログには一切触れない)
seed_notify_record() {
    local ts="$1" task_id="$2" notify_count="$3"
    "$PROJECT_ROOT/.venv/bin/python3" -c "
import json, sys
ts, task_id, notify_count = sys.argv[1:4]
rec = {'ts': ts, 'event': 'dashboard_stale_notified', 'cmd_id': None, 'task_id': task_id,
       'agent': 'karo', 'redo_of': None, 'qc_result': None, 'source': 'test',
       'extra': f'notify_count={notify_count}'}
print(json.dumps(rec, ensure_ascii=False))
" "$ts" "$task_id" "$notify_count" >> "$TIMING_LOG"
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

run_dashboard_staleness() {
    run bash -c '
        SCRIPT_DIR="'"$TEST_TMP"'"
        export __INBOX_WATCHER_TESTING__=1
        source "'"$WATCHER_SCRIPT"'" >/dev/null 2>&1
        check_dashboard_staleness
    '
}

run_urgent_escalation() {
    run bash -c '
        SCRIPT_DIR="'"$TEST_TMP"'"
        export __INBOX_WATCHER_TESTING__=1
        source "'"$WATCHER_SCRIPT"'" >/dev/null 2>&1
        check_urgent_inbox_escalation
    '
}

# ═══════════════════════════════════════════════════════════════
# ① セクション限定
# ═══════════════════════════════════════════════════════════════

@test "①-1: 🚨要対応セクション外のcreated_atは通知対象から除外される" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"  # 26.7時間前(>24h stale)
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🛡️ Watcher稼働状態
<!-- created_at: ${old_ts} -->
不要な記録行(セクション外1)

## 🧊 フィーチャーフリーズ宣言
<!-- created_at: ${old_ts} -->
背景説明の文章(セクション外2)

## 🚨 要対応
<!-- created_at: ${old_ts} -->
本物の要対応項目

## ✅ 解決済み
<!-- created_at: ${old_ts} -->
解決済みなので対象外(セクション外3)
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "本物の要対応項目" "$NTFY_LOG"
    ! grep -q "セクション外" "$NTFY_LOG"
}

@test "①-2: 見出し絵文字を変えたダミーコピーでも区間検出できる(表記ゆれ吸収)" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 📌 予定事項
<!-- created_at: ${old_ts} -->
対象外の予定事項

## 📛 要対応
<!-- created_at: ${old_ts} -->
絵文字違いでも検出されるべき項目

## 📜 クローズ済み
<!-- created_at: ${old_ts} -->
対象外のクローズ済み
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "絵文字違いでも検出されるべき項目" "$NTFY_LOG"
}

@test "①-3: 🚨要対応セクションが無いdashboard.mdでは何も通知しない" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 📌 予定事項
<!-- created_at: ${old_ts} -->
要対応セクションがそもそも存在しないケース
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# ② 緊急エスカレーション(新設)
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
# ③ 再通知の段階抑制(360分→720分→1440分)
# ═══════════════════════════════════════════════════════════════

@test "③-1: 初回通知(前回通知記録なし)はstale項目に対して即座に発火する" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
初回通知対象
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "notify_count=1" "$TIMING_LOG"
}

@test "③-2: 1回目通知から360分未満は再通知しない" {
    local old_ts prev_notify_ts
    old_ts="$(ts_minutes_ago 1600)"
    prev_notify_ts="$(ts_minutes_ago 100)"  # 360分未満
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
再通知抑止対象
EOF
    seed_notify_record "$prev_notify_ts" "$old_ts" 1
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "③-3: 1回目通知から360分以上経過で2回目を再通知する" {
    local old_ts prev_notify_ts
    old_ts="$(ts_minutes_ago 1600)"
    prev_notify_ts="$(ts_minutes_ago 400)"  # 360分以上
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
2回目通知対象
EOF
    seed_notify_record "$prev_notify_ts" "$old_ts" 1
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "notify_count=2" "$TIMING_LOG"
}

@test "③-4: 2回目通知から720分未満は3回目を通知しない" {
    local old_ts prev_notify_ts
    old_ts="$(ts_minutes_ago 1600)"
    prev_notify_ts="$(ts_minutes_ago 100)"  # 720分未満
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
3回目抑止対象
EOF
    seed_notify_record "$prev_notify_ts" "$old_ts" 2
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "③-5: 2回目通知から720分以上経過で3回目を再通知する" {
    local old_ts prev_notify_ts
    old_ts="$(ts_minutes_ago 1600)"
    prev_notify_ts="$(ts_minutes_ago 800)"  # 720分以上
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
3回目通知対象
EOF
    seed_notify_record "$prev_notify_ts" "$old_ts" 2
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "notify_count=3" "$TIMING_LOG"
}

@test "③-6: 3回目以降は1440分未満だと再通知しない" {
    local old_ts prev_notify_ts
    old_ts="$(ts_minutes_ago 3000)"
    prev_notify_ts="$(ts_minutes_ago 1000)"  # 1440分未満
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
4回目抑止対象
EOF
    seed_notify_record "$prev_notify_ts" "$old_ts" 3
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "③-7: 3回目以降は1440分以上経過すると再通知する(24時間間隔)" {
    local old_ts prev_notify_ts
    old_ts="$(ts_minutes_ago 3000)"
    prev_notify_ts="$(ts_minutes_ago 1500)"  # 1440分以上
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
4回目通知対象
EOF
    seed_notify_record "$prev_notify_ts" "$old_ts" 3
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "notify_count=4" "$TIMING_LOG"
}

@test "③-8: 通知頻度が下がってもdashboard.md上の項目自体は消えない(抑止と黙殺の分離)" {
    local old_ts prev_notify_ts
    old_ts="$(ts_minutes_ago 3000)"
    prev_notify_ts="$(ts_minutes_ago 1000)"  # cooldown中(再通知は抑止される)
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
可視性維持の確認対象
EOF
    seed_notify_record "$prev_notify_ts" "$old_ts" 3
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
    # 通知は止まったが、項目自体はdashboard.mdから削除されていないこと
    grep -q "可視性維持の確認対象" "$TEST_TMP/dashboard.md"
}

# ═══════════════════════════════════════════════════════════════
# ④ 敵対的回帰(cmd_170: 取消線除外・項目単位created_at・持ち越しマーカー)
# ═══════════════════════════════════════════════════════════════

@test "④-1: 取消線あり・単一行 → 通知されない" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
- ~~取消線あり単一行の項目~~ ✅完了
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "④-2: 取消線あり・複数行にまたがる → 通知されない" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
- ~~取消線が
複数行にまたがる項目~~ ✅完了
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "④-3: 取消線なし・項目単位created_atが新しい(閾値未満) → 通知されない" {
    local recent_ts
    recent_ts="$(ts_minutes_ago 60)"  # 24h閾値未満
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${recent_ts} -->
- 取消線なし・created_atが新しい項目
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "④-4: 取消線なし・項目単位created_atが古い(閾値超過) → 通知される" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
- 取消線なし・created_atが古い項目
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "取消線なし・created_atが古い項目" "$NTFY_LOG"
}

@test "④-5: carryover_approvedあり・created_at超過 → 通知されない" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
<!-- carryover_approved: true -->
- carryover承認済み・放置ではない項目
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}

@test "④-6: carryover_approvedなし・created_at超過 → 通知される(非存在チェックの明示分離)" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
- carryover_approvedマーカーが存在しない・超過項目
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "carryover_approvedマーカーが存在しない・超過項目" "$NTFY_LOG"
}

@test "④-7: 同一セクション内に取消線あり1件+carryoverあり1件+通常stale1件が混在 → stale1件のみ通知される" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
- ~~取消線あり項目(混在)~~ ✅完了
<!-- created_at: ${old_ts} -->
<!-- carryover_approved: true -->
- carryover承認済み項目(混在)
<!-- created_at: ${old_ts} -->
- 通常stale項目(混在・唯一通知されるべき)
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "通常stale項目(混在・唯一通知されるべき)" "$NTFY_LOG"
    ! grep -q "取消線あり項目(混在)" "$NTFY_LOG"
    ! grep -q "carryover承認済み項目(混在)" "$NTFY_LOG"
}

@test "④-8: 取消線の開始~~のみあり閉じタグが無い(壊れたMarkdown) → 安全側(通知する)へ倒れる" {
    local old_ts
    old_ts="$(ts_minutes_ago 1600)"
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts} -->
- ~~閉じタグの無い壊れたMarkdown項目
EOF
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "閉じタグの無い壊れたMarkdown項目" "$NTFY_LOG"
}

@test "④-9: 同一セクション内でcooldown中の項目とstale初回項目が混在しても項目単位で独立して判定される(旧セクション単位1マーカーでは検証不能だった回帰)" {
    local old_ts_a old_ts_b prev_notify_ts
    old_ts_a="$(ts_minutes_ago 1600)"
    old_ts_b="$(ts_minutes_ago 1700)"
    prev_notify_ts="$(ts_minutes_ago 100)"  # cooldown 360分未満 → old_ts_aは抑止されるべき
    cat > "$TEST_TMP/dashboard.md" <<EOF
## 🚨 要対応
<!-- created_at: ${old_ts_a} -->
- cooldown中のため抑止されるべき項目(混在)
<!-- created_at: ${old_ts_b} -->
- 初回stale・通知されるべき項目(混在)
EOF
    seed_notify_record "$prev_notify_ts" "$old_ts_a" 1
    run_dashboard_staleness
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "初回stale・通知されるべき項目(混在)" "$NTFY_LOG"
    ! grep -q "cooldown中のため抑止されるべき項目" "$NTFY_LOG"
    grep -qF "\"task_id\": \"${old_ts_b}\"" "$TIMING_LOG"
    grep -qF "\"extra\": \"notify_count=1\"" "$TIMING_LOG"
}
