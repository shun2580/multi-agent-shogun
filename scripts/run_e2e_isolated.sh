#!/usr/bin/env bash
# run_e2e_isolated.sh — tests/e2e を「使い捨ての tmux サーバ」でだけ走らせる runner (cmd_225, cmd_229)
#
# 使い方:
#   bash scripts/run_e2e_isolated.sh                              # tests/e2e 全部
#   bash scripts/run_e2e_isolated.sh tests/e2e/e2e_redo.bats      # 指定ファイルのみ
#   bash scripts/run_e2e_isolated.sh --tap tests/e2e/             # bats の引数はそのまま渡る
#
# やること:
#   1. リポジトリ内の <repo>/.e2e_work/ (git 追跡外・.gitignore 済み) に mktemp -d で専用ディレクトリ
#      (<repo>/.e2e_work/iso.XXXXXX, 0700)を作り、目印ファイル(.e2e_disposable_marker: dir / nonce / runner_pid)
#      を置く。/tmp には作らない。
#   2. TMUX_TMPDIR をその配下に向け、TMUX / TMUX_PANE を unset する(生きた陣のソケットに繋がらぬ)。
#   3. PATH 先頭に tests/e2e/helpers/bin/tmux(ラッパ)を置く。書込系 tmux はラッパがガードを再実行し、
#      使い捨てサーバと証明できなければ exit 97 で拒否する。試行は E2E_TMUX_WRAPPER_LOG に記録される。
#   4. 隔離サーバに番人セッション(e2e_keeper)を立て、実 tmux に socket_path を問い合わせて
#      専用ディレクトリ配下かつ既定ソケット(/tmp/tmux-<uid>/default)でないことを確かめる。満たさねば bats を走らせず終了。
#   5. bats を実行し、終了時(成功・失敗・ガードによる停止・Ctrl-C/TERM/HUP のすべて。trap EXIT)に
#      隔離サーバの終了を待ち、ラッパ記録の集計を出してから、専用ディレクトリを消す。
#
# 片付け(cmd_229):
#   - kill / pkill / kill-server / kill-session は使わない(D006)。番人は目印ファイルが消えたら自分で終わり、
#     残ったペインへは C-c → exit を送る(人が端末でやるのと同じ。C-c を無視する物が残れば下記の通り消さずに報告)。
#     ソケットは専用ディレクトリの中にあるので、隔離サーバが終わったと
#     確かめてから(終わらなければ消さずに)ディレクトリを消す。
#   - 消す直前に realpath で「<repo>/.e2e_work/iso.XXXXXX そのもの」であること、目印の dir/nonce が自分のものと
#     一致することを確かめる。ひとつでも確かめられぬときは何も消さず、理由を stderr に出して非0で終わる(fail-closed)。
#     rm -rf は、その確認済みの置場そのものにだけ使う。
#   - 隔離サーバが残った場合(exit に応じぬペインがある等)も、置場は消さずに残す物を表示して非0で終わる。
#   - 消えない場合は: runner を SIGKILL された(trap が走らぬ)とき、隔離サーバが終わらぬとき。残骸は
#     <repo>/.e2e_work/ の中に限られ(追跡外)、runner_pid が死んでいるのでガードは二度と通さぬ。
#   - TERM を runner だけに送った場合、bash は前景の bats が終わるまで trap を保留する。bats が走っている間は
#     置場を消さぬ、という安全側の性質でもある。Ctrl-C (プロセスグループ全体への INT) は bats も止める。
#   - .e2e_work/ 自体(空の親ディレクトリ)は並行する runner と競合せぬよう消さない。増えるものではない。
#
# 重要: 生きた multiagent / shogun に対して tests/e2e を素の環境で走らせてはならぬ。必ずこの runner 経由で。

set -u

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WRAPPER_BIN="$REPO_ROOT/tests/e2e/helpers/bin"
ISO_PARENT="$REPO_ROOT/.e2e_work"
ISO_DIR=""
NONCE=""
KEEP_FILE=""
REAL_TMUX=""
UID_NUM="$(id -u)"

die() { echo "run_e2e_isolated: $*" >&2; exit 2; }

