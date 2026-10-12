#!/usr/bin/env bats
# test_inbox_watcher_busyguard.bats — cmd_231 / 殿命 S-19
#   見張り役(inbox_watcher)が、画面が働き中と見える足軽へ /clear を送る欠陥の是正を、
#   別名ファイル scripts/inbox_watcher.sh.new で示す。本番 scripts/inbox_watcher.sh は触らない。
#
# 実証の仕組み:
#   - 試験ごとに <repo>/.e2e_work/busyguard.XXXXXX (git追跡外・/tmp ではない) に使い捨ての木を作り、
#     そこへ対象の見張り役を scripts/inbox_watcher.sh として複製して __INBOX_WATCHER_TESTING__=1 で source し、
#     process_unread を直接呼ぶ(本番と同じ set -euo pipefail 下)。
#   - a/b の実証は、専用 TMUX_TMPDIR の「別 tmux サーバ」に偽ペイン(画面が working 表示 / idle 表示)を立て、
#     ペインが受け取った入力を cat で recv.log に記録して並べる。生きた陣(multiagent / shogun)には繋がらない。
#   - c の実証は、画面観測だけを差し替え(agent_is_busy_check)、時刻を INBOX_WATCHER_TEST_NOW で進め、
#     ntfy の送り先を BUSYGUARD_NOTIFY_CMD で「ファイルへの追記(写し)」に替える。本物の ntfy は送らない。
#
# T-BG-A1/A2 : 【直す前】本番版は、働き中と見える足軽へ /clear を送る(欠陥の記録)
# T-BG-B1/B2 : 【直した後】.new は同じ場面で /clear を送らず、時間を進めても送らない
# T-BG-B3    : 働き中でない足軽は従来どおり段階的に起こす(本番と同一の入力列)
# T-BG-B4    : 受け取りの印(read: true)に頼らず成り立つ(未読が残ったままでも送らない)
# T-BG-C1〜C6: 固まった足軽の知らせ(30分/60分/60分ごと・名と長さ・秘匿値なし・idleで止まる・途切れで数え直す)
# T-BG-S1〜S2: settings の鍵と既定値
# T-BG-P1〜P2: 本番の watcher が無変更 / 起動経路に .new が入っていない
#
# 注意(工程C=本番差し替え時): T-BG-A1/A2 は「本番版の欠陥」を記録する試験ゆえ、差し替え後は
#   BUSYGUARD_TEST_PROD を .new に向けるか削除する。T-BG-P1 は差し替えで落ちる(意図どおり)ので外す。

# 足軽の名は生きた陣に居ない ashigaru9 を使う(生きた見張り役の inotifywait を self-watch と誤認せぬため)
SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PROD_WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh"
NEW_WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh.new"
BASE_WATCHER_COMMIT="cf432d8"   # cmd_231 着手前の HEAD

