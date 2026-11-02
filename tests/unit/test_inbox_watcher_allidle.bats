#!/usr/bin/env bats
# test_inbox_watcher_allidle.bats — cmd_255 / 殿命 2026-11-02(claude.ai 代筆)
#   見張り役(inbox_watcher)の busy_guard に足す『進行中の cmd があるのに、全員が20分待機』の2段の起こしの試験。
#     条件: 進行中の cmd が1つ以上 かつ 家老・軍師・足軽1〜7の全員が待機(画面idle かつ idleフラグあり) かつ 20分続く
#     評価するのは家老の見張り役だけ(他の watcher は評価しない)
#     1段目: 家老へ inbox_write.sh(from=inbox_watcher, type=info。殿の一文入り。同じ cmd へは30分に1回まで)
#     2段目: 1段目がさらに20分 read: false のままのときだけ ntfy で殿へ(既読なら出さない)
#     足軽ごとの停滞(cmd_252)と重なるとき(足軽に assigned/in_progress の task)は、足軽への1段目を優先し、
#     家老へはその足軽の2段目の時刻(1段目の最終送信+20分)まで送らぬ。ただし全員待機が(20+20)分続いたら必ず送る(上限)。
#
# 隔離(cmd_231 / cmd_234 / cmd_252 の決まり):
#   - 試験ごとに $BATS_TEST_TMPDIR に使い捨ての木を作り、見張り役を複製して __INBOX_WATCHER_TESTING__=1 で source する。
#   - tmux は専用 TMUX_TMPDIR の別サーバ(偽ペイン)。生きた陣(multiagent / shogun)には繋がらず、キーも送らない。
#   - IDLE_FLAG_DIR=$WORK/flags、BUSYGUARD_STATE_DIR=$WORK/logs/watcher_busy、INBOX_WATCHER_TEST_NOW で「いま」を注入、
#     ntfy は BUSYGUARD_NOTIFY_CMD で写しへ(本物の ntfy は送らない・dry-run)。ntfy の値・topic は一切扱わない。
#   - 画面の分類(wk_screen_class / _ai_peer_screen)は予定表 AI_SCHED で差し替える。idle フラグは本物の判定(ファイルの有無)。
#     ただし T-AI-P1 だけは、偽ペイン + @agent_id で本物のペイン探しと画面分類を通す。
#
# T-AI-F*  発火する        T-AI-N*  発火しない     T-AI-T*  30分の間引き / 2段目の ntfy
# T-AI-M*  文面            T-AI-L*  ログ(fail-loud) T-AI-G*  家老の見張り役だけが評価する
# T-AI-O*  足軽ごとの条件(cmd_252)との重なり        T-AI-S*  settings の鍵と既定値
# T-AI-W*  配線(新しい常駐物が無い)               T-AI-P*  本物のペイン探し
# T-AI-B*  status=blocked の cmd は進行中に数えない(cmd_256 / 殿裁定『殿の裁定待ちの cmd は進行中に数えない』)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh"
BASE=1800000000
ALL_AGENTS="karo gunshi ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7"

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
        local p
        for p in $(iso_tmux list-panes -a -F '#{pane_id}' 2>/dev/null); do
            iso_tmux send-keys -t "$p" C-d C-d 2>/dev/null || true
        done
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

# start_pane <working|idle>  — bgt:0.0 を作る(karo のペイン役)
start_pane() {
    iso_tmux new-session -d -s bgt -x 200 -y 50 "bash $WORK/fakepane.sh $1 $WORK/recv.log"
    iso_tmux set-option -p -t bgt:0.0 @agent_cli claude
    iso_tmux set-option -p -t bgt:0.0 @agent_id karo
    local i
    for i in $(seq 1 20); do
        if iso_tmux capture-pane -t bgt:0.0 -p 2>/dev/null | grep -q -E 'esc to interrupt|❯'; then return 0; fi
        sleep 0.25
    done
    return 1
}

# write_driver — busy_guard_tick(AI_FN=tick)または process_unread(AI_FN=cycle)を、注入した時刻で回す運転台
#   ST_AGENT    見張り対象(既定 karo)
#   AI_OFFSETS  各回の「いま」= BASE からの秒数
#   AI_SCHED    画面の予定表 "agent=t:v/t:v agent2=t:v" (v: 0=working 1=idle 2=failed 3=nopane)。未記載の agent は常に idle。
#               最後に t<=now のものが効く。AI_SCHED が空でも差し替える(本物の偽ペインを見るのは AI_REALPANE=1 のときだけ)
#   AI_NOFLAG   idleフラグを立てない agent(空白区切り)。他は全員立てる
#   AI_BADCMDS=1 壊れた YAML を置く
#   AI_CMDS     queue/shogun_to_karo.yaml の中身 "cmd_255=in_progress cmd_254=done"(空なら commands: [])。AI_NOCMDFILE=1 ならファイルを作らぬ
#   AI_TASKS    各 agent の task YAML "ashigaru3=assigned:subtask_x gunshi=done:subtask_y"(未記載は作らぬ)
#   AI_TICKERS  各回、karo の前に busy_guard_tick を回す agent(足軽ごとの停滞 cmd_252 との重なりの試験用)。空白区切り
#   AI_AGENTS   BUSYGUARD_ALLIDLE_AGENTS を上書き(P1 用)
write_driver() {
    cat > "$WORK/driver.sh" <<'EOF'
#!/usr/bin/env bash
export __INBOX_WATCHER_TESTING__=1
export AGENT_ID="${ST_AGENT:-karo}"
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
[ -n "${AI_AGENTS:-}" ] && export BUSYGUARD_ALLIDLE_AGENTS="$AI_AGENTS"
unset TMUX TMUX_PANE
# shellcheck disable=SC1091
source "$WORK/scripts/inbox_watcher.sh"
set -euo pipefail
sleep() { command sleep 0.1; }
CUR_NOW=0
# sched_for <agent> — AI_SCHED から agent の「いま」の値(未記載は 1=idle)
sched_for() {
    local agent="$1" ent e t v="1"
    for ent in ${AI_SCHED:-}; do
        [ "${ent%%=*}" = "$agent" ] || continue
        for e in $(printf '%s' "${ent#*=}" | tr '/' ' '); do
            t="${e%%:*}"; [ "$t" -le "$CUR_NOW" ] && v="${e#*:}"
        done
    done
    printf '%s' "$v"
}
v2cls() { case "$1" in 0) echo working ;; 1) echo idle ;; 2) echo failed ;; 3) echo nopane ;; *) echo undetermined ;; esac; }
if [ "${AI_REALPANE:-0}" != 1 ]; then
    wk_screen_class() { local c; c=$(v2cls "$(sched_for "$AGENT_ID")"); [ "$c" = nopane ] && c=failed; echo "$c"; }
    _ai_peer_screen() { v2cls "$(sched_for "$1")"; }
