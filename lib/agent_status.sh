#!/usr/bin/env bash
# lib/agent_status.sh — エージェント稼働状態検出の共有ライブラリ
#
# 提供関数:
#   agent_is_busy_check <pane_target>   → 0=busy, 1=idle, 2=観測失敗(unknown)
#   get_pane_state_label <pane_target>  → "稼働中" / "待機中" / "不明"
#
# 使用例:
#   source lib/agent_status.sh
#   agent_is_busy_check "multiagent:agents.0"
#   state=$(get_pane_state_label "multiagent:agents.3")
#
# rc=2 (unknown) の意味論（cmd_123 Part A / Fable裁定20260728 Q8）:
#   busy=観測に成功しbusyだった／idle=観測に成功しidleだった／
#   unknown=観測自体に失敗した（pane不在・capture-pane失敗等）。
#   「観測できなかった」ことと「観測してidleだった」ことを同一視しない
#   （族「観測失敗と否定的観測の同一視」を作らない）。
#   rc=2時、原因種別を AGENT_STATUS_UNKNOWN_REASON に設定する。
AGENT_STATUS_UNKNOWN_REASON=""

# agent_is_busy_check <pane_target> [cli_type]
# tmux paneの末尾5行からCLI固有のidle/busyパターンを検出する。
# Returns: 0=busy, 1=idle, 2=pane不在
#
# Detection strategy:
#   1. OpenCode special-case: animated status row (`[■⬝]{8}`) = busy; if that
#      row is absent, fall back to the bottom status line's interrupt hint.
#   2. Status bar check (last non-empty line): 'esc to' only appears in
#      Claude Code's status bar during active processing. This is the most
#      reliable busy signal — immune to old spinner text in scroll-back.
#   3. Idle checks: CLI-specific idle prompts (❯, Codex ? prompt)
#   4. Text-based busy markers: spinner keywords in bottom 5 lines
#
# Why this order matters:
#   - Claude Code shows ❯ prompt even during thinking/working, so idle
#     checks alone cause false-idle (the bug that broke is_busy).
#   - Old spinner text (e.g. "Working on task • esc to interrupt") lingers
#     in scroll-back, so checking all 5 lines for 'esc to' causes false-busy
#     (the bug T-BUSY-008 fixed). Solution: check ONLY the last line for
#     'esc to' — the status bar is always at the bottom.
agent_is_busy_check() {
    local pane_target="$1"
    local cli_type="${2:-}"
    local pane_tail

    AGENT_STATUS_UNKNOWN_REASON=""

    # Pane existence check — independent of capture-pane result.
    # capture-pane on a TUI app (e.g. Claude Code) often returns only trailing
    # blank lines when pane height > visible content, making pane_tail empty
    # even when the pane exists and is healthy. Use display-message instead.
    if ! tmux display-message -t "$pane_target" -p '#{pane_id}' &>/dev/null; then
        AGENT_STATUS_UNKNOWN_REASON="pane_absent: tmux display-message failed for $pane_target"
        return 2  # 観測失敗(unknown) — pane truly absent / tmux query failed
    fi

    # capture-pane -p outputs the full pane height including trailing blank lines.
    # Piping directly to `tail -5` captures those blank lines → empty result.
    # Fix: store in a variable first so command-substitution strips trailing newlines,
    # then pipe to tail.
    if [[ -z "$cli_type" ]]; then
        cli_type=$(timeout 2 tmux show-options -v -p -t "$pane_target" @agent_cli 2>/dev/null || true)
    fi

    local full_capture capture_rc
    full_capture=$(timeout 2 tmux capture-pane -t "$pane_target" -p 2>/dev/null)
    capture_rc=$?
    # Only check the bottom 5 lines by default. Old busy markers linger in
    # scroll-back and cause false-busy if we scan too many lines.
    pane_tail=$(echo "$full_capture" | tail -5)

    # OpenCode uses a different layout from Codex/Claude. When the pane is
    # blank, treat it as idle so the watcher can recover instead of holding the
    # agent in permanent busy state after a crash or failed render. When the TUI
    # is visible, prefer the busy animation row and then the interrupt hint.
    if [[ "$cli_type" == "opencode" ]]; then
        local opencode_visible opencode_last_line
        opencode_visible=$(printf '%s\n' "$full_capture" | grep -v '^[[:space:]]*$' || true)
        if [[ -z "$opencode_visible" ]]; then
            return 1
        fi
        if opencode_has_busy_animation "$opencode_visible"; then
            return 0
        fi
        opencode_last_line=$(printf '%s\n' "$opencode_visible" | tail -1)
        if echo "$opencode_last_line" | grep -qiE '(^|[[:space:]])esc([[:space:]]+to)?[[:space:]]+interrupt([[:space:]]|$)'; then
            return 0
        fi
        return 1
    fi

    # capture-pane itself failed (non-zero exit — e.g. timeout killed it, tmux
    # transient error). This is an OBSERVATION FAILURE, not "pane is blank" —
    # do not collapse it into idle (that is exactly the 族「観測失敗と否定的
    # 観測の同一視」the cmd_123 Fable裁定 warns against). Report unknown so the
    # caller can apply the correct fail-safe direction for its own action.
    if [[ "$capture_rc" -ne 0 ]]; then
        AGENT_STATUS_UNKNOWN_REASON="capture_pane_failed: tmux capture-pane exited ${capture_rc} for $pane_target"
        return 2
    fi

    # capture-pane succeeded but returned nothing — pane exists and the query
    # itself worked, the content is genuinely blank. This is a real (negative)
    # observation, not a failure, so idle remains correct here.
    if [[ -z "$pane_tail" ]]; then
        return 1
    fi

    # ── Status bar check (last non-empty line = most reliable) ──
    # Claude Code status bar appends 'esc to interrupt' (or truncated 'esc to…')
    # ONLY during active processing. When idle, this suffix disappears.
    # Checking only the last line avoids false-busy from old spinner text
    # that might still be visible in the bottom 5 lines (T-BUSY-008 scenario).
    local last_line
    last_line=$(echo "$pane_tail" | grep -v '^[[:space:]]*$' | tail -1)
    if echo "$last_line" | grep -qiF 'esc to'; then
        return 0  # busy — status bar confirms active processing
    fi

    # ── Idle checks ──
    # Codex idle prompt
    if echo "$pane_tail" | grep -qE '(\? for shortcuts|context left)'; then
        return 1
    fi
    # Claude Code bare prompt
    if echo "$pane_tail" | grep -qE '^(❯|›)\s*$'; then
        return 1
    fi

    # ── Text-based busy markers (bottom 5 lines) ──
    # These catch non-Claude-Code CLIs and edge cases where status bar
    # isn't present but spinner text indicates active work.
    if echo "$pane_tail" | grep -qiF 'background terminal running'; then
        return 0
    fi
    if echo "$pane_tail" | grep -qiE '(Working|Thinking|Planning|Sending|task is in progress|Compacting conversation|thought for|思考中|考え中|計画中|送信中|処理中|実行中)'; then
        return 0
    fi

    return 1  # idle (default)
}

