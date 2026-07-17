#!/usr/bin/env bats
# subtask_086_partB: watcher_supervisor.sh のペイン文字列不一致バグ修正(軍師design方針B)の隔離テスト
# 実tmux・実プロセス(inbox_watcher.sh)は一切起動しない。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SUPERVISOR_SCRIPT="$PROJECT_ROOT/scripts/watcher_supervisor.sh"
    TEST_TMP="$(mktemp -d)"
    SPAWN_LOG="$TEST_TMP/spawn.log"
    LOG_FILE="$TEST_TMP/dummy.log"
    : > "$SPAWN_LOG"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# start_watcher_if_missing を呼び、spawn_watcher が呼ばれたかどうかを SPAWN_LOG で判定するヘルパー。
# 疑似 pgrep で実プロセス一覧を差し替え、pane_exists/spawn_watcher をスタブ化した上で
# 別プロセス(bash -c)内で source して検証する。実tmux依存・実プロセス生成は一切なし。
run_start_watcher_case() {
    local agent="$1" pane="$2" fake_proclist="$3"

    run env \
        SPAWN_LOG="$SPAWN_LOG" \
        FAKE_PROCLIST="$fake_proclist" \
        bash -c '
            source "'"$SUPERVISOR_SCRIPT"'" >/dev/null 2>&1

            pane_exists() { return 0; }
            spawn_watcher() { echo "SPAWNED $1 $2" >> "$SPAWN_LOG"; }
            pgrep() {
                local pattern="${!#}"
                printf "%s\n" "$FAKE_PROCLIST" | grep -Eq -- "$pattern"
            }

            start_watcher_if_missing "'"$agent"'" "'"$pane"'" "'"$LOG_FILE"'"
        '
}

@test "source scripts/watcher_supervisor.sh returns immediately without entering the supervisor loop" {
    run timeout 3 bash -c 'source "'"$SUPERVISOR_SCRIPT"'" >/dev/null 2>&1; echo SOURCED_OK'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SOURCED_OK"* ]]
}

@test "case A: shogun の重複watcherは pane_bare 一致で正しく抑止される(修正の核心)" {
    run_start_watcher_case shogun "shogun:main.0" "scripts/inbox_watcher.sh shogun shogun:main claude"
    [ "$status" -eq 0 ]
    [ ! -s "$SPAWN_LOG" ]
}

@test "case B: 実プロセスなしなら spawn_watcher が呼ばれる(過抑制の回帰防止)" {
    run_start_watcher_case shogun "shogun:main.0" ""
    [ "$status" -eq 0 ]
    run cat "$SPAWN_LOG"
    [[ "$output" == *"SPAWNED shogun shogun:main.0"* ]]
}

@test "case C: 非shogunエージェント(末尾.0なし)は既存動作が変わらない" {
    run_start_watcher_case ashigaru3 "multiagent:agents.3" "scripts/inbox_watcher.sh ashigaru3 multiagent:agents.3 claude"
    [ "$status" -eq 0 ]
    [ ! -s "$SPAWN_LOG" ]
}