setup() {
    mkdir -p "$SCRIPT_DIR/.e2e_work"
    WORK="$(mktemp -d "$SCRIPT_DIR/.e2e_work/busyguard.XXXXXX")"
    export WORK
    mkdir -p "$WORK/scripts" "$WORK/lib" "$WORK/config" "$WORK/queue/inbox" "$WORK/queue/tasks" \
             "$WORK/queue/metrics" "$WORK/flags" "$WORK/tmux" "$WORK/logs"
    cp "$SCRIPT_DIR/lib/cli_adapter.sh" "$SCRIPT_DIR/lib/agent_status.sh" "$WORK/lib/"
    for f in "$SCRIPT_DIR"/lib/*.sh; do cp -n "$f" "$WORK/lib/" 2>/dev/null || true; done
    if [ -f "$SCRIPT_DIR/config/settings.yaml" ]; then
        cp "$SCRIPT_DIR/config/settings.yaml" "$WORK/config/settings.yaml"
    else
        cp "$SCRIPT_DIR/config/settings.yaml.example" "$WORK/config/settings.yaml"
    fi
    ln -s "$SCRIPT_DIR/.venv" "$WORK/.venv"
    : > "$WORK/recv.log"
    : > "$WORK/notify.out"
    # ntfy の写し(本物の ntfy は送らない)
    cat > "$WORK/notify_copy.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$(dirname "${BASH_SOURCE[0]}")/notify.out"
EOF
    chmod +x "$WORK/notify_copy.sh"
    # 偽ペイン: 画面を作って、受け取った入力を recv.log へ追記する(C-c は無視、C-d で終わる)
    cat > "$WORK/fakepane.sh" <<'EOF'
#!/usr/bin/env bash
mode="$1"; recv="$2"
trap '' INT
stty -echo 2>/dev/null
case "$mode" in
  working) printf 'running the task...\n✻ Working… (12s)\n  ⏵⏵ bypass permissions on · esc to interrupt\n' ;;
  idle)    printf 'done.\n❯ \n' ;;
  confirm) printf ' Bash command\n\n   rm -rf "$T"\n\n Dangerous rm operation on possibly-empty variable path\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · Tab to amend\n' ;;
  quote)   printf 'the agent quoted: Do you want to proceed?\n ❯ 1. Yes\n   2. No\n  Esc to cancel\n(end of quote)\n✻ Working… (3s)\n  ⏵⏵ bypass permissions on · esc to interrupt\n' ;;
esac
exec cat >> "$recv"
EOF
    chmod +x "$WORK/fakepane.sh"
    # 未読の task_assigned 1件(足軽1)
    cat > "$WORK/queue/inbox/ashigaru9.yaml" <<'EOF'
messages:
- cmd_id: cmd_999
  content: タスクYAMLを読んで作業開始せよ。
  from: karo
  id: msg_t1
  read: false
  task_id: subtask_999_A
  timestamp: '2026-10-12T22:00:00'
  type: task_assigned
EOF
    cat > "$WORK/queue/tasks/ashigaru9.yaml" <<'EOF'
task:
  task_id: subtask_999_A
  status: assigned
EOF
}

teardown() {
    # 偽ペインを自然終了させる(kill 系は使わぬ・D006)。C-d で cat が EOF → ペイン終了 → セッション終了。
    if [ -n "${WORK:-}" ] && [ -d "$WORK/tmux" ]; then
        iso_tmux send-keys -t bgt:0.0 C-d C-d 2>/dev/null || true
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            iso_tmux list-sessions >/dev/null 2>&1 || break
            sleep 0.5
        done
    fi
    safe_remove_work
}

# 後始末: 変数パスへの rm -rf は書かない(Claude Code の確認画面で止まる・追補2)。
# 作業木は <repo>/.e2e_work/busyguard.XXXXXX に残す(追跡外・小さい)。消す場合は人が固定パスで行う。
safe_remove_work() { return 0; }

# ── 道具 ──

iso_tmux() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$WORK/tmux" tmux "$@"; }

# install_watcher <path> — 対象の見張り役を使い捨ての木へ scripts/inbox_watcher.sh として複製する
install_watcher() {
    cp "$1" "$WORK/scripts/inbox_watcher.sh"
    chmod +x "$WORK/scripts/inbox_watcher.sh"
}

# start_pane <working|idle|confirm|quote> — 別 tmux サーバに偽ペインを立てる
start_pane() {
    iso_tmux new-session -d -s bgt -x 200 -y 50 "bash $WORK/fakepane.sh $1 $WORK/recv.log"
    iso_tmux set-option -p -t bgt:0.0 @agent_cli claude
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if iso_tmux capture-pane -t bgt:0.0 -p 2>/dev/null | grep -q -E 'esc to interrupt|❯|Esc to cancel'; then return 0; fi
        sleep 0.25
    done
    return 1
}

# write_driver — process_unread を直接呼ぶ運転台
#   CYC_AGE      FIRST_UNREAD_SEEN を何秒前にするか(欠陥の再現: 未読が古く残る)
#   CYC_OFFSETS  .new のとき、各回の「いま」を base からの秒数で注入(本番は注入口が無いので無視)
#   CYC_CTX      NEW_CONTEXT_SENT の初期値(1=着任時の /clear は済んだ後)
#   CYC_BASE     「いま」の起点(epoch秒)を固定する。複数回の運転で状態ファイルの時刻を繋ぐ用
#   CYC_VERDICT_FILE があれば agent_is_busy_check を差し替え(ファイルの数字 0/1/2 を返す)
write_driver() {
    cat > "$WORK/driver.sh" <<'EOF'
#!/usr/bin/env bash
export __INBOX_WATCHER_TESTING__=1
export AGENT_ID=ashigaru9
export PANE_TARGET=bgt:0.0
export CLI_TYPE=claude
export SCRIPT_DIR="$WORK"
export INBOX="$WORK/queue/inbox/ashigaru9.yaml"
export LOCKFILE="${INBOX}.lock"
export IDLE_FLAG_DIR="$WORK/flags"
export METRICS_FILE="$WORK/queue/metrics/ashigaru9_selfwatch.yaml"
export BUSYGUARD_STATE_DIR="$WORK/logs/watcher_busy"
export BUSYGUARD_NOTIFY_CMD="$WORK/notify_copy.sh"
export TMUX_TMPDIR="$WORK/tmux"
unset TMUX TMUX_PANE
# shellcheck disable=SC1091
source "$WORK/scripts/inbox_watcher.sh"
# 本番と同じ厳しさ(set -euo pipefail)で走らせる
set -euo pipefail
sleep() { command sleep 0.1; }
if [ -n "${CYC_VERDICT_FILE:-}" ]; then
    agent_is_busy_check() { return "$(cat "$CYC_VERDICT_FILE")"; }
fi
NEW_CONTEXT_SENT="${CYC_CTX:-1}"
base="${CYC_BASE:-$(date +%s)}"
FIRST_UNREAD_SEEN=$((base - ${CYC_AGE:-0}))
for off in ${CYC_OFFSETS:-0}; do
    if [ -n "${CYC_INJECT:-}" ]; then export INBOX_WATCHER_TEST_NOW=$((base + off)); fi
    process_unread timeout
done
echo "DRIVER_DONE"
EOF
}

# run_driver — 運転台を走らせ、出力(stderr込み)を $WORK/driver.log へ。bats の $output にも入れる。
run_driver() {
    write_driver
    run env WORK="$WORK" "$@" bash "$WORK/driver.sh"
    printf '%s\n' "$output" > "$WORK/driver.log"
    # 偽ペインが入力を書き終えるのを待つ
    sleep 1
}

recv() { cat "$WORK/recv.log"; }

# ═══════════════════════════════════════════════════════════════
# a. 【直す前】本番版は働き中と見える足軽に /clear を送る
# ═══════════════════════════════════════════════════════════════

@test "T-BG-A1: 【直す前】本番版: 画面が働き中・idleフラグ無し・未読400秒 → stale busy recovery で /clear が送られる" {
    install_watcher "$PROD_WATCHER"
    start_pane working
    run_driver CYC_AGE=400 CYC_CTX=1
    echo "--- driver.log (抜粋) ---"; grep -E "BUSY-DETERMINATION|stale busy|forcing idle|Phase 3|SEND-KEYS|BUSY-GUARD" "$WORK/driver.log" | head -20
    echo "--- recv.log ---"; recv
    [[ "$output" == *"DRIVER_DONE"* ]]
    # 欠陥の経路(働き中を idle と見なし直す行)が走った
    grep -q "stale busy recovery" "$WORK/driver.log"
    grep -q "ESCALATION Phase 3" "$WORK/driver.log"
    # 偽ペインが /clear を受け取った(=働き中の足軽へ /clear が送られた)
    recv | grep -qx "/clear"
    # 画面は終始 working 表示のままだった
    iso_tmux capture-pane -t bgt:0.0 -p | grep -q "esc to interrupt"
}

@test "T-BG-A2: 【直す前】本番版: 画面が働き中でも idleフラグが残っていれば Phase 3 で /clear が送られる" {
    install_watcher "$PROD_WATCHER"
    start_pane working
    touch "$WORK/flags/shogun_idle_ashigaru9"
    run_driver CYC_AGE=400 CYC_CTX=1
    echo "--- driver.log (抜粋) ---"; grep -E "BUSY-DETERMINATION|Phase 3|SEND-KEYS|BUSY-GUARD" "$WORK/driver.log" | head -20
    echo "--- recv.log ---"; recv
    [[ "$output" == *"DRIVER_DONE"* ]]
    grep -q "ESCALATION Phase 3" "$WORK/driver.log"
    recv | grep -qx "/clear"
}

# ═══════════════════════════════════════════════════════════════
# b. 【直した後】.new は働き中の足軽へ /clear を送らない
# ═══════════════════════════════════════════════════════════════

@test "T-BG-B1: 【直した後】.new: A1 と同じ場面で /clear を送らず、2〜4分・4分超・5分超に相当する経過でも送らない" {
    install_watcher "$NEW_WATCHER"
    start_pane working
    # 0秒 / 2分 / 3分 / 4分超 / 6分 / 10分 に相当する各回(「いま」を注入)
    run_driver CYC_AGE=400 CYC_CTX=1 CYC_INJECT=1 CYC_OFFSETS="0 130 190 250 400 700"
    echo "--- driver.log (抜粋) ---"; grep -E "BUSY-DETERMINATION|stale busy|forcing idle|Phase|SEND-KEYS|BUSY-GUARD|but agent is busy" "$WORK/driver.log" | head -30
    echo "--- recv.log ---"; recv
    [[ "$output" == *"DRIVER_DONE"* ]]
    ! grep -q "stale busy recovery" "$WORK/driver.log"
    ! grep -q "forcing idle flag" "$WORK/driver.log"
    ! grep -q "ESCALATION Phase 3: Agent" "$WORK/driver.log"
    ! grep -q "Sending /clear" "$WORK/driver.log"
    # 偽ペインは何も受け取っていない(/clear も nudge も)
    [ ! -s "$WORK/recv.log" ]
    # watcher は idleフラグを強制作成していない
    [ ! -e "$WORK/flags/shogun_idle_ashigaru9" ]
}

@test "T-BG-B2: 【直した後】.new: A2 と同じ場面(idleフラグ残り+画面は働き中)でも Phase 3 を見送り /clear を送らない" {
    install_watcher "$NEW_WATCHER"
    start_pane working
    touch "$WORK/flags/shogun_idle_ashigaru9"
    run_driver CYC_AGE=400 CYC_CTX=1 CYC_INJECT=1 CYC_OFFSETS="0 60 400"
    echo "--- driver.log (抜粋) ---"; grep -E "BUSY-DETERMINATION|Phase|SEND-KEYS|BUSY-GUARD" "$WORK/driver.log" | head -30
    echo "--- recv.log ---"; recv
    [[ "$output" == *"DRIVER_DONE"* ]]
    grep -q "Phase 3 withheld" "$WORK/driver.log"
    ! grep -q "Sending /clear" "$WORK/driver.log"
    [ ! -s "$WORK/recv.log" ]
}

@test "T-BG-B3: .new: 働き中でない足軽(idle)は従来どおり段階的に起こす(本番と同一の入力列。退行なし)" {
    # 段階: 未読 60s(Phase1: 通常nudgeは無効=何も送らぬ) → 150s(Phase2: nudge) → 400s(Phase3: /clear)
    local who got_prod got_new
    for who in prod new; do
        : > "$WORK/recv.log"
        if [ "$who" = prod ]; then install_watcher "$PROD_WATCHER"; else install_watcher "$NEW_WATCHER"; fi
        start_pane idle
        touch "$WORK/flags/shogun_idle_ashigaru9"
        # 3つの段階を別プロセスで(各回 FIRST_UNREAD_SEEN を段階の古さにする)
        local age
        for age in 60 150 400; do
            run_driver CYC_AGE=$age CYC_CTX=1
            [[ "$output" == *"DRIVER_DONE"* ]]
        done
        if [ "$who" = prod ]; then got_prod="$(recv)"; else got_new="$(recv)"; fi
        # 次の周回のためにペインを閉じる
        iso_tmux send-keys -t bgt:0.0 C-d C-d 2>/dev/null || true
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do iso_tmux list-sessions >/dev/null 2>&1 || break; sleep 0.5; done
    done
    echo "--- prod recv ---"; echo "$got_prod"
    echo "--- new  recv ---"; echo "$got_new"
    # 退行なし: 同一の入力列
    [ "$got_prod" = "$got_new" ]
    # 段階が実際に働いている: Phase2 の nudge と Phase3 の /clear が含まれる
    echo "$got_new" | grep -qx "inbox1"
    echo "$got_new" | grep -qx "/clear"
}

@test "T-BG-B4: 見張り役の直しは『足軽が read: true を先に付ける』ことに頼らず成り立つ(未読が残ったまま長時間でも送らない)" {
    install_watcher "$NEW_WATCHER"
    start_pane working
    # 未読(read:false)のまま 2 時間相当
    run_driver CYC_AGE=7200 CYC_CTX=1 CYC_INJECT=1 CYC_OFFSETS="0 600 3600 7200"
    grep -q "read: false" "$WORK/queue/inbox/ashigaru9.yaml"
    [[ "$output" == *"DRIVER_DONE"* ]]
    ! grep -q "Sending /clear" "$WORK/driver.log"
    [ ! -s "$WORK/recv.log" ]
}

@test "T-BG-B5: .new: 着任時の文脈リセット(send_context_reset)も、働き中と見える足軽には送らず、idleになってから送る" {
    install_watcher "$NEW_WATCHER"
    start_pane working
    touch "$WORK/flags/shogun_idle_ashigaru9"   # フラグはidleだが画面は働き中
    run_driver CYC_AGE=0 CYC_CTX=0
    echo "--- driver.log (抜粋) ---"; grep -E "BUSY-GUARD|CONTEXT-RESET|SEND-KEYS" "$WORK/driver.log" | head
    grep -q "context reset withheld" "$WORK/driver.log"
    ! grep -q "Sending /clear before task_assigned" "$WORK/driver.log"
    # /clear は届かない(従来どおり届く短い nudge "inbox1" は非破壊ゆえ許す)
    ! recv | grep -qx "/clear"
}

# ═══════════════════════════════════════════════════════════════
# c. 固まった足軽の知らせ(送り先は写し・時刻は注入)
# ═══════════════════════════════════════════════════════════════

# c_run <verdict> <offsets> [env...] — 画面観測を固定値で差し替え、offsets の各時刻で process_unread を回す
# 毎回、状態ファイルと写しを空にして始める(C_KEEP=1 のときは続きとして走らせる)。起点は固定(CYC_BASE)。
C_BASE=1800000000
c_run() {
    local verdict="$1" offsets="$2"; shift 2
    install_watcher "$NEW_WATCHER"
    if [ -z "${C_KEEP:-}" ]; then
        rm -f -- "$WORK"/logs/watcher_busy/*.state
        : > "$WORK/notify.out"
    fi
    printf '%s' "$verdict" > "$WORK/verdict"
    run_driver CYC_VERDICT_FILE="$WORK/verdict" CYC_AGE=0 CYC_CTX=1 CYC_INJECT=1 CYC_OFFSETS="$offsets" \
        CYC_BASE="$C_BASE" BUSYGUARD_RESUME_GAP_SEC=1000000 "$@"
    [[ "$output" == *"DRIVER_DONE"* ]]
}

notify_count() { grep -c . "$WORK/notify.out" || true; }

@test "T-BG-C1: 働き中のまま未読が30分残ると ntfy が1回(30分前は0回)。足軽の名・task_id・長さが載り、/clear は送らない" {
    # 5分刻み。unread は inbox に残ったまま(read:false)
    c_run 0 "0 300 600 900 1200 1500 1799"
    [ "$(notify_count)" -eq 0 ]
    c_run 0 "0 300 600 900 1200 1500 1799 1800 1860"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(notify_count)" -eq 1 ]
    grep -q "ashigaru9" "$WORK/notify.out"
    grep -q "subtask_999_A" "$WORK/notify.out"
    grep -q "30分" "$WORK/notify.out"
    grep -q "未読" "$WORK/notify.out"
    ! grep -q "Sending /clear" "$WORK/driver.log"
}

@test "T-BG-C2: 未読の有無を問わず働き中が連続60分で ntfy が1回(未読0でも出る)" {
    # 未読を既読にして(0件)、画面は働き中のまま 60 分
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/ashigaru9.yaml"
    c_run 0 "0 600 1200 1800 2400 3000 3599"
    [ "$(notify_count)" -eq 0 ]
    c_run 0 "0 600 1200 1800 2400 3000 3599 3600 3660"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(notify_count)" -eq 1 ]
    grep -q "ashigaru9" "$WORK/notify.out"
    grep -q "subtask_999_A" "$WORK/notify.out"
    grep -q "60分" "$WORK/notify.out"
    grep -q "連続" "$WORK/notify.out"
}

@test "T-BG-C3: 続く間は60分ごとに1回(未読あり: 30/60/90/120/150分で①②が各回出て、その間は出ない)" {
    # 5分刻みで 0〜150分(未読は残ったまま)
    local offs="" t
    for t in $(seq 0 300 9000); do offs="$offs $t"; done
    c_run 0 "$offs"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    # ①(未読): 30,90 分 → 2回(150分目は 9000s=150分ちょうどで3回目)  ②(連続): 60,120 分 → 2回
    local unread_n cont_n
    unread_n=$(grep -c "未読.*分残っている" "$WORK/notify.out" || true)
    cont_n=$(grep -c "連続している" "$WORK/notify.out" || true)
    echo "unread_n=$unread_n cont_n=$cont_n"
    [ "$unread_n" -eq 3 ]
    [ "$cont_n" -eq 2 ]
    [ "$(notify_count)" -eq 5 ]
}

@test "T-BG-C4: idleが1度観測されたら連続は止まり、数え直す(35分→idle→35分では出ない。止めなければ72分で出る)" {
    # 未読は既読にして(①を除き)、連続(②)だけを見る
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/ashigaru9.yaml"
    # 前半35分(働き中)
    c_run 0 "0 300 600 900 1200 1500 1800 2100"
    [ "$(notify_count)" -eq 0 ]
    # idle を1回観測(2160秒)
    C_KEEP=1 c_run 1 "2160"
    grep -q "^busy_since=0$" "$WORK/logs/watcher_busy/ashigaru9.state"
    # 再び働き中: 2220秒から35分(=合計72分を超えるが、idleで止まったので数え直し)
    C_KEEP=1 c_run 0 "2220 2520 2820 3120 3420 3720 4020 4320"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(notify_count)" -eq 0 ]
    # 対照: 止めなければ(途中でidleを観測しなければ)同じ時間幅で60分を超えて知らせが出る
    c_run 0 "0 300 600 900 1200 1500 1800 2100 2400 2700 3000 3300 3600 3900 4200 4320"
    [ "$(notify_count)" -eq 1 ]
}

@test "T-BG-C5: 観測が長く途切れたら(見張り役の停止等)古い連続は信用せず数え直す" {
    # 既定の途切れ許容(300秒)。10分空けた2回の観測では、連続は繋がらない
    install_watcher "$NEW_WATCHER"
    printf '0' > "$WORK/verdict"
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/ashigaru9.yaml"
    run_driver CYC_VERDICT_FILE="$WORK/verdict" CYC_AGE=0 CYC_CTX=1 CYC_INJECT=1 CYC_BASE="$C_BASE" CYC_OFFSETS="0 600 1200 1800 2400 3000 3600 4200"
    [[ "$output" == *"DRIVER_DONE"* ]]
    [ "$(notify_count)" -eq 0 ]
    # 対照: 途切れ許容を十分大きくすれば(連続と見なせば)同じ観測列で 60 分の知らせが出る
    rm -f -- "$WORK"/logs/watcher_busy/*.state; : > "$WORK/notify.out"
    run_driver CYC_VERDICT_FILE="$WORK/verdict" CYC_AGE=0 CYC_CTX=1 CYC_INJECT=1 CYC_BASE="$C_BASE" CYC_OFFSETS="0 600 1200 1800 2400 3000 3600 4200" BUSYGUARD_RESUME_GAP_SEC=1000000
    [ "$(notify_count)" -eq 1 ]
}

@test "T-BG-C6: 知らせにも状態ファイルにもログにも秘匿値(ntfy_topic 等)を書かない" {
    # 秘匿値の置場を作らず、見張り役が鍵名の値を扱わぬことを確認する。擬似の秘匿値を環境に置き、どこにも漏れぬことを見る
    local fake="ZZ_FAKE_SECRET_TOPIC_9f3a"
    c_run 0 "0 600 1200 1800 2400 3000 3600 4200" NTFY_TOPIC="$fake" SHOGUN_SECRETS_FILE="$WORK/none.env"
    [ "$(notify_count)" -ge 1 ]
    ! grep -rqF "$fake" "$WORK/notify.out" "$WORK/driver.log" "$WORK/logs" "$WORK/queue"
    ! grep -qiE "topic|token|bearer|password" "$WORK/notify.out"
}

# ═══════════════════════════════════════════════════════════════
# 追補②: 確認画面(許可待ち・Dangerous 確認)で待つ足軽を知らせの対象にできるか(可否の実測。.new へは未組込み)
# ═══════════════════════════════════════════════════════════════

# 候補の検出(試験内の定義。.new には入れていない): 画面の最終行が "Esc to cancel" で、かつ直近に選択肢 "❯ 1. Yes" がある
confirm_screen() {
    local tail_
    tail_="$(iso_tmux capture-pane -t bgt:0.0 -p | grep -v '^[[:space:]]*$' | tail -8)"
    echo "$tail_" | tail -1 | grep -qiE 'esc to cancel' && echo "$tail_" | grep -qE '❯ *1\. *Yes'
}

@test "T-BG-D1: 確認画面で待つ足軽: 現行の画面判定は busy と読み(最終行の 'Esc to cancel' が 'esc to' に合う)、.new は /clear せず連続60分で知らせる" {
    install_watcher "$NEW_WATCHER"
    start_pane confirm
    iso_tmux capture-pane -t bgt:0.0 -p | grep -q "Do you want to proceed?"
    # 現行の画面判定(agent_is_busy_check)の実測
    run bash -c 'source "'"$WORK"'/lib/agent_status.sh"; export TMUX_TMPDIR="'"$WORK"'/tmux"; unset TMUX TMUX_PANE; agent_is_busy_check bgt:0.0 claude; echo "rc=$?"'
    echo "agent_is_busy_check on confirmation screen: $output"
    [[ "$output" == *"rc=0"* ]]
    # 未読を既読にして(①を除く)、連続60分だけを見る。5分刻み
    sed -i 's/read: false/read: true/' "$WORK/queue/inbox/ashigaru9.yaml"
    local offs="" t
    for t in $(seq 0 300 3600); do offs="$offs $t"; done
    run_driver CYC_AGE=0 CYC_CTX=1 CYC_INJECT=1 CYC_BASE=1800000000 CYC_OFFSETS="$offs" BUSYGUARD_RESUME_GAP_SEC=1000000
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [[ "$output" == *"DRIVER_DONE"* ]]
    [ "$(notify_count)" -eq 1 ]
    grep -q "連続" "$WORK/notify.out"
    [ ! -s "$WORK/recv.log" ]
}

@test "T-BG-D2: 確認画面の検出は画面から可能(候補規則)。働き中・idle・『確認画面の文言を引用して働き中』の画面には誤報しない" {
    local m
    for m in confirm working idle quote; do
        : > "$WORK/recv.log"
        start_pane "$m"
        if [ "$m" = confirm ]; then
            confirm_screen
        else
            ! confirm_screen
        fi
        iso_tmux send-keys -t bgt:0.0 C-d C-d 2>/dev/null || true
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do iso_tmux list-sessions >/dev/null 2>&1 || break; sleep 0.5; done
    done
}

# ═══════════════════════════════════════════════════════════════
# settings の鍵と既定値
# ═══════════════════════════════════════════════════════════════

# print_cfg — settings(使い捨ての木の config/settings.yaml)から読まれる値を出す
print_cfg() {
    install_watcher "$NEW_WATCHER"
    run bash -c '
        export __INBOX_WATCHER_TESTING__=1 SCRIPT_DIR="'"$WORK"'" AGENT_ID=ashigaru9
        unset BUSYGUARD_UNREAD_MIN BUSYGUARD_CONTINUOUS_MIN BUSYGUARD_REPEAT_MIN
        source "'"$WORK"'/scripts/inbox_watcher.sh" 2>/dev/null
        echo "$BUSYGUARD_UNREAD_MIN $BUSYGUARD_CONTINUOUS_MIN $BUSYGUARD_REPEAT_MIN"
    '
}

@test "T-BG-S1: settings に busy_guard 鍵が無ければ既定(30/60/60)、あればその値(誤記は既定に戻る)" {
    sed -i '/^busy_guard:/,/^[a-z_]*:/{/^busy_guard:/d;/^  /d}' "$WORK/config/settings.yaml"
    ! grep -q "^busy_guard:" "$WORK/config/settings.yaml"
    print_cfg
    [ "$status" -eq 0 ]
    [ "$output" = "30 60 60" ]
    cat >> "$WORK/config/settings.yaml" <<'EOF'
busy_guard:
  unread_notify_minutes: 7
  continuous_notify_minutes: 9
  repeat_notify_minutes: 11
EOF
    print_cfg
    [ "$output" = "7 9 11" ]
    sed -i 's/unread_notify_minutes: 7/unread_notify_minutes: abc/; s/repeat_notify_minutes: 11/repeat_notify_minutes: 0/' "$WORK/config/settings.yaml"
    print_cfg
    [ "$output" = "30 9 60" ]
}

@test "T-BG-S2: config/settings.yaml.example(追跡)に busy_guard の鍵があり、既定値が実効値(30/60/60)と同じ" {
    grep -q "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example"
    grep -A4 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "unread_notify_minutes: 30"
    grep -A4 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "continuous_notify_minutes: 60"
    grep -A4 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "repeat_notify_minutes: 60"
}

# ═══════════════════════════════════════════════════════════════
# 本番の watcher が既定で無変更
# ═══════════════════════════════════════════════════════════════

@test "T-BG-P1: 本番 scripts/inbox_watcher.sh は cmd_231 着手前から無変更(コミットも差分も無い)" {
    cd "$SCRIPT_DIR"
    [ -z "$(git diff --stat -- scripts/inbox_watcher.sh)" ]
    [ -z "$(git diff --cached --stat -- scripts/inbox_watcher.sh)" ]
    [ -z "$(git log --oneline "$BASE_WATCHER_COMMIT"..HEAD -- scripts/inbox_watcher.sh)" ]
}

@test "T-BG-P2: .new は本番の起動経路(watcher_supervisor / shutsujin / switch_cli 等)から参照されない" {
    cd "$SCRIPT_DIR"
    local hits
    hits="$(grep -rl "inbox_watcher.sh.new" --include='*.sh' --include='*.yaml' --include='*.py' scripts lib config shutsujin_departure.sh first_setup.sh 2>/dev/null | grep -v '^scripts/inbox_watcher.sh.new$' || true)"
    echo "hits=[$hits]"
    [ -z "$hits" ]
}