fi
for a in $ALL_AGENTS_LIST; do
    case " ${AI_NOFLAG:-} " in *" $a "*) rm -f "$IDLE_FLAG_DIR/shogun_idle_$a" ;; *) touch "$IDLE_FLAG_DIR/shogun_idle_$a" ;; esac
done
touch "$IDLE_FLAG_DIR/shogun_idle_shogun" "$IDLE_FLAG_DIR/shogun_idle_ashigaru9"
write_cmds() {
    [ "${AI_NOCMDFILE:-0}" = 1 ] && { rm -f "$WORK/queue/shogun_to_karo.yaml"; return 0; }
    [ "${AI_BADCMDS:-0}" = 1 ] && { printf 'commands: [\n  - id: x\n  :::\n' > "$WORK/queue/shogun_to_karo.yaml"; return 0; }
    if [ -z "${AI_CMDS:-}" ]; then printf 'commands: []\n' > "$WORK/queue/shogun_to_karo.yaml"; return 0; fi
    { echo "commands:"; local ent; for ent in $AI_CMDS; do printf -- '- id: %s\n  timestamp: "2026-11-02T00:00:00"\n  status: %s\n' "${ent%%=*}" "${ent#*=}"; done; } > "$WORK/queue/shogun_to_karo.yaml"
}
write_tasks() {
    local ent a rest
    for ent in ${AI_TASKS:-}; do
        a="${ent%%=*}"; rest="${ent#*=}"
        printf 'task:\n  task_id: %s\n  status: %s\n' "${rest#*:}" "${rest%%:*}" > "$WORK/queue/tasks/$a.yaml"
    done
}
NEW_CONTEXT_SENT=1
FIRST_UNREAD_SEEN=$((BASE - ${ST_AGE:-0}))
write_cmds
write_tasks
for off in ${AI_OFFSETS:-0}; do
    CUR_NOW=$off
    export INBOX_WATCHER_TEST_NOW=$((BASE + off))
    for t in ${AI_TICKERS:-}; do
        ( AGENT_ID="$t"; INBOX="$WORK/queue/inbox/$t.yaml"; export AGENT_ID INBOX; busy_guard_tick 0 ) || true
    done
    if [ "${AI_FN:-tick}" = cycle ]; then process_unread timeout; else busy_guard_tick 0; fi
done
echo "DRIVER_DONE"
EOF
}

