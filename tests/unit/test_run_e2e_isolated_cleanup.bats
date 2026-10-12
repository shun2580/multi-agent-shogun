#!/usr/bin/env bats
# test_run_e2e_isolated_cleanup.bats — scripts/run_e2e_isolated.sh の自己片付け (cmd_229)
#
# 1. safe_remove_iso の fail-closed: 確かめられぬ置場は消さず、理由を stderr に出して非0。
# 2. 実走: 成功 / 失敗 / 途中停止(INT) のどの終わり方でも、置場 (<repo>/.e2e_work/iso.*) が残らず、
#    置場は /tmp でなくリポジトリ内、終了コードは bats のものが保たれる。
# 実走は使い捨ての tmux サーバ(runner が専用ディレクトリに立てる)だけに触れ、生きた陣には触れない。

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
    RUNNER="$REPO_ROOT/scripts/run_e2e_isolated.sh"
    FAKE_REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$FAKE_REPO/.e2e_work"
    FAKE_REPO="$(cd -P "$FAKE_REPO" && pwd -P)"
}

# 単体試験用: runner を source し (main は走らぬ)、変数を偽リポジトリに向ける
call_remove() {
    # call_remove <ISO_DIR> [NONCE]
    run bash -c '
        source "$1"
        REPO_ROOT="$2"; ISO_PARENT="$2/.e2e_work"; ISO_DIR="$3"; NONCE="$4"
        safe_remove_iso
    ' _ "$RUNNER" "$FAKE_REPO" "$1" "${2-n0nce}"
}

mk_iso() {
    # mk_iso <name> — 正しい形の置場を作る
    local d="$FAKE_REPO/.e2e_work/$1"
    mkdir -p "$d/tmux"
    d="$(cd -P "$d" && pwd -P)"
    printf 'dir=%s\nnonce=n0nce\nrunner_pid=1\n' "$d" > "$d/.e2e_disposable_marker"
    : > "$d/tmux_wrapper.log"
    echo "$d"
}

@test "safe_remove_iso: a correctly-shaped work dir is removed (and only it)" {
    local d keep
    d="$(mk_iso iso.abc123)"
    keep="$(mk_iso iso.zzz999)"
    call_remove "$d"
    [ "$status" -eq 0 ]
    [ ! -e "$d" ]
    [ -d "$keep" ]
    [ -d "$FAKE_REPO/.e2e_work" ]
}

@test "safe_remove_iso: an already-removed dir is not an error" {
    call_remove "$FAKE_REPO/.e2e_work/iso.gone00"
    [ "$status" -eq 0 ]
}

@test "safe_remove_iso: REFUSES an empty variable" {
    call_remove ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT removing"* ]]
    [ -d "$FAKE_REPO/.e2e_work" ]
}

@test "safe_remove_iso: REFUSES an empty nonce (cannot prove the dir is ours)" {
    local d; d="$(mk_iso iso.abc123)"
    call_remove "$d" ""
    [ "$status" -ne 0 ]
    [ -d "$d" ]
    [[ "$output" == *"nonce is empty"* ]]
}

@test "safe_remove_iso: REFUSES / , HOME, the repo root, and the parent itself" {
    local t
    for t in "/" "$HOME" "$FAKE_REPO" "$FAKE_REPO/.e2e_work"; do
        call_remove "$t"
        [ "$status" -ne 0 ] || { echo "removed or accepted: $t" >&2; return 1; }
        [[ "$output" == *"NOT removing"* ]]
    done
    [ -d "$FAKE_REPO/.e2e_work" ]
    [ -d "$HOME" ]
}

@test "safe_remove_iso: REFUSES a dir outside <repo>/.e2e_work even with a valid-looking marker and name" {
    local d="$BATS_TEST_TMPDIR/elsewhere/iso.abc123"
    mkdir -p "$d"
    d="$(cd -P "$d" && pwd -P)"
    printf 'dir=%s\nnonce=n0nce\n' "$d" > "$d/.e2e_disposable_marker"
    call_remove "$d"
    [ "$status" -ne 0 ]
    [ -d "$d" ]
    [[ "$output" == *"not directly inside"* ]]
}

@test "safe_remove_iso: REFUSES a nested path under the parent (not directly inside)" {
    local d="$FAKE_REPO/.e2e_work/iso.abc123/iso.def456"
    mkdir -p "$d"
    d="$(cd -P "$d" && pwd -P)"
    printf 'dir=%s\nnonce=n0nce\n' "$d" > "$d/.e2e_disposable_marker"
    call_remove "$d"
    [ "$status" -ne 0 ]
    [ -d "$d" ]
}

