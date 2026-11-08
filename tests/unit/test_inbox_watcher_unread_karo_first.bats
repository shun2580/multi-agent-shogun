#!/usr/bin/env bats
# test_inbox_watcher_unread_karo_first.bats — cmd_267 / 殿裁定 2026-11-08 15:45(足軽5の停止の再発防止・4)
#   見張り役(inbox_watcher)の busy_guard ①『待機と言い切れぬ画面のまま未読が残る』(⏳ …キーは送っていない)を、
#   殿へ直接 ntfy する形から、次の順に改めたことを縛る試験:
#     1段目: 未読が30分(unread_notify_minutes)残ったら、まず家老へ inbox(scripts/inbox_write.sh・from=inbox_watcher・type=info)。殿へはまだ出さぬ
#     2段目: 家老へ知らせてから30分(unread_ntfy_after_minutes)たっても解けなければ殿へ ntfy
#   変えぬもの: 閾値(未読30分・連続60分・再通知60分)・足軽へキーを送らぬ作り・②(連続60分)・⓪(確認画面)
#   『解けた』= 既存の判定そのまま(未読が0になった / 待機の画面に戻った)。家老の inbox の既読は『解けた』に使わぬ。
#   対象の見張り役は、差し替え前は scripts/inbox_watcher.sh.cmd267(差し替え候補)、差し替え後は scripts/inbox_watcher.sh。
#
# 隔離(cmd_231 / cmd_252 の決まり): 試験ごとに $BATS_TEST_TMPDIR に使い捨ての木を作る。本物の ntfy は送らぬ
#   (BUSYGUARD_NOTIFY_CMD で写しへ)。時刻は INBOX_WATCHER_TEST_NOW で注入。画面の分類は固定値で差し替え。生きた陣へは繋がらぬ。
#
# T-UK-A*  家老への知らせが先に出る(殿へはまだ出ない)・内容(安全な手順・キーを送らぬ旨・秘匿値なし)
# T-UK-B*  家老へ知らせて30分で解けねば殿へ ntfy(家老の inbox が未読のままでも・既読にされても出る)
# T-UK-C*  30分の間に解けたら殿へ出ない(未読0・待機の画面)
# T-UK-D*  閾値は変わらず・足軽へキーを送らず・②は従来どおり・設定の鍵
# T-UK-E*  家老自身の止まり / 家老への inbox_write の失敗は、従来どおり直接 ntfy(fail-safe)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
if [ -f "$SCRIPT_DIR/scripts/inbox_watcher.sh.cmd267" ]; then
    WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh.cmd267"
else
    WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh"
fi
BASE_WATCHER_COMMIT="139e3b9"   # cmd_267 着手前の HEAD(=直す前の見張り役が本番だった版)
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

# ═══════════════════════════════════════════════════════════════
# A. 家老への知らせが先に出る(殿への ntfy はまだ出ない)
# ═══════════════════════════════════════════════════════════════

@test "T-UK-A1: 未読が30分残ると、まず家老へ inbox が1通(from=inbox_watcher・type=info)。殿への ntfy は出ない" {
    uk_run 0 "$(offs 0 29)"
    [ "$(karo_notice_count)" -eq 0 ]
    [ "$(notify_count)" -eq 0 ]
    uk_run 0 "$(offs 0 31)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(karo_notice_count)" -eq 1 ]
    [ "$(karo_field from)" = "inbox_watcher" ]
    [ "$(karo_field type)" = "info" ]
    [ "$(karo_field read)" = "False" ]
    [ "$(notify_count)" -eq 0 ]
    grep -q "stage1(karo)" "$WORK/driver.log"
}

