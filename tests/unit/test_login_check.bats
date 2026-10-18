#!/usr/bin/env bats
# test_login_check.bats — cmd_235 工程B: 出陣時ログイン判定(lib/login_check.sh)の試験
#
# 背景: 出陣ログで login unknown が毎回8件出ていた。判定の時点で multiagent セッションに誰も繋がず、
#       tmux 既定の小さな画面(80x24)を9つに割っていたため、狭い pane では claude の最下行
#       「⏵⏵ bypass permissions on (shift+tab to cycle)」が右端で切れ、目印が見つからなかった(偽unknown)。
#       直し = multiagent を `-x 200 -y 50` で作る + 判定関数を lib/login_check.sh へ切り出す。
#
# 隔離の作法(受入基準4・D006):
#   - 専用ソケット(-L bats_login_<pid>_<n>)の別 tmux サーバで全てを行う。tmux は関数 tmux() で差し替え、
#     lib の判定関数が呼ぶ素の `tmux` も同じ隔離サーバへ向く。-f /dev/null で利用者の tmux.conf も読まぬ。
#   - 生きた陣の shogun / multiagent には触れぬ(別ソケットゆえ名前が同じでも別サーバ。socket_path で確認する)。
#   - 停止系の命令は使わぬ。teardown は各 pane のスクリプトに Enter を送って自然終了させ、
#     サーバが空になって落ちるのを待つ。残ったソケットファイルだけ realpath で確かめて rm する。
#
# T1: 誰も繋がぬ 200x50 の 3x3 で 9 pane 全て authenticated           (受入基準1)
# T2: 既定 80x24 では旧判定が偽unknownを出し、新版(200x50)は出さぬ     (受入基準1の裏)
# T3: Not logged in は unauthenticated・同居なら優先                  (受入基準2)
# T4: 判定できる pane は待ち時間を使い切らぬ・目印なしは unknown      (受入基準3)
# T5: shutsujin_departure.sh の静的確認

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LOGIN_LIB="${LOGIN_CHECK_LIB:-$PROJECT_ROOT/lib/login_check.sh}"   # 上書きは試験自身の検証(変異版)用
    SHUTSUJIN="$PROJECT_ROOT/shutsujin_departure.sh"
    OLD_COMMIT="1789acb"   # cmd_235 着手前の shutsujin_departure.sh(旧判定)。HEAD が進んでも固定
    TEST_TMP="$(mktemp -d)"
    ISO_SOCK="bats_login_$$_${BATS_TEST_NUMBER}"
    ISO_SESSION="multiagent"
    ISO_WINDOW="agents"
    unset TMUX TMUX_PANE
    export ISO_SOCK

    # 全 tmux 呼び出しを隔離サーバへ向ける(lib の判定関数が呼ぶ素の tmux も同じ)
    tmux() { command tmux -L "$ISO_SOCK" -f /dev/null "$@"; }

    # pane に出す「claude の画面」の写し。右端で切れる(折り返さぬ)ところまで claude の TUI に倣う。
    #   $1 = 最下行の文言(空なら目印なしの画面)  $2 = 最下行の前に出す行(任意)  $3 = 描き終えたら作るファイル
    cat > "$TEST_TMP/screen.sh" <<'SCREEN'
#!/usr/bin/env bash
# claude TUI の写し: 画面を消し、折り返しを止め、最下行に文言を置く。Enter で終わる。
#   $1=最下行 $2=その少し上の行 $3=描き終えたら作るファイル $4=pane の行数
#   行数は tmux の #{pane_height} を試験側から渡す(pane 内の stty size は分割直後に古い値を返すことがある)
bottom="$1"
above="${2:-}"
rows="${4:-24}"
printf '\033[2J\033[?7l'
if [ -n "$above" ]; then
    printf '\033[%d;1H%s' $((rows - 2)) "$above"
fi
if [ -n "$bottom" ]; then
    printf '\033[%d;1H%s' "$rows" "$bottom"
