#!/usr/bin/env bats
# cmd_140: pane出力静止検知・自動復旧watcher scripts/stall_watcher.sh のテスト
# 軍師設計(gunshi_design_140) bats_test_plan (12ケース、SKIP不可)準拠。
# 実tmux・実ntfy送信・本番ログ(logs/stall_events.jsonl等)は一切使わない。
# tmuxはPATH経由の疑似実行ファイルに差し替え(timeout経由の呼び出しにも
# 対応するため、test_deadman_watcher.batsのシェル関数スタブ方式ではなく
# 実行ファイル方式を採る)。ntfy.sh/inbox_write.shはtest_deadman_watcher.bats
# と同じくbashシェル関数の差し替えでインターセプトする(timeoutを経由しない
# 直接呼び出しのため関数スタブで十分)。
#
# ケース12(watcher_supervisor.shの冪等性)は
# tests/unit/test_watcher_supervisor_dedup.bats の case D/E に実装済み
# (実際のsupervisorテストファイル名は test_watcher_supervisor.bats ではなく
# test_watcher_supervisor_dedup.bats。設計書のファイル名記載は誤りだったため
# 既存の実ファイルへ追加した)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    STALL_SCRIPT="$PROJECT_ROOT/scripts/stall_watcher.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/bin" "$TEST_TMP/inbox"

    TIMING_LOG="$TEST_TMP/timing_events.jsonl"
    STALL_LOG="$TEST_TMP/stall_events.jsonl"
    : > "$STALL_LOG"
    SETTINGS="$TEST_TMP/settings.yaml"
    AGENT_SETTINGS="$TEST_TMP/agent_settings.yaml"
    INBOX_DIR="$TEST_TMP/inbox"
    NOW_EPOCH=1700000000

    # 固定5エージェント編成(karo/ashigaru1/ashigaru2/gunshi/shogun)にして、
    # pane割当を本番settings.yamlの変化に影響されず決定的にする。
    cat > "$AGENT_SETTINGS" <<'EOF'
cli:
  agents:
    karo:
    ashigaru1:
    ashigaru2:
    gunshi:
    shogun:
EOF

    # tmuxの疑似実行ファイル。get_pane_output_hash/send_nudge_to_paneは
    # timeout経由でtmuxを呼ぶため、シェル関数スタブではtimeoutの子プロセスに
    # 継承されない(execvpで直接"tmux"を探す)。PATH上に実体を置くことで
    # timeout経由でも確実にインターセプトする。
    cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    capture-pane)
        pane=""
        args=("\$@")
        for i in "\${!args[@]}"; do
            if [[ "\${args[\$i]}" == "-t" ]]; then pane="\${args[\$((i+1))]}"; fi
        done
        safe_pane=\$(printf '%s' "\$pane" | tr ':.' '__')
        if [ -f "$TEST_TMP/capture_\${safe_pane}.txt" ]; then
            cat "$TEST_TMP/capture_\${safe_pane}.txt"
        fi
        exit 0
        ;;
    send-keys)
        echo "SENDKEYS \$*" >> "$TEST_TMP/sendkeys.log"
        exit 0
        ;;
    show-options)
        echo "0"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$TEST_TMP/bin/tmux"
}

teardown() {
    rm -rf "$TEST_TMP"
}

write_settings() {
    local enabled="$1" threshold="${2:-10}" karo_wait="${3:-10}" ntfy_wait="${4:-10}" nudge_limit="${5:-3}" tick_sec="${6:-60}"
    cat > "$SETTINGS" <<EOF
features:
  stall_detection_enabled: $enabled
stall_detection:
  stall_threshold_min: $threshold
  karo_escalation_wait_min: $karo_wait
  ntfy_escalation_wait_min: $ntfy_wait
  nudge_limit_per_task: $nudge_limit
  tick_sec: $tick_sec
EOF
}

write_assigned() {
    local ts="$1" task_id="$2" agent="$3" cmd_id="${4:-cmd_test}"
    printf '{"ts": "%s", "event": "assigned", "cmd_id": "%s", "task_id": "%s", "agent": "%s", "redo_of": null, "qc_result": null, "source": "test", "extra": null}\n' \
        "$ts" "$cmd_id" "$task_id" "$agent" >> "$TIMING_LOG"
}