# ai_run <offsets> [env...] — 状態ファイルと写しを空にして始める(AI_KEEP=1 なら続き)。ログは $WORK/driver.log
ai_run() {
    local offsets="$1"; shift
    local keep="" a
    for a in "$@"; do
        case "$a" in AI_KEEP=*) keep="${a#AI_KEEP=}" ;; esac
    done
    install_watcher "$WATCHER"
    if [ -z "$keep" ]; then
        rm -f -- "$WORK"/logs/watcher_busy/*.state
        : > "$WORK/notify.out"
        for a in $ALL_AGENTS ashigaru9 shogun; do printf 'messages: []\n' > "$WORK/queue/inbox/$a.yaml"; done
    fi
    write_driver
    run env WORK="$WORK" BASE="$BASE" ALL_AGENTS_LIST="$ALL_AGENTS" AI_OFFSETS="$offsets" "$@" bash "$WORK/driver.sh"
    printf '%s\n' "$output" > "$WORK/driver.log"
    [[ "$output" == *"DRIVER_DONE"* ]]
}

# not <cmd...> — cmd が成功したら失敗(bats は途中の `! cmd` を見逃すため)
not() { if "$@"; then return 1; else return 0; fi; }

# steps <from> <step> <to> — from から step 刻みで to まで。to ちょうどの時刻も必ず含める(境界の試験用)
steps() { { seq "$1" "$2" "$3"; echo "$3"; } | sort -un | tr '\n' ' '; }

# 全員待機の知らせ(1段目)の件数 = 家老の inbox の from=inbox_watcher かつ task_id が allidle_ で始まるもの
ai_msgs() {
    local f="$WORK/queue/inbox/${1:-karo}.yaml"
    [ -f "$f" ] || { echo 0; return 0; }
    grep -c "task_id: allidle_" "$f" || true
}
# 全員待機の2段目(ntfy)の件数
ai_notify_count() { grep -c "全員が" "$WORK/notify.out" || true; }
ai_content() {
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1],encoding='utf-8'))
print([m for m in d['messages'] if str(m.get('task_id','')).startswith('allidle_')][0]['content'])
" "$WORK/queue/inbox/karo.yaml"
}

CMD_ACTIVE="cmd_255=in_progress"

# ═══════════════════════════════════════════════════════════════
# F. 発火する
# ═══════════════════════════════════════════════════════════════

@test "T-AI-F1: 進行中の cmd + 9体全員が画面idle・idleフラグあり が20分続くと、家老へ1段目が1通(from=inbox_watcher, type=info)。1199sは0通・1200sで1通" {
    ai_run "$(steps 0 60 1199)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 0 60 1200)" AI_CMDS="$CMD_ACTIVE"
    echo "--- karo inbox ---"; cat "$WORK/queue/inbox/karo.yaml"
    [ "$(ai_msgs)" -eq 1 ]
    grep -q "type: info" "$WORK/queue/inbox/karo.yaml"
    grep -q "from: inbox_watcher" "$WORK/queue/inbox/karo.yaml"
    grep -q "read: false" "$WORK/queue/inbox/karo.yaml"
    # 他の agent の inbox には何も送られない
    [ "$(grep -c "inbox_watcher" "$WORK/queue/inbox/ashigaru1.yaml" || true)" -eq 0 ]
}

@test "T-AI-F2: 進行中の定義は lib.js(CMD_ACTIVE)から blocked を除いたもの — pending / in_progress / assigned が進行中(blocked は cmd_256 で除外: T-AI-B*)。他の cmd が終端でも1つあれば足りる" {
    local s
    for s in pending in_progress assigned; do
        ai_run "$(steps 0 60 1200)" AI_CMDS="cmd_100=done $CMD_ACTIVE cmd_101=$s"
        echo "status=$s msgs=$(ai_msgs)"
        [ "$(ai_msgs)" -eq 1 ]
    done
    ai_run "$(steps 0 60 1200)" AI_CMDS="cmd_100=done cmd_101=cancelled_by_lord cmd_102=pending"
    [ "$(ai_msgs)" -eq 1 ]
}

@test "T-AI-F3: 配線 — process_unread(未読0の周期)から呼ばれても発火する(busy_guard_tick 経由・本物の偽ペイン)" {
    start_pane idle
    ai_run "$(steps 0 120 1200)" AI_FN=cycle AI_CMDS="$CMD_ACTIVE" ST_AGE=0
    echo "--- ALL-IDLE ---"; grep "ALL-IDLE" "$WORK/driver.log" | head
    [ "$(ai_msgs)" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════
# N. 発火しない
# ═══════════════════════════════════════════════════════════════

@test "T-AI-N1: 誰か1人でも働き中なら(どの1人でも)何時間でも発火しない — karo・gunshi・足軽1〜7を1人ずつ" {
    local a
    for a in $ALL_AGENTS; do
        ai_run "$(steps 0 300 7200)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="$a=0:0"
        echo "busy=$a msgs=$(ai_msgs) notify=$(ai_notify_count)"
        [ "$(ai_msgs)" -eq 0 ]
        [ "$(ai_notify_count)" -eq 0 ]
    done
}

@test "T-AI-N2: 誰か1人でも idleフラグが無ければ(画面がidleでも)発火しない" {
    local a
    for a in $ALL_AGENTS; do
        ai_run "$(steps 0 300 3600)" AI_CMDS="$CMD_ACTIVE" AI_NOFLAG="$a"
        echo "noflag=$a msgs=$(ai_msgs)"
        [ "$(ai_msgs)" -eq 0 ]
    done
}

@test "T-AI-N3: 20分未満では発火しない(1199s)。途中で誰かが働いたら時計は数え直す(900〜959sに足軽4が働く → 960sに待機へ戻ってから20分後の2160sで出る)" {
    ai_run "$(steps 0 60 2159)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="ashigaru4=0:1/900:0/960:1"
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 0 60 2160)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="ashigaru4=0:1/900:0/960:1"
    [ "$(ai_msgs)" -eq 1 ]
}

@test "T-AI-N4: 進行中の cmd が無ければ発火しない — 全部が終端(done / done_with_caveat / superseded_* / cancelled_* / failed_*)・空・cmd ファイル無し" {
    ai_run "$(steps 0 60 3600)" AI_CMDS="cmd_1=done cmd_2=done_with_caveat cmd_3=superseded_by_cmd_075 cmd_4=cancelled_by_lord cmd_5=failed_x"
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 0 60 3600)" AI_CMDS=""
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 0 60 3600)" AI_NOCMDFILE=1
    [ "$(ai_msgs)" -eq 0 ]
    [ "$(ai_notify_count)" -eq 0 ]
}

@test "T-AI-N5: 終端の判定は scripts/done.sh と同じ — done.sh が終端とする裸の superseded / cancelled / failed も進行中に数えない" {
    ai_run "$(steps 0 60 3600)" AI_CMDS="cmd_1=superseded cmd_2=cancelled cmd_3=failed"
    [ "$(ai_msgs)" -eq 0 ]
}

@test "T-AI-N6: 画面を取れなかった(failed)・ペインが見つからぬ(nopane)tickは時計を始めも止めもしない(保持)。nopane が続けば発火せず、理由がログに残る" {
    # 足軽2が 660〜1020 の間 failed → 開始(0)から数えて1200sで出る
    ai_run "$(steps 0 60 1200)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="ashigaru2=0:1/660:2/1080:1"
    [ "$(ai_msgs)" -eq 1 ]
    # 足軽6のペインが最初からずっと無い → 何時間でも発火しない
    ai_run "$(steps 0 300 7200)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="ashigaru6=0:3"
    [ "$(ai_msgs)" -eq 0 ]
    grep -q "\[ALL-IDLE\].*skip.*reason=peer_unknown.*ashigaru6" "$WORK/driver.log"
}

@test "T-AI-N7: cmd ファイルが読めぬ(壊れた YAML)ときも発火せず、理由がログに残る(黙って進行中とみなさない)" {
    ai_run "$(steps 0 300 3600)" AI_BADCMDS=1
    [ "$(ai_msgs)" -eq 0 ]
    [ "$(ai_notify_count)" -eq 0 ]
    grep -q "\\[ALL-IDLE\\].*skip.*reason=cmds_unreadable" "$WORK/driver.log"
}

# ═══════════════════════════════════════════════════════════════
# T. 30分の間引き / 2段目の ntfy
# ═══════════════════════════════════════════════════════════════

@test "T-AI-T1: 同じ cmd への1段目は30分に1回まで(1200s・3000s・4800s に出て、その間は出ない)" {
    ai_run "$(steps 0 60 2999)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 1 ]
    ai_run "$(steps 0 60 3000)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 2 ]
    ai_run "$(steps 0 60 4799)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 2 ]
    ai_run "$(steps 0 60 4800)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 3 ]
}

@test "T-AI-T2: 間引きは待機が途切れても同じ cmd なら効く(1200sに出た後、誰かが働いて戻っても30分以内は再送しない)" {
    ai_run "$(steps 0 60 2999)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="ashigaru1=0:1/1260:0/1320:1"
    [ "$(ai_msgs)" -eq 1 ]
    ai_run "$(steps 0 60 3000)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="ashigaru1=0:1/1260:0/1320:1"
    [ "$(ai_msgs)" -eq 2 ]
}

@test "T-AI-T3: 1段目がさらに20分 read: false のままなら2段目の ntfy が1回(2399sは0回・2400sで1回)。文面に cmd と待機の分数" {
    ai_run "$(steps 0 60 2399)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_notify_count)" -eq 0 ]
    ai_run "$(steps 0 60 2400)" AI_CMDS="$CMD_ACTIVE"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(ai_notify_count)" -eq 1 ]
    grep -q "cmd_255" "$WORK/notify.out"
    grep -q "40分" "$WORK/notify.out"
}

@test "T-AI-T4: 既読なら ntfy を出さない — 1段目が20分後に read: true なら2段目は出ず(stage2-skipped)、待機が続けば1段目が30分間隔で繰り返される" {
    ai_run "$(steps 0 60 1500)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 1 ]
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/karo.yaml"
    ai_run "$(steps 1560 60 2999)" AI_CMDS="$CMD_ACTIVE" AI_KEEP=1
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(ai_notify_count)" -eq 0 ]
    [ "$(ai_msgs)" -eq 1 ]
    grep -q "\[ALL-IDLE\].*stage2-skipped.*reason=stage1_read" "$WORK/driver.log"
    ai_run "$(steps 3000 60 3000)" AI_CMDS="$CMD_ACTIVE" AI_KEEP=1
    [ "$(ai_msgs)" -eq 2 ]
    [ "$(ai_notify_count)" -eq 0 ]
}

@test "T-AI-T5: 未読なら出す — 繰り返された1段目も未読のまま20分たてば ntfy が出る(既読にした分は数えず、最新の1段目で判定)" {
    ai_run "$(steps 0 60 1500)" AI_CMDS="$CMD_ACTIVE"
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/karo.yaml"
    ai_run "$(steps 1560 60 4199)" AI_CMDS="$CMD_ACTIVE" AI_KEEP=1
    [ "$(ai_msgs)" -eq 2 ]
    [ "$(ai_notify_count)" -eq 0 ]
    ai_run "$(steps 4200 60 4200)" AI_CMDS="$CMD_ACTIVE" AI_KEEP=1
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(ai_notify_count)" -eq 1 ]
}

@test "T-AI-T6: 1段目の後に誰かが働き出した(待機が途切れた)なら、2段目の ntfy は出ない" {
    ai_run "$(steps 0 60 3000)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="gunshi=0:1/1500:0/1560:1"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(ai_msgs)" -ge 1 ]
    [ "$(ai_notify_count)" -eq 0 ]
}

@test "T-AI-T7: 2段目の ntfy は続く間も毎tickは出ない(repeat_notify_minutes=60 間隔 → 2400sと6000s)" {
    ai_run "$(steps 0 60 7199)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_notify_count)" -eq 2 ]
}

@test "T-AI-T8: ntfy の送り先が失敗しても落ちず、毎tickは叩かず(再試行間隔)、失敗がログに残る" {
    cat > "$WORK/notify_fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "x" >> "$(dirname "${BASH_SOURCE[0]}")/notify_fail.count"
exit 7
EOF
    chmod +x "$WORK/notify_fail.sh"
    rm -f "$WORK/notify_fail.count"
    ai_run "$(steps 0 60 3000)" AI_CMDS="$CMD_ACTIVE" BUSYGUARD_NOTIFY_CMD="$WORK/notify_fail.sh"
    grep -q "NOTIFY-FAIL" "$WORK/driver.log"
    [ "$(wc -l < "$WORK/notify_fail.count")" -le 3 ]
    [ "$(ai_notify_count)" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# M. 文面
# ═══════════════════════════════════════════════════════════════

@test "T-AI-M1: 1段目の文面に殿の一文が入る(cmd の id・待機の分数入り)。from は家老以外(inbox_watcher)" {
    ai_run "$(steps 0 60 1200)" AI_CMDS="$CMD_ACTIVE"
    local c
    c="$(ai_content)"
    echo "$c"
    [[ "$c" == *"cmd_255 が進行中なのに、全員が 20 分待機している。各足軽の task の status・report・裏の処理の出力を確かめ、報告漏れ・通知漏れがあれば拾って次へ進めよ。裏の処理がまだ動いているなら、何も始めずに手番を終えてよい(やり直さない)。殿の裁定待ちなら、そのまま手番を終えてよい"* ]]
    grep -q "from: inbox_watcher" "$WORK/queue/inbox/karo.yaml"
    not grep -q "from: karo" "$WORK/queue/inbox/karo.yaml"
}

@test "T-AI-M2: 進行中の cmd が複数なら文面に全部並ぶ(古い順・・区切り)" {
    ai_run "$(steps 0 60 1200)" AI_CMDS="cmd_253=in_progress cmd_255=in_progress"
    [[ "$(ai_content)" == *"cmd_253・cmd_255 が進行中なのに、全員が 20 分待機している"* ]]
}

@test "T-AI-M3: 2段目(殿への ntfy)の文面は『全員が』を含み、家老へ送った inbox が未読のままと分かる。秘匿値(NTFY_TOPIC など)を載せない" {
    ai_run "$(steps 0 60 2400)" AI_CMDS="$CMD_ACTIVE"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    grep -q "全員が" "$WORK/notify.out"
    grep -q "未読" "$WORK/notify.out"
    not grep -qi "topic\|secret\|token" "$WORK/notify.out"
}

# ═══════════════════════════════════════════════════════════════
# L. ログ(fail-loud)
# ═══════════════════════════════════════════════════════════════

@test "T-AI-L1: 発火はすべてログに残る(追跡の開始・1段目の送信・2段目の通知)。cmd が載る" {
    ai_run "$(steps 0 60 2400)" AI_CMDS="$CMD_ACTIVE"
    echo "--- ALL-IDLE ---"; grep "ALL-IDLE" "$WORK/driver.log"
    grep -q "\[ALL-IDLE\].*track.*cmds=cmd_255" "$WORK/driver.log"
    grep -q "\[ALL-IDLE\].*stage1.*cmds=cmd_255.*idle_for=20m" "$WORK/driver.log"
    grep -q "\[ALL-IDLE\].*stage2.*cmds=cmd_255.*idle_for=40m" "$WORK/driver.log"
}

@test "T-AI-L2: 発火しない理由もログに残る(進行 cmd なし・誰かが働き中・フラグ無し)。毎tickは出さず、理由が変わったときだけ" {
    ai_run "$(steps 0 60 600)" AI_CMDS="cmd_1=done"
    grep -q "\[ALL-IDLE\].*skip.*reason=no_active_cmd" "$WORK/driver.log"
    [ "$(grep -c "reason=no_active_cmd" "$WORK/driver.log")" -eq 1 ]
    ai_run "$(steps 0 60 600)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="ashigaru3=0:0"
    grep -q "\[ALL-IDLE\].*skip.*reason=peer_not_idle.*ashigaru3" "$WORK/driver.log"
    [ "$(grep -c "reason=peer_not_idle" "$WORK/driver.log")" -eq 1 ]
    ai_run "$(steps 0 60 600)" AI_CMDS="$CMD_ACTIVE" AI_NOFLAG="gunshi"
    grep -q "\[ALL-IDLE\].*skip.*reason=peer_not_idle.*gunshi" "$WORK/driver.log"
}

@test "T-AI-L3: 1段目の間引き中もログに残る(throttled)" {
    ai_run "$(steps 0 60 2700)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="ashigaru1=0:1/1260:0/1320:1"
    grep -q "\[ALL-IDLE\].*stage1-throttled" "$WORK/driver.log"
}

@test "T-AI-L4: 1段目の送信失敗は stage1-FAIL でログに残り、毎tickは叩かず(再試行間隔)、後で成功すれば送る" {
    install_watcher "$WATCHER"
    # inbox_write.sh を失敗するものに差し替える(この使い捨ての木の中だけ)
    cp "$WORK/scripts/inbox_write.sh" "$WORK/scripts/inbox_write.sh.real"
    printf '#!/usr/bin/env bash\necho x >> "%s/iw_fail.count"\nexit 9\n' "$WORK" > "$WORK/scripts/inbox_write.sh"
    chmod +x "$WORK/scripts/inbox_write.sh"
    rm -f "$WORK/iw_fail.count"
    local ia
    for ia in $ALL_AGENTS; do printf 'messages: []\n' > "$WORK/queue/inbox/$ia.yaml"; done
    write_driver
    run env WORK="$WORK" BASE="$BASE" ALL_AGENTS_LIST="$ALL_AGENTS" AI_OFFSETS="$(steps 0 60 1800)" AI_CMDS="$CMD_ACTIVE" bash "$WORK/driver.sh"
    printf '%s\n' "$output" > "$WORK/driver.log"
    [[ "$output" == *"DRIVER_DONE"* ]]
    grep -q "\[ALL-IDLE\].*stage1-FAIL" "$WORK/driver.log"
    [ "$(wc -l < "$WORK/iw_fail.count")" -le 3 ]
}

# ═══════════════════════════════════════════════════════════════
# G. 家老の見張り役だけが評価する
# ═══════════════════════════════════════════════════════════════

@test "T-AI-G1: 家老以外の見張り役(軍師・足軽1〜7・将軍・足軽9)は評価しない — 同じ条件で何時間回しても誰の inbox にも ntfy にも出ない" {
    local a
    for a in gunshi ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 ashigaru9 shogun; do
        ai_run "$(steps 0 300 7200)" AI_CMDS="$CMD_ACTIVE" ST_AGENT="$a"
        echo "agent=$a msgs(karo)=$(ai_msgs karo) msgs($a)=$(ai_msgs "$a") notify=$(ai_notify_count)"
        [ "$(ai_msgs karo)" -eq 0 ]
        [ "$(ai_msgs "$a")" -eq 0 ]
        [ "$(ai_notify_count)" -eq 0 ]
        not grep -q "\[ALL-IDLE\].*\(stage1\|stage2\|track\)" "$WORK/driver.log"
    done
}

@test "T-AI-G2: 家老以外の見張り役が評価しない理由は1回だけログに残る(reason=not_karo_watcher)" {
    ai_run "$(steps 0 300 3600)" AI_CMDS="$CMD_ACTIVE" ST_AGENT=ashigaru3
    [ "$(grep -c "\[ALL-IDLE\].*reason=not_karo_watcher" "$WORK/driver.log")" -eq 1 ]
}

@test "T-AI-G3: 全員の定義は 家老・軍師・足軽1〜7 の9体で、将軍は含まれない(将軍が働き中・フラグ無しでも発火を妨げない)" {
    ai_run "$(steps 0 60 1200)" AI_CMDS="$CMD_ACTIVE" AI_SCHED="shogun=0:0" AI_NOFLAG="shogun"
    [ "$(ai_msgs)" -eq 1 ]
    run bash -c "grep -n 'BUSYGUARD_ALLIDLE_AGENTS=' '$WATCHER' | head -1"
    echo "$output"
    [[ "$output" == *"karo gunshi ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7"* ]]
    [[ "$output" != *"shogun "* ]]
}

# ═══════════════════════════════════════════════════════════════
# O. 足軽ごとの条件(cmd_252)との重なり
# ═══════════════════════════════════════════════════════════════

@test "T-AI-O1: 足軽3に assigned の task があるとき、足軽3への1段目(1200s)を優先し、家老へはその2段目の時刻(1200s+20分=2400s)まで送らない" {
    ai_run "$(steps 0 60 2399)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="ashigaru3=assigned:subtask_300_A" AI_TICKERS="ashigaru3"
    echo "ashigaru3 stage1: $(grep -c 'from: inbox_watcher' "$WORK/queue/inbox/ashigaru3.yaml" || true) / karo: $(ai_msgs)"
    [ "$(grep -c 'from: inbox_watcher' "$WORK/queue/inbox/ashigaru3.yaml" || true)" -eq 1 ]
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 0 60 2400)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="ashigaru3=assigned:subtask_300_A" AI_TICKERS="ashigaru3"
    [ "$(ai_msgs)" -eq 1 ]
    grep -q "\[ALL-IDLE\].*deferred.*agent=ashigaru3" "$WORK/driver.log"
}

@test "T-AI-O2: 上限 — 足軽3に assigned の task があっても、その見張り役が足軽3へ1段目を送れていなければ、全員待機が40分(20+20)続いた時点で家老へ送る(永久に待たない)" {
    ai_run "$(steps 0 60 2399)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="ashigaru3=assigned:subtask_300_A"
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 0 60 2400)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="ashigaru3=assigned:subtask_300_A"
    [ "$(ai_msgs)" -eq 1 ]
}

@test "T-AI-O3: task が終端(done)の足軽・task YAML の無い足軽は優先しない — 20分で家老へ送る" {
    ai_run "$(steps 0 60 1200)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="ashigaru3=done:subtask_300_A ashigaru4=idle:none"
    [ "$(ai_msgs)" -eq 1 ]
}

@test "T-AI-O4: in_progress の task を持つ軍師も同じく優先する(足軽に限らぬ — cmd_252 の対象と同じ)" {
    ai_run "$(steps 0 60 2399)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="gunshi=in_progress:subtask_300_Q" AI_TICKERS="gunshi"
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 0 60 2400)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="gunshi=in_progress:subtask_300_Q" AI_TICKERS="gunshi"
    [ "$(ai_msgs)" -eq 1 ]
}

@test "T-AI-O5: 足軽側が既読で2段目を見送った(stage1_read)後も、足軽3へ最後に送った時刻+20分を過ぎていれば家老へ送る(2400s以降)" {
    # 足軽3の1段目(1200s)を 1500s に本人が既読にする → 足軽3の2段目は出ない。家老へは 2400s に出る
    ai_run "$(steps 0 60 1500)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="ashigaru3=assigned:subtask_300_A" AI_TICKERS="ashigaru3"
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/ashigaru3.yaml"
    ai_run "$(steps 1560 60 2399)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="ashigaru3=assigned:subtask_300_A" AI_TICKERS="ashigaru3" AI_KEEP=1
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 2400 60 2400)" AI_CMDS="$CMD_ACTIVE" AI_TASKS="ashigaru3=assigned:subtask_300_A" AI_TICKERS="ashigaru3" AI_KEEP=1
    [ "$(ai_msgs)" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════
# S. settings
# ═══════════════════════════════════════════════════════════════

@test "T-AI-S1: settings に鍵が無ければ既定(20/30/20)、あればその値(誤記は既定に戻る)" {
    install_watcher "$WATCHER"
    run bash -c "
        export __INBOX_WATCHER_TESTING__=1 AGENT_ID=karo PANE_TARGET=x:0.0 CLI_TYPE=claude SCRIPT_DIR='$WORK'
        export INBOX='$WORK/queue/inbox/karo.yaml' LOCKFILE='$WORK/queue/inbox/karo.yaml.lock'
        source '$WORK/scripts/inbox_watcher.sh' >/dev/null 2>&1
        echo \"\$BUSYGUARD_ALLIDLE_MIN \$BUSYGUARD_ALLIDLE_REPEAT_MIN \$BUSYGUARD_ALLIDLE_NTFY_AFTER_MIN\""
    echo "$output"
    [[ "$output" == *"20 30 20" ]]
    cat >> "$WORK/config/settings.yaml" <<'EOF'
busy_guard:
  all_idle_minutes: 5
  all_idle_repeat_minutes: 45
  all_idle_ntfy_after_minutes: 9
EOF
    run bash -c "
        export __INBOX_WATCHER_TESTING__=1 AGENT_ID=karo PANE_TARGET=x:0.0 CLI_TYPE=claude SCRIPT_DIR='$WORK'
        export INBOX='$WORK/queue/inbox/karo.yaml' LOCKFILE='$WORK/queue/inbox/karo.yaml.lock'
        source '$WORK/scripts/inbox_watcher.sh' >/dev/null 2>&1
        echo \"\$BUSYGUARD_ALLIDLE_MIN \$BUSYGUARD_ALLIDLE_REPEAT_MIN \$BUSYGUARD_ALLIDLE_NTFY_AFTER_MIN\""
    [[ "$output" == *"5 45 9" ]]
    sed -i 's/all_idle_minutes: 5/all_idle_minutes: abc/; s/all_idle_ntfy_after_minutes: 9/all_idle_ntfy_after_minutes: 0/' "$WORK/config/settings.yaml"
    run bash -c "
        export __INBOX_WATCHER_TESTING__=1 AGENT_ID=karo PANE_TARGET=x:0.0 CLI_TYPE=claude SCRIPT_DIR='$WORK'
        export INBOX='$WORK/queue/inbox/karo.yaml' LOCKFILE='$WORK/queue/inbox/karo.yaml.lock'
        source '$WORK/scripts/inbox_watcher.sh' >/dev/null 2>&1
        echo \"\$BUSYGUARD_ALLIDLE_MIN \$BUSYGUARD_ALLIDLE_REPEAT_MIN \$BUSYGUARD_ALLIDLE_NTFY_AFTER_MIN\""
    [[ "$output" == *"20 45 20" ]]
}

@test "T-AI-S2: settings の値が効く(all_idle_minutes: 5 なら5分で1段目)" {
    cat >> "$WORK/config/settings.yaml" <<'EOF'
busy_guard:
  all_idle_minutes: 5
EOF
    ai_run "$(steps 0 30 299)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 0 30 300)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 1 ]
}

@test "T-AI-S3: config/settings.yaml.example(追跡)の busy_guard に3つの鍵があり、既定値が実効値(20/30/20)と同じ" {
    grep -A30 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "all_idle_minutes: 20"
    grep -A30 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "all_idle_repeat_minutes: 30"
    grep -A30 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "all_idle_ntfy_after_minutes: 20"
}

# ═══════════════════════════════════════════════════════════════
# W. 配線 / 新しい常駐物が無い
# ═══════════════════════════════════════════════════════════════

@test "T-AI-W1: 配線 — busy_guard_tick が _ai_tick を呼ぶ。足した関数(_ai_*)に nohup / crontab / & による裏起動 / inotifywait が無い" {
    grep -q "_ai_tick" "$WATCHER"
    awk '/^busy_guard_tick\(\)/,/^}/' "$WATCHER" | grep -q "_ai_tick"
    local body
    body="$(awk '/^_ai_[a-z_]*\(\)/,/^}/' "$WATCHER")"
    [ -n "$body" ]
    not grep -Eq 'nohup|crontab|inotifywait|disown|setsid| & *$' <<< "$body"
}

@test "T-AI-W2: 隔離 — 運転台の ntfy は写し(BUSYGUARD_NOTIFY_CMD)で、本物の scripts/ntfy.sh を呼ばない。使い捨ての木に ntfy.sh が無い" {
    [ ! -e "$WORK/scripts/ntfy.sh" ]
    ai_run "$(steps 0 60 2400)" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_notify_count)" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════
# P. 本物のペイン探し(@agent_id)と画面分類
# ═══════════════════════════════════════════════════════════════

@test "T-AI-P1: 本物のペイン探し — 同じ tmux サーバの @agent_id で他の agent のペインを見つけ、画面の分類(idle / working)まで通る。gunshi が働き中なら発火せず、待機なら発火する" {
    start_pane idle
    # gunshi のペインを足す(働き中)
    iso_tmux split-window -t bgt:0 "bash $WORK/fakepane.sh working $WORK/recv2.log"
    iso_tmux set-option -p -t bgt:0.1 @agent_id gunshi
    local i
    for i in $(seq 1 20); do
        iso_tmux capture-pane -t bgt:0.1 -p 2>/dev/null | grep -q 'esc to interrupt' && break
        sleep 0.25
    done
    ai_run "$(steps 0 120 1800)" AI_REALPANE=1 AI_AGENTS="karo gunshi" AI_CMDS="$CMD_ACTIVE"
    echo "--- ALL-IDLE ---"; grep "ALL-IDLE" "$WORK/driver.log" | head
    [ "$(ai_msgs)" -eq 0 ]
    grep -q "\[ALL-IDLE\].*skip.*reason=peer_not_idle.*gunshi" "$WORK/driver.log"
    # gunshi を待機のペインに差し替える(働き中のペインを自然終了させて、待機のペインを作り直す)
    iso_tmux send-keys -t bgt:0.1 C-d C-d 2>/dev/null || true
    sleep 1
    iso_tmux split-window -t bgt:0 "bash $WORK/fakepane.sh idle $WORK/recv2.log"
    iso_tmux set-option -p -t bgt:0.1 @agent_id gunshi
    for i in $(seq 1 20); do
        iso_tmux capture-pane -t bgt:0.1 -p 2>/dev/null | grep -q '❯' && break
        sleep 0.25
    done
    ai_run "$(steps 0 120 1200)" AI_REALPANE=1 AI_AGENTS="karo gunshi" AI_CMDS="$CMD_ACTIVE"
    echo "--- ALL-IDLE ---"; grep "ALL-IDLE" "$WORK/driver.log" | head
    [ "$(ai_msgs)" -eq 1 ]
}

@test "T-AI-P2: 本物のペイン探しで、@agent_id を持つペインが無い agent は peer_unknown(nopane)になり、発火しない" {
    start_pane idle
    ai_run "$(steps 0 300 3600)" AI_REALPANE=1 AI_AGENTS="karo ashigaru7" AI_CMDS="$CMD_ACTIVE"
    [ "$(ai_msgs)" -eq 0 ]
    grep -q "\[ALL-IDLE\].*skip.*reason=peer_unknown.*ashigaru7" "$WORK/driver.log"
}

# ═══════════════════════════════════════════════════════════════
# B. status=blocked の cmd は進行中に数えない(cmd_256)
#    殿の裁定待ちの cmd は、陣が全員待機でも正当な待機。家老を30分ごとに起こし続けてはならぬ。
#    ただし黙って何もしない分岐は作らぬ — 発火しなかった理由は reason=all_blocked でログに残す(fail-loud)。
# ═══════════════════════════════════════════════════════════════

@test "T-AI-B1: blocked の cmd だけなら発火しない — 何時間待っても家老の inbox にも ntfy にも出ない(blocked 1件・複数件)" {
    ai_run "$(steps 0 60 3600)" AI_CMDS="cmd_253=blocked"
    [ "$(ai_msgs)" -eq 0 ]
    [ "$(ai_notify_count)" -eq 0 ]
    ai_run "$(steps 0 60 7200)" AI_CMDS="cmd_253=blocked cmd_254=blocked"
    [ "$(ai_msgs)" -eq 0 ]
    [ "$(ai_notify_count)" -eq 0 ]
}

@test "T-AI-B2: blocked と終端だけ(進行中なし)でも発火しない — all_blocked として止まる" {
    ai_run "$(steps 0 60 3600)" AI_CMDS="cmd_1=done cmd_2=cancelled_by_lord cmd_253=blocked"
    [ "$(ai_msgs)" -eq 0 ]
    [ "$(ai_notify_count)" -eq 0 ]
    grep -q "\[ALL-IDLE\].*skip.*reason=all_blocked" "$WORK/driver.log"
}

@test "T-AI-B3: blocked と進行中が混ざれば発火する — 進行中が pending / in_progress / assigned のどれでも1段目が1通(1199sは0通・1200sで1通)" {
    local s
    for s in pending in_progress assigned; do
        ai_run "$(steps 0 60 1199)" AI_CMDS="cmd_253=blocked cmd_300=$s"
        [ "$(ai_msgs)" -eq 0 ]
        ai_run "$(steps 0 60 1200)" AI_CMDS="cmd_253=blocked cmd_300=$s"
        echo "status=$s msgs=$(ai_msgs)"
        [ "$(ai_msgs)" -eq 1 ]
    done
    # blocked が先頭・末尾のどちらにあっても同じ
    ai_run "$(steps 0 60 1200)" AI_CMDS="cmd_300=in_progress cmd_253=blocked"
    [ "$(ai_msgs)" -eq 1 ]
}

@test "T-AI-B4: 混ざったときの文面・ログ・task_id には進行中の cmd だけが載り、blocked の cmd は載らない(数えない)" {
    ai_run "$(steps 0 60 2400)" AI_CMDS="cmd_253=blocked cmd_300=in_progress cmd_301=blocked"
    echo "--- karo inbox ---"; cat "$WORK/queue/inbox/karo.yaml"
    [ "$(ai_msgs)" -eq 1 ]
    grep -q "task_id: allidle_cmd_300" "$WORK/queue/inbox/karo.yaml"
    content="$(ai_content)"
    [[ "$content" == *cmd_300* ]]
    [[ "$content" != *cmd_253* ]]
    [[ "$content" != *cmd_301* ]]
    grep -q "\[ALL-IDLE\].*track.*cmds=cmd_300" "$WORK/driver.log"
    grep -q "\[ALL-IDLE\].*stage1.*cmds=cmd_300" "$WORK/driver.log"
    not grep -q "\[ALL-IDLE\].*cmds=[^ ]*cmd_253" "$WORK/driver.log"
}

@test "T-AI-B5: 発火しなかった理由が毎tickでなく1回だけ、cmd の id 入りでログに残る(reason=all_blocked blocked=…)。進行中なしの no_active_cmd とは区別される" {
    ai_run "$(steps 0 60 1800)" AI_CMDS="cmd_253=blocked cmd_254=blocked"
    echo "--- ALL-IDLE ---"; grep "ALL-IDLE" "$WORK/driver.log"
    grep -q "\[ALL-IDLE\].*skip.*reason=all_blocked.*blocked=cmd_253.*cmd_254" "$WORK/driver.log"
    [ "$(grep -c "reason=all_blocked" "$WORK/driver.log")" -eq 1 ]
    not grep -q "reason=no_active_cmd" "$WORK/driver.log"
    # blocked が1件も無い(全部終端)なら従来どおり no_active_cmd で、all_blocked は出ない
    ai_run "$(steps 0 60 600)" AI_CMDS="cmd_1=done"
    grep -q "reason=no_active_cmd" "$WORK/driver.log"
    not grep -q "reason=all_blocked" "$WORK/driver.log"
}

@test "T-AI-B6: 裁定が出て blocked が in_progress に戻れば、また数える — blocked の間に積んだ時計は捨てられ、戻した時点から20分で発火する" {
    ai_run "$(steps 0 60 1800)" AI_CMDS="cmd_253=blocked"
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 1860 60 3059)" AI_CMDS="cmd_253=in_progress" AI_KEEP=1
    [ "$(ai_msgs)" -eq 0 ]
    ai_run "$(steps 3060 60 3060)" AI_CMDS="cmd_253=in_progress" AI_KEEP=1
    [ "$(ai_msgs)" -eq 1 ]
}
