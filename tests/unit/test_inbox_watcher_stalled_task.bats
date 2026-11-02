#!/usr/bin/env bats
# test_inbox_watcher_stalled_task.bats — cmd_252 / 殿命 2026-11-02(claude.ai 代筆)
#   見張り役(inbox_watcher)の busy_guard に足す『task を持ったまま待機が続く agent』の2段の起こしの試験。
#     1段目: 本人へ inbox_write.sh(from=inbox_watcher, type=info)で「task <id> が未完了のまま待機している…」
#     2段目: 1段目の後さらに20分待機のままなら、既存の reporting(scripts/ntfy.sh)の経路で殿へ ntfy
#   対象の見張り役は、差し替え前は scripts/inbox_watcher.sh.cmd252(差し替え候補)、差し替え後は scripts/inbox_watcher.sh。
#   (候補を .new でなく .cmd252 にしたのは、T-BG-P1 が『.new は残っていない』を要求しているため)
#
# 隔離(cmd_231 / cmd_234 の決まり):
#   - 試験ごとに $BATS_TEST_TMPDIR に使い捨ての木を作り、見張り役を複製して __INBOX_WATCHER_TESTING__=1 で source する。
#   - tmux は専用 TMUX_TMPDIR の別サーバ(偽ペイン)。生きた陣(multiagent / shogun)には繋がらず、キーも送らない。
#   - IDLE_FLAG_DIR=$WORK/flags(本番の /tmp/shogun_idle_* に触れない)、BUSYGUARD_STATE_DIR=$WORK/logs/watcher_busy
#     (本番の logs/watcher_busy に書かない)、INBOX_WATCHER_TEST_NOW で「いま」を注入、ntfy は BUSYGUARD_NOTIFY_CMD で写しへ
#     (本物の ntfy は送らない・dry-run)。
#   - 画面の分類(wk_screen_class)は固定値の予定表(ST_SCHED)で差し替える。idle フラグは本物の判定(ファイルの有無)を使う。
#
# T-ST-F*  発火する(assigned / in_progress + idle画面 + idleフラグ + 20分)
# T-ST-N*  発火しない(働き中・status が done 系・20分未満・フラグ無し・途中で働いた)
# T-ST-T*  30分の間引き / 2段目の ntfy(20分後・文面・働き出したら出ない)
# T-ST-L*  ログ(fail-loud: 黙って何もしない分岐が無い)
# T-ST-G*  対象(足軽・家老・軍師は task YAML 次第・将軍は対象外)
# T-ST-K*  1段目は inbox_write.sh を通る(KEY-GATE: キーを直接打たない)・from/type・失敗の扱い
# T-ST-C*  1段目が待機中の agent に意図せぬ /clear を招かない
# T-ST-S*  settings の鍵と既定値
# T-ST-W*  配線(busy_guard の箇所に足してある・新しい常駐物が無い)・隔離の確認

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
if [ -f "$SCRIPT_DIR/scripts/inbox_watcher.sh.cmd252" ]; then
    WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh.cmd252"
else
    WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh"
fi
BASE=1800000000

