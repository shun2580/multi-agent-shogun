#!/usr/bin/env bats
# test_inbox_watcher_keygate.bats — cmd_231 工程B / 殿命 S-19 追補(00:20)
#   見張り役(inbox_watcher)がキー(起こしの文字・Enter・Escape・C-u・C-c・/clear・起動の口上 ほか全て)を送ってよいのは、
#   「送る直前に画面を見て、待機中のプロンプトと言い切れるとき」だけ — を、別名ファイル scripts/inbox_watcher.sh.new で示す。
#   本番 scripts/inbox_watcher.sh は触らない(比較の相手として複製して動かすだけ)。
#
# 実証の仕組み(busyguard bats と同じ隔離):
#   - 試験ごとに $BATS_TEST_TMPDIR(bats が消す。リポジトリ内に残骸を残さぬ)へ使い捨ての木を作り、
#     対象の見張り役を scripts/inbox_watcher.sh として複製して __INBOX_WATCHER_TESTING__=1 で source する。
#   - 専用 TMUX_TMPDIR の「別 tmux サーバ」に偽ペインを立てる。生きた陣(multiagent / shogun)には繋がらない。
#     記録つき tmux ラッパ($WORK/bin/tmux)は、TMUX_TMPDIR が使い捨て配下でなければ exit 97 で中継を拒み、
#     send-keys を1回ずつ KEYLOG へ記録する(Enter を含む送信かどうかも)。T-KG-I1 が拒否を実測する。
#
# T-KG-C* : 画面の分類(待機と言い切れる積極条件)  T-KG-M* : 場面×送信口の送信回数表(直す前=本番版 / 直した後=.new)
# T-KG-N* : 確認画面・判別不能の知らせ            T-KG-F* : ntfy の戻り値のログ(失敗を模擬)
# T-KG-S* : 送信口が1本・設定               T-KG-I1 : 隔離の実測

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PROD_WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh"
NEW_WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh.new"

