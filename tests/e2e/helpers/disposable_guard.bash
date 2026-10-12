#!/usr/bin/env bash
# disposable_guard.bash — e2e が「使い捨ての tmux サーバ」でのみ走ることを証明する共通ガード (cmd_225)
#
# 背景: e2e は tmux へキーを送る。既定ソケットのまま走ると、使い捨てセッションは生きた陣
# (multiagent / shogun) と同じサーバに立ち、名前の完全修飾だけが守りだった。ここでは
# 「サーバ分離」を、実 tmux に問い合わせた事実で証明する。
#
# 方針 (fail-closed):
#   - 肯定の証明が無い限り「使い捨てでない」。環境変数だけの自己申告では通さない。
#   - 判定中に tmux が応答しない・パスが取れない・変数が欠ける等は「止まる」側。
#
# 使い捨てと認めるのは、次の全部が満たされたときのみ。
#   dir      E2E_DISPOSABLE_DIR が実在し、自分の所有・symlinkでない・他者書込不可
#   marker   その直下に runner が作った目印があり、nonce が環境変数と一致、dir が一致、
#            runner_pid が生きている(= 今回の実行のために作られたもの)
#   tmpdir   TMUX_TMPDIR がその専用ディレクトリ配下
#   tmuxenv  TMUX が未設定、または専用ディレクトリ配下のソケットを指す
#   pane     TMUX_PANE が未設定 (生きた陣のペインIDが隔離サーバのペインと偶然一致する事故を避ける)
#   query    実 tmux に `display-message -p '#{socket_path}'` を問い合わせて取得できる
#   sockdir  取得したソケットが専用ディレクトリ配下
#   notdef   取得したソケットが既定ソケット (/tmp/tmux-$UID/default) と異なる
#
# 使い方:
#   source tests/e2e/helpers/disposable_guard.bash
#   e2e_require_disposable || return 1      # setup_file / setup の最初に
#   e2e_disposable_check                    # 理由を stderr に出して 0=許可 / 1=拒否
#
# 各検査は独立した関数 (_e2e_chk_*)。変異試験 (tests/unit/test_e2e_disposable_guard.bats) が
# 1つずつ無効化して、対応する試験が落ちることを確かめる。

E2E_DISPOSABLE_MARKER_NAME=".e2e_disposable_marker"
E2E_TMUX_SHIM_TAG="E2E_TMUX_WRAPPER_SHIM"

# 最後に拒否した検査の理由 (ラッパのログ用)
E2E_GUARD_REASON=""

_e2e_deny() {
    E2E_GUARD_REASON="$1"
    echo "e2e disposable guard: DENY [$1]" >&2
    return 1
}

# e2e_find_real_tmux — PATH から「ラッパのshimでない」実 tmux を探す。
e2e_find_real_tmux() {
    local dir cand
    local IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || continue
        cand="$dir/tmux"
        [ -f "$cand" ] && [ -x "$cand" ] || continue
        if head -c 512 "$cand" 2>/dev/null | grep -aq "$E2E_TMUX_SHIM_TAG"; then
            continue
        fi
        printf '%s\n' "$cand"
        return 0
    done
    return 1
}

# _e2e_real_dir <path> — 実在ディレクトリの物理パス (無ければ失敗)
_e2e_real_dir() {
    (cd -P "$1" 2>/dev/null && pwd -P)
}