fi
# 描き終えた合図(試験側が、プロンプトやコマンドのエコーでなく本当の画面を読むための待ち合わせ)
[ -n "${3:-}" ] && : > "$3"
read -r _
SCREEN
    chmod +x "$TEST_TMP/screen.sh"
}

teardown() {
    # 各 pane のスクリプトは read で待っている。Enter を送って自然終了させる(停止系の命令は使わぬ)。
    if tmux has-session -t "$ISO_SESSION" 2>/dev/null; then
        local p
        for p in $(tmux list-panes -a -F '#{pane_id}' 2>/dev/null); do
            tmux send-keys -t "$p" Enter 2>/dev/null || true
        done
        # 最後の pane が閉じればセッションが消え、サーバも空で終わる。最大3秒待つ。
        local _i
        for _i in $(seq 1 30); do
            tmux has-session -t "$ISO_SESSION" 2>/dev/null || break
            sleep 0.1
        done
        # 画面を出す前に試験が落ちた場合など、素の shell のまま残った pane は exit で閉じる
        for p in $(tmux list-panes -a -F '#{pane_id}' 2>/dev/null); do
            tmux send-keys -t "$p" 'exit' Enter 2>/dev/null || true
        done
        for _i in $(seq 1 30); do
            tmux has-session -t "$ISO_SESSION" 2>/dev/null || break
            sleep 0.1
        done
    fi
    # サーバが落ちた後に残る専用ソケットのファイルだけを、実体を確かめてから消す
    local sock_dir sock_path
    sock_dir="/tmp/tmux-$(id -u)"
    sock_path="$(realpath -m "$sock_dir/$ISO_SOCK")"
    case "$sock_path" in
        "$sock_dir"/bats_login_*) [ -S "$sock_path" ] && ! command tmux -L "$ISO_SOCK" has-session 2>/dev/null && rm -f "$sock_path" ;;
    esac
    rm -rf "$TEST_TMP"
    return 0
}

# ─── 補助 ───

# 隔離サーバに繋がっていること(生きた陣のソケットではないこと)を確かめる
assert_isolated() {
    local sp
    sp="$(tmux display-message -p -t "$ISO_SESSION:$ISO_WINDOW" '#{socket_path}')"
    [[ "$sp" == *"/bats_login_"* ]] || { echo "NOT ISOLATED: $sp"; return 1; }
}

# build_grid [WxH]
#   shutsujin_departure.sh と同じ作り(new-session -d → split-window -h x2 → 各列を split-window -v x2)で 3x3=9 pane。
#   WxH を渡すと `-x W -y H` を付ける。渡さねば既定サイズ(80x24。旧版の作り)。
build_grid() {
    local size="${1:-}"
    local -a dims=()
    if [ -n "$size" ]; then
        dims=(-x "${size%x*}" -y "${size#*x}")
    fi
    tmux new-session -d -s "$ISO_SESSION" -n "$ISO_WINDOW" "${dims[@]}"
    assert_isolated
    local base
    base="$(tmux show-options -gv pane-base-index)"
    tmux split-window -h -t "$ISO_SESSION:$ISO_WINDOW"
    tmux split-window -h -t "$ISO_SESSION:$ISO_WINDOW"
    tmux select-pane -t "$ISO_SESSION:$ISO_WINDOW.${base}"
    tmux split-window -v
    tmux split-window -v
    tmux select-pane -t "$ISO_SESSION:$ISO_WINDOW.$((base + 3))"
    tmux split-window -v
    tmux split-window -v
    tmux select-pane -t "$ISO_SESSION:$ISO_WINDOW.$((base + 6))"
    tmux split-window -v
    tmux split-window -v
    PANE_BASE="$base"
    [ "$(tmux list-panes -t "$ISO_SESSION:$ISO_WINDOW" | wc -l)" -eq 9 ]
}