# opencode_has_busy_animation <capture_text>
# OpenCode paneの busy animation (`[■⬝]{8}`) を検出する。
opencode_has_busy_animation() {
    local capture_text="$1"

    if command -v python3 &>/dev/null; then
        OPENCODE_CAPTURE_TEXT="$capture_text" python3 - <<'PY'
import os
import sys

text = os.environ.get("OPENCODE_CAPTURE_TEXT", "")
for line in text.splitlines():
    glyphs = "".join(ch for ch in line if ch in "■⬝")
    if len(glyphs) >= 8:
        sys.exit(0)
sys.exit(1)
PY
        return $?
    fi

    local line
    while IFS= read -r line; do
        # Python is preferred for Unicode handling.  This shell fallback keeps
        # the same contract: any OpenCode spinner line with at least eight
        # busy-animation glyphs is busy, regardless of the current frame.
        if [[ "$line" =~ ([■⬝].*){8} ]]; then
            return 0
        fi
    done <<< "$capture_text"
    return 1
}

# get_pane_state_label <pane_target>
# 人間が読めるラベルを返す。
get_pane_state_label() {
    local pane_target="$1"
    agent_is_busy_check "$pane_target"
    local rc=$?
    case $rc in
        0) echo "稼働中" ;;
        1) echo "待機中" ;;
        2) echo "不在" ;;
    esac
}
