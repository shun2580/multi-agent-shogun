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

# cmd_116 S-2: WATCHER_STATUS虚偽表示の根本原因は、wait_for_process_pid()の
# タイムアウトを呼び出し側が無条件で「未起動」という確定断定にフォールバック
# させていたこと(pgrep -f のパターン照合不一致は「見つからない」≠「本当に停止」)。
# watcher_status_display()は稼働中/停止中/unknown(判定不能)の三値を返す。
# 受け入れ条件: 「稼働中」ケースはモックではなく実プロセスに対する実pgrepで検証する
# (表示ロジック単体テストでは不可、という指示書要件に対応)。

@test "watcher_status_display 実機: 実際に起動中のダミープロセスに対して稼働中(PID=...)を返す" {
    local marker="test_dummy_watcher_process_cmd116_$$"
    ( exec -a "$marker" sleep 20 ) &
    local dummy_pid=$!
    # execで名前が付け替わるまでの猶予
    for _ in 1 2 3 4 5; do
        pgrep -f "$marker" >/dev/null 2>&1 && break
        sleep 0.2
    done

    # marker文字列をbash -cのスクリプト本文へ直接埋め込むと、その呼び出し自身の
    # argv(/proc/PID/cmdline)にmarkerが含まれてしまいpgrep -fが自己一致して
    # しまう(ダミープロセスを検出しなくても常に「稼働中」になる誤検証)。
    # `env VAR=value cmd`もVAR=valueがそのenvプロセス自身のargvに現れるため
    # 同じ穴に落ちる(実際に踏んで発見・修正した)。exportしたシェル変数は
    # execve()時にenvp経由で継承されargvには現れないため、これを使う。
    export MARKER="$marker"
    run timeout 5 bash -c '
        source "'"$LIFECYCLE_SCRIPT"'" >/dev/null 2>&1
        watcher_status_display "$MARKER" 3
    '
    unset MARKER

    kill "$dummy_pid" 2>/dev/null || true
    wait "$dummy_pid" 2>/dev/null || true

    [ "$status" -eq 0 ]
    [[ "$output" == "稼働中(PID="* ]]
}

@test "watcher_status_display 実機: 存在しないプロセス名では停止中を返す(実pgrep・モックなし)" {
    local marker="test_dummy_watcher_process_never_exists_cmd116_$$"

    # 上記と同じ自己一致回避のためexportしたシェル変数(argvに現れない)経由で渡す。
    export MARKER="$marker"
    run timeout 5 bash -c '
        source "'"$LIFECYCLE_SCRIPT"'" >/dev/null 2>&1
        watcher_status_display "$MARKER" 1
    '
    unset MARKER

    [ "$status" -eq 1 ]
    [ "$output" = "停止中" ]
}

@test "watcher_status_display: pgrep自体が異常終了(rc>=2)した場合はunknownを返し停止中と断定しない" {
    run timeout 5 bash -c '
        source "'"$LIFECYCLE_SCRIPT"'" >/dev/null 2>&1
        pgrep() { return 2; }
        watcher_status_display "scripts/deadman_watcher.sh" 2
    '
    [ "$status" -eq 2 ]
    [ "$output" = "unknown" ]
}