@test "safe_remove_iso: REFUSES a wrong name (not iso.XXXXXX)" {
    local d="$FAKE_REPO/.e2e_work/important_data"
    mkdir -p "$d"; d="$(cd -P "$d" && pwd -P)"
    printf 'dir=%s\nnonce=n0nce\n' "$d" > "$d/.e2e_disposable_marker"
    call_remove "$d"
    [ "$status" -ne 0 ]
    [ -d "$d" ]
    [[ "$output" == *"is not iso.XXXXXX"* ]]
}

@test "safe_remove_iso: REFUSES a symlink under the parent, and leaves its target untouched" {
    local victim="$BATS_TEST_TMPDIR/victim"
    mkdir -p "$victim"; echo precious > "$victim/file"
    ln -s "$victim" "$FAKE_REPO/.e2e_work/iso.abc123"
    call_remove "$FAKE_REPO/.e2e_work/iso.abc123"
    [ "$status" -ne 0 ]
    [ -f "$victim/file" ]
    [[ "$output" == *"symlink"* ]]
}

@test "safe_remove_iso: REFUSES a dir without our marker" {
    local d="$FAKE_REPO/.e2e_work/iso.abc123"
    mkdir -p "$d"; echo keep > "$d/data"
    call_remove "$d"
    [ "$status" -ne 0 ]
    [ -f "$d/data" ]
    [[ "$output" == *"no disposable marker"* ]]
}

@test "safe_remove_iso: REFUSES a marker with a foreign nonce or a mismatching dir field" {
    local d; d="$(mk_iso iso.abc123)"
    call_remove "$d" "somebody-elses-nonce"
    [ "$status" -ne 0 ]
    [ -d "$d" ]
    [[ "$output" == *"nonce does not match"* ]]
    printf 'dir=/somewhere/else\nnonce=n0nce\n' > "$d/.e2e_disposable_marker"
    call_remove "$d"
    [ "$status" -ne 0 ]
    [ -d "$d" ]
    [[ "$output" == *"dir field"* ]]
}

@test "safe_remove_iso: REFUSES when the parent is not <repo>/.e2e_work" {
    local d out="$BATS_TEST_TMPDIR/other_parent/iso.abc123"
    mkdir -p "$out"; out="$(cd -P "$out" && pwd -P)"
    printf 'dir=%s\nnonce=n0nce\n' "$out" > "$out/.e2e_disposable_marker"
    run bash -c '
        source "$1"
        REPO_ROOT="$2"; ISO_PARENT="$3"; ISO_DIR="$4"; NONCE="n0nce"
        safe_remove_iso
    ' _ "$RUNNER" "$FAKE_REPO" "$(dirname "$out")" "$out"
    [ "$status" -ne 0 ]
    [ -d "$out" ]
    [[ "$output" == *"is not <repo>/.e2e_work"* ]]
}

@test "safe_remove_iso: removes a work dir that contains a read-only subdirectory (only inside the verified dir)" {
    local d; d="$(mk_iso iso.abc123)"
    mkdir -p "$d/ro/sub"; touch "$d/ro/sub/f"; chmod 500 "$d/ro"
    call_remove "$d"
    [ "$status" -eq 0 ]
    [ ! -e "$d" ]
}

# ── 実走 ──

mk_scratch_bats() {
    # mk_scratch_bats <name> <body>
    printf '@test "%s" {\n%s\n}\n' "$1" "$2" > "$BATS_TEST_TMPDIR/$1.bats"
    echo "$BATS_TEST_TMPDIR/$1.bats"
}

# runner が出す "[e2e-isolated] dir=<置場> socket=..." から今回の置場を取る(並行して他の runner が走っていても影響されぬ)
printed_dir() { sed -n 's/^\[e2e-isolated\] dir=\([^ ]*\) socket=.*/\1/p' <<< "$output" | head -1; }

run_runner() { env -u TMUX -u TMUX_PANE SCRATCH_DIRFILE="$BATS_TEST_TMPDIR/dir.txt" bash "$RUNNER" "$@"; }

