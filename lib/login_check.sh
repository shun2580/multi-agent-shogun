#!/usr/bin/env bash
# login_check.sh — 出陣後ログイン状態判定ライブラリ (cmd_176 / cmd_235)
#
# shutsujin_departure.sh STEP 6.55 から切り出した判定関数。切り出しの目的は、
# tmux を別ソケットへ差し替えた試験(関数 tmux() で上書き)を可能にすること。
#
# 提供関数:
#   check_pane_login_status <tmux target>
#       標準出力: authenticated / unauthenticated / unknown のいずれか
#       判定順: 「Not logged in」→ unauthenticated を優先、
#               次に "bypass permissions" → authenticated、
#               どちらも出なければ retry、使い切れば unknown
#               (観測失敗を unauthenticated 側へ断定しない)
#       判定できた回で即 break し、sleep を踏まない。
#
# 環境変数 (試験で待ち時間を短縮するための上書き用):
#   LOGIN_CHECK_MAX_RETRIES    試行回数 (既定 5)
#   LOGIN_CHECK_RETRY_INTERVAL 試行間の待ち秒 (既定 2)
#
# 注意: tmux は素の `tmux` コマンドで呼ぶ (試験が関数 tmux() で差し替える)。
#       破壊的動作は一切行わない (D006): capture-pane の読み取りのみ。

check_pane_login_status() {
    # 引数: $1=tmux target（例: shogun:main / multiagent:agents.0）
    local target="$1"
    local max_retries="${LOGIN_CHECK_MAX_RETRIES:-5}"
    local retry_interval="${LOGIN_CHECK_RETRY_INTERVAL:-2}"
    local status="unknown"
    local pane_output
    local _try

    for ((_try=1; _try<=max_retries; _try++)); do
        pane_output=$(tmux capture-pane -t "$target" -p 2>/dev/null || echo "")
        if echo "$pane_output" | grep -q "Not logged in"; then
            status="unauthenticated"
            break
        elif echo "$pane_output" | grep -q "bypass permissions"; then
            status="authenticated"
            break
        fi
        sleep "$retry_interval"
    done
    echo "$status"
}