# show_screen IDX BOTTOM [ABOVE]: pane IDX の shell を screen.sh に置き換えて画面を出す
show_screen() {
    local idx="$1" bottom="$2" above="${3:-}"
    local target="$ISO_SESSION:$ISO_WINDOW.$((PANE_BASE + idx))" cmd rows
    rows="$(tmux display-message -p -t "$target" '#{pane_height}')"
    rm -f "$TEST_TMP/ready_$idx"
    cmd="$(printf 'exec bash %q %q %q %q %q' "$TEST_TMP/screen.sh" "$bottom" "$above" "$TEST_TMP/ready_$idx" "$rows")"
    tmux send-keys -t "$target" "$cmd" Enter
}

# wait_rendered IDX: screen.sh が描き終えるまで待つ。最大5秒。
#   合図のファイルを待った上で、打ち込んだコマンドのエコーが画面に残っていないことも確かめる
#   (エコーには目印の文字列が含まれ、判定を偽の authenticated / unauthenticated にしてしまう)。
wait_rendered() {
    local idx="$1" target="$ISO_SESSION:$ISO_WINDOW.$((PANE_BASE + $1))" _i
    for _i in $(seq 1 50); do
        if [ -f "$TEST_TMP/ready_$idx" ] \
            && ! tmux capture-pane -t "$target" -p 2>/dev/null | grep -q 'exec bash'; then
            return 0
        fi
        sleep 0.1
    done
    echo "pane $target did not render" >&2
    return 1
}

# fill_all_panes BOTTOM [ABOVE]: 9 pane 全てに同じ画面を出し、描画を待つ
fill_all_panes() {
    local bottom="$1" above="${2:-}" i
    for i in $(seq 0 8); do
        show_screen "$i" "$bottom" "$above"
    done
    for i in $(seq 0 8); do
        wait_rendered "$i"
    done
}

# load_new_lib: 新版の判定関数を読み込む(無ければ SKIP でなく失敗にする)
load_new_lib() {
    [ -f "$LOGIN_LIB" ] || { echo "lib/login_check.sh がない: $LOGIN_LIB" >&2; return 1; }
    # shellcheck source=/dev/null
    source "$LOGIN_LIB"
    declare -F check_pane_login_status >/dev/null
}

# load_old_func: 旧版(commit 1789acb の shutsujin_departure.sh)の check_pane_login_status を取り出して定義する。
#   旧版は max_retries=5・retry_interval=2 を関数内に直書きしている。判定ロジックは変えず、
#   待ち時間だけ関数 sleep() で潰す(unknown の pane ごとに10秒待たぬため)。
load_old_func() {
    local src
    src="$(git -C "$PROJECT_ROOT" show "${OLD_COMMIT}:shutsujin_departure.sh" \
        | sed -n '/^    check_pane_login_status() {$/,/^    }$/p')"
    [ -n "$src" ] || { echo "旧関数を ${OLD_COMMIT} から取り出せない" >&2; return 1; }
    # 取り出したものが旧ロジックそのものであることの確認(bypass permissions を探すだけの作り)
    grep -q 'local max_retries=5' <<<"$src"
    grep -q 'grep -q "bypass permissions"' <<<"$src"
    eval "$src"
    sleep() { :; }
}

# assert_all_panes_show TEXT: 9 pane の画面すべてに TEXT が出ていること(試験の画面が狙い通りに描けている証明)
assert_all_panes_show() {
    local text="$1" i
    for i in $(seq 0 8); do
        tmux capture-pane -t "$ISO_SESSION:$ISO_WINDOW.$((PANE_BASE + i))" -p | grep -qF "$text" \
            || { echo "pane $i の画面に '$text' が無い"; return 1; }
    done
}

# 全 pane の判定を "idx=status" で並べて出す
statuses_of_all_panes() {
    local i
    for i in $(seq 0 8); do
        printf '%s=%s\n' "$i" "$(check_pane_login_status "$ISO_SESSION:$ISO_WINDOW.$((PANE_BASE + i))")"
    done
}

BYPASS_LINE='⏵⏵ bypass permissions on (shift+tab to cycle)'