@test "runner: success → the work dir (inside the repo, not /tmp) is gone afterwards, exit 0" {
    local f d
    f="$(mk_scratch_bats okcase '[ -d "$E2E_DISPOSABLE_DIR" ]; echo "$E2E_DISPOSABLE_DIR" > "$SCRATCH_DIRFILE"')"
    run run_runner "$f"
    [ "$status" -eq 0 ]
    d="$(cat "$BATS_TEST_TMPDIR/dir.txt")"
    [ "$d" = "$(printed_dir)" ]
    [[ "$d" == "$REPO_ROOT"/.e2e_work/iso.* ]]
    [[ "$d" != /tmp/* ]]
    [ ! -e "$d" ]
    [[ "$output" == *"[e2e-wrapper]"* ]]    # 集計が消す前に出ている
}

@test "runner: a failing bats → its exit code is kept and the work dir is gone" {
    local f d
    f="$(mk_scratch_bats failcase 'echo "$E2E_DISPOSABLE_DIR" > "$SCRATCH_DIRFILE"; false')"
    run run_runner "$f"
    [ "$status" -eq 1 ]
    d="$(cat "$BATS_TEST_TMPDIR/dir.txt")"
    [ ! -e "$d" ]
}

@test "runner: stopped by the guard/startup (bats file missing) → the work dir is gone" {
    local d
    run run_runner "$BATS_TEST_TMPDIR/does_not_exist.bats"
    [ "$status" -ne 0 ]
    d="$(printed_dir)"
    [ -n "$d" ]
    [ ! -e "$d" ]
}

@test "runner: INT while bats runs (Ctrl-C) → 130, a leftover session in the disposable server is ended and the work dir is gone" {
    local f d
    f="$(mk_scratch_bats intcase 'echo "$E2E_DISPOSABLE_DIR" > "$SCRATCH_DIRFILE"; tmux new-session -d -s e2e_test_leftover "sleep 300"; sleep 30')"
    run timeout --preserve-status -s INT 8 env -u TMUX -u TMUX_PANE SCRATCH_DIRFILE="$BATS_TEST_TMPDIR/dir.txt" bash "$RUNNER" "$f"
    [ "$status" -eq 130 ]
    d="$(cat "$BATS_TEST_TMPDIR/dir.txt")"
    [ ! -e "$d" ]
}

@test "runner: a pane that ignores C-c and exit keeps the server alive → the dir is NOT removed, reported, non-zero (fail-closed, no kill)" {
    local f d
    # SIGINT・SIGHUP を無視する物を残す。D006 により kill では片付けぬ → 置場を残して報告する
    f="$(mk_scratch_bats stubborn 'echo "$E2E_DISPOSABLE_DIR" > "$SCRATCH_DIRFILE"; touch "$E2E_DISPOSABLE_DIR/.stubborn"; tmux new-session -d -s e2e_test_stubborn "bash -c \"trap : INT HUP TERM; while [ -e $E2E_DISPOSABLE_DIR/.stubborn ]; do sleep 1; done\""')"
    run run_runner "$f"
    d="$(cat "$BATS_TEST_TMPDIR/dir.txt")"
    [ "$status" -ne 0 ]
    [ -d "$d" ]
    [[ "$output" == *"NOT removing"* ]]
    [[ "$output" == *"left running"* ]]
    # 後始末: 目印を消すと頑固な物が自分で終わる → サーバが消えたら置場を片付ける
    rm -f "$d/.stubborn"
    local i
    for i in $(seq 1 15); do
        run env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$d/tmux" tmux list-sessions
        [ "$status" -ne 0 ] && break
        sleep 1
    done
    [ "$status" -ne 0 ]
    case "$d" in "$REPO_ROOT"/.e2e_work/iso.??????) rm -rf -- "$d" ;; esac
    [ ! -e "$d" ]
}

@test "static: the runner never uses kill / pkill / killall / kill-server / kill-session, and does not create work dirs under /tmp" {
    local code
    code="$(grep -v '^\s*#' "$RUNNER")"
    ! grep -Eq '(^|[^A-Za-z_-])(kill|pkill|killall)([[:space:]]|$)' <<< "$code"
    ! grep -Eq 'kill-server|kill-session' <<< "$code"
    ! grep -Eq 'mktemp[^|]*/tmp' <<< "$code"
    ! grep -Eq '/tmp/e2e_iso' <<< "$code"
    # rm -rf は確認済みの置場 ($target) にだけ
    local calls n
    calls="$(grep -E 'rm -rf' <<< "$code" | grep -v 'refuse ')"
    n="$(grep -c . <<< "$calls")"
    [ "$n" -eq 2 ]
    ! grep -qv -- 'rm -rf -- "\$target"' <<< "$calls"
}

@test "static: .e2e_work/ is git-ignored (explicitly)" {
    run git -C "$REPO_ROOT" check-ignore -q .e2e_work/iso.abc123/.e2e_disposable_marker
    [ "$status" -eq 0 ]
    grep -qx '\.e2e_work/' "$REPO_ROOT/.gitignore"
}
