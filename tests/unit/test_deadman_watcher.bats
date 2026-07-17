#!/usr/bin/env bats
# cmd_092: 停滞警報(デッドマンスイッチ)v1 scripts/deadman_watcher.sh のテスト
# 正典(fable_directive_deadman.md)§1-11 (a)〜(e) 準拠。
# 実tmux・実ntfy送信・本番ログ(logs/timing_events.jsonl等)は一切使わない。
# capture_pane_snapshots/bash(ntfy呼び出し)はソース後にスタブへ差し替える。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    DEADMAN_SCRIPT="$PROJECT_ROOT/scripts/deadman_watcher.sh"
    TEST_TMP="$(mktemp -d)"
    TIMING_LOG="$TEST_TMP/timing_events.jsonl"
    ALERTS_LOG="$TEST_TMP/deadman_alerts.log"
    INCIDENTS_DIR="$TEST_TMP/incidents"
    SETTINGS="$TEST_TMP/settings.yaml"
    : > "$ALERTS_LOG"
    # 固定の"現在時刻"(DEADMAN_TEST_NOWオーバーライド)でelapsed計算を決定的にする。
    NOW_ISO="2026-07-17T12:00:00+09:00"
}

teardown() {
    rm -rf "$TEST_TMP"
}

write_settings() {
    local enabled="$1" threshold="$2"
    cat > "$SETTINGS" <<EOF
features:
  deadman_enabled: $enabled
deadman:
  stall_threshold_min: $threshold
EOF
}

# スタブ: capture_pane_snapshots(実tmux非依存)・bash(ntfy.sh実送信を防止)を
# source後に差し替えた上で、与えられたsnippetを実行する。
run_deadman() {
    local snippet="$1"
    run env \
        TIMING_EVENTS_JSONL="$TIMING_LOG" \
        DEADMAN_ALERTS_LOG="$ALERTS_LOG" \
        DEADMAN_INCIDENTS_DIR="$INCIDENTS_DIR" \
        DEADMAN_SETTINGS="$SETTINGS" \
        DEADMAN_TEST_NOW="$NOW_ISO" \
        TEST_TMP="$TEST_TMP" \
        bash -c '
            source "'"$DEADMAN_SCRIPT"'" >/dev/null 2>&1

            capture_pane_snapshots() {
                mkdir -p "$1"
                echo "CAPTURED $1" >> "$TEST_TMP/capture.log"
            }
            bash() {
                if [[ "$1" == *ntfy.sh ]]; then
                    echo "NOTIFIED $2" >> "$TEST_TMP/ntfy.log"
                else
                    command bash "$@"
                fi
            }

            '"$snippet"'
        '
}

# --- (a) stall_threshold_min超過のfixtureでfire_alertが呼ばれる(発火) ---

@test "(a) stall exceeding threshold min fires an alert" {
    cat > "$TIMING_LOG" <<'EOF'
{"ts": "2026-07-17T11:00:00+09:00", "event": "assigned", "cmd_id": "cmd_a", "task_id": "task_a", "agent": "ashigaru1", "redo_of": null, "qc_result": null, "source": "test", "extra": null}
EOF
    write_settings true 20

    run_deadman "check_stalls"
    [ "$status" -eq 0 ]

    run grep -c '"event": "deadman_fired"' "$ALERTS_LOG"
    [ "$output" -eq 1 ]

    run cat "$TEST_TMP/ntfy.log"
    [[ "$output" == *"NOTIFIED"* ]]
    [[ "$output" == *"task_a"* ]]
}

# --- (b) 閾値内の新しいactivityイベントを追加したfixtureで発火しない(誤警報ケース) ---

@test "(b) fresh activity event within threshold resets the timer, no false alarm" {
    cat > "$TIMING_LOG" <<'EOF'
{"ts": "2026-07-17T11:00:00+09:00", "event": "assigned", "cmd_id": "cmd_b", "task_id": "task_b", "agent": "ashigaru1", "redo_of": null, "qc_result": null, "source": "test", "extra": null}
{"ts": "2026-07-17T11:50:00+09:00", "event": "agent_started", "cmd_id": "cmd_b", "task_id": "task_b", "agent": "ashigaru1", "redo_of": null, "qc_result": null, "source": "test", "extra": null}
EOF
    write_settings true 20

    run_deadman "check_stalls"
    [ "$status" -eq 0 ]
    [ ! -s "$ALERTS_LOG" ]
    [ ! -f "$TEST_TMP/ntfy.log" ]
}

