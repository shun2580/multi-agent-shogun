#!/usr/bin/env bats
# test_e2e_disposable_guard.bats — cmd_225 / subtask_225_C
# tests/e2e が「使い捨ての tmux サーバ」でのみ走ることを、実 tmux を一切使わずに確かめる。
#   - 偽 tmux (PATH 先頭) が呼出を記録し、socket_path 問合せに答える。実 tmux には届かない。
#   - guard (tests/e2e/helpers/disposable_guard.bash) の許可/拒否の両側
#   - ラッパ (tests/e2e/helpers/bin/tmux) の二重化: 書込系は自身で判定を再実行、読取系は素通し、
#     空/省略ターゲット・グローバル -S/-L/-f/-c・kill-server は拒否、`capture-pane -S -` は誤拒否しない
#   - 空 E2E_SESSION の teardown が kill-session を打たぬこと
#   - 変異試験: 各検査を1つずつ無効化すると、対応する拒否理由が出なくなる(= 試験が感度を持つ)
#   - e2e の各 bats がガードを呼び、生きた陣を前提にしないこと(静的確認)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GUARD="$REPO_ROOT/tests/e2e/helpers/disposable_guard.bash"
    WRAPPER="$REPO_ROOT/tests/e2e/helpers/bin/tmux"
    UID_NUM="$(id -u)"

    # 偽 tmux: 呼出を記録。`#{socket_path}` 問合せには FAKE_TMUX_SOCKET を返す (FAKE_TMUX_FAIL=1 なら失敗)
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$FAKEBIN"
    export FAKE_TMUX_LOG="$BATS_TEST_TMPDIR/fake_tmux_calls.log"
    : > "$FAKE_TMUX_LOG"
    cat > "$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
echo "CALL $*" >> "$FAKE_TMUX_LOG"
case "$*" in
    *'#{socket_path}'*)
        [ "${FAKE_TMUX_FAIL:-0}" = "1" ] && exit 1
        printf '%s\n' "${FAKE_TMUX_SOCKET:-}"
        exit 0 ;;
esac
exit 0
FAKE
    chmod +x "$FAKEBIN/tmux"
    export PATH="$FAKEBIN:/usr/bin:/bin"
    [ "$(command -v tmux)" = "$FAKEBIN/tmux" ]   # 実 tmux に触れぬ番

    unset TMUX TMUX_PANE FAKE_TMUX_FAIL E2E_SESSION
    export E2E_TMUX_WRAPPER_LOG="$BATS_TEST_TMPDIR/wrapper.log"
    : > "$E2E_TMUX_WRAPPER_LOG"
    mk_disposable
}

# 全条件を満たす「使い捨て」環境を作る
mk_disposable() {
    ISO="$(mktemp -d "$BATS_TEST_TMPDIR/iso.XXXXXX")"
    chmod 700 "$ISO"
    ISO="$(cd -P "$ISO" && pwd -P)"
    NONCE="nonce_$RANDOM$RANDOM"
    {
        echo "dir=$ISO"
        echo "nonce=$NONCE"
        echo "runner_pid=$$"
    } > "$ISO/.e2e_disposable_marker"
    mkdir -p "$ISO/tmux/tmux-$UID_NUM"
    export E2E_DISPOSABLE_DIR="$ISO" E2E_DISPOSABLE_NONCE="$NONCE"
    export TMUX_TMPDIR="$ISO/tmux"
    export FAKE_TMUX_SOCKET="$ISO/tmux/tmux-$UID_NUM/default"
}

dead_pid() { sleep 0 & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }

sendkeys_calls() { grep -c 'CALL .*send-keys' "$FAKE_TMUX_LOG" || true; }

# guard を現シェルで読み、判定を実行。$status / $output / REASON を得る
run_check() {
    run bash -c 'source "$1"; e2e_disposable_check; rc=$?; echo "reason=$E2E_GUARD_REASON"; exit $rc' _ "${1:-$GUARD}"
}

