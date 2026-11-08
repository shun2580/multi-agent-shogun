#!/usr/bin/env bats
# test_inbox_watcher_one_lord_notice.bats — cmd_268 ■2-1 / 殿裁定 2026-11-08 23:36
#   同じ止まりで、①(未読が残る・30+30分)と②(待機と言い切れぬ状態が連続60分)が同時に満ちると、
#   殿へ ⏳ が2通同時に届いた(cmd_267 の申し送り)。1回の止まりで殿への ⏳ は1通にまとめたことを縛る試験。
#   直したもの: 殿へ ⏳ を出す2経路(①未読・②連続)は、他方が repeat_notify_minutes 以内に殿へ出していれば出さぬ(先に出した方が持つ)。
#   変えぬもの: 閾値(未読30・連続60・再通知60)・知らせの順序(まず家老・30分で殿)・足軽へキーを送らぬ作り・
#               家老自身の止まりは直接殿へ・家老への inbox_write 失敗は即殿へ(fail-safe)。
#   対象の見張り役は、差し替え前は scripts/inbox_watcher.sh.cmd268(差し替え候補)、差し替え後は scripts/inbox_watcher.sh。
#
# 隔離(cmd_231 / cmd_252 の決まり): 試験ごとに $BATS_TEST_TMPDIR に使い捨ての木を作る。本物の ntfy は送らぬ
#   (BUSYGUARD_NOTIFY_CMD で写しへ)。時刻は INBOX_WATCHER_TEST_NOW で注入。画面の分類は固定値で差し替え。生きた陣へは繋がらぬ。
#
# T-ON-A*  未読と連続が同時に満ちる止まりで、殿への ⏳ は1通(その後の再通知も1通ずつ)
# T-ON-B*  どちらか片方しか満ちぬ場面は従来どおり(重複抑止が余計な抑止をせぬ・ntfy 失敗時は他方が出る)
# T-ON-C*  閾値・順序・fail-safe は変わらぬ

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
if [ -f "$SCRIPT_DIR/scripts/inbox_watcher.sh.cmd268" ]; then
    WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh.cmd268"
else
    WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh"
fi
BASE_WATCHER_COMMIT="9ca721c"   # cmd_268 着手前の HEAD
BASE=1800000000
MIN=60

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
    # 試験の設定は常に既定(busy_guard の節は一度消す)
    sed -i '/^busy_guard:/,/^[a-z_]*:/{/^busy_guard:/d;/^  /d}' "$WORK/config/settings.yaml"
    ln -s "$SCRIPT_DIR/.venv" "$WORK/.venv"
    : > "$WORK/recv.log"
    : > "$WORK/notify.out"
    cat > "$WORK/notify_copy.sh" <<'NEOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$(dirname "${BASH_SOURCE[0]}")/notify.out"
NEOF
    chmod +x "$WORK/notify_copy.sh"
    # 偽ペイン(働き中の画面)。受け取った入力は recv.log へ(キーを送っていないことの確認用)
    cat > "$WORK/fakepane.sh" <<'NEOF'
#!/usr/bin/env bash
recv="$1"
trap '' INT
stty -echo 2>/dev/null
printf 'running the task...\n✻ Working… (12s)\n  ⏵⏵ bypass permissions on · esc to interrupt\n'
exec cat >> "$recv"
NEOF
    chmod +x "$WORK/fakepane.sh"
    write_inbox ashigaru9 false
    cat > "$WORK/queue/tasks/ashigaru9.yaml" <<'NEOF'
task:
  task_id: subtask_999_A
  status: assigned
NEOF
    cp "$WATCHER" "$WORK/scripts/inbox_watcher.sh"
    chmod +x "$WORK/scripts/inbox_watcher.sh"
    iso_tmux new-session -d -s bgt -x 200 -y 50 "bash $WORK/fakepane.sh $WORK/recv.log"
    iso_tmux set-option -p -t bgt:0.0 @agent_cli claude
    local i
    for i in $(seq 1 20); do
        if iso_tmux capture-pane -t bgt:0.0 -p 2>/dev/null | grep -q 'esc to interrupt'; then break; fi
        sleep 0.25
    done
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