# cmd_194工程2是正: in-flight判定が一次資料(queue/tasks/{agent}.yaml)中心へ
# 転換されたため、write_assignedだけではarmしない。write_assigned直後に
# 対応するtask YAML fixtureを書くために使う(last_event_type/last_event_ts
# 表示用の付帯情報としてはwrite_assignedを引き続き使う)。
write_task_yaml() {
    local agent="$1" task_id="$2" cmd_id="${3:-cmd_test}"
    mkdir -p "$TEST_TMP/tasks"
    cat > "$TEST_TMP/tasks/${agent}.yaml" <<EOF
task:
  task_id: $task_id
  parent_cmd: $cmd_id
  status: assigned
EOF
}

pane_for() {
    case "$1" in
        karo) echo "multiagent:agents.0" ;;
        ashigaru1) echo "multiagent:agents.1" ;;
        ashigaru2) echo "multiagent:agents.2" ;;
        gunshi) echo "multiagent:agents.3" ;;
    esac
}

safe_pane_name() {
    printf '%s' "$1" | tr ':.' '__'
}

write_capture() {
    local pane="$1" text="$2"
    printf '%s' "$text" > "$TEST_TMP/capture_$(safe_pane_name "$pane").txt"
}

write_inbox() {
    local agent="$1" unread="$2"
    local msgs="" i
    for ((i = 0; i < unread; i++)); do
        msgs+=$'\n'"- read: false"$'\n'"  content: test"
    done
    if [ -z "$msgs" ]; then
        printf 'messages: []\n' > "$INBOX_DIR/${agent}.yaml"
    else
        printf 'messages:%s\n' "$msgs" > "$INBOX_DIR/${agent}.yaml"
    fi
}

seed_stall_event() {
    local ts="$1" event="$2" agent="$3" task_id="$4"
    printf '{"ts": "%s", "event": "%s", "agent": "%s", "task_id": "%s", "cmd_id": "cmd_seed", "pane_target": "%s", "elapsed_min": 10, "nudge_count_this_task": 1, "stall_threshold_min": 10}\n' \
        "$ts" "$event" "$agent" "$task_id" "$(pane_for "$agent")" >> "$STALL_LOG"
}

# スタブ: bash(ntfy.sh/inbox_write.sh実送信を防止)を差し替えた上でsnippetを実行する。
run_stall() {
    local snippet="$1"
    run env \
        TIMING_EVENTS_JSONL="$TIMING_LOG" \
        INFLIGHT_TASKS_DIR="$TEST_TMP/tasks" \
        INFLIGHT_REPORTS_DIR="$TEST_TMP/reports" \
        STALL_EVENTS_LOG="$STALL_LOG" \
        STALL_SETTINGS="$SETTINGS" \
        STALL_INBOX_DIR="$INBOX_DIR" \
        STALL_TEST_NOW="$NOW_EPOCH" \
        NOW_EPOCH="$NOW_EPOCH" \
        SHOGUN_PANE_BASE="0" \
        AGENT_REGISTRY_SETTINGS="$AGENT_SETTINGS" \
        PATH="$TEST_TMP/bin:$PATH" \
        TEST_TMP="$TEST_TMP" \
        bash -c '
            source "'"$STALL_SCRIPT"'" >/dev/null 2>&1

            bash() {
                if [[ "$1" == *ntfy.sh ]]; then
                    echo "NTFY $2" >> "$TEST_TMP/ntfy.log"
                elif [[ "$1" == *inbox_write.sh ]]; then
                    echo "INBOX_WRITE $*" >> "$TEST_TMP/inbox_write.log"
                else
                    command bash "$@"
                fi
            }

            '"$snippet"'
        '
}

# --- 1: flag=off即非発火 ---

@test "(1) stall_detection_enabled=false disables run_stall_tick entirely" {
    write_settings false
    write_assigned "2026-07-01T00:00:00+09:00" "task_1" "ashigaru1" "cmd_1"
    write_inbox ashigaru1 0
    write_capture "$(pane_for ashigaru1)" "steady output"

    run_stall 'run_stall_tick; STALL_TEST_NOW=$((NOW_EPOCH + 700)); run_stall_tick'
    [ "$status" -eq 0 ]
    [ ! -s "$STALL_LOG" ]
    [ ! -f "$TEST_TMP/sendkeys.log" ]
    [ ! -f "$TEST_TMP/ntfy.log" ]
    [ ! -f "$TEST_TMP/inbox_write.log" ]
}

# --- 2: 起動直後誤発火防止 ---

@test "(2) first observation of a task never fires stall/nudge, even with stale timing records" {
    write_settings true
    # 起動前から存在した「古い」assignedレコード(現在時刻から遥か過去)
    write_assigned "2020-01-01T00:00:00+09:00" "task_2" "ashigaru1" "cmd_2"
    write_inbox ashigaru1 0
    write_capture "$(pane_for ashigaru1)" "steady output"

    run_stall 'check_stall_tick'
    [ "$status" -eq 0 ]
    [ ! -s "$STALL_LOG" ]
    [ ! -f "$TEST_TMP/sendkeys.log" ]
    [ ! -f "$TEST_TMP/ntfy.log" ]
}

