#!/usr/bin/env bats
# subtask_113_part1: lib/watcher_lifecycle.sh (shutsujin_departure.sh STEP 6.6.5 が
# source する watcher_supervisor.sh 冪等起動ロジック) の隔離テスト。
# 実プロセス(watcher_supervisor.sh/deadman_watcher.sh)は一切起動しない。
# nohup/pgrep をスタブして「未起動→起動する」「起動済み→重複しない」の両ケースを検証する。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIFECYCLE_SCRIPT="$PROJECT_ROOT/lib/watcher_lifecycle.sh"
    TEST_TMP="$(mktemp -d)"
    SPAWN_LOG="$TEST_TMP/spawn.log"
    LOG_FILE="$TEST_TMP/dummy.log"
    : > "$SPAWN_LOG"
    BASELINE_SUPERVISOR_PIDS="$(pgrep -f 'scripts/watcher_supervisor.sh' | sort -n | tr '\n' ' ')"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# 実プロセス(watcher_supervisor.sh)のPID集合がテスト前後で変化していないことを確認する。
# test_watcher_supervisor_dedup.bats と同じ設計思想(本番稼働中watcherとの区別)。
assert_no_supervisor_process_leak() {
    local after
    after="$(pgrep -f 'scripts/watcher_supervisor.sh' | sort -n | tr '\n' ' ')"
    [ "$after" = "$BASELINE_SUPERVISOR_PIDS" ]
}

run_start_supervisor_case() {
    local fake_proclist="$1"

    run timeout 5 env \
        SPAWN_LOG="$SPAWN_LOG" \
        FAKE_PROCLIST="$fake_proclist" \
        bash -c '
            source "'"$LIFECYCLE_SCRIPT"'" >/dev/null 2>&1

            nohup() { echo "SPAWNED $*" >> "$SPAWN_LOG"; }
            disown() { :; }
            pgrep() {
                local pattern="${!#}"
                printf "%s\n" "$FAKE_PROCLIST" | grep -Eq -- "$pattern"
            }

            start_watcher_supervisor_if_missing "'"$PROJECT_ROOT"'" "'"$LOG_FILE"'"
        '
}

@test "source lib/watcher_lifecycle.sh は副作用なく関数定義のみ読み込む" {
    run timeout 3 bash -c 'source "'"$LIFECYCLE_SCRIPT"'" >/dev/null 2>&1; echo SOURCED_OK'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SOURCED_OK"* ]]
    assert_no_supervisor_process_leak
}

@test "未起動時: watcher_supervisor.sh が存在しなければ nohup 経由で起動される" {
    run_start_supervisor_case ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"[START]"* ]]
    run timeout 5 cat "$SPAWN_LOG"
    [[ "$output" == *"SPAWNED bash $PROJECT_ROOT/scripts/watcher_supervisor.sh"* ]]
    assert_no_supervisor_process_leak
}

@test "起動済み時: watcher_supervisor.sh が既存なら二重起動しない" {
    run_start_supervisor_case "scripts/watcher_supervisor.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"* ]]
    [[ "$output" == *"二重起動せず"* ]]
    [ ! -s "$SPAWN_LOG" ]
    assert_no_supervisor_process_leak
}

@test "wait_for_process_pid: 対象プロセスが即座に存在すればPIDを返す" {
    run timeout 5 env FAKE_PROCLIST="scripts/deadman_watcher.sh" bash -c '
        source "'"$LIFECYCLE_SCRIPT"'" >/dev/null 2>&1
        pgrep() {
            local pattern="${!#}"
            if printf "%s\n" "$FAKE_PROCLIST" | grep -Eq -- "$pattern"; then
                echo 12345
            fi
        }
        wait_for_process_pid "scripts/deadman_watcher.sh" 3
    '
    [ "$status" -eq 0 ]
    [ "$output" = "12345" ]
}

@test "wait_for_process_pid: 対象プロセスが最終的に見つからなければタイムアウトしexit 1を返す" {
    run timeout 5 env FAKE_PROCLIST="" bash -c '
        source "'"$LIFECYCLE_SCRIPT"'" >/dev/null 2>&1
        pgrep() { return 1; }
        wait_for_process_pid "scripts/deadman_watcher.sh" 2
    '
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
