#!/usr/bin/env bash
# PreToolUse hook: ツール呼び出し直前にidleフラグを削除する。
# agent_is_busy()のclaude分岐はフラグの存在有無のみで判定するため、
# 作業再開時に削除しない限りフラグは永久に残り「非busy」誤判定を招く
# (cmd_066根因)。本フックがその唯一の削除箇所となる。
set -euo pipefail
AGENT_ID=$(tmux display-message -t "${TMUX_PANE:-}" -p '#{@agent_id}' 2>/dev/null || true)
if [ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "shogun" ]; then
    rm -f "${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}" 2>/dev/null || true
fi
exit 0