# ── 壊し方 (各検査に1つ)。壊した環境で拒否され、理由の先頭が検査名になること ──
break_dir()      { export E2E_DISPOSABLE_DIR="$BATS_TEST_TMPDIR/nonexistent_dir"; }
break_marker()   { rm -f "$ISO/.e2e_disposable_marker"; }
break_nonce()    { export E2E_DISPOSABLE_NONCE="somebody-elses-nonce"; }
break_runner()   { sed -i "s/^runner_pid=.*/runner_pid=$(dead_pid)/" "$ISO/.e2e_disposable_marker"; }
break_tmpdir()   { export TMUX_TMPDIR="$BATS_TEST_TMPDIR/outside_tmpdir"; mkdir -p "$TMUX_TMPDIR"; }
break_tmuxenv()  { export TMUX="/tmp/tmux-$UID_NUM/default,4332,1"; }
break_pane()     { export TMUX_PANE="%1"; }
break_query()    { export FAKE_TMUX_FAIL=1; }
break_sockdir()  { mkdir -p "$BATS_TEST_TMPDIR/elsewhere"; export FAKE_TMUX_SOCKET="$BATS_TEST_TMPDIR/elsewhere/default"; }

CHECKS="dir:_e2e_chk_dir marker:_e2e_chk_marker nonce:_e2e_chk_nonce runner:_e2e_chk_runner_alive tmpdir:_e2e_chk_tmpdir tmuxenv:_e2e_chk_tmux_env pane:_e2e_chk_tmux_pane query:_e2e_chk_socket_query sockdir:_e2e_chk_socket_under"
# break_<name> が出す理由の先頭
reason_prefix() {
    case "$1" in
        runner) echo "runner_pid:" ;;
        *) echo "$1:" ;;
    esac
}

# ═══ 許可側 ═══

@test "guard: all conditions satisfied → allowed" {
    run_check
    [ "$status" -eq 0 ]
}

@test "guard: TMUX unset or pointing inside the disposable dir → allowed" {
    export TMUX="$FAKE_TMUX_SOCKET,4332,1"
    run_check
    [ "$status" -eq 0 ]
}