@test "T-UK-A2: 家老への知らせは足軽名・task_id・画面を読む手順(読むだけ・安全なら答える・前面コマンドは Escape・それ以外は殿へ)を含み、秘匿値を含まぬ" {
    uk_run 0 "$(offs 0 31)" NTFY_TOPIC="ZZ_FAKE_SECRET_TOPIC_9f3a"
    local c; c="$(karo_field content)"
    echo "--- content ---"; echo "$c"
    [[ "$c" == *"ashigaru9"* ]]
    [[ "$c" == *"subtask_999_A"* ]]
    [[ "$c" == *"30分"* ]]
    [[ "$c" == *"capture-pane"* ]]
    [[ "$c" == *"bgt:0.0"* ]]
    [[ "$c" == *"キーを送っていない"* ]]
    [[ "$c" == *"Escape"* ]]
    [[ "$c" == *"殿へ"* ]]
    [ "$(karo_field task_id)" = "busyguard_ashigaru9" ]
    ! grep -rqF "ZZ_FAKE_SECRET_TOPIC_9f3a" "$WORK/queue" "$WORK/logs" "$WORK/notify.out" "$WORK/driver.log"
    ! grep -qiE "topic|token|bearer|password" <<<"$c"
}

@test "T-UK-A3: 家老への知らせは同じ未読の間に1通だけ(続く間に何通も積まぬ)" {
    uk_run 0 "$(offs 0 59)"
    [ "$(karo_notice_count)" -eq 1 ]
    [ "$(notify_count)" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# B. 家老へ知らせて30分で解けなければ殿へ ntfy
# ═══════════════════════════════════════════════════════════════

@test "T-UK-B1: 家老へ知らせた時刻から30分(未読の開始から60分)で殿へ ntfy が1回。その直前までは出ない" {
    uk_run 0 "$(offs 0 59)"
    [ "$(unread_ntfy_count)" -eq 0 ]
    uk_run 0 "$(offs 0 61)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(unread_ntfy_count)" -eq 1 ]
    grep -q "⏳" "$WORK/notify.out"
    grep -q "ashigaru9" "$WORK/notify.out"
    grep -q "subtask_999_A" "$WORK/notify.out"
    grep -q "キーは送っていない" "$WORK/notify.out"
    grep -q "家老へ inbox で知らせて30分" "$WORK/notify.out"
    [ "$(karo_notice_count)" -eq 1 ]
}

@test "T-UK-B2: 家老が止まっていて家老の inbox が未読のままでも(家老は何も読まぬ)30分後に殿へ出る" {
    uk_run 0 "$(offs 0 61)"
    [ "$(karo_field read)" = "False" ]
    [ "$(unread_ntfy_count)" -eq 1 ]
}

@test "T-UK-B3: 家老が通知を既読にしただけで画面が解けぬ場合も、30分で殿へ出る(家老の既読は『解けた』ではない)" {
    uk_run 0 "$(offs 0 45)"
    [ "$(karo_notice_count)" -eq 1 ]
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/karo.yaml"
    UK_KEEP=1 uk_run 0 "$(offs 46 61)"
    [ "$(unread_ntfy_count)" -eq 1 ]
}

@test "T-UK-B4: 殿への再通知は従来どおり60分ごと(60分で1回目 → 90分では出ず → 120分で2回目)。家老へは再送せぬ" {
    uk_run 0 "$(offs 0 89)"
    [ "$(unread_ntfy_count)" -eq 1 ]
    uk_run 0 "$(offs 0 121)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(unread_ntfy_count)" -eq 2 ]
    [ "$(karo_notice_count)" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════
# C. 30分の間に解けたら殿へ出ない
# ═══════════════════════════════════════════════════════════════

@test "T-UK-C1: 家老へ知らせた後、30分の間に未読が既読になれば(画面は働き中のまま)殿へは出ない" {
    uk_run 0 "$(offs 0 45)"
    [ "$(karo_notice_count)" -eq 1 ]
    write_inbox ashigaru9 true
    UK_KEEP=1 uk_run 0 "$(offs 46 120)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    # 未読が無ければ①は出ない(②の連続60分は別物ゆえ、ここでは①の文面だけを数える)
    ! grep -q "未読[0-9?]*件が.*分残っている" "$WORK/notify.out"
    grep -q "^unread_karo=0$" "$WORK/logs/watcher_busy/ashigaru9.state"
    grep -q "^unread_since=0$" "$WORK/logs/watcher_busy/ashigaru9.state"
}

@test "T-UK-C2: 家老へ知らせた後、30分の間に待機の画面に戻れば殿へは出ない。状態は戻る" {
    uk_run 0 "$(offs 0 45)"
    [ "$(karo_notice_count)" -eq 1 ]
    UK_KEEP=1 uk_run 1 "$(offs 46 46)"
    grep -q "^unread_karo=0$" "$WORK/logs/watcher_busy/ashigaru9.state"
    UK_KEEP=1 uk_run 1 "$(offs 47 120)"
    [ "$(notify_count)" -eq 0 ]
}

@test "T-UK-C3: 解けて再び詰まれば、数え直して家老への1段目から(殿へ直接は出ぬ)" {
    uk_run 0 "$(offs 0 45)"
    UK_KEEP=1 uk_run 1 "$(offs 46 46)"
    # 再び働き中・未読。起点は 47分(以前の1段目の時刻は忘れている)
    UK_KEEP=1 uk_run 0 "$(offs 47 76)"
    [ "$(notify_count)" -eq 0 ]
    UK_KEEP=1 uk_run 0 "$(offs 77 78)"
    [ "$(karo_notice_count)" -eq 2 ]
    [ "$(notify_count)" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# D. 変えぬもの
# ═══════════════════════════════════════════════════════════════

@test "T-UK-D1: 閾値は変わらぬ(未読30分・連続60分・再通知60分)。新しい鍵の既定は30分" {
    run bash -c '
        export __INBOX_WATCHER_TESTING__=1 SCRIPT_DIR="'"$WORK"'" AGENT_ID=ashigaru9
        source "'"$WORK"'/scripts/inbox_watcher.sh"
        echo "unread=$BUSYGUARD_UNREAD_MIN continuous=$BUSYGUARD_CONTINUOUS_MIN repeat=$BUSYGUARD_REPEAT_MIN after=$BUSYGUARD_UNREAD_NTFY_AFTER_MIN confirm_repeat=$BUSYGUARD_CONFIRM_REPEAT_MIN"
    '
    echo "$output"
    [[ "$output" == *"unread=30 continuous=60 repeat=60 after=30 confirm_repeat=30"* ]]
}

@test "T-UK-D2: 新しい鍵は env と settings で上書きでき、誤記は既定の30へ戻る" {
    run bash -c '
        export __INBOX_WATCHER_TESTING__=1 SCRIPT_DIR="'"$WORK"'" AGENT_ID=ashigaru9 BUSYGUARD_UNREAD_NTFY_AFTER_MIN=12
        source "'"$WORK"'/scripts/inbox_watcher.sh"; echo "env=$BUSYGUARD_UNREAD_NTFY_AFTER_MIN"'
    [[ "$output" == *"env=12"* ]]
    printf 'busy_guard:\n  unread_ntfy_after_minutes: 7\n' >> "$WORK/config/settings.yaml"
    run bash -c '
        export __INBOX_WATCHER_TESTING__=1 SCRIPT_DIR="'"$WORK"'" AGENT_ID=ashigaru9
        source "'"$WORK"'/scripts/inbox_watcher.sh"; echo "yaml=$BUSYGUARD_UNREAD_NTFY_AFTER_MIN"'
    [[ "$output" == *"yaml=7"* ]]
    run bash -c '
        export __INBOX_WATCHER_TESTING__=1 SCRIPT_DIR="'"$WORK"'" AGENT_ID=ashigaru9 BUSYGUARD_UNREAD_NTFY_AFTER_MIN=abc
        source "'"$WORK"'/scripts/inbox_watcher.sh"; echo "bad=$BUSYGUARD_UNREAD_NTFY_AFTER_MIN"'
    [[ "$output" == *"bad=30"* ]]
}

@test "T-UK-D3: 上書きした猶予(10分)が効く: 未読30分で家老へ → 40分で殿へ" {
    uk_run 0 "$(offs 0 39)" BUSYGUARD_UNREAD_NTFY_AFTER_MIN=10
    [ "$(notify_count)" -eq 0 ]
    uk_run 0 "$(offs 0 41)" BUSYGUARD_UNREAD_NTFY_AFTER_MIN=10
    [ "$(notify_count)" -eq 1 ]
    [ "$(unread_ntfy_count)" -eq 1 ]
}

@test "T-UK-D4: 足軽へキーを送らない: 偽ペインは何も受け取らず、キーを送る箇所の数は直す前と同じ" {
    uk_run 0 "$(offs 0 125)"
    sleep 1
    [ ! -s "$WORK/recv.log" ]
    local base_count new_count
    base_count="$(git -C "$SCRIPT_DIR" show "$BASE_WATCHER_COMMIT:scripts/inbox_watcher.sh" | grep -c 'send-keys' || true)"
    new_count="$(grep -c 'send-keys' "$WATCHER" || true)"
    echo "send-keys: base=$base_count new=$new_count"
    [ "$base_count" -eq "$new_count" ]
}

@test "T-UK-D5: ②(連続60分)は変えぬ: 未読0で働き中が60分続くと殿へ直接1回。家老へは何も送らぬ" {
    write_inbox ashigaru9 true
    uk_run 0 "$(offs 0 59)"
    [ "$(notify_count)" -eq 0 ]
    uk_run 0 "$(offs 0 61)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(notify_count)" -eq 1 ]
    grep -q "連続している" "$WORK/notify.out"
    [ "$(karo_notice_count)" -eq 0 ]
}

@test "T-UK-D6: 新しい常駐物・新しい見張りを作らない(nohup/setsid/cron/& 起動の行が直す前と同数)" {
    local base_count new_count
    base_count="$(git -C "$SCRIPT_DIR" show "$BASE_WATCHER_COMMIT:scripts/inbox_watcher.sh" | grep -cE 'nohup|setsid|crontab|disown' || true)"
    new_count="$(grep -cE 'nohup|setsid|crontab|disown' "$WATCHER" || true)"
    [ "$base_count" -eq "$new_count" ]
}

# ═══════════════════════════════════════════════════════════════
# E. fail-safe
# ═══════════════════════════════════════════════════════════════

@test "T-UK-E1: 家老の見張り役(AGENT_ID=karo)は自分へ知らせず、従来どおり30分で殿へ直接 ntfy(理由をログに残す)" {
    cp "$WORK/queue/inbox/ashigaru9.yaml" "$WORK/queue/inbox/karo.yaml"
    cat > "$WORK/queue/tasks/karo.yaml" <<'NEOF'
task:
  task_id: subtask_999_K
  status: assigned
NEOF
    rm -f -- "$WORK"/logs/watcher_busy/*.state; : > "$WORK/notify.out"
    UK_KEEP=1 uk_run 0 "$(offs 0 31)" UK_AGENT=karo
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(notify_count)" -eq 1 ]
    grep -q "self_is_karo" "$WORK/driver.log"
    ! grep -q "inbox_watcher" "$WORK/queue/inbox/karo.yaml"
}

@test "T-UK-E2: 家老への inbox_write が失敗したら、知らせの道を塞がぬよう30分でその場で殿へ ntfy する" {
    rm -f "$WORK/scripts/inbox_write.sh"
    uk_run 0 "$(offs 0 31)"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(notify_count)" -eq 1 ]
    grep -q "stage1-FAIL" "$WORK/driver.log"
    [ ! -f "$WORK/queue/inbox/karo.yaml" ]
}
