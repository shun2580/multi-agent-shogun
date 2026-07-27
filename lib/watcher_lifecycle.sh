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

# cmd_116 S-2: WATCHER_STATUS虚偽表示の恒久修正。
#
# 根本原因: wait_for_process_pid()のタイムアウト(=pgrepで見つからない)を
# 呼び出し側(shutsujin_departure.sh)が無条件で「未起動」という確定断定文字列に
# フォールバックしていた(`${_pid:-未起動}`)。pgrep -f はパターン照合方式のため
# cmd_086/093で二度実例のあるペイン文字列照合不一致等により「見つからない」が
# 「実際に停止している」を意味するとは限らない。にもかかわらず確定値「未起動」を
# 表示すると、本当のサイレント死が起きた際に「またいつもの誤検知か」と無視される
# 狼少年化を招く(Part1本来の目的を損なう)。
#
# 対策: pgrep自体が異常終了(no such option/regex構文エラー等、rc>=2)した場合は
# 「判定不能」として`unknown`を返す。pgrepが正常動作(rc 0/1)した上でタイムアウト
# まで一度も見つからなければ、そのときに限り「停止中」と断定する。
watcher_status_display() {
    local pattern="$1"
    local timeout_sec="${2:-10}"
    local waited=0
    local pid=""
    local pgrep_out=""
    local pgrep_rc=0

    while [ "$waited" -lt "$timeout_sec" ]; do
        pgrep_out="$(pgrep -f "$pattern" 2>/dev/null)"
        pgrep_rc=$?
        pid="$(printf '%s\n' "$pgrep_out" | head -1)"
        if [ -n "$pid" ]; then
            echo "稼働中(PID=${pid})"
            return 0
        fi
        if [ "$pgrep_rc" -ge 2 ]; then
            echo "unknown"
            return 2
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "停止中"
    return 1
}