# ═══════════════════════════════════════════════════════════════════════════
# T1: 受入基準1 — 誰も繋がぬ 200x50 の 3x3 で、ログイン済み9 pane が全て authenticated
# ═══════════════════════════════════════════════════════════════════════════

@test "T1: 200x50で作った3x3の9paneは、最下行が bypass permissions なら全て authenticated" {
    load_new_lib
    build_grid 200x50
    fill_all_panes "$BYPASS_LINE"
    assert_all_panes_show 'bypass permissions on (shift+tab to cycle)'

    # 狭くても切れぬ幅であること(前提の確認: 最も狭い pane でも最下行の目印が丸ごと入る)
    local min_w
    min_w="$(tmux list-panes -t "$ISO_SESSION:$ISO_WINDOW" -F '#{pane_width}' | sort -n | head -1)"
    echo "min pane width = $min_w"
    [ "$min_w" -ge 46 ]

    export LOGIN_CHECK_MAX_RETRIES=2 LOGIN_CHECK_RETRY_INTERVAL=1
    run statuses_of_all_panes
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '=authenticated$' <<<"$output")" -eq 9 ]
    [ "$(grep -vc '=authenticated$' <<<"$output")" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# T2: 受入基準1の裏 — 既定80x24では旧判定が偽unknownを出す。新版の作り(200x50)は出さぬ。
# ═══════════════════════════════════════════════════════════════════════════

@test "T2a: 既定80x24の9paneでは、狭いpaneの最下行が切れて旧判定は偽unknownを出す(再現)" {
    load_old_func
    build_grid
    fill_all_panes "$BYPASS_LINE"

    # 再現の前提: 画面が既定の 80x24 で、最下行の目印が入りきらぬ pane がある
    [ "$(tmux display-message -p -t "$ISO_SESSION:$ISO_WINDOW" '#{window_width}x#{window_height}')" = "80x24" ]
    local narrow
    narrow="$(tmux list-panes -t "$ISO_SESSION:$ISO_WINDOW" -F '#{pane_width}' | awk '$1 < 36' | wc -l)"
    echo "narrow panes (<36 cols) = $narrow"
    [ "$narrow" -ge 1 ]

    run statuses_of_all_panes
    echo "$output"
    [ "$status" -eq 0 ]
    # 全員ログイン済みなのに、旧判定は unknown を出す(偽陽性。実事象は8件)
    [ "$(grep -c '=unknown$' <<<"$output")" -ge 1 ]
    # 切れなかった pane は旧判定でも通る(家老の pane が通ったという実測と整合)
    [ "$(grep -c '=authenticated$' <<<"$output")" -ge 1 ]
    [ "$(grep -c '=unauthenticated$' <<<"$output")" -eq 0 ]
}

@test "T2b: 同じ画面を200x50で作ると、旧判定でも新判定でも偽unknownは出ない(対の片割れ)" {
    load_new_lib
    build_grid 200x50
    fill_all_panes "$BYPASS_LINE"

    export LOGIN_CHECK_MAX_RETRIES=2 LOGIN_CHECK_RETRY_INTERVAL=1
    run statuses_of_all_panes
    echo "new: $output"
    [ "$(grep -c '=unknown$' <<<"$output")" -eq 0 ]
    [ "$(grep -c '=authenticated$' <<<"$output")" -eq 9 ]

    # 旧判定を同じ 9 pane に当てても unknown は出ない(= 偽unknownの原因は画面の狭さであって、判定語ではない)
    load_old_func
    run statuses_of_all_panes
    echo "old: $output"
    [ "$(grep -c '=unknown$' <<<"$output")" -eq 0 ]
    [ "$(grep -c '=authenticated$' <<<"$output")" -eq 9 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# T3: 受入基準2 — Not logged in は unauthenticated(どの幅でも)・同居なら優先
# ═══════════════════════════════════════════════════════════════════════════

@test "T3a: 200x50のpaneに Not logged in が出ていれば unauthenticated" {
    load_new_lib
    build_grid 200x50
    fill_all_panes '' 'Not logged in · Run /login'

    export LOGIN_CHECK_MAX_RETRIES=2 LOGIN_CHECK_RETRY_INTERVAL=1
    run statuses_of_all_panes
    echo "$output"
    [ "$(grep -c '=unauthenticated$' <<<"$output")" -eq 9 ]
}

@test "T3b: 既定80x24の狭いpaneでも、Not logged in の画面は unauthenticated(幅に依らぬ)" {
    load_new_lib
    build_grid
    # 狭い pane でも入る短い文言(右端で切れない長さ)
    fill_all_panes '' 'Not logged in'
    assert_all_panes_show 'Not logged in'

    local min_w
    min_w="$(tmux list-panes -t "$ISO_SESSION:$ISO_WINDOW" -F '#{pane_width}' | sort -n | head -1)"
    echo "min pane width = $min_w"
    [ "$min_w" -lt 36 ]   # 狭い pane を含む画面であること

    export LOGIN_CHECK_MAX_RETRIES=2 LOGIN_CHECK_RETRY_INTERVAL=1
    run statuses_of_all_panes
    echo "$output"
    [ "$(grep -c '=unauthenticated$' <<<"$output")" -eq 9 ]
}

@test "T3c: Not logged in と bypass permissions が同居したら unauthenticated を優先する" {
    load_new_lib
    build_grid 200x50
    fill_all_panes "$BYPASS_LINE" 'Not logged in · Run /login'
    # 同居の前提: 全 pane に両方の文言が実際に出ている
    assert_all_panes_show 'Not logged in'
    assert_all_panes_show 'bypass permissions'

    export LOGIN_CHECK_MAX_RETRIES=2 LOGIN_CHECK_RETRY_INTERVAL=1
    run statuses_of_all_panes
    echo "$output"
    [ "$(grep -c '=unauthenticated$' <<<"$output")" -eq 9 ]
    [ "$(grep -c '=authenticated$' <<<"$output")" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════
# T4: 受入基準3 — 判定できる pane は待ち時間を使い切らぬ。目印なしは unknown
# ═══════════════════════════════════════════════════════════════════════════

# 判定1回の所要秒(整数)を $ELAPSED、結果を $RESULT に入れる
time_check() {
    local target="$1" t0 t1
    t0=$(date +%s.%N)
    RESULT="$(check_pane_login_status "$target")"
    t1=$(date +%s.%N)
    ELAPSED="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
}

@test "T4a: 待ち間隔を10秒にしても、authenticated の pane は3秒未満で返る" {
    load_new_lib
    build_grid 200x50
    fill_all_panes "$BYPASS_LINE"

    export LOGIN_CHECK_MAX_RETRIES=5 LOGIN_CHECK_RETRY_INTERVAL=10
    time_check "$ISO_SESSION:$ISO_WINDOW.${PANE_BASE}"
    echo "result=$RESULT elapsed=${ELAPSED}s"
    [ "$RESULT" = "authenticated" ]
    awk -v e="$ELAPSED" 'BEGIN { exit !(e < 3) }'
}

@test "T4b: 待ち間隔を10秒にしても、unauthenticated の pane は3秒未満で返る" {
    load_new_lib
    build_grid 200x50
    fill_all_panes '' 'Not logged in · Run /login'

    export LOGIN_CHECK_MAX_RETRIES=5 LOGIN_CHECK_RETRY_INTERVAL=10
    time_check "$ISO_SESSION:$ISO_WINDOW.${PANE_BASE}"
    echo "result=$RESULT elapsed=${ELAPSED}s"
    [ "$RESULT" = "unauthenticated" ]
    awk -v e="$ELAPSED" 'BEGIN { exit !(e < 3) }'
}

@test "T4c: 9paneを続けて判定しても合計3秒未満(既定の2秒×5回を一つも踏まぬ)" {
    load_new_lib
    build_grid 200x50
    fill_all_panes "$BYPASS_LINE"

    export LOGIN_CHECK_MAX_RETRIES=5 LOGIN_CHECK_RETRY_INTERVAL=10
    local t0 t1 total
    t0=$(date +%s.%N)
    run statuses_of_all_panes
    t1=$(date +%s.%N)
    total="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
    echo "$output"
    echo "total=${total}s"
    [ "$(grep -c '=authenticated$' <<<"$output")" -eq 9 ]
    awk -v e="$total" 'BEGIN { exit !(e < 3) }'
}

@test "T4d: 目印のない pane は MAX_RETRIES=2・INTERVAL=1 で絞れば unknown を返し、待つのは間隔分だけ" {
    load_new_lib
    build_grid 200x50
    fill_all_panes 'Welcome to a shell with no marker'

    export LOGIN_CHECK_MAX_RETRIES=2 LOGIN_CHECK_RETRY_INTERVAL=1
    time_check "$ISO_SESSION:$ISO_WINDOW.${PANE_BASE}"
    echo "result=$RESULT elapsed=${ELAPSED}s"
    [ "$RESULT" = "unknown" ]
    # 2回試して各回の後に1秒待つ = 約2秒。使い切るが、既定の10秒には達しない
    awk -v e="$ELAPSED" 'BEGIN { exit !(e >= 1.5 && e < 5) }'
}

@test "T4e: 環境変数を与えぬ既定でも、authenticated の pane は2秒未満で返る(既定値で待ちを踏まぬ)" {
    load_new_lib
    build_grid 200x50
    fill_all_panes "$BYPASS_LINE"

    unset LOGIN_CHECK_MAX_RETRIES LOGIN_CHECK_RETRY_INTERVAL
    time_check "$ISO_SESSION:$ISO_WINDOW.${PANE_BASE}"
    echo "result=$RESULT elapsed=${ELAPSED}s"
    [ "$RESULT" = "authenticated" ]
    awk -v e="$ELAPSED" 'BEGIN { exit !(e < 2) }'
}

@test "T4f: 存在しない pane は例外にならず unknown を返す(観測失敗を unauthenticated へ断定せぬ)" {
    load_new_lib
    build_grid 200x50
    fill_all_panes "$BYPASS_LINE"

    export LOGIN_CHECK_MAX_RETRIES=2 LOGIN_CHECK_RETRY_INTERVAL=0
    run check_pane_login_status "$ISO_SESSION:$ISO_WINDOW.99"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

# ═══════════════════════════════════════════════════════════════════════════
# T5: 静的確認 — shutsujin_departure.sh が直しを実際に使っていること(配線)
# ═══════════════════════════════════════════════════════════════════════════

@test "T5a: shutsujin_departure.sh の multiagent の new-session 行に -x 200 -y 50 がある" {
    run grep -nE 'tmux new-session -d -s multiagent .*-x 200 -y 50' "$SHUTSUJIN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "T5b: shutsujin_departure.sh が lib/login_check.sh を source している" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]+"?\$(\{)?SCRIPT_DIR(\})?/lib/login_check\.sh"?' "$SHUTSUJIN"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "T5c: shutsujin_departure.sh に判定関数の定義が残っていない(lib 側が唯一の定義)" {
    run grep -nE '^[[:space:]]*check_pane_login_status\(\)' "$SHUTSUJIN"
    echo "$output"
    [ "$status" -ne 0 ]
    # 一方 lib 側には定義がある
    run grep -nE '^check_pane_login_status\(\)' "$LOGIN_LIB"
    [ "$status" -eq 0 ]
}

@test "T5d: 判定の待ち時間の既定(5回・2秒)が lib に残り、環境変数で上書きできる" {
    run grep -nE 'LOGIN_CHECK_MAX_RETRIES:-5' "$LOGIN_LIB"
    [ "$status" -eq 0 ]
    run grep -nE 'LOGIN_CHECK_RETRY_INTERVAL:-2' "$LOGIN_LIB"
    [ "$status" -eq 0 ]
}
