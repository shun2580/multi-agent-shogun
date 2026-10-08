#!/usr/bin/env bats
# subtask_086_partB: watcher_supervisor.sh のペイン文字列不一致バグ修正(軍師design方針B)の隔離テスト
# subtask_093_partAB: 実装に存在しない関数名へのスタブを廃止し、実際にプロセスを起動する
# nohup呼び出しそのものをスタブする方式に是正。加えてPID集合比較による実プロセス
# 非生成の明示検証と、全run呼び出しへのtimeoutガードを追加。
# 実tmux・実プロセス(inbox_watcher.sh)は一切起動しない。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SUPERVISOR_SCRIPT="$PROJECT_ROOT/scripts/watcher_supervisor.sh"
    TEST_TMP="$(mktemp -d)"
    SPAWN_LOG="$TEST_TMP/spawn.log"
    LOG_FILE="$TEST_TMP/dummy.log"
    : > "$SPAWN_LOG"
    BASELINE_INBOX_PIDS="$(pgrep -f 'scripts/inbox_watcher.sh' | sort -n | tr '\n' ' ')"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# 実プロセス(inbox_watcher.sh)がテストによって新規に生成(漏出)されていないことを確認する。
# 単純な有無チェックだと本番稼働中の正規watcher群と区別できないため、
# setupで取得したベースラインPID集合に無い「新規PID」のみを漏出候補とする。
# 稼働中の本物のwatcherは$(...)等で短命なサブシェルをforkし、fork直後はexecを
# 経ていないためargvが親と同一のまま一瞬だけpgrep -fにマッチする(偽陽性。
# cmd_212実測: 30回中7回の間欠失敗の原因)。これは時間待ちではなく親子関係で除外する:
#   - 候補PIDが既に消えている → 短命サブシェル。漏出ではない(漏出は持続する)。
#   - 候補PIDの親が inbox_watcher.sh のargvを持つ → 稼働中watcherのサブシェル。除外。
#   - 親が読めない(消滅済み) → 短命サブシェルの連鎖。除外(テスト中のbashは生存している)。
# テストが本当に起動した watcher の親は bats/bash/init 等であり、除外されない。
assert_no_inbox_watcher_process_leak() {
    local pid ppid pcmd
    for pid in $(pgrep -f 'scripts/inbox_watcher.sh'); do
        case " $BASELINE_INBOX_PIDS " in *" $pid "*) continue ;; esac
        ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)" || continue
        [ -n "$ppid" ] || continue
        pcmd="$(tr '\0' ' ' < "/proc/$ppid/cmdline" 2>/dev/null)" || continue
        [ -n "$pcmd" ] || continue
        case "$pcmd" in *scripts/inbox_watcher.sh*) continue ;; esac
        echo "leaked inbox_watcher process: pid=$pid ppid=$ppid parent=[$pcmd]" >&2
        return 1
    done
    return 0
}

# start_watcher_if_missing を呼び、実装内の nohup 呼び出しが行われたかどうかを SPAWN_LOG で判定するヘルパー。
# 疑似 pgrep で実プロセス一覧を差し替え、pane_exists/nohup をスタブ化した上で
# 別プロセス(bash -c)内で source して検証する。nohup は
# start_watcher_if_missing 最終行に実在する呼び出しを直接インターセプトするスタブであり、
# 実装に存在しない関数名(旧spawn_watcher)へのスタブは使わない。
run_start_watcher_case() {
    local agent="$1" pane="$2" fake_proclist="$3"

    run timeout 5 env \
        SPAWN_LOG="$SPAWN_LOG" \
        FAKE_PROCLIST="$fake_proclist" \
        bash -c '
            source "'"$SUPERVISOR_SCRIPT"'" >/dev/null 2>&1

            pane_exists() { return 0; }
            nohup() { echo "SPAWNED $*" >> "$SPAWN_LOG"; }
            pgrep() {
                local pattern="${!#}"
                printf "%s\n" "$FAKE_PROCLIST" | grep -Eq -- "$pattern"
            }

            start_watcher_if_missing "'"$agent"'" "'"$pane"'" "'"$LOG_FILE"'"
            wait
        '
}

@test "source scripts/watcher_supervisor.sh returns immediately without entering the supervisor loop" {
    run timeout 3 bash -c 'source "'"$SUPERVISOR_SCRIPT"'" >/dev/null 2>&1; echo SOURCED_OK'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SOURCED_OK"* ]]
    assert_no_inbox_watcher_process_leak
}

@test "case A: shogun の重複watcherは pane_bare 一致で正しく抑止される(修正の核心)" {
    run_start_watcher_case shogun "shogun:main.0" "scripts/inbox_watcher.sh shogun shogun:main claude"
    [ "$status" -eq 0 ]
    [ ! -s "$SPAWN_LOG" ]
    assert_no_inbox_watcher_process_leak
}

@test "case B: 実プロセスなしなら nohup 経由の起動が試みられる(過抑制の回帰防止)" {
    run_start_watcher_case shogun "shogun:main.0" ""
    [ "$status" -eq 0 ]
    run timeout 5 cat "$SPAWN_LOG"
    [[ "$output" == *"SPAWNED bash scripts/inbox_watcher.sh shogun shogun:main.0"* ]]
    assert_no_inbox_watcher_process_leak
}

@test "case C: 非shogunエージェント(末尾.0なし)は既存動作が変わらない" {
    run_start_watcher_case ashigaru3 "multiagent:agents.3" "scripts/inbox_watcher.sh ashigaru3 multiagent:agents.3 claude"
    [ "$status" -eq 0 ]
    [ ! -s "$SPAWN_LOG" ]
    assert_no_inbox_watcher_process_leak
}
