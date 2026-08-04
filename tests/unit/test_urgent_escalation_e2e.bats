#!/usr/bin/env bats
# test_urgent_escalation_e2e.bats — cmd_146 A2
#
# gunshi QC(gunshi_qc_146_a)指摘: check_urgent_inbox_escalation()自体は健全だが、
# urgent:trueを書き込む経路がinbox_write.sh含めどこにも存在せず「本番到達性」が
# 欠けていた。本テストは、実際のinbox_write.sh(--urgentフラグ)を実行して
# メッセージを書き込み、その実出力に対してcheck_urgent_inbox_escalation()を
# 走らせるところまでを一気通貫で確認する(モックで済ませない)。
#
# 隔離: TEST_TMP配下に scripts/inbox_write.sh・.venv・scripts/inbox_watcher.sh用
# ntfyダミーをシンボリックリンク/生成し、本番queue/inbox・logs/timing_events.jsonlには
# 一切触れない。--urgentで書き込むメッセージのTYPEはcmd_new/task_assigned/
# report_received以外の値にし、log_timing_event.sh呼び出し分岐(_TIMING_EVENT)を
# 意図的に踏ませない(このテストの関心=urgentフィールドの書込→検出のみのため)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WRITE_SCRIPT="$PROJECT_ROOT/scripts/inbox_write.sh"
    WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/logs" "$TEST_TMP/queue/inbox" "$TEST_TMP/config" "$TEST_TMP/scripts"
    ln -s "$PROJECT_ROOT/.venv" "$TEST_TMP/.venv"
    # inbox_write.sh は自身のBASH_SOURCEからSCRIPT_DIRを解決するため、
    # symlinkをTEST_TMP/scripts/配下に置いて呼び出すことでSCRIPT_DIR=TEST_TMPにできる。
    ln -s "$WRITE_SCRIPT" "$TEST_TMP/scripts/inbox_write.sh"

    NTFY_LOG="$TEST_TMP/ntfy.log"
    TIMING_LOG="$TEST_TMP/logs/timing_events.jsonl"
    : > "$NTFY_LOG"
    : > "$TIMING_LOG"

    cat > "$TEST_TMP/scripts/ntfy.sh" <<EOF
#!/bin/bash
echo "NTFY \$*" >> "$NTFY_LOG"
EOF
    chmod +x "$TEST_TMP/scripts/ntfy.sh"

    cat > "$TEST_TMP/config/settings.yaml" <<'EOF'
urgent_inbox_escalation:
  threshold_minutes: 120
  check_interval_minutes: 0
  cooldown_after_escalation_minutes: 60
EOF
}

teardown() {
    rm -rf "$TEST_TMP"
}

# 実際に書き込まれたtimestampを、閾値超過となる過去日時へ書き換える
# (実時間120分の経過を待たずに検証するための合成——注入先はTEST_TMP隔離inboxのみ)
backdate_timestamp() {
    local inbox_file="$1" minutes_ago="$2"
    "$PROJECT_ROOT/.venv/bin/python3" -c "
import datetime, sys
import yaml

path, minutes_ago = sys.argv[1], float(sys.argv[2])
with open(path) as f:
    data = yaml.safe_load(f)
past = (datetime.datetime.now() - datetime.timedelta(minutes=minutes_ago)).isoformat(timespec='seconds')
for msg in data['messages']:
    msg['timestamp'] = past
with open(path, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
" "$inbox_file" "$minutes_ago"
}

run_urgent_escalation() {
    run bash -c '
        SCRIPT_DIR="'"$TEST_TMP"'"
        export __INBOX_WATCHER_TESTING__=1
        source "'"$WATCHER_SCRIPT"'" >/dev/null 2>&1
        check_urgent_inbox_escalation
    '
}

@test "E2E-1: inbox_write.sh --urgent で書いた実メッセージが、閾値超過後にcheck_urgent_inbox_escalationで実際に発火する" {
    run bash "$TEST_TMP/scripts/inbox_write.sh" karo "至急確認されたし(E2E合成)" urgent_test gunshi --urgent
    [ "$status" -eq 0 ]

    local inbox_file="$TEST_TMP/queue/inbox/karo.yaml"
    [ -f "$inbox_file" ]
    grep -q "urgent: true" "$inbox_file"

    backdate_timestamp "$inbox_file" 150

    run_urgent_escalation
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
    grep -q "至急確認されたし(E2E合成)" "$NTFY_LOG"
}

@test "E2E-2: --urgent=true でも同様にurgent:trueが書き込まれ発火する" {
    run bash "$TEST_TMP/scripts/inbox_write.sh" karo "至急確認されたし(E2E合成2)" urgent_test gunshi --urgent=true
    [ "$status" -eq 0 ]

    local inbox_file="$TEST_TMP/queue/inbox/karo.yaml"
    backdate_timestamp "$inbox_file" 150

    run_urgent_escalation
    [ "$status" -eq 0 ]
    [ "$(grep -c '^NTFY' "$NTFY_LOG")" -eq 1 ]
}

@test "E2E-3: --urgent省略時(既存動作)はurgent:falseで書き込まれ、閾値超過でも発火しない(後方互換)" {
    run bash "$TEST_TMP/scripts/inbox_write.sh" karo "通常報告(E2E合成)" urgent_test gunshi
    [ "$status" -eq 0 ]

    local inbox_file="$TEST_TMP/queue/inbox/karo.yaml"
    grep -q "urgent: false" "$inbox_file"

    backdate_timestamp "$inbox_file" 150

    run_urgent_escalation
    [ "$status" -eq 0 ]
    [ ! -s "$NTFY_LOG" ]
}
