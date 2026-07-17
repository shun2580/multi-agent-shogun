#!/usr/bin/env bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

source "$SCRIPT_DIR/lib/agent_registry.sh"

mkdir -p logs queue/inbox

get_multiagent_pane_base() {
    if [ -n "${SHOGUN_PANE_BASE:-}" ]; then
        echo "$SHOGUN_PANE_BASE"
        return 0
    fi
    tmux show-options -gv pane-base-index 2>/dev/null || echo 0
}

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli
    # cmd_093発見: shogun等、末尾のペインインデックス(.0等)無しで実際には
    # 起動している既存watcherも重複と正しく判定できるよう、インデックス
    # 除去形(pane_bare)でも一致を確認する。完全一致のみだと本日の
    # インシデントで観測されたshogun重複watcherを検知できない。
    local pane_bare="${pane%.*}"

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    if pgrep -f "scripts/inbox_watcher.sh ${agent} (${pane}|${pane_bare})( |$)" >/dev/null 2>&1; then
        return 0
    fi

    if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
        echo "[$(date)] [WARN] stale watcher detected for ${agent}; starting watcher for expected pane ${pane}" >&2
    fi

    cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
}

watcher_specs() {
    local pane_base
    local agent
    pane_base=$(get_multiagent_pane_base)

    while IFS= read -r agent; do
        [ -z "$agent" ] && continue
        local pane
        if ! pane=$(agent_registry_pane_for_agent "$agent" "$pane_base"); then
            continue
        fi
        printf '%s\t%s\tlogs/inbox_watcher_%s.log\n' "$agent" "$pane" "$agent"
    done < <(agent_registry_agents)
}

start_all_watchers() {
    local agent pane log_file
    while IFS=$'\t' read -r agent pane log_file; do
        start_watcher_if_missing "$agent" "$pane" "$log_file"
    done < <(watcher_specs)

    start_deadman_watcher_if_missing
}

# cmd_092: 停滞警報(デッドマンスイッチ)v1。エージェントではないため上の
# 9エージェント分ループ(watcher_specs/agent_registry.sh)には混ぜず、
# 専用の1行分岐として追加する。
start_deadman_watcher_if_missing() {
    if pgrep -f "scripts/deadman_watcher.sh" >/dev/null 2>&1; then
        return 0
    fi
    nohup bash scripts/deadman_watcher.sh >> logs/deadman_watcher.log 2>&1 &
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "${1:-}" = "--print-watchers" ]; then
        watcher_specs
        exit 0
    fi

    # Preflight check (致命依存欠落なら中止)
    if ! bash "$SCRIPT_DIR/scripts/preflight_check.sh"; then
        echo "[$(date)] [FATAL] 必須依存が欠落。起動を中止します。" >&2
        exit 1
    fi

    # tmux bell抑制: multiagent:agents window (ashigaru/gunshi常駐) の bell 中継を止める。
    # 殿が手動操作する shogun/karo pane (multiagent:0 等) は対象外。
    # 冪等: monitor-bell off は状態設定のため何度実行しても副作用なし。
    tmux set-option -w -t multiagent:agents monitor-bell off 2>/dev/null || true

    while true; do
        start_all_watchers
        sleep 5
    done
fi