setup() {
    WORK="$BATS_TEST_TMPDIR/w"
    mkdir -p "$WORK"
    export WORK
    mkdir -p "$WORK/scripts" "$WORK/lib" "$WORK/config" "$WORK/queue/inbox" "$WORK/queue/tasks" \
             "$WORK/queue/metrics" "$WORK/flags" "$WORK/tmux" "$WORK/logs"
    for f in "$SCRIPT_DIR"/lib/*.sh; do cp -n "$f" "$WORK/lib/" 2>/dev/null || true; done
    cp "$SCRIPT_DIR/scripts/inbox_write.sh" "$WORK/scripts/inbox_write.sh"
    if [ -f "$SCRIPT_DIR/config/settings.yaml" ]; then
        cp "$SCRIPT_DIR/config/settings.yaml" "$WORK/config/settings.yaml"
    else
        cp "$SCRIPT_DIR/config/settings.yaml.example" "$WORK/config/settings.yaml"
    fi
    # 試験の設定は常に既定(busy_guard の節は一度消す。個別の試験が必要なら足す)
    sed -i '/^busy_guard:/,/^[a-z_]*:/{/^busy_guard:/d;/^  /d}' "$WORK/config/settings.yaml"
    ln -s "$SCRIPT_DIR/.venv" "$WORK/.venv"
    : > "$WORK/recv.log"
    : > "$WORK/notify.out"
    cat > "$WORK/notify_copy.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$(dirname "${BASH_SOURCE[0]}")/notify.out"
EOF
    chmod +x "$WORK/notify_copy.sh"
    cat > "$WORK/fakepane.sh" <<'EOF'
#!/usr/bin/env bash
mode="$1"; recv="$2"
trap '' INT
stty -echo 2>/dev/null
case "$mode" in
  working) printf 'running the task...\n✻ Working… (12s)\n  ⏵⏵ bypass permissions on · esc to interrupt\n' ;;
  idle)    printf 'done.\n❯ \n' ;;
esac
exec cat >> "$recv"
EOF
    chmod +x "$WORK/fakepane.sh"
}

teardown() {
    # 偽ペインを自然終了させる(kill 系は使わぬ・D006)
    if [ -n "${WORK:-}" ] && [ -d "$WORK/tmux" ]; then
        iso_tmux send-keys -t bgt:0.0 C-d C-d 2>/dev/null || true
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            iso_tmux list-sessions >/dev/null 2>&1 || break
            sleep 0.5
        done
    fi
}

# ── 道具 ──

iso_tmux() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$WORK/tmux" tmux "$@"; }

install_watcher() {
    cp "$1" "$WORK/scripts/inbox_watcher.sh"
    chmod +x "$WORK/scripts/inbox_watcher.sh"
}

# start_pane <working|idle>
start_pane() {
    iso_tmux new-session -d -s bgt -x 200 -y 50 "bash $WORK/fakepane.sh $1 $WORK/recv.log"
    iso_tmux set-option -p -t bgt:0.0 @agent_cli claude
    local i
    for i in $(seq 1 20); do
        if iso_tmux capture-pane -t bgt:0.0 -p 2>/dev/null | grep -q -E 'esc to interrupt|❯'; then return 0; fi
        sleep 0.25
    done
    return 1
}

# write_driver — busy_guard_tick(ST_FN=tick)または process_unread(ST_FN=cycle)を、注入した時刻で回す運転台
#   ST_AGENT   見張り対象(既定 ashigaru9)
#   ST_OFFSETS 各回の「いま」= BASE からの秒数
#   ST_SCHED   画面の予定表 "秒:値 ..."(値 0=working 1=idle 2=failed)。最後に t<=now のものが効く。空なら画面を差し替えない(本物の偽ペインを見る)
#   ST_STATUS  task YAML の status の予定表 "秒:status ..."(既定 "0:assigned")。ST_NOTASK=1 なら task YAML を作らない
#   ST_FLAG    1=idleフラグを立てる(既定) 0=立てない
#   ST_TASKID  task YAML の task_id(既定 subtask_999_A)
#   ST_AGE     cycle のとき FIRST_UNREAD_SEEN を何秒前にするか
write_driver() {
    cat > "$WORK/driver.sh" <<'EOF'
#!/usr/bin/env bash
export __INBOX_WATCHER_TESTING__=1
export AGENT_ID="${ST_AGENT:-ashigaru9}"
export PANE_TARGET=bgt:0.0
export CLI_TYPE=claude
export SCRIPT_DIR="$WORK"
export INBOX="$WORK/queue/inbox/${AGENT_ID}.yaml"
export LOCKFILE="${INBOX}.lock"
export IDLE_FLAG_DIR="$WORK/flags"
export METRICS_FILE="$WORK/queue/metrics/${AGENT_ID}_selfwatch.yaml"
export BUSYGUARD_STATE_DIR="$WORK/logs/watcher_busy"
export BUSYGUARD_NOTIFY_CMD="${BUSYGUARD_NOTIFY_CMD:-$WORK/notify_copy.sh}"
export BUSYGUARD_RESUME_GAP_SEC=1000000
export TMUX_TMPDIR="$WORK/tmux"
unset TMUX TMUX_PANE
# shellcheck disable=SC1091
source "$WORK/scripts/inbox_watcher.sh"
set -euo pipefail
sleep() { command sleep 0.1; }
sched() { # sched "t:v t:v" now → 最後に t<=now のものの v
    local s="$1" now="$2" v="" e t
    for e in $s; do t="${e%%:*}"; [ "$t" -le "$now" ] && v="${e#*:}"; done
    printf '%s' "$v"
}
CUR_V=1
if [ -n "${ST_SCHED:-}" ]; then
    wk_screen_class() { case "$CUR_V" in 0) echo working ;; 1) echo idle ;; *) echo failed ;; esac; }
fi
if [ "${ST_FLAG:-1}" = 1 ]; then touch "$IDLE_FLAG_DIR/shogun_idle_${AGENT_ID}"; else rm -f "$IDLE_FLAG_DIR/shogun_idle_${AGENT_ID}"; fi
NEW_CONTEXT_SENT=1
FIRST_UNREAD_SEEN=$((BASE - ${ST_AGE:-0}))
for off in ${ST_OFFSETS:-0}; do
    export INBOX_WATCHER_TEST_NOW=$((BASE + off))
    [ -n "${ST_SCHED:-}" ] && CUR_V="$(sched "$ST_SCHED" "$off")"
    if [ "${ST_NOTASK:-0}" != 1 ]; then
        st="$(sched "${ST_STATUS:-0:assigned}" "$off")"
        printf 'task:\n  task_id: %s\n  status: %s\n' "${ST_TASKID:-subtask_999_A}" "$st" > "$WORK/queue/tasks/${AGENT_ID}.yaml"
    else
        rm -f "$WORK/queue/tasks/${AGENT_ID}.yaml"
    fi
    if [ "${ST_FN:-tick}" = cycle ]; then process_unread timeout; else busy_guard_tick 0; fi
done
echo "DRIVER_DONE"
EOF
}

# st_run <offsets> [env...] — 状態ファイルと写しを空にして始める(ST_KEEP=1 なら続き)。ログは $WORK/driver.log
st_run() {
    local offsets="$1"; shift
    # 引数の ST_KEEP= / ST_AGENT= は運転台(env)へ渡す値であると同時に、ここでの前準備の判断にも要る
    local keep="" agent="ashigaru9" a
    for a in "$@"; do
        case "$a" in
            ST_KEEP=*) keep="${a#ST_KEEP=}" ;;
            ST_AGENT=*) agent="${a#ST_AGENT=}" ;;
        esac
    done
    install_watcher "$WATCHER"
    if [ -z "$keep" ]; then
        rm -f -- "$WORK"/logs/watcher_busy/*.state
        : > "$WORK/notify.out"
        printf 'messages: []\n' > "$WORK/queue/inbox/${agent}.yaml"
    fi
    write_driver
    run env WORK="$WORK" BASE="$BASE" ST_OFFSETS="$offsets" "$@" bash "$WORK/driver.sh"
    printf '%s\n' "$output" > "$WORK/driver.log"
    [[ "$output" == *"DRIVER_DONE"* ]]
}

# steps <from> <step> <to> — from から step 刻みで to まで。to ちょうどの時刻も必ず含める(境界の試験用)
steps() { { seq "$1" "$2" "$3"; echo "$3"; } | sort -un | tr '\n' ' '; }

notify_count() { grep -c . "$WORK/notify.out" || true; }
# 2段目(待機停滞)の通知だけの件数(既存の働き中の知らせ[cmd_231]は数えない)
stall_notify_count() { grep -c "未完了のまま待機" "$WORK/notify.out" || true; }
# 1段目(from=inbox_watcher)の件数
stall_msgs() {
    local f="$WORK/queue/inbox/${1:-ashigaru9}.yaml"
    [ -f "$f" ] || { echo 0; return 0; }
    grep -c "from: inbox_watcher" "$f" || true
}
recv() { cat "$WORK/recv.log"; }

# ═══════════════════════════════════════════════════════════════
# F. 発火する
# ═══════════════════════════════════════════════════════════════

@test "T-ST-F1: assigned + 画面idle + idleフラグが20分続くと、本人へ1段目の inbox が1通届く(from=inbox_watcher, type=info, task_id入り)" {
    st_run "$(steps 0 60 1199)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 0 ]
    st_run "$(steps 0 60 1200)" ST_SCHED="0:1"
    echo "--- inbox ---"; cat "$WORK/queue/inbox/ashigaru9.yaml"
    [ "$(stall_msgs)" -eq 1 ]
    grep -q "type: info" "$WORK/queue/inbox/ashigaru9.yaml"
    grep -q "task_id: subtask_999_A" "$WORK/queue/inbox/ashigaru9.yaml"
    grep -q "task subtask_999_A が未完了のまま待機している。裏の処理の状態を確かめて続けよ" "$WORK/queue/inbox/ashigaru9.yaml"
    grep -q "read: false" "$WORK/queue/inbox/ashigaru9.yaml"
}

@test "T-ST-F2: status が in_progress でも同じく発火する" {
    st_run "$(steps 0 60 1200)" ST_SCHED="0:1" ST_STATUS="0:in_progress"
    [ "$(stall_msgs)" -eq 1 ]
}

@test "T-ST-F3: 配線 — process_unread(未読0の周期)から呼ばれても発火する(busy_guard_tick 経由)" {
    start_pane idle
    st_run "$(steps 0 120 1200)" ST_FN=cycle ST_AGE=0
    echo "--- driver.log (抜粋) ---"; grep -E "STALLED-TASK" "$WORK/driver.log" | head
    [ "$(stall_msgs)" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════
# N. 発火しない
# ═══════════════════════════════════════════════════════════════

@test "T-ST-N1: 画面が働き中なら、何時間でも発火しない(busy)" {
    st_run "$(steps 0 300 7200)" ST_SCHED="0:0"
    [ "$(stall_msgs)" -eq 0 ]
    [ "$(stall_notify_count)" -eq 0 ]
}

@test "T-ST-N2: status が done / idle / cancelled / blocked など done 系なら発火しない" {
    local s
    for s in done idle cancelled blocked failed completed; do
        st_run "$(steps 0 60 3600)" ST_SCHED="0:1" ST_STATUS="0:$s"
        echo "status=$s msgs=$(stall_msgs)"
        [ "$(stall_msgs)" -eq 0 ]
        [ "$(stall_notify_count)" -eq 0 ]
    done
}

@test "T-ST-N3: 19分59秒(20分未満)では発火しない" {
    st_run "0 600 1199" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 0 ]
}

@test "T-ST-N4: idleフラグが無ければ発火しない(画面がidleでも)" {
    st_run "$(steps 0 60 3600)" ST_SCHED="0:1" ST_FLAG=0
    [ "$(stall_msgs)" -eq 0 ]
}

@test "T-ST-N5: 途中で働き出したら時計は数え直す(0〜900s待機 → 960sに働く → 1020sから待機: 2220s前は出ず、2220sで出る)" {
    st_run "$(steps 0 60 2219)" ST_SCHED="0:1 960:0 1020:1"
    [ "$(stall_msgs)" -eq 0 ]
    st_run "$(steps 0 60 2220)" ST_SCHED="0:1 960:0 1020:1"
    [ "$(stall_msgs)" -eq 1 ]
}

@test "T-ST-N6: 画面を取れなかった(failed)tickは時計を始めも止めもしない(保持)" {
    # 0〜600 idle、660〜1020 failed、1080〜 idle → 開始(0)から数えて1200sで出る
    st_run "$(steps 0 60 1200)" ST_SCHED="0:1 660:2 1080:1"
    [ "$(stall_msgs)" -eq 1 ]
}

@test "T-ST-N7: task が替わったら(別の task_id)時計は数え直す(新 task の20分後に出て、文面は新 task_id)" {
    st_run "$(steps 0 60 600)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 0 ]
    # 600s で別 task に替わる。状態ファイルは引き継ぐ(ST_KEEP)。旧 task の時計(0s〜)なら 1200s で出るが、数え直すので 1860s(660s+20分)
    st_run "$(steps 660 60 1859)" ST_SCHED="0:1" ST_TASKID=subtask_999_B ST_KEEP=1
    [ "$(stall_msgs)" -eq 0 ]
    st_run "$(steps 1860 60 1860)" ST_SCHED="0:1" ST_TASKID=subtask_999_B ST_KEEP=1
    [ "$(stall_msgs)" -eq 1 ]
    grep -q "task subtask_999_B" "$WORK/queue/inbox/ashigaru9.yaml"
}

# ═══════════════════════════════════════════════════════════════
# T. 30分の間引き / 2段目の ntfy
# ═══════════════════════════════════════════════════════════════

@test "T-ST-T1: 同じ task への1段目は30分に1回まで(1200s・3000s・4800s に出て、その間は出ない)" {
    st_run "$(steps 0 60 2999)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 1 ]
    st_run "$(steps 0 60 3000)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 2 ]
    st_run "$(steps 0 60 4799)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 2 ]
    st_run "$(steps 0 60 4800)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 3 ]
}

@test "T-ST-T2: 間引きは待機が途切れても同じ task なら効く(1200sに出た後、働いて戻っても30分以内は再送しない)" {
    # 1200s に1段目 → 1260s 働く → 1320s から待機 → 20分後(2520s)は資格があるが、1200s+30分=3000s まで出ない
    st_run "$(steps 0 60 2999)" ST_SCHED="0:1 1260:0 1320:1"
    [ "$(stall_msgs)" -eq 1 ]
    st_run "$(steps 0 60 3000)" ST_SCHED="0:1 1260:0 1320:1"
    [ "$(stall_msgs)" -eq 2 ]
}

@test "T-ST-T3: 1段目の後さらに20分待機のままなら2段目の ntfy が1回(2399sは0回・2400sで1回)。文面に agent・task_id・待機の分数" {
    st_run "$(steps 0 60 2399)" ST_SCHED="0:1"
    [ "$(stall_notify_count)" -eq 0 ]
    st_run "$(steps 0 60 2400)" ST_SCHED="0:1"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(stall_notify_count)" -eq 1 ]
    grep -q "ashigaru9" "$WORK/notify.out"
    grep -q "subtask_999_A" "$WORK/notify.out"
    grep -q "40分" "$WORK/notify.out"
}

@test "T-ST-T7: 殿の修正①『読んだら出さない』 — 1段目が20分後に read: true なら2段目の ntfy は出ず、待機が続けば1段目が30分間隔で繰り返される" {
    # 1200s に1段目 → 1500s に本人が既読にする → 2400s(1段目から20分)になっても ntfy は出ない
    st_run "$(steps 0 60 1500)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 1 ]
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/ashigaru9.yaml"
    st_run "$(steps 1560 60 2999)" ST_SCHED="0:1" ST_KEEP=1
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(stall_notify_count)" -eq 0 ]
    [ "$(stall_msgs)" -eq 1 ]
    grep -q "\[STALLED-TASK\].*stage2-skipped.*agent=ashigaru9.*reason=stage1_read" "$WORK/driver.log"
    # 待機が続くので、1段目は最後の送信(1200s)から30分後(3000s)に繰り返される
    st_run "$(steps 3000 60 3000)" ST_SCHED="0:1" ST_KEEP=1
    [ "$(stall_msgs)" -eq 2 ]
    [ "$(stall_notify_count)" -eq 0 ]
}

@test "T-ST-T8: 殿の修正①『未読なら出す』 — 繰り返された1段目も未読のまま20分たてば ntfy が出る(既読にした分は数えず、最新の1段目の既読で判定)" {
    st_run "$(steps 0 60 1500)" ST_SCHED="0:1"
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/ashigaru9.yaml"
    # 3000s に2通目(未読)。その20分後(4200s)まで未読 → ntfy が1回
    st_run "$(steps 1560 60 4199)" ST_SCHED="0:1" ST_KEEP=1
    [ "$(stall_msgs)" -eq 2 ]
    [ "$(stall_notify_count)" -eq 0 ]
    st_run "$(steps 4200 60 4200)" ST_SCHED="0:1" ST_KEEP=1
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(stall_notify_count)" -eq 1 ]
    grep -q "subtask_999_A" "$WORK/notify.out"
}

@test "T-ST-M1: 殿の修正② 1段目の文面に、動いていれば何も始めず手番を終えてよい・二重に走らせない・終わっていれば続きを、および既読にしてから終える、が入っている" {
    st_run "$(steps 0 60 1200)" ST_SCHED="0:1"
    local f="$WORK/queue/inbox/ashigaru9.yaml" c
    # YAML の折り返しに左右されぬよう、content を取り出して比べる
    c="$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1],encoding='utf-8'))
print([m for m in d['messages'] if m['from']=='inbox_watcher'][0]['content'])
" "$f")"
    echo "$c"
    [[ "$c" == *"task subtask_999_A が未完了のまま待機している。裏の処理の状態を確かめて続けよ"* ]]
    [[ "$c" == *"裏の処理がまだ動いているなら、何も始めずにそのまま手番を終えてよい。計測や作業をやり直さない(二重に走らせない)。終わっていれば結果を読んで続きを進めよ"* ]]
    [[ "$c" == *"この通知を既読(read: true)にしてから手番を終えよ"* ]]
}

@test "T-ST-T4: 1段目の後に働き出したなら(待機が途切れたなら)2段目の ntfy は出ない" {
    st_run "$(steps 0 60 3000)" ST_SCHED="0:1 1500:0 1560:1"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(stall_msgs)" -ge 1 ]
    [ "$(stall_notify_count)" -eq 0 ]
}

@test "T-ST-T5: 2段目の ntfy は続く間も毎tickは出ない(repeat_notify_minutes=60 間隔)" {
    st_run "$(steps 0 60 7199)" ST_SCHED="0:1"
    # 2400s(初回)・6000s(+60分) → 7199sまでで2回
    [ "$(stall_notify_count)" -eq 2 ]
}

@test "T-ST-T6: ntfy の送り先が失敗しても落ちず、毎tickは叩かず(再試行間隔)、失敗がログに残る" {
    cat > "$WORK/notify_fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "x" >> "$(dirname "${BASH_SOURCE[0]}")/notify_fail.count"
exit 7
EOF
    chmod +x "$WORK/notify_fail.sh"
    rm -f "$WORK/notify_fail.count"
    st_run "$(steps 0 60 3000)" ST_SCHED="0:1" BUSYGUARD_NOTIFY_CMD="$WORK/notify_fail.sh"
    echo "--- driver.log (抜粋) ---"; grep -E "NOTIFY|STALLED" "$WORK/driver.log" | head
    grep -q "NOTIFY-FAIL" "$WORK/driver.log"
    # 2400〜3000s の 11 tick のうち、再試行間隔(300s)ゆえ 3 回以下
    [ "$(wc -l < "$WORK/notify_fail.count")" -le 3 ]
    [ "$(stall_notify_count)" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# L. ログ(fail-loud)
# ═══════════════════════════════════════════════════════════════

@test "T-ST-L1: 発火はすべてログに残る(追跡の開始・1段目の送信・2段目の通知)。agent と task が載る" {
    st_run "$(steps 0 60 2400)" ST_SCHED="0:1"
    echo "--- STALLED-TASK ---"; grep "STALLED-TASK" "$WORK/driver.log"
    grep -q "\[STALLED-TASK\].*track.*agent=ashigaru9.*task=subtask_999_A" "$WORK/driver.log"
    grep -q "\[STALLED-TASK\].*stage1.*agent=ashigaru9.*task=subtask_999_A.*stalled_for=20m" "$WORK/driver.log"
    grep -q "\[STALLED-TASK\].*stage2.*agent=ashigaru9.*task=subtask_999_A.*stalled_for=40m" "$WORK/driver.log"
}

@test "T-ST-L2: 発火しない理由もログに残る(status が done 系・フラグ無し・働き中 …)。毎tickは出さず、理由が変わったときだけ" {
    st_run "$(steps 0 60 600)" ST_SCHED="0:1" ST_STATUS="0:done"
    echo "--- STALLED-TASK ---"; grep "STALLED-TASK" "$WORK/driver.log"
    grep -q "\[STALLED-TASK\].*skip.*agent=ashigaru9.*reason=status_done" "$WORK/driver.log"
    [ "$(grep -c "reason=status_done" "$WORK/driver.log")" -eq 1 ]
    st_run "$(steps 0 60 600)" ST_SCHED="0:1" ST_FLAG=0
    grep -q "\[STALLED-TASK\].*skip.*reason=no_idle_flag" "$WORK/driver.log"
    st_run "$(steps 0 60 600)" ST_SCHED="0:0"
    grep -q "\[STALLED-TASK\].*skip.*reason=not_idle_screen" "$WORK/driver.log"
}

@test "T-ST-L3: 1段目の間引き中もログに残る(throttled)" {
    st_run "$(steps 0 60 2700)" ST_SCHED="0:1 1260:0 1320:1"
    grep -q "\[STALLED-TASK\].*stage1-throttled" "$WORK/driver.log"
}

# ═══════════════════════════════════════════════════════════════
# G. 対象
# ═══════════════════════════════════════════════════════════════

@test "T-ST-G1: 足軽は対象(ashigaru1〜7 のどれでも)" {
    local a
    for a in ashigaru1 ashigaru7; do
        st_run "$(steps 0 60 1200)" ST_SCHED="0:1" ST_AGENT="$a"
        [ "$(stall_msgs "$a")" -eq 1 ]
    done
}

@test "T-ST-G2: 家老・軍師は task YAML を持つ(assigned)なら同じ扱い" {
    local a
    for a in karo gunshi; do
        st_run "$(steps 0 60 1200)" ST_SCHED="0:1" ST_AGENT="$a"
        [ "$(stall_msgs "$a")" -eq 1 ]
    done
}

@test "T-ST-G3: 家老・軍師は task YAML を持たないなら対象外(発火せず、理由 no_task がログに残る)" {
    local a
    for a in karo gunshi; do
        st_run "$(steps 0 60 3600)" ST_SCHED="0:1" ST_AGENT="$a" ST_NOTASK=1
        [ "$(stall_msgs "$a")" -eq 0 ]
        [ "$(stall_notify_count)" -eq 0 ]
        grep -q "\[STALLED-TASK\].*skip.*agent=$a.*reason=no_task" "$WORK/driver.log"
    done
}

@test "T-ST-G4: 将軍は対象外(task YAML があっても発火せず、ログに対象外と残る)" {
    st_run "$(steps 0 60 3600)" ST_SCHED="0:1" ST_AGENT=shogun
    [ "$(stall_msgs shogun)" -eq 0 ]
    [ "$(stall_notify_count)" -eq 0 ]
    grep -q "\[STALLED-TASK\].*skip.*agent=shogun.*reason=shogun_excluded" "$WORK/driver.log"
}

# ═══════════════════════════════════════════════════════════════
# K. 1段目は inbox_write.sh を通る(KEY-GATE)
# ═══════════════════════════════════════════════════════════════

@test "T-ST-K1: 1段目は inbox_write.sh を通る(偽ペインにキーは1つも届かない。呼び出し関数に send-keys が無い)" {
    start_pane idle
    st_run "$(steps 0 60 1200)" ST_SCHED="0:1"
    sleep 1
    [ "$(stall_msgs)" -eq 1 ]
    [ ! -s "$WORK/recv.log" ]
    # 静的: 1段目・2段目を担う関数群は tmux send-keys を直接呼ばない
    local body
    body="$(awk '/^_st_[a-z_]*\(\) *\{/,/^}/' "$WATCHER")"
    [ -n "$body" ]
    ! grep -q "send-keys" <<<"$body"
    grep -q "inbox_write.sh" <<<"$body"
}

@test "T-ST-K2: 1段目の from は本人以外(inbox_watcher)で REJECT されない・type は report_received でない(info)" {
    st_run "$(steps 0 60 1200)" ST_SCHED="0:1"
    grep -q "from: inbox_watcher" "$WORK/queue/inbox/ashigaru9.yaml"
    ! grep -q "from: ashigaru9" "$WORK/queue/inbox/ashigaru9.yaml"
    ! grep -q "type: report_received" "$WORK/queue/inbox/ashigaru9.yaml"
    ! grep -q "REJECTED" "$WORK/driver.log"
}

@test "T-ST-K3: 手引きの例文 — 裏の処理が from=bgjob / type=info で自分宛てに送ると届く。from を本人にすると REJECT される" {
    printf 'messages: []\n' > "$WORK/queue/inbox/ashigaru9.yaml"
    run bash "$WORK/scripts/inbox_write.sh" ashigaru9 "計測完了 exit=0 (task subtask_999_A)" info bgjob
    [ "$status" -eq 0 ]
    grep -q "from: bgjob" "$WORK/queue/inbox/ashigaru9.yaml"
    grep -q "type: info" "$WORK/queue/inbox/ashigaru9.yaml"
    grep -q "計測完了 exit=0" "$WORK/queue/inbox/ashigaru9.yaml"
    run bash "$WORK/scripts/inbox_write.sh" ashigaru9 "計測完了 exit=0" info ashigaru9
    [ "$status" -ne 0 ]
    [[ "$output" == *"REJECTED"* ]]
}

@test "T-ST-K4: inbox_write.sh が失敗しても見張り役は落ちず、失敗がログに残り、毎tickは叩かない(再試行間隔)" {
    cat > "$WORK/scripts/inbox_write.sh" <<'EOF'
#!/usr/bin/env bash
echo x >> "$(dirname "${BASH_SOURCE[0]}")/../iw.count"
exit 1
EOF
    rm -f "$WORK/iw.count"
    # st_run は inbox_write を上書きしないので、複製後に差し替えられるよう先に install だけ行い、driver を直接走らせる
    install_watcher "$WATCHER"
    write_driver
    printf 'messages: []\n' > "$WORK/queue/inbox/ashigaru9.yaml"
    rm -f -- "$WORK"/logs/watcher_busy/*.state
    run env WORK="$WORK" BASE="$BASE" ST_OFFSETS="$(steps 0 60 1800)" ST_SCHED="0:1" bash "$WORK/driver.sh"
    printf '%s\n' "$output" > "$WORK/driver.log"
    [[ "$output" == *"DRIVER_DONE"* ]]
    grep -q "\[STALLED-TASK\].*stage1-FAIL.*agent=ashigaru9" "$WORK/driver.log"
    # 1200〜1800s の 11 tick のうち、再試行間隔(300s)ゆえ 3 回以下
    [ "$(wc -l < "$WORK/iw.count")" -le 3 ]
    [ "$(wc -l < "$WORK/iw.count")" -ge 1 ]
}

# ═══════════════════════════════════════════════════════════════
# C. 1段目が待機中の agent に意図せぬ /clear を招かない
# ═══════════════════════════════════════════════════════════════

# c_cycle <from> — 未読が1件(from の info)だけ残る足軽(画面idle・フラグあり)に対し、未読が4分超(age 400s)の周期を回す
c_cycle() {
    local from="$1"
    install_watcher "$WATCHER"
    printf 'messages: []\n' > "$WORK/queue/inbox/ashigaru9.yaml"
    run bash "$WORK/scripts/inbox_write.sh" ashigaru9 "task subtask_999_A が未完了のまま待機している。裏の処理の状態を確かめて続けよ" info "$from" --task_id=subtask_999_A
    [ "$status" -eq 0 ]
    : > "$WORK/recv.log"
    rm -f -- "$WORK"/logs/watcher_busy/*.state
    write_driver
    run env WORK="$WORK" BASE="$BASE" ST_FN=cycle ST_AGE=400 ST_OFFSETS="0" bash "$WORK/driver.sh"
    printf '%s\n' "$output" > "$WORK/driver.log"
    sleep 1
    [[ "$output" == *"DRIVER_DONE"* ]]
}

@test "T-ST-C1: 【対照】普通の info(from=karo)が4分超 未読のまま待機中の足軽には、従来どおり /clear が送られる(試験が /clear を検出できる証明)" {
    start_pane idle
    c_cycle karo
    echo "--- driver.log (抜粋) ---"; grep -E "Phase|Sending /clear|STALLED" "$WORK/driver.log" | head
    echo "--- recv.log ---"; recv
    recv | grep -qx "/clear"
}

@test "T-ST-C2: 1段目(from=inbox_watcher の info)だけが4分超 未読でも /clear は送られない(Phase 3 を見送り、ログに残る)" {
    start_pane idle
    c_cycle inbox_watcher
    echo "--- driver.log (抜粋) ---"; grep -E "Phase|Sending /clear|STALLED" "$WORK/driver.log" | head
    echo "--- recv.log ---"; recv
    ! recv | grep -qx "/clear"
    ! grep -q "Sending /clear" "$WORK/driver.log"
    grep -q "\[STALLED-TASK\].*phase3-withheld" "$WORK/driver.log"
}

@test "T-ST-C3: 1段目に加えて別の未読(from=karo)もあるなら、従来どおり /clear の対象(1段目だけを特別扱いする)" {
    start_pane idle
    install_watcher "$WATCHER"
    printf 'messages: []\n' > "$WORK/queue/inbox/ashigaru9.yaml"
    bash "$WORK/scripts/inbox_write.sh" ashigaru9 "task subtask_999_A が未完了のまま待機している。" info inbox_watcher --task_id=subtask_999_A
    bash "$WORK/scripts/inbox_write.sh" ashigaru9 "別件の連絡" info karo
    : > "$WORK/recv.log"
    write_driver
    run env WORK="$WORK" BASE="$BASE" ST_FN=cycle ST_AGE=400 ST_OFFSETS="0" bash "$WORK/driver.sh"
    sleep 1
    [[ "$output" == *"DRIVER_DONE"* ]]
    recv | grep -qx "/clear"
}

# ═══════════════════════════════════════════════════════════════
# S. settings
# ═══════════════════════════════════════════════════════════════

print_stalled_cfg() {
    install_watcher "$WATCHER"
    run bash -c '
        export __INBOX_WATCHER_TESTING__=1 SCRIPT_DIR="'"$WORK"'" AGENT_ID=ashigaru9
        unset BUSYGUARD_STALLED_MIN BUSYGUARD_STALLED_FIRST_REPEAT_MIN BUSYGUARD_STALLED_NTFY_AFTER_MIN
        source "'"$WORK"'/scripts/inbox_watcher.sh" 2>/dev/null
        echo "$BUSYGUARD_STALLED_MIN $BUSYGUARD_STALLED_FIRST_REPEAT_MIN $BUSYGUARD_STALLED_NTFY_AFTER_MIN"
    '
}

@test "T-ST-S1: settings に鍵が無ければ既定(20/30/20)、あればその値(誤記は既定に戻る)" {
    print_stalled_cfg
    [ "$status" -eq 0 ]
    [ "$output" = "20 30 20" ]
    cat >> "$WORK/config/settings.yaml" <<'EOF'
busy_guard:
  stalled_task_minutes: 5
  stalled_first_repeat_minutes: 7
  stalled_ntfy_after_minutes: 9
EOF
    print_stalled_cfg
    [ "$output" = "5 7 9" ]
    sed -i 's/stalled_task_minutes: 5/stalled_task_minutes: abc/; s/stalled_ntfy_after_minutes: 9/stalled_ntfy_after_minutes: 0/' "$WORK/config/settings.yaml"
    print_stalled_cfg
    [ "$output" = "20 7 20" ]
}

@test "T-ST-S2: settings の値が効く(stalled_task_minutes: 2 なら2分で1段目)" {
    cat >> "$WORK/config/settings.yaml" <<'EOF'
busy_guard:
  stalled_task_minutes: 2
EOF
    st_run "$(steps 0 30 119)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 0 ]
    st_run "$(steps 0 30 120)" ST_SCHED="0:1"
    [ "$(stall_msgs)" -eq 1 ]
}

@test "T-ST-S3: config/settings.yaml.example(追跡)の busy_guard に3つの鍵があり、既定値が実効値(20/30/20)と同じ" {
    grep -A20 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "stalled_task_minutes: 20"
    grep -A20 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "stalled_first_repeat_minutes: 30"
    grep -A20 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "stalled_ntfy_after_minutes: 20"
}

# ═══════════════════════════════════════════════════════════════
# W. 配線・隔離
# ═══════════════════════════════════════════════════════════════

@test "T-ST-W1: busy_guard_tick の中から呼ばれている(新しい呼び出し口を作らず cmd_231 の箇所に足してある)" {
    local body
    body="$(awk '/^busy_guard_tick\(\) *\{/,/^}/' "$WATCHER")"
    [ -n "$body" ]
    grep -q "_st_tick" <<<"$body"
}

@test "T-ST-W2: 新しい常駐プロセス・cron を作っていない(inotifywait / nohup / crontab / 無限ループの数が本番版と同じ)" {
    local f prod cand
    for f in 'inotifywait' 'nohup' 'crontab' 'while true' 'setsid' ' & *$'; do
        prod="$(grep -c -- "$f" "$SCRIPT_DIR/scripts/inbox_watcher.sh" || true)"
        cand="$(grep -c -- "$f" "$WATCHER" || true)"
        echo "pattern=[$f] prod=$prod cand=$cand"
        [ "$prod" = "$cand" ]
    done
}

@test "T-ST-W3: 秘匿値を書いていない(候補の見張り役・試験に ntfy の topic を含む URL・鍵の値が無い。値の置場は読まない)" {
    ! grep -qiE 'ntfy\.sh/[A-Za-z0-9_-]{8,}' "$WATCHER" "$BATS_TEST_FILENAME"
    ! grep -qE 'NTFY_TOPIC''=[^ ]' "$WATCHER" "$BATS_TEST_FILENAME"
}

@test "T-ST-W4: 隔離 — 試験は本番の logs/watcher_busy/ にも /tmp の idle フラグにも触れていない" {
    local prod_state="$SCRIPT_DIR/logs/watcher_busy/ashigaru9.state"
    local before_state="absent" before_flag="absent"
    [ -e "$prod_state" ] && before_state="$(cksum < "$prod_state")"
    [ -e /tmp/shogun_idle_ashigaru9 ] && before_flag="$(stat -c %Y /tmp/shogun_idle_ashigaru9)"
    st_run "$(steps 0 60 2400)" ST_SCHED="0:1"
    local after_state="absent" after_flag="absent"
    [ -e "$prod_state" ] && after_state="$(cksum < "$prod_state")"
    [ -e /tmp/shogun_idle_ashigaru9 ] && after_flag="$(stat -c %Y /tmp/shogun_idle_ashigaru9)"
    [ "$before_state" = "$after_state" ]
    [ "$before_flag" = "$after_flag" ]
    # 状態は使い捨ての木に書かれた
    [ -f "$WORK/logs/watcher_busy/ashigaru9.state" ]
    # 本番の inbox にも書いていない(1段目は $WORK の inbox のみ)
    [ "$(stall_msgs)" -ge 1 ]
}