# write_inbox <agent> <read:true|false> — 未読(または既読)1件の inbox
write_inbox() {
    cat > "$WORK/queue/inbox/$1.yaml" <<NEOF
messages:
- cmd_id: cmd_999
  content: タスクYAMLを読んで作業開始せよ。
  from: karo
  id: msg_t1
  read: $2
  task_id: subtask_999_A
  timestamp: '2026-10-12T22:00:00'
  type: task_assigned
NEOF
}

write_driver() {
    cat > "$WORK/driver.sh" <<'NEOF'
#!/usr/bin/env bash
export __INBOX_WATCHER_TESTING__=1
export AGENT_ID="${UK_AGENT:-ashigaru9}"
export PANE_TARGET=bgt:0.0
export CLI_TYPE=claude
export SCRIPT_DIR="$WORK"
export INBOX="$WORK/queue/inbox/${AGENT_ID}.yaml"
export LOCKFILE="${INBOX}.lock"
export IDLE_FLAG_DIR="$WORK/flags"
export METRICS_FILE="$WORK/queue/metrics/${AGENT_ID}_selfwatch.yaml"
export BUSYGUARD_STATE_DIR="$WORK/logs/watcher_busy"
export BUSYGUARD_NOTIFY_CMD="$WORK/notify_copy.sh"
export TMUX_TMPDIR="$WORK/tmux"
unset TMUX TMUX_PANE
# shellcheck disable=SC1091
source "$WORK/scripts/inbox_watcher.sh"
set -euo pipefail
sleep() { command sleep 0.1; }
agent_is_busy_check() { return "$(cat "$WORK/verdict")"; }
wk_screen_class() { case "$(cat "$WORK/verdict")" in 0) echo working ;; 1) echo idle ;; *) echo failed ;; esac; }
NEW_CONTEXT_SENT=1
FIRST_UNREAD_SEEN=$BASE
for off in ${UK_OFFSETS:-0}; do
    export INBOX_WATCHER_TEST_NOW=$((BASE + off))
    process_unread timeout
done
echo "DRIVER_DONE"
NEOF
}

