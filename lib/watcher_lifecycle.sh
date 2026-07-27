#!/usr/bin/env bash
# cmd_113 Part1-B: shutsujin_departure.sh起動時にwatcher_supervisor.shを冪等に起動する。
#
# 背景: watcher_supervisor.sh/deadman_watcher.shはshutsujin_departure.shに一切
# 組み込まれておらず(cmd_092/093導入時に手動nohup起動されたのみ)、システム
# 全体が9日間非稼働だった間(2026-07-17〜2026-07-26)、次回起動時に誰も
# 起こさなかったライフサイクルの穴があった(cmd_113 Part1-A死因特定)。
#
# watcher_supervisor.sh自体が内部でstart_deadman_watcher_if_missing()を呼ぶため、
# ここではwatcher_supervisor.shの起動のみを冪等に扱えばdeadman_watcher.shも連動して
# 起動する。
#
# テスト容易性: 関数定義のみのファイルであり、source時に副作用はない
# (scripts/watcher_supervisor.shのBASH_SOURCEガードと同じ設計思想)。

start_watcher_supervisor_if_missing() {
    local script_dir="$1"
    local log_file="${2:-$script_dir/logs/watcher_supervisor.log}"

    if pgrep -f "scripts/watcher_supervisor.sh" >/dev/null 2>&1; then
        local existing_pid
        existing_pid="$(pgrep -f "scripts/watcher_supervisor.sh" | head -1)"
        echo "[$(date)] [OK] watcher_supervisor.sh は稼働中(PID=${existing_pid})。二重起動せず。"
        return 0
    fi

    nohup bash "$script_dir/scripts/watcher_supervisor.sh" >> "$log_file" 2>&1 &
    local new_pid=$!
    disown
    echo "[$(date)] [START] watcher_supervisor.sh を起動した(PID=${new_pid})。deadman_watcher.shも連動して起動する。"
}

# cmd_113 Part1-B可視化バグ修正: watcher_supervisor.shはpreflight_check.sh実行と
# 全エージェント分のwatcher起動ループを経てからstart_deadman_watcher_if_missing()に
# 到達するため、起動直後の単発pgrepではdeadman_watcher.shのPIDをまだ検出できず
# dashboard.mdに「未起動」と誤表示される競合状態があった。ポーリングで待つ。
wait_for_process_pid() {
    local pattern="$1"
    local timeout_sec="${2:-10}"
    local waited=0
    local pid=""

    while [ "$waited" -lt "$timeout_sec" ]; do
        pid="$(pgrep -f "$pattern" | head -1)"
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}
