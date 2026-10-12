#!/usr/bin/env bash
# run_e2e_isolated.sh — tests/e2e を「使い捨ての tmux サーバ」でだけ走らせる runner (cmd_225)
#
# 使い方:
#   bash scripts/run_e2e_isolated.sh                              # tests/e2e 全部
#   bash scripts/run_e2e_isolated.sh tests/e2e/e2e_redo.bats      # 指定ファイルのみ
#   bash scripts/run_e2e_isolated.sh --tap tests/e2e/             # bats の引数はそのまま渡る
#
# やること:
#   1. mktemp -d で専用ディレクトリ(/tmp/e2e_iso.XXXXXX, 0700)を作り、目印ファイル
#      (.e2e_disposable_marker: dir / nonce / runner_pid)を置く。
#   2. TMUX_TMPDIR をその配下に向け、TMUX / TMUX_PANE を unset する(生きた陣のソケットに繋がらぬ)。
#   3. PATH 先頭に tests/e2e/helpers/bin/tmux(ラッパ)を置く。書込系 tmux はラッパがガードを再実行し、
#      使い捨てサーバと証明できなければ exit 97 で拒否する。試行は E2E_TMUX_WRAPPER_LOG に記録される。
#   4. 隔離サーバに番人セッション(e2e_keeper)を立て、実 tmux に socket_path を問い合わせて
#      専用ディレクトリ配下かつ既定ソケット(/tmp/tmux-<uid>/default)でないことを確かめる。満たさねば bats を走らせず終了。
#   5. bats を実行し、終了時に隔離サーバだけを片付ける。最後にラッパ記録の集計を出す。
#
# 片付け: kill-server / kill-session は使わない(D006)。番人は目印ファイルが消えたら自分で終わり、
#   残ったペインへは exit を送る。サーバが残った場合は、そのソケットを表示して終わる(消さない)。
#   専用ディレクトリ(/tmp/e2e_iso.*)は記録(tmux_wrapper.log)を残すため消さない。
#   runner が終われば目印の runner_pid は死ぬので、残骸のディレクトリは使い捨ての証明として二度と通らない。
#
# 重要: 生きた multiagent / shogun に対して tests/e2e を素の環境で走らせてはならぬ。必ずこの runner 経由で。

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER_BIN="$REPO_ROOT/tests/e2e/helpers/bin"

die() { echo "run_e2e_isolated: $*" >&2; exit 2; }

command -v tmux >/dev/null 2>&1 || die "tmux not found"
command -v bats >/dev/null 2>&1 || die "bats not found"
[ -x "$WRAPPER_BIN/tmux" ] || chmod +x "$WRAPPER_BIN/tmux" 2>/dev/null   # core.fileMode=false の checkout 対策
[ -x "$WRAPPER_BIN/tmux" ] || die "wrapper missing or not executable: $WRAPPER_BIN/tmux"

# 実 tmux (ラッパを PATH に入れる前に確定)
REAL_TMUX="$(command -v tmux)"
if head -c 512 "$REAL_TMUX" 2>/dev/null | grep -aq "E2E_TMUX_WRAPPER_SHIM"; then
    die "tmux on PATH is already the e2e wrapper; run from a clean PATH"
fi

UID_NUM="$(id -u)"
ISO_DIR="$(mktemp -d /tmp/e2e_iso.XXXXXX)" || die "mktemp failed"
chmod 700 "$ISO_DIR"
ISO_DIR="$(cd -P "$ISO_DIR" && pwd -P)"
NONCE="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[ -n "$NONCE" ] || die "cannot generate nonce"
KEEP_FILE="$ISO_DIR/.keeper_alive"

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

# 隔離サーバのソケットを実 tmux から取得し、専用ディレクトリ配下・既定ソケットでないことを確認
iso_socket() {
    local s d
    s="$(timeout 5 "$REAL_TMUX" display-message -p '#{socket_path}' 2>/dev/null)" || return 1
    s="${s%%$'\n'*}"
    [ -n "$s" ] || return 1
    d="$(cd -P "$(dirname "$s")" 2>/dev/null && pwd -P)" || return 1
    case "$d/" in "$ISO_DIR"/*) ;; *) return 1 ;; esac
    [ "$d/$(basename "$s")" != "/tmp/tmux-$UID_NUM/default" ] || return 1
    printf '%s\n' "$s"
}

cleanup() {
    local sock p n
    trap - EXIT INT TERM
    rm -f "$KEEP_FILE"   # 番人が自分で終わる
    if sock="$(iso_socket)"; then
        # 残ったペインへ exit を送る (隔離サーバのみ。確認済みのときだけ)
        for p in $(timeout 5 "$REAL_TMUX" list-panes -a -F '#{pane_id}' 2>/dev/null); do
            "$REAL_TMUX" send-keys -t "$p" "exit" Enter 2>/dev/null || true
        done
        for n in 1 2 3 4 5 6 7 8 9 10; do
            "$REAL_TMUX" list-sessions >/dev/null 2>&1 || break
            sleep 1
        done
        if "$REAL_TMUX" list-sessions >/dev/null 2>&1; then
            echo "run_e2e_isolated: isolated tmux server still alive at $sock (left running; not killed by design)" >&2
        fi
    fi
    summarize_log
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
    echo "[e2e-wrapper] log: $E2E_TMUX_WRAPPER_LOG"
}
trap cleanup EXIT INT TERM

# 隔離サーバの番人 (KEEP_FILE が消えたら自分で終わる)
"$REAL_TMUX" new-session -d -s e2e_keeper -x 200 -y 50 \
    "bash -c 'while [ -e \"$KEEP_FILE\" ]; do sleep 1; done'" \
    || die "cannot start the isolated tmux server"

SOCK="$(iso_socket)" || die "cannot prove the tmux server is isolated (socket not under $ISO_DIR, or is the default socket) — refusing to run"
echo "[e2e-isolated] dir=$ISO_DIR socket=$SOCK"

cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"
if [ "$#" -eq 0 ]; then
    set -- tests/e2e/
fi
bats "$@"
exit $?