@test "e2e_require_disposable: allowed (wrapper first on PATH) → returns 0 and prints nothing to stderr" {
    run bash -c 'source "$1"; e2e_install_tmux_wrapper; e2e_require_disposable' _ "$GUARD"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "e2e_require_disposable: DENY when tmux does not resolve to the wrapper (a plain real tmux would be used)" {
    run bash -c 'source "$1"; e2e_require_disposable' _ "$GUARD"
    [ "$status" -ne 0 ]
    [[ "$output" == *"wrapper:"* ]]
    [[ "$output" == *"refusing to run"* ]]
}

@test "mutation: disabling the wrapper-active check lets a bare PATH through e2e_require_disposable" {
    mutate _e2e_chk_wrapper_active
    run bash -c 'source "$1"; e2e_require_disposable' _ "$MUTANT"
    [ "$status" -eq 0 ]
}

# ═══ 拒否側 (1条件ずつ) ═══

@test "guard: DENY when E2E_DISPOSABLE_DIR is unset (no marker proof)" {
    unset E2E_DISPOSABLE_DIR
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=dir:"* ]]
}

@test "guard: DENY when the marker is missing" {
    break_marker
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=marker:"* ]]
}

@test "guard: DENY when the disposable dir is a symlink" {
    ln -s "$ISO" "$BATS_TEST_TMPDIR/link_to_iso"
    export E2E_DISPOSABLE_DIR="$BATS_TEST_TMPDIR/link_to_iso"
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=dir:"* ]]
}

@test "guard: DENY when the disposable dir is group/other writable" {
    chmod 777 "$ISO"
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=dir:"* ]]
}

@test "guard: DENY when the nonce does not match (a self-declared env var is not enough)" {
    break_nonce
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=nonce:"* ]]
}

@test "guard: DENY when the runner that created the marker is no longer alive" {
    break_runner
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=runner_pid:"* ]]
}

@test "guard: DENY when TMUX_TMPDIR is outside the disposable dir" {
    break_tmpdir
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=tmpdir:"* ]]
}

@test "guard: DENY when TMUX_TMPDIR is unset" {
    unset TMUX_TMPDIR
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=tmpdir:"* ]]
}

@test "guard: DENY when TMUX points at the live (default) socket" {
    break_tmuxenv
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=tmuxenv:"* ]]
}

@test "guard: DENY when TMUX_PANE is set (pane ids could collide with the live server)" {
    break_pane
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=pane:"* ]]
}

@test "guard: DENY (fail-closed) when the socket path cannot be obtained from tmux" {
    break_query
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=query:"* ]]
}

@test "guard: DENY (fail-closed) when tmux returns an empty socket path" {
    export FAKE_TMUX_SOCKET=""
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=query:"* ]]
}

@test "guard: DENY when no real tmux is on PATH (fail-closed)" {
    # tmux だけが無い PATH (必要な coreutils は symlink で用意)
    mkdir -p "$BATS_TEST_TMPDIR/nobin"
    local u
    for u in id stat grep cut head dirname basename timeout; do
        ln -sf "$(command -v "$u")" "$BATS_TEST_TMPDIR/nobin/$u"
    done
    run env PATH="$BATS_TEST_TMPDIR/nobin" /bin/bash -c 'source "$1"; e2e_disposable_check; rc=$?; echo "reason=$E2E_GUARD_REASON"; exit $rc' _ "$GUARD"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=query:"* ]]
}

@test "guard: DENY when tmux reports a socket outside the disposable dir" {
    break_sockdir
    run_check
    [ "$status" -ne 0 ]
    [[ "$output" == *"reason=sockdir:"* ]]
}

# ── 兄弟ディレクトリ (専用ディレクトリ名と接頭辞が文字列として一致するだけ) は専用ディレクトリ配下ではない ──
# 境界は『専用ディレクトリ + /』で判定する。"$ISO"_evil と "$ISO"evil の両形を拒否側で確かめる。

mk_sibling() {
    # mk_sibling <suffix> → SIB に ${ISO}<suffix> を作り、その下に tmux ソケット用ディレクトリも作る
    SIB="${ISO}$1"
    mkdir -p "$SIB/tmux/tmux-$UID_NUM"
}

@test "guard: DENY when TMUX_TMPDIR is a sibling dir sharing the disposable dir's name as a prefix" {
    local suffix
    for suffix in _evil evil; do
        mk_sibling "$suffix"
        export TMUX_TMPDIR="$SIB/tmux"
        run_check
        [ "$status" -ne 0 ]
        [[ "$output" == *"reason=tmpdir:"* ]]
    done
}

@test "guard: DENY when TMUX points at a socket under a sibling dir sharing the disposable dir's name as a prefix" {
    local suffix
    for suffix in _evil evil; do
        mk_sibling "$suffix"
        export TMUX="$SIB/tmux/tmux-$UID_NUM/default,4332,1"
        run_check
        [ "$status" -ne 0 ]
        [[ "$output" == *"reason=tmuxenv:"* ]]
    done
}

@test "guard: DENY when tmux reports a socket under a sibling dir sharing the disposable dir's name as a prefix" {
    local suffix
    for suffix in _evil evil; do
        mk_sibling "$suffix"
        export FAKE_TMUX_SOCKET="$SIB/tmux/tmux-$UID_NUM/default"
        run_check
        [ "$status" -ne 0 ]
        [[ "$output" == *"reason=sockdir:"* ]]
    done
}

@test "wrapper: send-keys REFUSED (0 calls) for each sibling-prefix path (TMUX_TMPDIR / TMUX / socket)" {
    mk_sibling _evil
    export TMUX_TMPDIR="$SIB/tmux"
    wrap send-keys -t "multiagent:agents.4" "x" Enter
    [ "$status" -eq 97 ]
    [[ "$output" == *"tmpdir:"* ]]

    mk_disposable; mk_sibling evil
    export TMUX="$SIB/tmux/tmux-$UID_NUM/default,4332,1"
    wrap send-keys -t "multiagent:agents.4" "x" Enter
    [ "$status" -eq 97 ]
    [[ "$output" == *"tmuxenv:"* ]]

    unset TMUX
    mk_disposable; mk_sibling _evil
    export FAKE_TMUX_SOCKET="$SIB/tmux/tmux-$UID_NUM/default"
    wrap send-keys -t "multiagent:agents.4" "x" Enter
    [ "$status" -eq 97 ]
    [[ "$output" == *"sockdir:"* ]]

    [ "$(sendkeys_calls)" -eq 0 ]
}

@test "guard: a path strictly inside the disposable dir (boundary '<dir>/') is still allowed for TMUX_TMPDIR / TMUX / socket" {
    mkdir -p "$ISO/tmux_evil/tmux-$UID_NUM"
    export TMUX_TMPDIR="$ISO/tmux_evil"
    export TMUX="$ISO/tmux_evil/tmux-$UID_NUM/default,4332,1"
    export FAKE_TMUX_SOCKET="$ISO/tmux_evil/tmux-$UID_NUM/default"
    run_check
    [ "$status" -eq 0 ]
}

@test "guard: the default socket (/tmp/tmux-<uid>/default) is refused by the notdef check" {
    run bash -c 'source "$1"; _E2E_SOCK="/tmp/tmux-$2/default"; _e2e_chk_socket_not_default; echo "reason=$E2E_GUARD_REASON"' _ "$GUARD" "$UID_NUM"
    [[ "$output" == *"reason=notdef:"* ]]
    run bash -c 'source "$1"; _E2E_SOCK="/tmp/e2e_iso.x/tmux/tmux-$2/default"; _e2e_chk_socket_not_default && echo passed' _ "$GUARD" "$UID_NUM"
    [[ "$output" == *"passed"* ]]
}

@test "e2e_require_disposable: denied → non-zero, names the reason, never silently ok or skip" {
    break_marker
    run bash -c 'source "$1"; e2e_install_tmux_wrapper; e2e_require_disposable' _ "$GUARD"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" == *"marker:"* ]]
    [[ "$output" != *"skip"* ]]
}

@test "guard: a denial never calls send-keys on the (fake) tmux" {
    break_tmuxenv
    run_check
    [ "$status" -ne 0 ]
    [ "$(sendkeys_calls)" -eq 0 ]
}

# ═══ ラッパ ═══

wrap() { run "$WRAPPER" "$@"; }

@test "wrapper: write command allowed in a disposable env and forwarded to the real tmux" {
    wrap send-keys -t "e2e_x:agents.1" "inbox1" Enter
    [ "$status" -eq 0 ]
    [ "$(sendkeys_calls)" -eq 1 ]
    grep -q 'ALLOW send-keys' "$E2E_TMUX_WRAPPER_LOG"
}

@test "wrapper: set-option -p / new-session / respawn-pane allowed in a disposable env" {
    wrap set-option -p -t "e2e_x:agents.1" @agent_cli claude
    [ "$status" -eq 0 ]
    wrap new-session -d -s e2e_x -n agents
    [ "$status" -eq 0 ]
    wrap respawn-pane -k -t "e2e_x:agents.1" "bash"
    [ "$status" -eq 0 ]
}

@test "wrapper: send-keys REFUSED (exit 97, reason on stderr, 0 calls) without the marker" {
    break_marker
    wrap send-keys -t "multiagent:agents.4" "x" Enter
    [ "$status" -eq 97 ]
    [[ "$output" == *"REFUSE"* ]]
    [[ "$output" == *"marker:"* ]]
    [ "$(sendkeys_calls)" -eq 0 ]
    grep -q 'DENY send-keys' "$E2E_TMUX_WRAPPER_LOG"
}

@test "wrapper: send-keys REFUSED when TMUX points at the live socket" {
    break_tmuxenv
    wrap send-keys -t "multiagent:agents.4" "x" Enter
    [ "$status" -eq 97 ]
    [[ "$output" == *"tmuxenv:"* ]]
    [ "$(sendkeys_calls)" -eq 0 ]
}

@test "wrapper: send-keys REFUSED when TMUX_TMPDIR is outside the disposable dir" {
    break_tmpdir
    wrap send-keys -t "multiagent:agents.4" "x" Enter
    [ "$status" -eq 97 ]
    [[ "$output" == *"tmpdir:"* ]]
    [ "$(sendkeys_calls)" -eq 0 ]
}

@test "wrapper: send-keys REFUSED when the socket path cannot be obtained (fail-closed)" {
    break_query
    wrap send-keys -t "multiagent:agents.4" "x" Enter
    [ "$status" -eq 97 ]
    [[ "$output" == *"query:"* ]]
    [ "$(sendkeys_calls)" -eq 0 ]
}

@test "wrapper: empty -t target is REFUSED even in a disposable env (send-keys / kill-session)" {
    wrap send-keys -t "" "x" Enter
    [ "$status" -eq 97 ]
    wrap kill-session -t ""
    [ "$status" -eq 97 ]
    [ "$(sendkeys_calls)" -eq 0 ]
    ! grep -q 'CALL kill-session' "$FAKE_TMUX_LOG"
}

@test "wrapper: omitted -t target is REFUSED even in a disposable env" {
    wrap send-keys "x" Enter
    [ "$status" -eq 97 ]
    wrap kill-session
    [ "$status" -eq 97 ]
    wrap respawn-pane -k
    [ "$status" -eq 97 ]
    ! grep -q 'CALL kill-session\|CALL send-keys\|CALL respawn-pane' "$FAKE_TMUX_LOG"
}

@test "wrapper: global -S / -L / -f before the subcommand is REFUSED on a write command" {
    wrap -S /tmp/tmux-"$UID_NUM"/default send-keys -t "a:b.1" x
    [ "$status" -eq 97 ]
    wrap -L other send-keys -t "a:b.1" x
    [ "$status" -eq 97 ]
    wrap -f /dev/null new-session -d -s zz
    [ "$status" -eq 97 ]
    wrap -2S/tmp/x send-keys -t "a:b.1" x
    [ "$status" -eq 97 ]
    [ "$(sendkeys_calls)" -eq 0 ]
}

@test "wrapper: kill-server is always REFUSED" {
    wrap kill-server
    [ "$status" -eq 97 ]
    ! grep -q 'CALL kill-server' "$FAKE_TMUX_LOG"
}

@test "wrapper: an unknown subcommand is treated as a write command (REFUSED without proof)" {
    break_marker
    wrap run-shell "echo hi"
    [ "$status" -eq 97 ]
    wrap some-future-subcommand -t x
    [ "$status" -eq 97 ]
}

@test "wrapper: read commands pass through even with no marker (capture-pane -S - is NOT mistaken for global -S)" {
    break_marker
    wrap capture-pane -t "e2e_x:agents.1" -p -S -
    [ "$status" -eq 0 ]
    grep -q 'CALL capture-pane -t e2e_x:agents.1 -p -S -' "$FAKE_TMUX_LOG"
    wrap capture-pane -J -t "e2e_x:agents.1" -p -S - -E -
    [ "$status" -eq 0 ]
}

@test "wrapper: list-panes / list-sessions / display-message / show-options / has-session pass through" {
    break_marker
    for sub in "list-panes -a" "list-sessions" "ls" "display-message -p -t x:0.1 #{pane_id}" "show-options -v -p -t x:0.1 @agent_cli" "has-session -t x" "list-clients" "show-environment -t x"; do
        # shellcheck disable=SC2086
        wrap $sub
        [ "$status" -eq 0 ]
    done
    [ "$(wc -l < "$FAKE_TMUX_LOG")" -eq 8 ]
}

@test "wrapper: read commands with global -L still pass (only writes are refused for -L)" {
    break_marker
    wrap -L other list-sessions
    [ "$status" -eq 0 ]
}

@test "wrapper: attempts are logged (ALLOW and DENY lines carry the subcommand and target)" {
    wrap send-keys -t "e2e_x:agents.2" "a"
    break_marker
    wrap send-keys -t "multiagent:agents.4" "b"
    grep -q 'ALLOW send-keys target=e2e_x:agents.2' "$E2E_TMUX_WRAPPER_LOG"
    grep -q 'DENY send-keys target=multiagent:agents.4' "$E2E_TMUX_WRAPPER_LOG"
    [ "$(grep -c 'DENY send-keys' "$E2E_TMUX_WRAPPER_LOG")" -eq 1 ]
}

@test "wrapper: -V (version) passes through without a subcommand" {
    break_marker
    wrap -V
    [ "$status" -eq 0 ]
}

# ═══ 空 E2E_SESSION の teardown (軍師QC追補) ═══

@test "teardown_e2e_session: an empty E2E_SESSION does NOT call kill-session" {
    export E2E_SESSION=""
    run bash -c 'source "$1/tests/e2e/helpers/setup.bash"; teardown_e2e_session' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    ! grep -q 'CALL kill-session' "$FAKE_TMUX_LOG"
    # -n ガード自体が効いている: ラッパに拒否させるまでもなく、kill-session を試みてすらいない
    ! grep -q 'kill-session' "$E2E_TMUX_WRAPPER_LOG"
}

@test "teardown_e2e_session: an unset E2E_SESSION does NOT call kill-session" {
    unset E2E_SESSION
    run bash -c 'source "$1/tests/e2e/helpers/setup.bash"; teardown_e2e_session' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    ! grep -q 'CALL kill-session' "$FAKE_TMUX_LOG"
    ! grep -q 'kill-session' "$E2E_TMUX_WRAPPER_LOG"
}

@test "teardown_e2e_session: a set E2E_SESSION still kills its own session (in a disposable env)" {
    export E2E_SESSION="e2e_test_123"
    run bash -c 'source "$1/tests/e2e/helpers/setup.bash"; teardown_e2e_session' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    grep -q 'CALL kill-session -t e2e_test_123' "$FAKE_TMUX_LOG"
}

@test "teardown_e2e_session: even if the -n guard were removed, the wrapper refuses the empty target" {
    # setup.bash が PATH 先頭へ置くラッパ経由で、空ターゲットの kill-session を直接打つ
    run bash -c 'source "$1/tests/e2e/helpers/setup.bash"; E2E_SESSION=""; tmux kill-session -t "$E2E_SESSION"' _ "$REPO_ROOT"
    [ "$status" -eq 97 ]
    ! grep -q 'CALL kill-session' "$FAKE_TMUX_LOG"
}

@test "setup_e2e_session: refuses before touching tmux when not disposable (no new-session / send-keys)" {
    break_marker
    run bash -c 'source "$1/tests/e2e/helpers/setup.bash"; setup_e2e_session 3' _ "$REPO_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    ! grep -q 'CALL new-session\|CALL send-keys\|CALL split-window' "$FAKE_TMUX_LOG"
}

# ═══ 変異試験: 検査を1つ無効化すると、その拒否理由が出なくなる ═══

mutate() {
    # mutate <function> → 無効化した guard のパスを MUTANT に
    MUTANT="$BATS_TEST_TMPDIR/mutant_$1.bash"
    sed "s/^$1() {\$/$1() { return 0; }\n_unused_$1() {/" "$GUARD" > "$MUTANT"
    grep -q "^$1() { return 0; }" "$MUTANT"   # 置換が効いたこと
}

@test "mutation: disabling each single check removes its denial (so each deny test above has teeth)" {
    local entry name fn expect
    for entry in $CHECKS; do
        name="${entry%%:*}"; fn="${entry#*:}"
        expect="$(reason_prefix "$name")"

        # 実物: 壊した環境で、その検査名の理由で拒否される
        mk_disposable
        "break_$name"
        run_check "$GUARD"
        [ "$status" -ne 0 ]
        [[ "$output" == *"reason=$expect"* ]]

        # 変異: 検査を無効化すると、同じ理由では拒否されない
        mutate "$fn"
        run_check "$MUTANT"
        if [[ "$output" == *"reason=$expect"* ]]; then
            echo "mutation of $fn was NOT detected: still denied with '$expect'" >&2
            return 1
        fi
        unset FAKE_TMUX_FAIL TMUX TMUX_PANE
    done
}

@test "mutation: disabling the notdef check lets the default socket through" {
    mutate _e2e_chk_socket_not_default
    run bash -c 'source "$1"; _E2E_SOCK="/tmp/tmux-$2/default"; _e2e_chk_socket_not_default && echo passed' _ "$MUTANT" "$UID_NUM"
    [[ "$output" == *"passed"* ]]
}

@test "mutation: weakening the boundary to a bare string-prefix match lets every sibling-prefix path through (so the sibling tests have teeth)" {
    # 境界判定 _e2e_under を『接頭辞一致だけ』にした変異体。guard 本体は書換えず、source 後に関数を上書きする。
    local mut='_e2e_under() { case "$1" in "$2"*) return 0 ;; esac; return 1; }'
    local suffix
    for suffix in _evil evil; do
        mk_disposable; mk_sibling "$suffix"

        export TMUX_TMPDIR="$SIB/tmux"
        run bash -c 'source "$1"; eval "$2"; e2e_disposable_check; rc=$?; echo "reason=$E2E_GUARD_REASON"; exit $rc' _ "$GUARD" "$mut"
        [[ "$output" != *"reason=tmpdir:"* ]]

        mk_disposable; mk_sibling "$suffix"
        export TMUX="$SIB/tmux/tmux-$UID_NUM/default,4332,1"
        run bash -c 'source "$1"; eval "$2"; e2e_disposable_check; rc=$?; echo "reason=$E2E_GUARD_REASON"; exit $rc' _ "$GUARD" "$mut"
        [[ "$output" != *"reason=tmuxenv:"* ]]
        unset TMUX

        mk_disposable; mk_sibling "$suffix"
        export FAKE_TMUX_SOCKET="$SIB/tmux/tmux-$UID_NUM/default"
        run bash -c 'source "$1"; eval "$2"; e2e_disposable_check; rc=$?; echo "reason=$E2E_GUARD_REASON"; exit $rc' _ "$GUARD" "$mut"
        [[ "$output" != *"reason=sockdir:"* ]]
    done
}

@test "mutation: the full check (no single check disabled) refuses every broken environment — and a mutant that disables a check allows at least one" {
    # TMUX 検査を外した変異体は、TMUX が生きたソケットを指していても通してしまう(= 検査が実効)
    mutate _e2e_chk_tmux_env
    break_tmuxenv
    run_check "$MUTANT"
    # tmuxenv 理由では拒否されない
    [[ "$output" != *"reason=tmuxenv:"* ]]
}

# ═══ 静的確認: e2e の各 bats がガードを呼び、生きた陣を前提にしない ═══

@test "static: every tmux-using e2e bats calls e2e_require_disposable in setup_file" {
    local f n=0
    for f in "$REPO_ROOT"/tests/e2e/e2e_*.bats; do
        # コメント行(slim_retention の頭コメントのような説明文)は数えない。コードに tmux / setup_e2e_session / helpers/setup があれば tmux 系。
        if grep -v '^\s*#' "$f" | grep -Eq 'tmux|setup_e2e_session|helpers/setup'; then
            grep -v '^\s*#' "$f" | grep -q 'e2e_require_disposable' || { echo "missing guard call (comments do not count): $f" >&2; return 1; }
            n=$((n + 1))
        fi
    done
    [ "$n" -ge 12 ]
}

@test "static: the one e2e bats that never touches tmux (slim_retention) really has no tmux" {
    local f="$REPO_ROOT/tests/e2e/e2e_slim_retention.bats"
    # コード(コメント行を除く)に tmux / setup_e2e_session / helpers/setup が現れたら落ちる。
    if grep -v '^\s*#' "$f" | grep -Eq 'tmux|setup_e2e_session|helpers/setup'; then
        echo "e2e_slim_retention.bats now uses tmux: add 'e2e_require_disposable' to its setup_file (see its header comment) — do not loosen this test" >&2
        return 1
    fi
}

@test "static: e2e_slim_retention documents why it is outside the guard and that tmux use would require the guard (cmd_229)" {
    local f="$REPO_ROOT/tests/e2e/e2e_slim_retention.bats"
    head -40 "$f" | grep -q 'e2e_require_disposable'
    head -40 "$f" | grep -q '対象外'
    head -40 "$f" | grep -q '将来'
    head -40 "$f" | grep -q 'static: the one e2e bats that never touches tmux'
}

@test "static: setup.bash puts the wrapper first on PATH and guards setup_e2e_session" {
    grep -q 'e2e_install_tmux_wrapper' "$REPO_ROOT/tests/e2e/helpers/setup.bash"
    grep -q 'e2e_require_disposable' "$REPO_ROOT/tests/e2e/helpers/setup.bash"
    grep -q '\[ -n "\${E2E_SESSION:-}" \]' "$REPO_ROOT/tests/e2e/helpers/setup.bash"
}

@test "static: e2e_bloom_routing no longer depends on a live 'multiagent' (no has-session multiagent, no list-panes -a, no trap EXIT)" {
    local f="$REPO_ROOT/tests/e2e/e2e_bloom_routing.bats"
    ! grep -v '^\s*#' "$f" | grep -q 'has-session -t multiagent'
    ! grep -v '^\s*#' "$f" | grep -q 'list-panes -a'
    ! grep -v '^\s*#' "$f" | grep -q 'trap .* EXIT'
    grep -q 'e2e_require_disposable' "$f"
}

@test "static: the wrapper carries the shim tag in its first 512 bytes (guard skips it when looking for the real tmux)" {
    head -c 512 "$WRAPPER" | grep -q 'E2E_TMUX_WRAPPER_SHIM'
}

@test "static: the runner exists, is executable, parses, and never calls kill-server or kill-session" {
    local r="$REPO_ROOT/scripts/run_e2e_isolated.sh"
    [ -x "$r" ]
    bash -n "$r"
    ! grep -v '^\s*#' "$r" | grep -Eq 'kill-server|kill-session'
    grep -q 'unset TMUX TMUX_PANE' "$r"
    grep -q 'TMUX_TMPDIR' "$r"
}