# _e2e_under <path> <dir> — path が dir 配下 (dir 自身を含む) なら 0。区切りで比較する。
_e2e_under() {
    case "$1/" in
        "$2"/*) return 0 ;;
    esac
    return 1
}

_e2e_marker_value() {
    # _e2e_marker_value <file> <key> — key=value 形式の値 (sourceせず grep のみ)
    grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-
}

# ── 検査 ── (各関数は 0=合格 / 1=拒否。_E2E_DIR に dir の物理パスを共有)

_e2e_chk_dir() {
    local dir="${E2E_DISPOSABLE_DIR:-}" uid mode
    [ -n "$dir" ] || { _e2e_deny "dir: E2E_DISPOSABLE_DIR unset (not started by scripts/run_e2e_isolated.sh)"; return 1; }
    [ ! -L "$dir" ] || { _e2e_deny "dir: $dir is a symlink"; return 1; }
    [ -d "$dir" ] || { _e2e_deny "dir: $dir is not a directory"; return 1; }
    _E2E_DIR="$(_e2e_real_dir "$dir")" || { _e2e_deny "dir: cannot resolve $dir"; return 1; }
    uid="$(id -u)"
    [ "$(stat -c %u "$_E2E_DIR" 2>/dev/null)" = "$uid" ] || { _e2e_deny "dir: $_E2E_DIR is not owned by uid $uid"; return 1; }
    mode="$(stat -c %a "$_E2E_DIR" 2>/dev/null)"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { _e2e_deny "dir: cannot read mode of $_E2E_DIR"; return 1; }
    if (( (8#$mode & 8#022) != 0 )); then
        _e2e_deny "dir: $_E2E_DIR is group/other writable (mode $mode)"
        return 1
    fi
    return 0
}

_e2e_chk_marker() {
    local marker="$_E2E_DIR/$E2E_DISPOSABLE_MARKER_NAME"
    [ ! -L "$marker" ] && [ -f "$marker" ] || { _e2e_deny "marker: $marker missing (not created by the runner)"; return 1; }
    [ "$(stat -c %u "$marker" 2>/dev/null)" = "$(id -u)" ] || { _e2e_deny "marker: not owned by current uid"; return 1; }
    local mdir
    mdir="$(_e2e_marker_value "$marker" dir)"
    [ -n "$mdir" ] && [ "$mdir" = "$_E2E_DIR" ] || { _e2e_deny "marker: dir field does not match $_E2E_DIR"; return 1; }
    return 0
}

_e2e_chk_nonce() {
    local marker="$_E2E_DIR/$E2E_DISPOSABLE_MARKER_NAME" nonce
    nonce="$(_e2e_marker_value "$marker" nonce)"
    [ -n "$nonce" ] && [ "$nonce" = "${E2E_DISPOSABLE_NONCE:-}" ] || { _e2e_deny "nonce: marker nonce does not match E2E_DISPOSABLE_NONCE (stale or foreign directory)"; return 1; }
    return 0
}

_e2e_chk_runner_alive() {
    local marker="$_E2E_DIR/$E2E_DISPOSABLE_MARKER_NAME" pid
    pid="$(_e2e_marker_value "$marker" runner_pid)"
    [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ] || { _e2e_deny "runner_pid: runner process '${pid:-?}' is not alive (directory is left over from an earlier run)"; return 1; }
    return 0
}

_e2e_chk_tmpdir() {
    local tmpdir="${TMUX_TMPDIR:-}" real
    [ -n "$tmpdir" ] || { _e2e_deny "tmpdir: TMUX_TMPDIR unset (tmux would use the default socket)"; return 1; }
    real="$(_e2e_real_dir "$tmpdir")" || { _e2e_deny "tmpdir: cannot resolve TMUX_TMPDIR=$tmpdir"; return 1; }
    _e2e_under "$real" "$_E2E_DIR" || { _e2e_deny "tmpdir: TMUX_TMPDIR=$real is outside $_E2E_DIR"; return 1; }
    return 0
}

_e2e_chk_tmux_env() {
    [ -n "${TMUX:-}" ] || return 0
    local sock="${TMUX%%,*}" sdir
    sdir="$(_e2e_real_dir "$(dirname "$sock")")" || { _e2e_deny "tmuxenv: cannot resolve the socket dir of TMUX=$sock"; return 1; }
    _e2e_under "$sdir" "$_E2E_DIR" || { _e2e_deny "tmuxenv: TMUX points at $sock (outside $_E2E_DIR) — a live server"; return 1; }
    return 0
}

_e2e_chk_tmux_pane() {
    [ -z "${TMUX_PANE:-}" ] || { _e2e_deny "pane: TMUX_PANE=${TMUX_PANE} is set (unset it; pane ids could match the live server)"; return 1; }
    return 0
}

_e2e_chk_socket_query() {
    local real out
    real="$(e2e_find_real_tmux)" || { _e2e_deny "query: no real tmux binary found on PATH"; return 1; }
    if command -v timeout >/dev/null 2>&1; then
        out="$(timeout 5 "$real" display-message -p '#{socket_path}' 2>/dev/null)" || { _e2e_deny "query: tmux did not report its socket path (no isolated server running, or tmux not responding)"; return 1; }
    else
        out="$("$real" display-message -p '#{socket_path}' 2>/dev/null)" || { _e2e_deny "query: tmux did not report its socket path"; return 1; }
    fi
    out="${out%%$'\n'*}"
    [ -n "$out" ] || { _e2e_deny "query: tmux returned an empty socket path"; return 1; }
    _E2E_SOCK="$out"
    return 0
}

_e2e_chk_socket_under() {
    local sdir
    sdir="$(_e2e_real_dir "$(dirname "$_E2E_SOCK")")" || { _e2e_deny "sockdir: cannot resolve the directory of socket $_E2E_SOCK"; return 1; }
    _e2e_under "$sdir" "$_E2E_DIR" || { _e2e_deny "sockdir: socket $_E2E_SOCK is outside $_E2E_DIR"; return 1; }
    return 0
}

_e2e_chk_socket_not_default() {
    local uid sdir
    uid="$(id -u)"
    sdir="$(_e2e_real_dir "$(dirname "$_E2E_SOCK")")" || sdir=""
    if [ "$_E2E_SOCK" = "/tmp/tmux-$uid/default" ] || [ "$sdir/$(basename "$_E2E_SOCK")" = "/tmp/tmux-$uid/default" ]; then
        _e2e_deny "notdef: socket $_E2E_SOCK is the default socket (the live fleet's server)"
        return 1
    fi
    return 0
}

# e2e_disposable_check — 全検査を順に実行。最初の拒否で打切り (理由は stderr と E2E_GUARD_REASON)。
e2e_disposable_check() {
    local _E2E_DIR="" _E2E_SOCK=""
    E2E_GUARD_REASON=""
    _e2e_chk_dir || return 1
    _e2e_chk_marker || return 1
    _e2e_chk_nonce || return 1
    _e2e_chk_runner_alive || return 1
    _e2e_chk_tmpdir || return 1
    _e2e_chk_tmux_env || return 1
    _e2e_chk_tmux_pane || return 1
    _e2e_chk_socket_query || return 1
    _e2e_chk_socket_under || return 1
    _e2e_chk_socket_not_default || return 1
    return 0
}

# _e2e_chk_wrapper_active — `tmux` が PATH 上でラッパに解決されること。
# (git の core.fileMode=false 環境でラッパが実行不可のまま落ちると、実 tmux が素通しで使われてしまう。)
# e2e_disposable_check (ラッパ自身も使う) には含めず、setup 側の e2e_require_disposable でのみ検査する。
_e2e_chk_wrapper_active() {
    local t
    t="$(command -v tmux 2>/dev/null)" || { _e2e_deny "wrapper: no tmux on PATH"; return 1; }
    if ! head -c 512 "$t" 2>/dev/null | grep -aq "$E2E_TMUX_SHIM_TAG"; then
        _e2e_deny "wrapper: tmux resolves to $t, not the e2e wrapper (helpers/bin/tmux missing or not executable)"
        return 1
    fi
    return 0
}

# e2e_require_disposable — setup_file / setup の最初に呼ぶ。満たせなければ非0で終わる (SKIP にしない)。
e2e_require_disposable() {
    if _e2e_chk_wrapper_active 2>/dev/null && e2e_disposable_check; then
        return 0
    fi
    local msg="e2e: refusing to run — not inside a disposable tmux server (${E2E_GUARD_REASON:-unknown}). Run via: bash scripts/run_e2e_isolated.sh [bats args]"
    echo "$msg" >&2
    # bats は setup_file の stderr を失敗時にしか見せぬことがあるので fd3 にも出す
    { echo "# $msg" >&3; } 2>/dev/null || true
    return 1
}

# e2e_install_tmux_wrapper — ラッパ (helpers/bin/tmux) を PATH 先頭へ。冪等。
# setup.bash が source 時に呼ぶ。runner 経由でなくても、e2e の tmux は必ずラッパを通る。
e2e_install_tmux_wrapper() {
    local bin
    bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/bin" 2>/dev/null && pwd)" || return 1
    [ -x "$bin/tmux" ] || chmod +x "$bin/tmux" 2>/dev/null || true
    case "$PATH" in
        "$bin":*) return 0 ;;
    esac
    export PATH="$bin:$PATH"
}