# iso_tmux — 実 tmux を「専用ディレクトリのソケット」にだけ向けて呼ぶ。TMUX / TMUX_PANE は外し、TMUX_TMPDIR を
# 毎回ここで明示する(環境の export 前に片付けへ入っても、生きた陣の既定ソケットに届かぬ)。
iso_tmux() {
    timeout 5 env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$ISO_DIR/tmux" "$REAL_TMUX" "$@"
}

# server_state — 隔離サーバの状態: alive | gone | unknown (応答なし等。消してよい証拠にはならぬ)
server_state() {
    local out r
    out="$(iso_tmux list-sessions 2>&1)"; r=$?
    if [ "$r" -eq 0 ]; then echo alive; return 0; fi
    if [ "$r" -ne 124 ] && printf '%s' "$out" | grep -Eq 'no server running|error connecting to'; then
        echo gone; return 0
    fi
    echo unknown
}

# 隔離サーバのソケットを実 tmux から取得し、専用ディレクトリ配下・既定ソケットでないことを確認
iso_socket() {
    local s d
    s="$(iso_tmux display-message -p '#{socket_path}' 2>/dev/null)" || return 1
    s="${s%%$'\n'*}"
    [ -n "$s" ] || return 1
    d="$(cd -P "$(dirname "$s")" 2>/dev/null && pwd -P)" || return 1
    case "$d/" in "$ISO_DIR"/*) ;; *) return 1 ;; esac
    [ "$d/$(basename "$s")" != "/tmp/tmux-$UID_NUM/default" ] || return 1
    printf '%s\n' "$s"
}

summarize_log() {
    [ -s "$E2E_TMUX_WRAPPER_LOG" ] || { echo "[e2e-wrapper] no write-command attempts recorded"; return 0; }
    awk '
        { dec=$3; sub_=$4; n[dec]++; k[dec" "sub_]++ }
        END {
            printf "[e2e-wrapper] write attempts: ALLOW=%d DENY=%d\n", n["ALLOW"], n["DENY"]
            for (x in k) printf "[e2e-wrapper]   %s=%d\n", x, k[x]
            printf "[e2e-wrapper] send-keys attempts refused (would have hit a non-disposable server): %d\n", k["DENY send-keys"]
        }' "$E2E_TMUX_WRAPPER_LOG" | sort
    case "$E2E_TMUX_WRAPPER_LOG" in
        "$ISO_DIR"/*) echo "[e2e-wrapper] log: removed together with the work dir (summary above is the record)" ;;
        *)            echo "[e2e-wrapper] log: $E2E_TMUX_WRAPPER_LOG" ;;
    esac
}

# safe_remove_iso — 専用ディレクトリ ($ISO_DIR) を消す。確かめられぬときは消さず、理由を stderr に出して 1 (fail-closed)。
# 使う変数: REPO_ROOT ISO_PARENT ISO_DIR NONCE
safe_remove_iso() {
    local target parent repo base marker mdir mnonce
    refuse() { echo "run_e2e_isolated: NOT removing '${ISO_DIR:-}': $*" >&2; return 1; }

    [ -n "${ISO_DIR:-}" ] || { refuse "work dir variable is empty"; return 1; }
    [ -n "${NONCE:-}" ] || { refuse "nonce is empty (cannot prove the dir is ours)"; return 1; }
    [ -e "$ISO_DIR" ] || [ -L "$ISO_DIR" ] || return 0     # もう無い
    [ ! -L "$ISO_DIR" ] || { refuse "it is a symlink"; return 1; }

    target="$(realpath -e -- "$ISO_DIR" 2>/dev/null)" || { refuse "realpath cannot resolve it"; return 1; }
    parent="$(realpath -e -- "$ISO_PARENT" 2>/dev/null)" || { refuse "realpath cannot resolve the parent $ISO_PARENT"; return 1; }
    repo="$(realpath -e -- "$REPO_ROOT" 2>/dev/null)" || { refuse "realpath cannot resolve the repo root"; return 1; }

    [ -n "$target" ] && [ -n "$parent" ] && [ -n "$repo" ] || { refuse "an empty resolved path"; return 1; }
    [ "$repo" != "/" ] && [ "$parent" != "/" ] && [ "$target" != "/" ] || { refuse "resolves to /"; return 1; }
    [ "$target" != "${HOME:-/nonexistent}" ] && [ "$target" != "$repo" ] && [ "$target" != "$parent" ] \
        || { refuse "resolves to HOME / the repo root / the parent itself ($target)"; return 1; }
    [ "$parent" = "$repo/.e2e_work" ] || { refuse "parent '$parent' is not <repo>/.e2e_work ('$repo/.e2e_work')"; return 1; }
    [ "$(dirname "$target")" = "$parent" ] || { refuse "'$target' is not directly inside $parent"; return 1; }
    base="$(basename "$target")"
    [[ "$base" =~ ^iso\.[A-Za-z0-9]{6}$ ]] || { refuse "name '$base' is not iso.XXXXXX"; return 1; }

    marker="$target/.e2e_disposable_marker"
    [ -f "$marker" ] && [ ! -L "$marker" ] || { refuse "no disposable marker inside (not created by this runner)"; return 1; }
    mdir="$(grep -m1 '^dir=' "$marker" 2>/dev/null | cut -d= -f2-)"
    mnonce="$(grep -m1 '^nonce=' "$marker" 2>/dev/null | cut -d= -f2-)"
    [ "$mdir" = "$target" ] || { refuse "marker dir field '$mdir' does not match '$target'"; return 1; }
    [ "$mnonce" = "$NONCE" ] || { refuse "marker nonce does not match this run (a foreign directory)"; return 1; }

    # ここまで全部確かめた置場そのものにだけ rm -rf を使う
    rm -rf -- "$target" 2>/dev/null
    if [ -e "$target" ]; then
        chmod -R u+rwX -- "$target" 2>/dev/null     # 確認済みの置場の内側のみ(読取専用で残った場合)
        rm -rf -- "$target" 2>/dev/null
    fi
    [ ! -e "$target" ] || { refuse "it still exists after rm -rf"; return 1; }
    return 0
}

cleanup() {
    local rc=$? sock="" p n state left=""
    trap '' INT TERM HUP          # 片付けの最中は中断させぬ(中断されると置場が残る)
    trap - EXIT
    [ -n "$ISO_DIR" ] || exit "$rc"

    rm -f -- "$KEEP_FILE"          # 番人が自分で終わる
    state="$(server_state)"
    if [ "$state" = "alive" ]; then
        if sock="$(iso_socket)"; then
            # 残ったペインへ、人が端末でやるのと同じ C-c → exit を送る (専用ソケットと証明できたときだけ。kill は使わぬ)
            for p in $(iso_tmux list-panes -a -F '#{pane_id}' 2>/dev/null); do
                iso_tmux send-keys -t "$p" C-c 2>/dev/null || true
            done
            sleep 1
            for p in $(iso_tmux list-panes -a -F '#{pane_id}' 2>/dev/null); do
                iso_tmux send-keys -t "$p" "exit" Enter 2>/dev/null || true
            done
        fi
        for n in $(seq 1 20); do
            state="$(server_state)"
            [ "$state" = "alive" ] || break
            sleep 1
        done
    fi

    summarize_log

    if [ "$state" != "gone" ]; then
        left="isolated tmux server is still '$state'"
        echo "run_e2e_isolated: NOT removing $ISO_DIR: $left (kill is not used by design — D006)." >&2
        echo "run_e2e_isolated: left running: socket ${sock:-$ISO_DIR/tmux/tmux-$UID_NUM/default}; sessions/panes:" >&2
        iso_tmux list-panes -a -F '  #{session_name}:#{pane_id} #{pane_current_command}' 2>&1 | head -20 >&2 || true
        echo "run_e2e_isolated: it ends by itself once its panes exit; remove $ISO_DIR by hand afterwards." >&2
        [ "$rc" -ne 0 ] && exit "$rc"
        exit 3
    fi

    if ! safe_remove_iso; then
        [ "$rc" -ne 0 ] && exit "$rc"
        exit 3
    fi
    exit "$rc"
}

on_signal() { exit "$1"; }          # EXIT trap (cleanup) が走る

main() {
    command -v tmux >/dev/null 2>&1 || die "tmux not found"
    command -v bats >/dev/null 2>&1 || die "bats not found"
    command -v realpath >/dev/null 2>&1 || die "realpath not found (needed to verify the work dir before removing it)"
    [ -x "$WRAPPER_BIN/tmux" ] || chmod +x "$WRAPPER_BIN/tmux" 2>/dev/null   # core.fileMode=false の checkout 対策
    [ -x "$WRAPPER_BIN/tmux" ] || die "wrapper missing or not executable: $WRAPPER_BIN/tmux"

    # 実 tmux (ラッパを PATH に入れる前に確定)
    REAL_TMUX="$(command -v tmux)"
    if head -c 512 "$REAL_TMUX" 2>/dev/null | grep -aq "E2E_TMUX_WRAPPER_SHIM"; then
        die "tmux on PATH is already the e2e wrapper; run from a clean PATH"
    fi

    # 置場: リポジトリ内の追跡外 (<repo>/.e2e_work/iso.XXXXXX)。/tmp には作らぬ。
    [ -n "$REPO_ROOT" ] && [ "$REPO_ROOT" != "/" ] && [ -f "$REPO_ROOT/scripts/run_e2e_isolated.sh" ] \
        || die "cannot determine the repo root"
    [ ! -L "$ISO_PARENT" ] || die "$ISO_PARENT is a symlink — refusing"
    mkdir -p "$ISO_PARENT" || die "cannot create $ISO_PARENT"
    chmod 700 "$ISO_PARENT"
    ISO_DIR="$(mktemp -d "$ISO_PARENT/iso.XXXXXX")" || { ISO_DIR=""; die "mktemp failed"; }
    # 以降の終了は(die も含め)必ず cleanup を通る
    trap cleanup EXIT
    trap 'on_signal 130' INT
    trap 'on_signal 143' TERM
    trap 'on_signal 129' HUP
    chmod 700 "$ISO_DIR"
    ISO_DIR="$(cd -P "$ISO_DIR" && pwd -P)"
    NONCE="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    [ -n "$NONCE" ] || die "cannot generate nonce"
    KEEP_FILE="$ISO_DIR/.keeper_alive"
    # unix ソケットのパス長の上限(約107)。越えると tmux が起動せぬ
    [ "$(( ${#ISO_DIR} + 24 ))" -le 104 ] || die "work dir path too long for a unix socket (${#ISO_DIR} chars): $ISO_DIR"

    {
        echo "dir=$ISO_DIR"
        echo "nonce=$NONCE"
        echo "runner_pid=$$"
        echo "created=$(date -Is)"
    } > "$ISO_DIR/.e2e_disposable_marker"
    chmod 600 "$ISO_DIR/.e2e_disposable_marker"
    : > "$KEEP_FILE"
    mkdir -p "$ISO_DIR/tmux"

    # 隔離環境 (生きた陣と混ざらぬもの)
    unset TMUX TMUX_PANE
    export TMUX_TMPDIR="$ISO_DIR/tmux"
    export E2E_DISPOSABLE_DIR="$ISO_DIR"
    export E2E_DISPOSABLE_NONCE="$NONCE"
    export E2E_TMUX_WRAPPER_LOG="${E2E_TMUX_WRAPPER_LOG:-$ISO_DIR/tmux_wrapper.log}"
    export PATH="$WRAPPER_BIN:$PATH"
    : > "$E2E_TMUX_WRAPPER_LOG"
    [ "$(command -v tmux)" = "$WRAPPER_BIN/tmux" ] || die "the e2e wrapper is not first on PATH — refusing to run"

    # 隔離サーバの番人 (KEEP_FILE が消えたら自分で終わる)
    iso_tmux new-session -d -s e2e_keeper -x 200 -y 50 \
        "bash -c 'while [ -e \"$KEEP_FILE\" ]; do sleep 1; done'" \
        || die "cannot start the isolated tmux server"

    local SOCK
    SOCK="$(iso_socket)" || die "cannot prove the tmux server is isolated (socket not under $ISO_DIR, or is the default socket) — refusing to run"
    echo "[e2e-isolated] dir=$ISO_DIR socket=$SOCK"

    cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"
    if [ "$#" -eq 0 ]; then
        set -- tests/e2e/
    fi
    bats "$@"
    exit $?
}

# source された場合は関数だけを定義する(単体試験用)。直接実行されたときだけ main を走らせる。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