# uk_run <verdict 0=working 1=idle> <offsets(秒)> [env...] — 毎回新規(UK_KEEP=1 なら続き)
uk_run() {
    local verdict="$1" offsets="$2"; shift 2
    if [ -z "${UK_KEEP:-}" ]; then
        rm -f -- "$WORK"/logs/watcher_busy/*.state "$WORK/queue/inbox/karo.yaml"
        : > "$WORK/notify.out"
    fi
    printf '%s' "$verdict" > "$WORK/verdict"
    write_driver
    run env WORK="$WORK" BASE="$BASE" UK_OFFSETS="$offsets" BUSYGUARD_RESUME_GAP_SEC=1000000 "$@" bash "$WORK/driver.sh"
    printf '%s\n' "$output" > "$WORK/driver.log"
    [[ "$output" == *"DRIVER_DONE"* ]]
}

# 5分刻みの時刻列 [from,to](分)
offs() { local t out=""; for t in $(seq $(( $1 * MIN )) 300 $(( $2 * MIN ))); do out="$out $t"; done; echo "$out"; }

notify_count() { grep -c . "$WORK/notify.out" || true; }
# ①(未読が残る)の殿への ntfy の数。②(連続60分)は未読30分+家老へ30分=60分と重なって同時に出るので、①だけを数える
unread_ntfy_count() { grep -c "未読[0-9?]*件が[0-9]*分残っている" "$WORK/notify.out" || true; }
# 家老の inbox にある inbox_watcher 発の info の数
karo_notice_count() {
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
except Exception:
    d = {}
print(sum(1 for m in (d.get('messages') or []) if m.get('from') == 'inbox_watcher' and m.get('type') == 'info'))
" "$WORK/queue/inbox/karo.yaml" 2>/dev/null || echo 0
}
karo_field() {  # karo_field <field> — 家老 inbox の最初の通知のフィールド
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
ms = [m for m in d.get('messages', []) if m.get('from') == 'inbox_watcher']
print(ms[0].get(sys.argv[2], '') if ms else '')
" "$WORK/queue/inbox/karo.yaml" "$1"
}


# 殿への ⏳ の数(①未読・②連続の両方を数える)
lord_notice_count() { grep -c "⏳" "$WORK/notify.out" || true; }
unread_ntfy_count() { grep -c "未読[0-9?]*件が[0-9]*分残っている" "$WORK/notify.out" || true; }
continuous_ntfy_count() { grep -c "分連続している" "$WORK/notify.out" || true; }

# ═══════════════════════════════════════════════════════════════
# A. 未読と連続が同時に満ちる止まり: 殿への ⏳ は1通
# ═══════════════════════════════════════════════════════════════

@test "T-ON-A1: 未読(30+30分)と連続(60分)が同じ60分で満ちても、殿への ⏳ は1通(家老へは1通)" {
    uk_run 0 "$(offs 0 59)"
    [ "$(lord_notice_count)" -eq 0 ]
    uk_run 0 "$(offs 0 61)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(lord_notice_count)" -eq 1 ]
    [ "$(unread_ntfy_count)" -eq 1 ]
    [ "$(karo_notice_count)" -eq 1 ]
}

@test "T-ON-A2: 続く止まりの再通知も60分ごとに1通ずつ(60分で1通 → 119分まで増えず → 120分で2通)" {
    uk_run 0 "$(offs 0 119)"
    [ "$(lord_notice_count)" -eq 1 ]
    uk_run 0 "$(offs 0 121)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(lord_notice_count)" -eq 2 ]
    [ "$(karo_notice_count)" -eq 1 ]
    uk_run 0 "$(offs 0 181)"
    [ "$(lord_notice_count)" -eq 3 ]
}

@test "T-ON-A3: 連続が先に出て、後から未読の2段目が満ちても(80分)、60分以内なら殿へ重ねて出さぬ" {
    write_inbox ashigaru9 true
    uk_run 0 "$(offs 0 20)"
    write_inbox ashigaru9 false
    # 未読の起点は21分 → 家老へ51分・殿へ81分。連続は60分に先に出る
    UK_KEEP=1 uk_run 0 "$(offs 21 85)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(continuous_ntfy_count)" -eq 1 ]
    [ "$(unread_ntfy_count)" -eq 0 ]
    [ "$(lord_notice_count)" -eq 1 ]
    [ "$(karo_notice_count)" -eq 1 ]
}

@test "T-ON-A3b: 連続が先に出た止まりでも、抑止し続けて殿へ永久に出なくなることはない(60分ごとに1通ずつ続く)" {
    write_inbox ashigaru9 true
    uk_run 0 "$(offs 0 20)"
    write_inbox ashigaru9 false
    UK_KEEP=1 uk_run 0 "$(offs 21 125)"
    [ "$(lord_notice_count)" -eq 2 ]
    UK_KEEP=1 uk_run 0 "$(offs 126 185)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(lord_notice_count)" -eq 3 ]
}

@test "T-ON-A4: 家老の見張り役(AGENT_ID=karo)も同じ: 30分の直接 ntfy の後、60分の連続は重ねて出さぬ" {
    cp "$WORK/queue/inbox/ashigaru9.yaml" "$WORK/queue/inbox/karo.yaml"
    cat > "$WORK/queue/tasks/karo.yaml" <<'NEOF'
task:
  task_id: subtask_999_K
  status: assigned
NEOF
    rm -f -- "$WORK"/logs/watcher_busy/*.state; : > "$WORK/notify.out"
    UK_KEEP=1 uk_run 0 "$(offs 0 61)" UK_AGENT=karo
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(lord_notice_count)" -eq 1 ]
    grep -q "self_is_karo" "$WORK/driver.log"
}

# ═══════════════════════════════════════════════════════════════
# B. 片方しか満ちぬ場面は従来どおり(余計な抑止をせぬ・ntfy 失敗時は他方が出る)
# ═══════════════════════════════════════════════════════════════

@test "T-ON-B1: 連続だけが満ちる(未読0)場面は従来どおり60分で1通" {
    write_inbox ashigaru9 true
    uk_run 0 "$(offs 0 59)"
    [ "$(lord_notice_count)" -eq 0 ]
    uk_run 0 "$(offs 0 61)"
    [ "$(lord_notice_count)" -eq 1 ]
    [ "$(continuous_ntfy_count)" -eq 1 ]
    [ "$(karo_notice_count)" -eq 0 ]
}

@test "T-ON-B2: 未読だけが満ちる(連続の閾値を遠くへ)場面は従来どおり、未読30+30分で1通" {
    uk_run 0 "$(offs 0 59)" BUSYGUARD_CONTINUOUS_MIN=100000
    [ "$(lord_notice_count)" -eq 0 ]
    uk_run 0 "$(offs 0 61)" BUSYGUARD_CONTINUOUS_MIN=100000
    [ "$(lord_notice_count)" -eq 1 ]
    [ "$(unread_ntfy_count)" -eq 1 ]
}

@test "T-ON-B3: 殿への ntfy が未読の経路で失敗しても、同じ時刻に連続の経路が出す(知らせの道を塞がぬ)" {
    cat > "$WORK/notify_copy.sh" <<'NEOF'
#!/usr/bin/env bash
case "$1" in *件が*分残っている*) exit 1 ;; esac
printf '%s\n' "$1" >> "$(dirname "${BASH_SOURCE[0]}")/notify.out"
NEOF
    uk_run 0 "$(offs 0 61)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(lord_notice_count)" -eq 1 ]
    [ "$(continuous_ntfy_count)" -eq 1 ]
}

@test "T-ON-B4: 確認画面(🛑)は別の知らせ: ⏳ の抑止に巻き込まれず、確認画面は従来どおり出る" {
    run bash -c "grep -n '🛑' '$WATCHER' | head -3"
    [ -n "$output" ]
    # 抑止は ① ② の ⏳ の2経路だけを対象にする(確認画面の経路に重複抑止の条件が入っていない)
    run bash -c "sed -n '/⓪ 確認画面/,/① 待機と言い切れぬ/p' '$WATCHER' | grep -c '_bg_lord_recent'"
    [ "$output" = "0" ]
}

# ═══════════════════════════════════════════════════════════════
# C. 変えぬもの
# ═══════════════════════════════════════════════════════════════

@test "T-ON-C1: 閾値は変わらぬ(未読30分・連続60分・再通知60分・家老から殿まで30分)" {
    run bash -c '
        export __INBOX_WATCHER_TESTING__=1 SCRIPT_DIR="'"$WORK"'" AGENT_ID=ashigaru9
        source "'"$WORK"'/scripts/inbox_watcher.sh"
        echo "unread=$BUSYGUARD_UNREAD_MIN continuous=$BUSYGUARD_CONTINUOUS_MIN repeat=$BUSYGUARD_REPEAT_MIN after=$BUSYGUARD_UNREAD_NTFY_AFTER_MIN"
    '
    echo "$output"
    [[ "$output" == *"unread=30 continuous=60 repeat=60 after=30"* ]]
}

@test "T-ON-C2: 順序は変わらぬ: 30分で家老へ(殿はまだ)→ 60分で殿へ。キーは足軽へ送らぬ" {
    uk_run 0 "$(offs 0 31)"
    [ "$(karo_notice_count)" -eq 1 ]
    [ "$(lord_notice_count)" -eq 0 ]
    uk_run 0 "$(offs 0 125)"
    sleep 1
    [ ! -s "$WORK/recv.log" ]
}

@test "T-ON-C3: 家老への inbox_write が失敗したら30分で即殿へ(fail-safe)。その後の60分の連続は重ねて出さぬ" {
    rm -f "$WORK/scripts/inbox_write.sh"
    uk_run 0 "$(offs 0 31)"
    [ "$(lord_notice_count)" -eq 1 ]
    grep -q "stage1-FAIL" "$WORK/driver.log"
    uk_run 0 "$(offs 0 61)"
    [ "$(lord_notice_count)" -eq 1 ]
}