setup() {
    WORK="$BATS_TEST_TMPDIR/w"
    export WORK
    mkdir -p "$WORK/scripts" "$WORK/lib" "$WORK/config" "$WORK/queue/inbox" "$WORK/queue/tasks" \
             "$WORK/queue/metrics" "$WORK/flags" "$WORK/tmux" "$WORK/logs" "$WORK/bin"
    cp "$SCRIPT_DIR/lib/cli_adapter.sh" "$SCRIPT_DIR/lib/agent_status.sh" "$WORK/lib/"
    for f in "$SCRIPT_DIR"/lib/*.sh; do cp -n "$f" "$WORK/lib/" 2>/dev/null || true; done
    cp "$SCRIPT_DIR/scripts/ntfy.sh" "$WORK/scripts/ntfy.sh"
    if [ -f "$SCRIPT_DIR/config/settings.yaml" ]; then
        cp "$SCRIPT_DIR/config/settings.yaml" "$WORK/config/settings.yaml"
    else
        cp "$SCRIPT_DIR/config/settings.yaml.example" "$WORK/config/settings.yaml"
    fi
    ln -s "$SCRIPT_DIR/.venv" "$WORK/.venv"
    REAL_TMUX="$(command -v tmux)"
    export REAL_TMUX
    KEYLOG="$WORK/keys.log"; export KEYLOG
    : > "$KEYLOG"
    : > "$WORK/recv.log"
    : > "$WORK/notify.out"

    # 記録つき tmux ラッパ(使い捨てサーバ以外へは中継しない)
    cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "${TMUX_TMPDIR:-}" in
  "$KG_WORK"/*) ;;
  *) echo "keylog tmux shim: REFUSE (TMUX_TMPDIR is not the disposable server)" >&2; exit 97 ;;
esac
if [ -n "${TMUX:-}" ]; then echo "keylog tmux shim: REFUSE (TMUX set)" >&2; exit 97; fi
for a in "$@"; do
  if [ "$a" = "send-keys" ]; then
    # 1送信=1行。対象(-t の値)は除き、キー名はそのまま、文字列は長さだけを記録する
    enter=0; kinds=""; skip=0
    for b in "$@"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$b" in
        send-keys) ;;
        -t) skip=1 ;;
        -l) kinds="$kinds -l" ;;
        Enter|C-m) enter=1; kinds="$kinds Enter" ;;
        Escape|C-u|C-c|C-d) kinds="$kinds $b" ;;
        *) kinds="$kinds text(${#b})" ;;
      esac
    done
    printf 'KEY\t%s\t%s\n' "$enter" "${kinds# }" >> "$KEYLOG"
    break
  fi
done
exec "$REAL_TMUX" "$@"
EOF
    chmod +x "$WORK/bin/tmux"
    export KG_WORK="$WORK"

    cat > "$WORK/fakepane.sh" <<'EOF'
#!/usr/bin/env bash
# 偽ペイン: 画面を作り、受け取った入力を recv.log へ追記する(C-c は無視、C-d で終わる)
mode="$1"; recv="$2"
trap '' INT
stty -echo 2>/dev/null
RULE='────────────────────────────────────────'
case "$mode" in
  idle)       printf '⏺ 了解した。タスクを完了した。\n\n%s\n❯ \n%s\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n' "$RULE" "$RULE" ;;
  idle_min)   printf 'done.\n❯ \n' ;;
  idle_old)   printf '╭────────────────────────────╮\n│ >                          │\n╰────────────────────────────╯\n  ? for shortcuts\n' ;;
  residue)    printf '%s\n❯ inbox1\n%s\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n' "$RULE" "$RULE" ;;
  working)    printf '⏺ Bash(sleep 100)\n  ⎿  Running…\n\n✻ Cogitating… (12s · ↓ 1.2k tokens · esc to interrupt)\n\n%s\n❯ \n%s\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt\n' "$RULE" "$RULE" ;;
  working_min) printf 'running the task...\n✻ Working… (12s)\n  ⏵⏵ bypass permissions on · esc to interrupt\n' ;;
  confirm)    printf ' Bash command\n\n   rm -rf "$T"\n   Remove the directory named by T\n\n Dangerous rm operation on possibly-empty variable path\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · Tab to amend\n' ;;
  confirm2)   printf ' Bash command\n\n   git push origin main\n   Push the branch\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · Tab to amend\n' ;;
  confirm_ynl) printf 'Overwrite existing file? (y/n)\n' ;;
  custom)     printf 'Proceed with deletion? [Ok/Cancel]\n' ;;
  quote)      printf 'the agent quoted: Do you want to proceed?\n ❯ 1. Yes\n   2. No\n  Esc to cancel\n(end of quote)\n✻ Working… (3s)\n  ⏵⏵ bypass permissions on · esc to interrupt\n' ;;
  idle_quote) printf 'the agent quoted: Do you want to proceed?\n 1. Yes\n 2. No\nEsc to cancel\n(end of quote)\nあとは報告を書くだけである。\n報告は queue/reports に置いた。\n\n%s\n❯ \n%s\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n' "$RULE" "$RULE" ;;
  suggest)    printf '%s\n❯ Try "fix lint errors"\n%s\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n' "$RULE" "$RULE" ;;
  typing)     printf '%s\n❯ hello wor\n%s\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n' "$RULE" "$RULE" ;;
  typed_long) printf '%s\n❯ Session Start — do ALL of this in one turn, do NOT stop early: 1) tmux display-message to\n  identify yourself. 2) Read queue/tasks/ashigaru9.yaml. 3) Read queue/inbox/ashigaru9.yaml.\n  4) Read context_files. 5) Execute the assigned task to completion.\n%s\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n' "$RULE" "$RULE" ;;
  noprompt)   printf 'unexpected full-screen pager\n-- lines 1-40/200 (END) --\n' ;;
  blank)      printf '\n\n\n' ;;
esac
exec cat >> "$recv"
EOF
    chmod +x "$WORK/fakepane.sh"

    cat > "$WORK/notify_copy.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$(dirname "${BASH_SOURCE[0]}")/notify.out"
EOF
    chmod +x "$WORK/notify_copy.sh"

    # 未読 task_assigned 1件 + 現在のタスク
    cat > "$WORK/queue/tasks/ashigaru9.yaml" <<'EOF'
task:
  task_id: subtask_999_A
  status: assigned
EOF
    write_inbox task
}

teardown() {
    # 偽ペインを自然終了させる(kill 系は使わぬ・D006)。作業木は bats が消す。rm は書かぬ。
    stop_pane
}

# ── 道具 ──

iso_tmux() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$WORK/tmux" "$REAL_TMUX" "$@"; }

write_inbox() {
    local kind="$1"
    case "$kind" in
        task)  printf 'messages:\n- cmd_id: cmd_999\n  content: タスクYAMLを読んで作業開始せよ。\n  from: karo\n  id: msg_t1\n  read: false\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: task_assigned\n' > "$WORK/queue/inbox/ashigaru9.yaml" ;;
        normal) printf 'messages:\n- cmd_id: cmd_999\n  content: 報告を見よ。\n  from: karo\n  id: msg_t1\n  read: false\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: info\n' > "$WORK/queue/inbox/ashigaru9.yaml" ;;
        clear) printf 'messages:\n- cmd_id: cmd_999\n  content: /clear\n  from: karo\n  id: msg_t1\n  read: false\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: clear_command\n' > "$WORK/queue/inbox/ashigaru9.yaml" ;;
        model) printf 'messages:\n- cmd_id: cmd_999\n  content: /model sonnet\n  from: karo\n  id: msg_t1\n  read: false\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: model_switch\n' > "$WORK/queue/inbox/ashigaru9.yaml" ;;
        none)  printf 'messages:\n- cmd_id: cmd_999\n  content: 済み。\n  from: karo\n  id: msg_t1\n  read: true\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: info\n' > "$WORK/queue/inbox/ashigaru9.yaml" ;;
    esac
}

install_watcher() {
    cp "$1" "$WORK/scripts/inbox_watcher.sh"
    chmod +x "$WORK/scripts/inbox_watcher.sh"
}

start_pane() {
    iso_tmux new-session -d -s bgt -x 200 -y 50 "bash $WORK/fakepane.sh $1 $WORK/recv.log"
    iso_tmux set-option -p -t bgt:0.0 @agent_cli "${2:-claude}"
    local i
    for i in $(seq 1 40); do
        if [ "$1" = blank ]; then sleep 0.3; return 0; fi
        if iso_tmux capture-pane -t bgt:0.0 -p 2>/dev/null | grep -q -E '[^[:space:]]'; then return 0; fi
        sleep 0.25
    done
    return 1
}

stop_pane() {
    if [ -n "${WORK:-}" ] && [ -d "$WORK/tmux" ]; then
        iso_tmux send-keys -t bgt:0.0 C-d C-d 2>/dev/null || true
        local i
        for i in $(seq 1 12); do
            iso_tmux list-sessions >/dev/null 2>&1 || break
            sleep 0.5
        done
    fi
}

# 運転台の前置き(全試験共通): 見張り役を source し、本番と同じ厳しさ(set -euo pipefail)にする
write_preamble() {
    cat > "$WORK/preamble.sh" <<'EOF'
export PATH="$KG_WORK/bin:$PATH"
export __INBOX_WATCHER_TESTING__=1
export AGENT_ID=ashigaru9
export PANE_TARGET=bgt:0.0
export CLI_TYPE=claude
export SCRIPT_DIR="$KG_WORK"
export INBOX="$KG_WORK/queue/inbox/ashigaru9.yaml"
export LOCKFILE="${INBOX}.lock"
export IDLE_FLAG_DIR="$KG_WORK/flags"
export METRICS_FILE="$KG_WORK/queue/metrics/ashigaru9_selfwatch.yaml"
export BUSYGUARD_STATE_DIR="$KG_WORK/logs/watcher_busy"
export BUSYGUARD_NOTIFY_CMD="${KG_NOTIFY_CMD:-$KG_WORK/notify_copy.sh}"
export TMUX_TMPDIR="$KG_WORK/tmux"
unset TMUX TMUX_PANE
source "$KG_WORK/scripts/inbox_watcher.sh"
set -euo pipefail
sleep() { command sleep 0.05; }
EOF
}

# run_snippet <bash 断片> [env...] — 前置きの後で断片を走らせる(出力は $output)
run_snippet() {
    local snippet="$1"; shift
    write_preamble
    printf '%s\n' "$snippet" > "$WORK/snippet.sh"
    run env KG_WORK="$WORK" "$@" bash -c 'source "$KG_WORK/preamble.sh"; source "$KG_WORK/snippet.sh"'
    printf '%s\n' "$output" > "$WORK/snippet.log"
}

class_of() {   # class_of <screen> [empty|pending]  — 新しい画面を立てて分類を得る
    install_watcher "$NEW_WATCHER"
    start_pane "$1"
    run_snippet "wk_screen_class ${2:-empty}"
    stop_pane
    echo "$output" | tail -1
}

keys_total() { grep -c '^KEY' "$KEYLOG" || true; }
keys_enter() { grep -c -P '^KEY\t1\t' "$KEYLOG" || true; }

# ═══════════════════════════════════════════════════════════════
# C. 画面の分類 — 待機と言い切れる積極条件(許すものだけを数える)
# ═══════════════════════════════════════════════════════════════

@test "T-KG-C1: 待機中のプロンプトと言い切れる画面だけが idle(実機型・最小・旧枠型・自分の打ち残し inboxN)" {
    [ "$(class_of idle)" = idle ]
    [ "$(class_of idle_min)" = idle ]
    [ "$(class_of idle_old)" = idle ]
    [ "$(class_of residue)" = idle ]
    # 確認画面の文言を『引用した』だけの待機画面は、入力欄の4行上より遠いので idle
    [ "$(class_of idle_quote)" = idle ]
}

@test "T-KG-C2: 確認画面は confirm、作業中は working(入力欄が見えていても。確認画面の文言を引用して働き中の画面は working)" {
    [ "$(class_of confirm)" = confirm ]
    [ "$(class_of confirm2)" = confirm ]
    [ "$(class_of confirm_ynl)" = confirm ]
    [ "$(class_of working)" = working ]
    [ "$(class_of working_min)" = working ]
    [ "$(class_of quote)" = working ]
}

@test "T-KG-C3: 待機と言い切れぬ画面(入力欄が無い・見慣れぬ文字・提案文・打ちかけ・空画面)は undetermined = 送らない側" {
    [ "$(class_of noprompt)" = undetermined ]
    [ "$(class_of suggest)" = undetermined ]
    [ "$(class_of typing)" = undetermined ]
    [ "$(class_of blank)" = undetermined ]
    # 設定した文言に無い確認画面は confirm にはならないが、待機でもない(送らない)
    [ "$(class_of custom)" = undetermined ]
}

@test "T-KG-C4: 画面を取れない(pane不在)は failed = 送らない側" {
    install_watcher "$NEW_WATCHER"
    start_pane idle
    run_snippet 'PANE_TARGET=nosuch:9.9; wk_screen_class empty; wk_pane_ready empty && echo READY || echo NOT_READY'
    echo "$output"
    echo "$output" | grep -qx "failed"
    echo "$output" | grep -qx "NOT_READY"
}

@test "T-KG-C5: pending(自分が打った列の途中)では入力欄の文字・下へ折り返す打ちかけも許すが、確認画面・作業中は許さない" {
    [ "$(class_of typed_long pending)" = idle ]
    [ "$(class_of typing pending)" = idle ]
    [ "$(class_of typed_long empty)" = undetermined ]
    [ "$(class_of confirm pending)" = confirm ]
    [ "$(class_of working pending)" = working ]
    [ "$(class_of noprompt pending)" = undetermined ]
}

@test "T-KG-C6: 待機の目印(idle flag)は根拠にしない — flag があっても確認画面は送らず、flag が無くても待機画面は送れる" {
    install_watcher "$NEW_WATCHER"
    start_pane confirm
    touch "$WORK/flags/shogun_idle_ashigaru9"
    run_snippet 'wk_pane_ready empty && echo READY || echo "NOT_READY($WK_LAST_CLASS)"'
    echo "flag=あり confirm: $output"
    echo "$output" | grep -qx "NOT_READY(confirm)"
    stop_pane
    start_pane idle
    rm -f "$WORK/flags/shogun_idle_ashigaru9"
    run_snippet 'wk_pane_ready empty && echo READY || echo "NOT_READY($WK_LAST_CLASS)"'
    echo "flag=なし idle: $output"
    echo "$output" | grep -qx "READY"
}

@test "T-KG-C7: 確認画面の検出文言は設定(busy_guard.confirm_screen_regex)・環境変数で変えられ、誤記の ERE は既定へ戻る" {
    install_watcher "$NEW_WATCHER"
    # 既定では custom 画面は confirm でない(C3)。設定に文言を足すと confirm になる
    sed -i '/^busy_guard:/,/^[a-z_]*:/{/^busy_guard:/d;/^  /d}' "$WORK/config/settings.yaml"
    cat >> "$WORK/config/settings.yaml" <<'EOF'
busy_guard:
  confirm_screen_regex: 'Proceed with .* \[Ok/Cancel\]'
EOF
    start_pane custom
    run_snippet 'wk_screen_class empty'
    echo "設定で文言を変更: $output"
    [ "$(echo "$output" | tail -1)" = confirm ]
    stop_pane
    # 設定した文言に変えると、既定の文言だった確認画面は confirm でなくなる(=設定が効いている証拠)
    start_pane confirm
    run_snippet 'wk_screen_class empty'
    [ "$(echo "$output" | tail -1)" = undetermined ] || [ "$(echo "$output" | tail -1)" = working ]
    stop_pane
    # 環境変数が設定より優先
    start_pane confirm
    run_snippet 'wk_screen_class empty' BUSYGUARD_CONFIRM_RE='Do you want to '
    [ "$(echo "$output" | tail -1)" = confirm ]
    stop_pane
    # 誤記の ERE(閉じていない括弧)は既定へ戻り、検出が黙って無効にならない
    start_pane confirm
    run_snippet 'wk_screen_class empty; echo "RE=$BUSYGUARD_CONFIRM_RE"' BUSYGUARD_CONFIRM_RE='(unclosed'
    echo "$output"
    echo "$output" | grep -qx "confirm"
    echo "$output" | grep -q "RE=Esc to cancel|Do you want to "
}

# ═══════════════════════════════════════════════════════════════
# M. 場面×送信口 の送信回数表 — 直す前(本番版)と直した後(.new)を並べる
# ═══════════════════════════════════════════════════════════════
# 場面: 確認画面 / 作業中 / 判別不能 / 待機。待機の目印(idle flag)は『あり(古い目印が残る最悪の場合)』と『なし』の両方。
# 送信口: nudge / phase2(claude) / phase2(copilot=Escape) / phase3(/clear) / 着任時リセット / clear_command / model_switch /
#          入力欄掃除(C-u・未読0) / 起動の口上
# 記録: 送信ごとに KEY 行(Enter を含むか)。ポートの区切りは PORT 行。

write_matrix_driver() {
    cat > "$WORK/matrix.sh" <<'EOF'
export ASW_PHASE=1     # 通常 nudge を flag で抑止する設定に依らず、送信口そのものを通す
flagfile="$IDLE_FLAG_DIR/shogun_idle_ashigaru9"
reset_state() {
    NEW_CONTEXT_SENT=0; STARTUP_PROMPT_SENT=0; LAST_CLEAR_TS=0; LAST_NUDGE_TS=0; LAST_NUDGE_COUNT=""
    LAST_ASSIGNMENT_TS=0; FIRST_UNREAD_SEEN=0
    if [ "$KG_FLAG" = present ]; then touch "$flagfile"; else rm -f "$flagfile"; fi
}
mkinbox() {
    local kind="$1"
    case "$kind" in
        task)  printf 'messages:\n- cmd_id: c\n  content: x\n  from: karo\n  id: m1\n  read: false\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: task_assigned\n' > "$INBOX" ;;
        clear) printf 'messages:\n- cmd_id: c\n  content: /clear\n  from: karo\n  id: m1\n  read: false\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: clear_command\n' > "$INBOX" ;;
        model) printf 'messages:\n- cmd_id: c\n  content: /model sonnet\n  from: karo\n  id: m1\n  read: false\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: model_switch\n' > "$INBOX" ;;
        none)  printf 'messages:\n- cmd_id: c\n  content: x\n  from: karo\n  id: m1\n  read: true\n  task_id: subtask_999_A\n  timestamp: "2026-10-12T22:00:00"\n  type: info\n' > "$INBOX" ;;
    esac
}
port() { echo "PORT $1" >> "$KEYLOG"; reset_state; }
now=$(date +%s)
port nudge;          mkinbox task;  NEW_CONTEXT_SENT=1; FIRST_UNREAD_SEEN=$((now - 60));  process_unread timeout || true
port phase2-claude;  mkinbox task;  NEW_CONTEXT_SENT=1; FIRST_UNREAD_SEEN=$((now - 150)); process_unread timeout || true
port phase2-copilot; mkinbox task;  NEW_CONTEXT_SENT=1; FIRST_UNREAD_SEEN=$((now - 150)); tmux set-option -p -t bgt:0.0 @agent_cli copilot; CLI_TYPE=copilot; process_unread timeout || true; tmux set-option -p -t bgt:0.0 @agent_cli claude; CLI_TYPE=claude
port phase3-clear;   mkinbox task;  NEW_CONTEXT_SENT=1; FIRST_UNREAD_SEEN=$((now - 400)); process_unread timeout || true
port context-reset;  mkinbox task;  NEW_CONTEXT_SENT=0; FIRST_UNREAD_SEEN=0;              process_unread timeout || true
port clear_command;  mkinbox clear; process_unread event || true
port model_switch;   mkinbox model; process_unread event || true
port clear-input;    mkinbox none;  process_unread timeout || true
port startup-prompt; send_startup_prompt || true
echo "MATRIX_DONE"
EOF
}

# matrix_run <prod|new> <scene> <present|absent> — 1場面分を走らせ、$WORK/matrix_<who>_<scene>_<flag>.keys に KEYLOG を保存する
matrix_run() {
    local who="$1" scene="$2" flag="$3" out
    : > "$KEYLOG"; : > "$WORK/recv.log"      # 場面ごとに記録を空にする(前の場面の入力を持ち越さぬ)
    if [ "$who" = prod ]; then install_watcher "$PROD_WATCHER"; else install_watcher "$NEW_WATCHER"; fi
    start_pane "$scene"
    write_matrix_driver
    # 偽ペインの画面を、場面名どおりのまま保つ(送信の影響を受けぬ静的な画面)
    run_snippet 'source "$KG_WORK/matrix.sh"' KG_FLAG="$flag" WK_STARTUP_WAIT_TRIES=1
    out="$output"
    echo "$out" | grep -q "MATRIX_DONE"
    # 運転が終わるまで待ち、偽ペインが入力を書き終えるのを待つ
    sleep 1
    mkdir -p "$BATS_FILE_TMPDIR/matrix"
    cp "$KEYLOG" "$BATS_FILE_TMPDIR/matrix/${who}_${scene}_${flag}.keys"
    cp "$WORK/recv.log" "$BATS_FILE_TMPDIR/matrix/${who}_${scene}_${flag}.recv"
    cp "$WORK/snippet.log" "$BATS_FILE_TMPDIR/matrix/${who}_${scene}_${flag}.log"
    stop_pane
}

# port_count <keysfile> <port> <total|enter> — そのポートの送信回数
port_count() {
    awk -v p="$2" -v m="$3" '
        /^PORT /{cur=$2; next}
        /^KEY\t/{ if (cur==p) { t++; split($0,a,"\t"); if (a[2]==1) e++ } }
        END{ if (m=="enter") print e+0; else print t+0 }' "$1"
}

PORTS="nudge phase2-claude phase2-copilot phase3-clear context-reset clear_command model_switch clear-input startup-prompt"

@test "T-KG-M1: 【直した後】.new — 確認画面・作業中・判別不能の画面には、idle flag が残っていても、全ての送信口で Enter を含むキーが 0 回" {
    local scene flag p
    for scene in confirm working noprompt; do
        for flag in present absent; do
            matrix_run new "$scene" "$flag"
            local f="$BATS_FILE_TMPDIR/matrix/new_${scene}_${flag}.keys"
            echo "--- new / $scene / flag=$flag: KEY 行 $(grep -c '^KEY' "$f")、うち Enter $(grep -c -P '^KEY\t1\t' "$f") ---"
            [ "$(grep -c '^KEY' "$f")" -eq 0 ]
            [ ! -s "$BATS_FILE_TMPDIR/matrix/new_${scene}_${flag}.recv" ]
        done
    done
}

@test "T-KG-M2: 【直した後】.new — 打鍵ゼロの間、見送りが [KEY-WITHHELD] で記録される(黙って捨てない)。確認画面の足軽には即時の知らせが出る" {
    local f="$BATS_FILE_TMPDIR/matrix/new_confirm_present.log"
    [ -f "$f" ]
    grep -q "\[KEY-WITHHELD\]" "$f"
    grep -q "screen=confirm" "$f"
    grep -q "notify(confirm)" "$f"
    f="$BATS_FILE_TMPDIR/matrix/new_noprompt_present.log"
    grep -q "screen=undetermined" "$f"
}

@test "T-KG-M3: 【直した後】.new — 待機の画面では従来どおり起こせる(退行なし): 全送信口が動き、Escape も届く" {
    local flag p
    for flag in present absent; do
        matrix_run new idle "$flag"
        local f="$BATS_FILE_TMPDIR/matrix/new_idle_${flag}.keys"
        for p in nudge phase2-claude phase2-copilot phase3-clear context-reset clear_command model_switch clear-input startup-prompt; do
            local n; n=$(port_count "$f" "$p" total)
            echo "new / idle / flag=$flag / $p: $n 回(Enter $(port_count "$f" "$p" enter))"
            # 通常の起こし(nudge)は、待機の目印が無い間は従来どおり『働き中』扱いで送らぬ(本番版も同じ。送らぬ側への据え置きで退行ではない)
            if [ "$p" = nudge ] && [ "$flag" = absent ]; then [ "$n" -eq 0 ]; continue; fi
            [ "$n" -ge 1 ]
        done
        # 起こし(nudge)の中身: C-u → inbox1 → Enter
        if [ "$flag" = present ]; then
            awk '/^PORT nudge/{on=1;next}/^PORT /{on=0}on' "$f" | grep -q -P '^KEY\t1\tEnter'
        fi
        grep -q -x "inbox1" "$BATS_FILE_TMPDIR/matrix/new_idle_${flag}.recv"
        # Escape 経路(copilot)で Escape が届く
        awk '/^PORT phase2-copilot/{on=1;next}/^PORT /{on=0}on' "$f" | grep -q "Escape"
        # /clear が届く
        grep -q -x "/clear" "$BATS_FILE_TMPDIR/matrix/new_idle_${flag}.recv"
    done
}

@test "T-KG-M4: 【直す前】本番版 scripts/inbox_watcher.sh — 同じ場面(確認画面・作業中・判別不能)に idle flag が残ると Enter を含むキーが送られる(今宵 00:10〜00:12 の再現)" {
    local scene flag
    for scene in confirm working noprompt idle; do
        for flag in present absent; do
            matrix_run prod "$scene" "$flag"
            local f="$BATS_FILE_TMPDIR/matrix/prod_${scene}_${flag}.keys"
            echo "--- prod / $scene / flag=$flag: KEY 行 $(grep -c '^KEY' "$f")、うち Enter $(grep -c -P '^KEY\t1\t' "$f") ---"
        done
    done
    # 確認画面 + idle flag あり: 起こし(inbox1+Enter)が確認画面に入る
    local f="$BATS_FILE_TMPDIR/matrix/prod_confirm_present.keys"
    [ "$(port_count "$f" nudge enter)" -ge 1 ]
    grep -q -x "inbox1" "$BATS_FILE_TMPDIR/matrix/prod_confirm_present.recv"
    # 作業中 + idle flag あり: 同じく送られる
    f="$BATS_FILE_TMPDIR/matrix/prod_working_present.keys"
    [ "$(port_count "$f" nudge enter)" -ge 1 ]
    # 判別不能 + 目印なし: 通常の起こしは目印が無いので出ぬが、画面を見ぬ他の送信口(/clear・起動の口上 ほか)には Enter が送られる
    f="$BATS_FILE_TMPDIR/matrix/prod_noprompt_absent.keys"
    [ "$(port_count "$f" nudge enter)" -eq 0 ]
    [ "$(grep -c -P '^KEY\t1\t' "$f")" -ge 1 ]
    [ "$(port_count "$f" startup-prompt enter)" -ge 1 ]
}

@test "T-KG-M5: 【表】場面×送信口の送信回数(Enter を含む送信)— 直す前(本番版)/ 直した後(.new)" {
    local f
    for f in prod_confirm_present new_confirm_present; do [ -f "$BATS_FILE_TMPDIR/matrix/$f.keys" ]; done
    local who scene flag p
    printf '\n| 場面 | idle flag | 版 | %s |\n' "$(echo $PORTS | sed 's/ / | /g')"
    printf '|---|---|---|%s\n' "$(for p in $PORTS; do printf -- '---|'; done)"
    for scene in confirm working noprompt idle; do
        for flag in present absent; do
            for who in prod new; do
                f="$BATS_FILE_TMPDIR/matrix/${who}_${scene}_${flag}.keys"
                [ -f "$f" ] || continue
                printf '| %s | %s | %s |' "$scene" "$flag" "$who"
                for p in $PORTS; do printf ' %s/%s |' "$(port_count "$f" "$p" total)" "$(port_count "$f" "$p" enter)"; done
                printf '\n'
            done
        done
    done
    echo "(セルは『送信回数/うち Enter を含む回数』)"
}

@test "T-KG-M6: 待機の画面では 本番版と .new の送信が同じ(退行なし) — 各送信口の送信回数と、偽ペインが受け取った入力列が一致" {
    local flag p
    for flag in present absent; do
        local fp="$BATS_FILE_TMPDIR/matrix/prod_idle_${flag}.keys" fn="$BATS_FILE_TMPDIR/matrix/new_idle_${flag}.keys"
        [ -f "$fp" ] && [ -f "$fn" ]
        for p in $PORTS; do
            echo "idle / flag=$flag / $p: prod=$(port_count "$fp" "$p" total) new=$(port_count "$fn" "$p" total)"
            [ "$(port_count "$fp" "$p" total)" = "$(port_count "$fn" "$p" total)" ]
        done
        diff "$BATS_FILE_TMPDIR/matrix/prod_idle_${flag}.recv" "$BATS_FILE_TMPDIR/matrix/new_idle_${flag}.recv"
    done
}

# ═══════════════════════════════════════════════════════════════
# N. 確認画面・判別不能の知らせ(送り先は写し。本物の ntfy は送らない)
# ═══════════════════════════════════════════════════════════════

NBASE=1800000000
# tick_run <未読件数> "<秒オフセット...>" [env...] — busy_guard_tick を各時刻で回す
tick_run() {
    local unread="$1" offs="$2"; shift 2
    run_snippet 'for off in $KG_OFFS; do export INBOX_WATCHER_TEST_NOW=$((KG_BASE + off)); busy_guard_tick "$KG_UNREAD"; done; echo TICKS_DONE' \
        KG_OFFS="$offs" KG_BASE="$NBASE" KG_UNREAD="$unread" BUSYGUARD_RESUME_GAP_SEC=1000000 "$@"
    [[ "$output" == *"TICKS_DONE"* ]]
}
ncount() { grep -c . "$WORK/notify.out" || true; }

@test "T-KG-N1: 確認画面と判じたときは待たずにすぐ1回知らせる(60分待ちにせぬ)。足軽名・task_id・状態が載り、秘匿値は載らぬ" {
    install_watcher "$NEW_WATCHER"
    start_pane confirm
    tick_run 0 "0" NTFY_TOPIC=ZZ_FAKE_SECRET_TOPIC_77c1
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(ncount)" -eq 1 ]
    grep -q "ashigaru9" "$WORK/notify.out"
    grep -q "subtask_999_A" "$WORK/notify.out"
    grep -q "確認画面" "$WORK/notify.out"
    ! grep -rqF "ZZ_FAKE_SECRET_TOPIC_77c1" "$WORK/notify.out" "$WORK/snippet.log" "$WORK/logs"
    ! grep -qiE "topic|token|bearer|password" "$WORK/notify.out"
}

@test "T-KG-N2: 同じ確認画面が続く間は毎tick送らず、30分で1回だけ再通知する(30秒刻みの観測を含む)" {
    install_watcher "$NEW_WATCHER"
    start_pane confirm
    local offs="" t
    for t in $(seq 0 30 1770); do offs="$offs $t"; done      # 0〜29分30秒を30秒刻み(60回)
    tick_run 0 "$offs"
    [ "$(ncount)" -eq 1 ]
    tick_run 0 "1800 1830 1860"
    [ "$(ncount)" -eq 2 ]
    tick_run 0 "3599"
    [ "$(ncount)" -eq 2 ]
    tick_run 0 "3600"
    # 3600秒: 確認画面の再通知(30分ぶり)と、連続60分の知らせ
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(grep -c '確認画面で止まっている' "$WORK/notify.out")" -eq 3 ]
}

@test "T-KG-N3: 別の確認画面に変わったら(画面の署名が違う)待たずにすぐ知らせ、待機を挟んで再び確認画面になってもすぐ知らせる" {
    install_watcher "$NEW_WATCHER"
    start_pane confirm
    tick_run 0 "0 60"
    [ "$(ncount)" -eq 1 ]
    stop_pane
    start_pane confirm2
    tick_run 0 "120"
    [ "$(ncount)" -eq 2 ]
    stop_pane
    start_pane idle
    tick_run 0 "180"
    [ "$(ncount)" -eq 2 ]
    grep -q "^confirm_since=0$" "$WORK/logs/watcher_busy/ashigaru9.state"
    stop_pane
    start_pane confirm
    tick_run 0 "240"
    [ "$(ncount)" -eq 3 ]
}

@test "T-KG-N4: 待機と判じられぬ画面(判別不能)のまま未読が溜まると30分で1回知らせる。未読が無ければ(無害な見慣れぬ画面で)騒がない" {
    install_watcher "$NEW_WATCHER"
    start_pane suggest
    tick_run 3 "0 600 1200 1799"
    [ "$(ncount)" -eq 0 ]
    tick_run 3 "1800 1860"
    echo "--- notify.out ---"; cat "$WORK/notify.out"
    [ "$(ncount)" -eq 1 ]
    grep -q "待機と判じられぬ画面" "$WORK/notify.out"
    grep -q "ashigaru9" "$WORK/notify.out"
    # 未読 0 のまま 3 時間: 知らせない
    : > "$WORK/notify.out"; rm -f "$WORK/logs/watcher_busy/ashigaru9.state"
    tick_run 0 "0 3600 7200 10800"
    [ "$(ncount)" -eq 0 ]
}

@test "T-KG-N5: 作業中の画面の知らせは従来どおり(未読30分で①、連続60分で②)で、文面は『働き中のまま』" {
    install_watcher "$NEW_WATCHER"
    start_pane working
    tick_run 2 "0 600 1200 1799"
    [ "$(ncount)" -eq 0 ]
    tick_run 2 "1800"
    [ "$(ncount)" -eq 1 ]
    grep -q "働き中のまま未読" "$WORK/notify.out"
    tick_run 2 "3600"
    grep -q "働き中のまま.*連続" "$WORK/notify.out"
}

# ═══════════════════════════════════════════════════════════════
# F. ntfy の送達成否をログに残す(軍師指摘1)
# ═══════════════════════════════════════════════════════════════

@test "T-KG-F1: ntfy 差替が非0で終わる場面 — 戻り値が [NOTIFY-FAIL] rc=3 でログに残り、watcher は落ちず、黙って捨てず 300秒後に再試行し、成功すれば [NOTIFY-OK]" {
    install_watcher "$NEW_WATCHER"
    start_pane confirm
    cat > "$WORK/notify_fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
    chmod +x "$WORK/notify_fail.sh"
    tick_run 0 "0 60 120" KG_NOTIFY_CMD="$WORK/notify_fail.sh"
    echo "--- log ---"; grep -E "NOTIFY|notify\(" "$WORK/snippet.log"
    # 落ちていない(TICKS_DONE は tick_run が確認済み)
    [ "$(grep -c '\[NOTIFY-FAIL\]' "$WORK/snippet.log")" -eq 1 ]
    grep -q "\[NOTIFY-FAIL\] kind=confirm agent=ashigaru9 rc=3" "$WORK/snippet.log"
    ! grep -q "\[NOTIFY-OK\]" "$WORK/snippet.log"
    # 失敗は『送れた』と記帳されない(次の周期で再試行される)
    grep -q "^confirm_notified=0$" "$WORK/logs/watcher_busy/ashigaru9.state"
    # 300秒後に再試行(もう1回 FAIL)
    tick_run 0 "299"
    [ "$(grep -c '\[NOTIFY-FAIL\]' "$WORK/snippet.log")" -eq 0 ]
    tick_run 0 "301" KG_NOTIFY_CMD="$WORK/notify_fail.sh"
    [ "$(grep -c '\[NOTIFY-FAIL\]' "$WORK/snippet.log")" -eq 1 ]
    # 直った(成功する差替)→ [NOTIFY-OK] rc=0 を記録し、送れたと記帳
    tick_run 0 "602"
    grep -q "\[NOTIFY-OK\] kind=confirm agent=ashigaru9 rc=0" "$WORK/snippet.log"
    ! grep -q "^confirm_notified=0$" "$WORK/logs/watcher_busy/ashigaru9.state"
    [ "$(ncount)" -eq 1 ]
}

@test "T-KG-F2: 失敗の理由は分類だけを記録する(secrets 欠落・topic 未設定・curl・HTTP)。生のエラー文・topic・パスはログに載せない" {
    install_watcher "$NEW_WATCHER"
    start_pane confirm
    local case_ msg reason
    for case_ in "secrets_file_missing|ERROR: secrets.env not found: /nonexistent/zz_path/secrets.env (NTFY_TOPIC cannot be read)" \
                 "topic_unset|ERROR: NTFY_TOPIC is not set in /nonexistent/zz_path/secrets.env" \
                 "curl_error|ntfy送信失敗: curl exit=6" \
                 "http_error|ntfy送信失敗: HTTP status=403" \
                 "unclassified|something else ZZ_FAKE_SECRET_TOPIC_77c1"; do
        reason="${case_%%|*}"; msg="${case_#*|}"
        printf '#!/usr/bin/env bash\necho %q >&2\nexit 1\n' "$msg" > "$WORK/notify_err.sh"
        chmod +x "$WORK/notify_err.sh"
        rm -f "$WORK/logs/watcher_busy/ashigaru9.state"
        tick_run 0 "0" KG_NOTIFY_CMD="$WORK/notify_err.sh" NTFY_TOPIC=ZZ_FAKE_SECRET_TOPIC_77c1
        echo "case=$reason: $(grep '\[NOTIFY-FAIL\]' "$WORK/snippet.log")"
        grep -q "\[NOTIFY-FAIL\] kind=confirm agent=ashigaru9 rc=1 reason=$reason " "$WORK/snippet.log"
        ! grep -q "zz_path" "$WORK/snippet.log"
        ! grep -q "ZZ_FAKE_SECRET_TOPIC_77c1" "$WORK/snippet.log"
        ! grep -rqF "ZZ_FAKE_SECRET_TOPIC_77c1" "$WORK/logs"
    done
}

@test "T-KG-F3: 実物の scripts/ntfy.sh で secrets.env が欠落している場面 — 送信(ネット)に入る前に失敗し、watcher は [NOTIFY-FAIL] reason=secrets_file_missing を記録して落ちない" {
    install_watcher "$NEW_WATCHER"
    start_pane confirm
    # BUSYGUARD_NOTIFY_CMD を空にして実物の経路(scripts/ntfy.sh)を通す。secrets の置場は存在しないパス
    run_snippet 'export BUSYGUARD_NOTIFY_CMD=""; export INBOX_WATCHER_TEST_NOW=1800000000; busy_guard_tick 0; echo TICKS_DONE' \
        SHOGUN_SECRETS_FILE="$WORK/no_such_dir/secrets.env"
    echo "$output" | grep -E "NOTIFY|TICKS"
    [[ "$output" == *"TICKS_DONE"* ]]
    echo "$output" | grep -q "\[NOTIFY-FAIL\] kind=confirm agent=ashigaru9 rc=1 reason=secrets_file_missing"
    ! echo "$output" | grep -q "no_such_dir"
}

# ═══════════════════════════════════════════════════════════════
# S. 送信口が1本・設定
# ═══════════════════════════════════════════════════════════════

@test "T-KG-S1: .new に実行される tmux send-keys は wk_send_keys の1箇所だけ(送信口を数える)" {
    local lines
    lines="$(grep -n 'tmux send-keys' "$NEW_WATCHER" | grep -v -E '^[0-9]+:[[:space:]]*#' | grep -v -E 'echo|WARNING' || true)"
    echo "$lines"
    [ "$(echo "$lines" | grep -c .)" -eq 1 ]
    # その1箇所は wk_send_keys の本体の中
    local ln fn
    ln="$(echo "$lines" | head -1 | cut -d: -f1)"
    fn="$(awk -v n="$ln" 'NR<=n && /^[a-z_]+\(\) \{/{f=$1} END{print f}' "$NEW_WATCHER")"
    echo "関数: $fn"
    [ "$fn" = "wk_send_keys()" ]
    # 他の関数は send-keys を直接書かず wk_send_keys を使う(本数の目安)
    [ "$(grep -c 'wk_send_keys' "$NEW_WATCHER")" -ge 30 ]
}

@test "T-KG-S2: settings.yaml.example に新しい鍵(confirm_repeat_notify_minutes・confirm_screen_regex の説明)があり、既定値が実効値(30)と同じ" {
    grep -A12 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "confirm_repeat_notify_minutes: 30"
    grep -A12 "^busy_guard:" "$SCRIPT_DIR/config/settings.yaml.example" | grep -q "confirm_screen_regex"
    install_watcher "$NEW_WATCHER"
    start_pane idle
    run_snippet 'echo "REPEAT=$BUSYGUARD_CONFIRM_REPEAT_MIN"'
    echo "$output" | grep -qx "REPEAT=30"
}

# ═══════════════════════════════════════════════════════════════
# I. 隔離の実測
# ═══════════════════════════════════════════════════════════════

@test "T-KG-I1: 試験は使い捨ての別 tmux サーバだけに触る — ソケットは作業木の中・既定ソケットでない、ラッパは使い捨て以外へ中継せず記録もしない" {
    install_watcher "$NEW_WATCHER"
    start_pane idle
    local sock
    sock="$(iso_tmux display-message -p '#{socket_path}')"
    echo "socket=$sock"
    case "$sock" in "$WORK"/*) ;; *) false ;; esac
    [ "$sock" != "/tmp/tmux-$(id -u)/default" ]
    # 生きた陣の既定ソケットを指す環境(TMUX_TMPDIR 無し)でラッパが send-keys を拒否し、記録もしない
    : > "$KEYLOG"
    run env -u TMUX_TMPDIR -u TMUX -u TMUX_PANE KG_WORK="$WORK" KEYLOG="$KEYLOG" REAL_TMUX=/bin/false "$WORK/bin/tmux" send-keys -t multiagent:0.0 "x"
    echo "status=$status output=$output"
    [ "$status" -eq 97 ]
    [ "$(grep -c '^KEY' "$KEYLOG")" -eq 0 ]
    # 別の場所の TMUX_TMPDIR でも拒否
    run env TMUX_TMPDIR=/tmp KG_WORK="$WORK" KEYLOG="$KEYLOG" REAL_TMUX=/bin/false "$WORK/bin/tmux" send-keys -t multiagent:0.0 "x"
    [ "$status" -eq 97 ]
}