# --- (c) in-flightなtask_idが0件のfixtureで発火しない ---

@test "(c) no in-flight task_id (already completed) does not fire" {
    cat > "$TIMING_LOG" <<'EOF'
{"ts": "2026-07-17T09:00:00+09:00", "event": "assigned", "cmd_id": "cmd_c", "task_id": "task_c", "agent": "ashigaru1", "redo_of": null, "qc_result": null, "source": "test", "extra": null}
{"ts": "2026-07-17T09:05:00+09:00", "event": "report_submitted", "cmd_id": "cmd_c", "task_id": "task_c", "agent": "ashigaru1", "redo_of": null, "qc_result": null, "source": "test", "extra": null}
EOF
    write_settings true 20

    run_deadman "check_stalls"
    [ "$status" -eq 0 ]
    [ ! -s "$ALERTS_LOG" ]
    [ ! -f "$TEST_TMP/ntfy.log" ]
}

# --- (d) deadman_enabled:false時にcheck_stalls自体が呼ばれない ---

@test "(d) deadman_enabled=false disables check_stalls entirely" {
    cat > "$TIMING_LOG" <<'EOF'
{"ts": "2026-07-17T11:00:00+09:00", "event": "assigned", "cmd_id": "cmd_d", "task_id": "task_d", "agent": "ashigaru1", "redo_of": null, "qc_result": null, "source": "test", "extra": null}
EOF
    write_settings false 20

    run_deadman '
        check_stalls() { echo CALLED >> "$TEST_TMP/check_stalls.marker"; }
        run_deadman_tick
    '
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/check_stalls.marker" ]
}

# --- (e) 同一last_event_tsで2回check_stallsを呼んでも2回目はalready_alertedがtrueを返し発火しない(重複抑制) ---

@test "(e) duplicate suppression: same stall episode alerts only once across two check_stalls calls" {
    cat > "$TIMING_LOG" <<'EOF'
{"ts": "2026-07-17T11:00:00+09:00", "event": "assigned", "cmd_id": "cmd_e", "task_id": "task_e", "agent": "ashigaru1", "redo_of": null, "qc_result": null, "source": "test", "extra": null}
EOF
    write_settings true 20

    run_deadman "check_stalls; check_stalls"
    [ "$status" -eq 0 ]

    run grep -c '"event": "deadman_fired"' "$ALERTS_LOG"
    [ "$output" -eq 1 ]

    run wc -l < "$TEST_TMP/ntfy.log"
    [ "$output" -eq 1 ]
}

# --- 補足: 新活動シグナルで再アームされ、新エピソードとして再発火することの確認 ---

@test "(f) new activity after a prior alert re-arms and fires a fresh episode" {
    cat > "$TIMING_LOG" <<'EOF'
{"ts": "2026-07-17T11:00:00+09:00", "event": "assigned", "cmd_id": "cmd_f", "task_id": "task_f", "agent": "ashigaru1", "redo_of": null, "qc_result": null, "source": "test", "extra": null}
EOF
    write_settings true 20

    run_deadman '
        check_stalls
        printf "%s\n" "{\"ts\": \"2026-07-17T11:55:00+09:00\", \"event\": \"agent_started\", \"cmd_id\": \"cmd_f\", \"task_id\": \"task_f\", \"agent\": \"ashigaru1\", \"redo_of\": null, \"qc_result\": null, \"source\": \"test\", \"extra\": null}" >> "$TIMING_EVENTS_JSONL"
        DEADMAN_TEST_NOW="2026-07-17T12:20:00+09:00"
        check_stalls
    '
    [ "$status" -eq 0 ]

    run grep -c '"event": "deadman_fired"' "$ALERTS_LOG"
    [ "$output" -eq 2 ]
}