# --- 3: 出力静止→nudge発火 ---

@test "(3) output static for stall_threshold_min fires exactly one nudge_sent" {
    write_settings true 10 10 10 3 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_3" "ashigaru1" "cmd_3"
    write_task_yaml "ashigaru1" "task_3" "cmd_3"
    write_inbox ashigaru1 0
    write_capture "$(pane_for ashigaru1)" "steady output"

    run_stall '
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 600))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    run grep -c '"event": "nudge_sent"' "$STALL_LOG"
    [ "$output" -eq 1 ]
    [ -s "$TEST_TMP/sendkeys.log" ]
    run grep -c "multiagent:agents.1" "$TEST_TMP/sendkeys.log"
    [ "$output" -ge 1 ]
}

# --- 4: 出力変化での復旧 ---

@test "(4) output change after a nudge resets the baseline instead of firing again" {
    write_settings true 10 10 10 3 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_4" "ashigaru1" "cmd_4"
    write_task_yaml "ashigaru1" "task_4" "cmd_4"
    write_inbox ashigaru1 0
    # 末尾行除外ロジック(get_pane_output_hash)は最後の非空行を1行削るため、
    # 実際のpane出力同様に本文行+状態バー行相当の2行以上を用意する。
    write_capture "$(pane_for ashigaru1)" "$(printf 'steady output\n(status)')"

    run_stall '
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 600))
        check_stall_tick
        printf "%s" "$(printf "changed output\n(status)")" > "'"$TEST_TMP"'/capture_multiagent_agents_1.txt"
        STALL_TEST_NOW=$((NOW_EPOCH + 660))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    run grep -c '"event": "nudge_sent"' "$STALL_LOG"
    [ "$output" -eq 1 ]
    run grep -c '"event": "output_changed"' "$STALL_LOG"
    [ "$output" -eq 1 ]
}

# --- 5: unreadがある場合はスキップ ---

@test "(5) agents with unread messages are skipped entirely, even when output is static" {
    write_settings true 10 10 10 3 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_5" "ashigaru1" "cmd_5"
    write_inbox ashigaru1 1
    write_capture "$(pane_for ashigaru1)" "steady output"

    run_stall '
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 700))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    [ ! -s "$STALL_LOG" ]
    [ ! -f "$TEST_TMP/sendkeys.log" ]
    [ ! -f "$TEST_TMP/ntfy.log" ]
    [ ! -f "$TEST_TMP/inbox_write.log" ]
}

# --- 6: nudgeカウンタのtask_id境界(上限到達→直接ntfy) ---

@test "(6) once nudge_limit_per_task is reached, new stall episodes skip karo and escalate straight to ntfy" {
    write_settings true 10 10 10 1 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_6" "ashigaru1" "cmd_6"
    write_task_yaml "ashigaru1" "task_6" "cmd_6"
    write_inbox ashigaru1 0
    write_capture "$(pane_for ashigaru1)" "steady output"
    seed_stall_event "2026-06-01T00:00:00+09:00" "nudge_sent" "ashigaru1" "task_6"

    run_stall '
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 600))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    run grep -c '"event": "nudge_sent"' "$STALL_LOG"
    [ "$output" -eq 1 ]
    run grep -c '"event": "escalated_to_karo"' "$STALL_LOG"
    [ "$output" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write.log" ]
    run grep -c '"event": "escalated_to_ntfy"' "$STALL_LOG"
    [ "$output" -eq 1 ]
    run cat "$TEST_TMP/ntfy.log"
    [[ "$output" == *"budget_exhausted"* ]]
}

# --- 7: task_id変更でのカウンタリセット ---

@test "(7) a new task_id for the same agent recounts nudges from zero" {
    write_settings true 10 10 10 3 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_7_new" "ashigaru1" "cmd_7"
    write_task_yaml "ashigaru1" "task_7_new" "cmd_7"
    write_inbox ashigaru1 0
    write_capture "$(pane_for ashigaru1)" "steady output"
    seed_stall_event "2026-06-01T00:00:00+09:00" "nudge_sent" "ashigaru1" "task_7_old"

    run_stall '
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 600))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    run grep -c '"task_id": "task_7_new".*"event": "nudge_sent"\|"event": "nudge_sent".*"task_id": "task_7_new"' "$STALL_LOG"
    [ "$output" -ge 1 ]
    run grep -c '"event": "nudge_sent"' "$STALL_LOG"
    [ "$output" -eq 2 ]
}

# --- 8: karo構造的除外(cmd_194工程2是正) ---
# cmd_194 Q52(c)裁定によりin-flight判定が一次資料(queue/tasks/{agent}.yaml)
# 中心へ転換された結果、karoはtask YAMLを持たない(queue/tasks/karo.yamlが
# 構造的に存在しない)ためget_in_flight_tasks_with_agent()の出力に一切
# 現れなくなり、check_stall_tickのループ自体に入らなくなった。これに伴い
# 旧来の「karo自身のstallはinbox_write_karoを経由せず直接ntfyへ短絡する」
# という経路(かつてのkaro_self_stall分岐)は構造的に到達不能になった。
# 実測(logs/timing_events.jsonl)では agent="karo" かつ event="assigned" の
# 実例が歴史上ほぼ皆無(e2e_test由来1件・task_id:null2件のみ)であり、
# 旧設計下でもkaro自身がin-flight化する経路は実質的にほとんど機能して
# いなかった(構造的除外は仕様どおりであり、regressionではない)。
@test "(8) karo never appears in the in-flight list — its self-stall escalation branch is now structurally unreachable" {
    write_settings true 10 10 10 3 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_8" "karo" "cmd_8"
    write_inbox karo 0
    write_capture "$(pane_for karo)" "steady output"
    # queue/tasks/karo.yaml は意図的に作らない(karoはtask YAMLを持たない)

    run_stall '
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 600))
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 1200))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write.log" ]
    [ ! -f "$TEST_TMP/ntfy.log" ]
    [ ! -s "$STALL_LOG" ]
}

# --- 9: shogun除外 ---

@test "(9) shogun is always skipped even when present in the in-flight task list" {
    write_settings true 10 10 10 3 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_9" "shogun" "cmd_9"

    run_stall '
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 700))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    [ ! -s "$STALL_LOG" ]
    [ ! -f "$TEST_TMP/sendkeys.log" ]
    [ ! -f "$TEST_TMP/ntfy.log" ]
    [ ! -f "$TEST_TMP/inbox_write.log" ]
}

# --- 10: 状態バー行除外によるfalse negative防止 ---

@test "(10) hash excludes the trailing status-bar line so elapsed-seconds churn does not mask a real stall" {
    write_settings true 10 10 10 3 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_10" "ashigaru1" "cmd_10"
    write_task_yaml "ashigaru1" "task_10" "cmd_10"
    write_inbox ashigaru1 0
    write_capture "$(pane_for ashigaru1)" "$(printf 'real unchanged content\nWorking on task (5s * esc to interrupt)')"

    run_stall '
        check_stall_tick
        printf "%s" "$(printf "real unchanged content\nWorking on task (65s * esc to interrupt)")" > "'"$TEST_TMP"'/capture_multiagent_agents_1.txt"
        STALL_TEST_NOW=$((NOW_EPOCH + 600))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    run grep -c '"event": "nudge_sent"' "$STALL_LOG"
    [ "$output" -eq 1 ]
    run grep -c '"event": "output_changed"' "$STALL_LOG"
    [ "$output" -eq 0 ]
}

# --- 11: プロセス再起動を模したLAST_HASH/LAST_CHANGE_TSの喪失 ---

@test "(11) losing LAST_HASH/LAST_CHANGE_TS (simulated process restart) re-collects a baseline instead of misfiring" {
    write_settings true 10 10 10 3 60
    write_assigned "2026-07-01T00:00:00+09:00" "task_11" "ashigaru1" "cmd_11"
    write_task_yaml "ashigaru1" "task_11" "cmd_11"
    write_inbox ashigaru1 0
    write_capture "$(pane_for ashigaru1)" "steady output"

    run_stall '
        check_stall_tick
        STALL_TEST_NOW=$((NOW_EPOCH + 600))
        check_stall_tick
        unset LAST_HASH LAST_CHANGE_TS
        declare -A LAST_HASH
        declare -A LAST_CHANGE_TS
        STALL_TEST_NOW=$((NOW_EPOCH + 1200))
        check_stall_tick
    '
    [ "$status" -eq 0 ]
    run grep -c '"event": "nudge_sent"' "$STALL_LOG"
    [ "$output" -eq 1 ]
    run grep -c '"event": "escalated_to_karo"' "$STALL_LOG"
    [ "$output" -eq 0 ]
    run grep -c '"event": "escalated_to_ntfy"' "$STALL_LOG"
    [ "$output" -eq 0 ]
}
