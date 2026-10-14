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
# T-KG-D* : 薄字(SGR 2)の提案文の例外(S-23/S-24)  — 実機の Claude Code の実画面の写し(-e つき・tests/fixtures/claude_screens/)で示す
# T-KG-A* : cmd_232 の非待機29場面+確認画面の実画面の当て直し(直す前=本番版/直した後=.new を一つの表で)

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PROD_WATCHER="$SCRIPT_DIR/scripts/inbox_watcher.sh"
FX_DIR="$SCRIPT_DIR/tests/fixtures/claude_screens"
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
mode="$1"; recv="$2"; fxdir="${3:-}"; fxfile="${4:-}"
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
  fx_*)       printf '%s' "$(cat "$fxdir/${mode#fx_}.ansi")" ;;
  fxfile)     printf '%s' "$(cat "$fxfile")" ;;
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
    iso_tmux new-session -d -s bgt -x 200 -y 50 "bash $WORK/fakepane.sh $1 $WORK/recv.log $FX_DIR ${3:-}"
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
# D. 薄字(SGR 2)の提案文の例外(S-23/S-24)— 実機の Claude Code の実画面の写し(-e つき)で示す
# ═══════════════════════════════════════════════════════════════
# 写しは tests/fixtures/claude_screens/*.ansi(使い捨ての tmux サーバで本物の claude を動かして capture-pane -p -e で採取。
# 生きた陣には触れていない。パスだけ /work/cwd に置換)。偽ペインへ cat して画面と属性を再現する。

class_of_file() {   # class_of_file <ansi ファイル> [empty|pending] — 属性つきの画面を立てて分類と薄字の例外の使用を得る
    install_watcher "$NEW_WATCHER"
    start_pane fxfile claude "$1"
    run_snippet "wk_pane_ready ${2:-empty} || true; echo \"CLASS=\$WK_LAST_CLASS PLACEHOLDER=\$WK_PLACEHOLDER\""
    stop_pane
    echo "$output" | tail -1
}

@test "T-KG-D1: 実画面の写し — 提案文つきの待機は薄字の例外で idle(2種)、打ちかけの文字・作業中・確認画面は idle にならぬ" {
    [ "$(class_of_file "$FX_DIR/idle_placeholder.ansi")" = "CLASS=idle PLACEHOLDER=1" ]
    [ "$(class_of_file "$FX_DIR/idle_suggestion_after_turn.ansi")" = "CLASS=idle PLACEHOLDER=1" ]
    [ "$(class_of_file "$FX_DIR/typed_text.ansi")" = "CLASS=undetermined PLACEHOLDER=0" ]
    [ "$(class_of_file "$FX_DIR/working_stream.ansi")" = "CLASS=working PLACEHOLDER=0" ]
    [ "$(class_of_file "$FX_DIR/working_tool.ansi")" = "CLASS=working PLACEHOLDER=0" ]
    [ "$(class_of_file "$FX_DIR/confirm_bash.ansi")" = "CLASS=confirm PLACEHOLDER=0" ]
    [ "$(class_of_file "$FX_DIR/confirm_exit_dialog.ansi")" = "CLASS=confirm PLACEHOLDER=0" ]
}

@test "T-KG-D2: 薄字と証明できぬ入力欄は idle にならぬ(通常の字が混じる・薄字の属性が無い・コロン区切りの SGR・色の引数の 2・未知の制御列)" {
    local src="$FX_DIR/idle_placeholder.ansi" v out
    mkdir -p "$WORK/variants"
    # 元の入力欄: ESC[39m ❯ NBSP ESC[2m Try "refactor inbox_watcher.sh" ESC[0m
    grep -aq $'\x1b\\[2mTry "refactor inbox_watcher.sh"\x1b\\[0m' "$src"
    sed $'s/\x1b\\[2m//' "$src"                                                           > "$WORK/variants/nodim.ansi"
    sed $'s/\x1b\\[2mTry /\x1b[2mTry \x1b[22m/'  "$src"                                   > "$WORK/variants/mixed_after.ansi"
    sed $'s/\x1b\\[2mTry /\x1b[0mTry \x1b[2m/'   "$src"                                   > "$WORK/variants/mixed_before.ansi"
    sed $'s/\x1b\\[2m/\x1b[2:1m/'                "$src"                                   > "$WORK/variants/colon_sgr.ansi"
    sed $'s/\x1b\\[2m/\x1b[38;2;10;20;30m/'      "$src"                                   > "$WORK/variants/truecolor_2.ansi"
    sed $'s/\x1b\\[2m/\x1b[38;5;2m/'             "$src"                                   > "$WORK/variants/color256_2.ansi"
    sed $'s/\x1b\\[2mTry /\x1b[2mTry \x1b[0m/'   "$src"                                   > "$WORK/variants/reset_mid.ansi"
    for v in nodim mixed_after mixed_before colon_sgr truecolor_2 color256_2 reset_mid; do
        out="$(class_of_file "$WORK/variants/$v.ansi")"
        echo "variant $v => $out"
        [ "$out" = "CLASS=undetermined PLACEHOLDER=0" ]
    done
    # 未知の制御列(tmux は capture-pane で SGR 以外を再描画して落とすので、関数へ直接渡して示す)
    install_watcher "$NEW_WATCHER"
    start_pane idle
    run_snippet 'P=$(printf "\033[39m❯\302\240\033[2mTry\033[0m"); wk_prompt_is_dim_placeholder "$P" && echo "base=PLACEHOLDER" || echo "base=NO"
        P=$(printf "\033[39m❯\302\240\0337\033[2mTry\033[0m"); wk_prompt_is_dim_placeholder "$P" && echo "esc7=PLACEHOLDER" || echo "esc7=NO"
        P=$(printf "\033[39m❯\302\240\033]8;;http://x\033\\\\\033[2mTry\033[0m"); wk_prompt_is_dim_placeholder "$P" && echo "osc=PLACEHOLDER" || echo "osc=NO"
        P=$(printf "\033[39m❯\302\240\033[2C\033[2mTry\033[0m"); wk_prompt_is_dim_placeholder "$P" && echo "cursor_move=PLACEHOLDER" || echo "cursor_move=NO"
        P=$(printf "no prompt glyph \033[2mTry\033[0m"); wk_prompt_is_dim_placeholder "$P" && echo "noglyph=PLACEHOLDER" || echo "noglyph=NO"
        P=$(printf "\033[39m❯\302\240\033[2m   \033[0m"); wk_prompt_is_dim_placeholder "$P" && echo "blank_dim=PLACEHOLDER" || echo "blank_dim=NO"'
    echo "$output"
    echo "$output" | grep -qx "base=PLACEHOLDER"
    echo "$output" | grep -qx "esc7=NO"
    echo "$output" | grep -qx "osc=NO"
    echo "$output" | grep -qx "cursor_move=PLACEHOLDER"
    echo "$output" | grep -qx "noglyph=NO"
    echo "$output" | grep -qx "blank_dim=NO"
    stop_pane
}

@test "T-KG-D3: 薄字と証明できる別の書式は idle(太字+薄字・色+薄字・薄字の解除で終わる)。色の引数の 2 は薄字と取り違えぬ" {
    local src="$FX_DIR/idle_placeholder.ansi" v out
    mkdir -p "$WORK/variants"
    sed $'s/\x1b\\[2m/\x1b[1;2m/'                "$src" > "$WORK/variants/bold_dim.ansi"
    sed $'s/\x1b\\[2m/\x1b[38;5;246;2m/'         "$src" > "$WORK/variants/color_dim.ansi"
    sed $'s/\x1b\\[2m/\x1b[38;2;1;2;3;2m/'       "$src" > "$WORK/variants/truecolor_then_dim.ansi"
    sed $'s/\x1b\\[0m$/\x1b[22m\x1b[39m/'        "$src" > "$WORK/variants/ends_22.ansi"
    for v in bold_dim color_dim truecolor_then_dim ends_22; do
        out="$(class_of_file "$WORK/variants/$v.ansi")"
        echo "variant $v => $out"
        [ "$out" = "CLASS=idle PLACEHOLDER=1" ]
    done
}

@test "T-KG-D4: 実機の空の入力欄は『❯』の後が NBSP — 空白と見なして idle(薄字の例外は使わぬ)" {
    mkdir -p "$WORK/variants"
    sed $'s/\x1b\\[2mTry .*\x1b\\[0m//' "$FX_DIR/idle_placeholder.ansi" > "$WORK/variants/empty_nbsp.ansi"
    grep -aq $'\xc2\xa0$' "$WORK/variants/empty_nbsp.ansi"
    [ "$(class_of_file "$WORK/variants/empty_nbsp.ansi")" = "CLASS=idle PLACEHOLDER=0" ]
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
do_port() {
    case "$1" in
    nudge)          port nudge;          mkinbox task;  NEW_CONTEXT_SENT=1; FIRST_UNREAD_SEEN=$((now - 60));  process_unread timeout || true ;;
    phase2-claude)  port phase2-claude;  mkinbox task;  NEW_CONTEXT_SENT=1; FIRST_UNREAD_SEEN=$((now - 150)); process_unread timeout || true ;;
    phase2-copilot) port phase2-copilot; mkinbox task;  NEW_CONTEXT_SENT=1; FIRST_UNREAD_SEEN=$((now - 150)); tmux set-option -p -t bgt:0.0 @agent_cli copilot; CLI_TYPE=copilot; process_unread timeout || true; tmux set-option -p -t bgt:0.0 @agent_cli claude; CLI_TYPE=claude ;;
    phase3-clear)   port phase3-clear;   mkinbox task;  NEW_CONTEXT_SENT=1; FIRST_UNREAD_SEEN=$((now - 400)); process_unread timeout || true ;;
    context-reset)  port context-reset;  mkinbox task;  NEW_CONTEXT_SENT=0; FIRST_UNREAD_SEEN=0;              process_unread timeout || true ;;
    clear_command)  port clear_command;  mkinbox clear; process_unread event || true ;;
    model_switch)   port model_switch;   mkinbox model; process_unread event || true ;;
    clear-input)    port clear-input;    mkinbox none;  process_unread timeout || true ;;
    startup-prompt) port startup-prompt; send_startup_prompt || true ;;
    esac
}
if [ -n "${KG_ONLY_PORT:-}" ]; then
    do_port "$KG_ONLY_PORT"
else
    for p in nudge phase2-claude phase2-copilot phase3-clear context-reset clear_command model_switch clear-input startup-prompt; do do_port "$p"; done
fi
echo "MATRIX_DONE"
EOF
}

# matrix_run <prod|new> <scene> <present|absent> — 1場面分を走らせ、$WORK/matrix_<who>_<scene>_<flag>.keys に KEYLOG を保存する
matrix_run() {
    local who="$1" scene="$2" flag="$3" only="${4:-}" out
    : > "$KEYLOG"; : > "$WORK/recv.log"      # 場面ごとに記録を空にする(前の場面の入力を持ち越さぬ)
    if [ "$who" = prod ]; then install_watcher "$PROD_WATCHER"; else install_watcher "$NEW_WATCHER"; fi
    start_pane "$scene"
    write_matrix_driver
    # 偽ペインの画面を、場面名どおりのまま保つ(送信の影響を受けぬ静的な画面)
    run_snippet 'source "$KG_WORK/matrix.sh"' KG_FLAG="$flag" KG_ONLY_PORT="$only" WK_STARTUP_WAIT_TRIES=1
    out="$output"
    echo "$out" | grep -q "MATRIX_DONE"
    # 運転が終わるまで待ち、偽ペインが入力を書き終えるのを待つ
    sleep 1
    mkdir -p "$BATS_FILE_TMPDIR/matrix"
    local tag="${who}_${scene}_${flag}${only:+_$only}"
    cp "$KEYLOG" "$BATS_FILE_TMPDIR/matrix/$tag.keys"
    cp "$WORK/recv.log" "$BATS_FILE_TMPDIR/matrix/$tag.recv"
    cp "$WORK/snippet.log" "$BATS_FILE_TMPDIR/matrix/$tag.log"
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

ZERO_SCENES="confirm working noprompt fx_confirm_bash fx_confirm_exit_dialog fx_working_stream fx_working_tool fx_typed_text"
IDLE_SCENES="idle fx_idle_placeholder fx_idle_suggestion_after_turn"

@test "T-KG-M1: 【直した後】.new — 確認画面・作業中・判別不能・打ちかけの画面(実画面の写しを含む)には、idle flag が残っていても、全ての送信口で Enter を含むキーが 0 回" {
    local scene flag
    for scene in $ZERO_SCENES; do
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
    # 実画面の写し(確認画面)でも同じ
    f="$BATS_FILE_TMPDIR/matrix/new_fx_confirm_bash_present.log"
    grep -q "\[KEY-WITHHELD\]" "$f"
    grep -q "screen=confirm" "$f"
}

@test "T-KG-M3: 【直した後】.new — 待機の画面(薄字の提案文つきの実画面の写しを含む)では従来どおり起こせる(退行なし): 全送信口が動き、Escape も届く" {
    local flag p scene
    for scene in $IDLE_SCENES; do
    for flag in present absent; do
        matrix_run new "$scene" "$flag"
        local f="$BATS_FILE_TMPDIR/matrix/new_${scene}_${flag}.keys"
        for p in nudge phase2-claude phase2-copilot phase3-clear context-reset clear_command model_switch clear-input startup-prompt; do
            local n; n=$(port_count "$f" "$p" total)
            echo "new / $scene / flag=$flag / $p: $n 回(Enter $(port_count "$f" "$p" enter))"
            # 通常の起こし(nudge)は、待機の目印が無い間は従来どおり『働き中』扱いで送らぬ(本番版も同じ。送らぬ側への据え置きで退行ではない)
            if [ "$p" = nudge ] && [ "$flag" = absent ]; then [ "$n" -eq 0 ]; continue; fi
            [ "$n" -ge 1 ]
        done
        # 起こし(nudge)の中身: C-u → inbox1 → Enter
        if [ "$flag" = present ]; then
            awk '/^PORT nudge/{on=1;next}/^PORT /{on=0}on' "$f" | grep -q -P '^KEY\t1\tEnter'
        fi
        grep -q -x "inbox1" "$BATS_FILE_TMPDIR/matrix/new_${scene}_${flag}.recv"
        # Escape 経路(copilot)で Escape が届く
        awk '/^PORT phase2-copilot/{on=1;next}/^PORT /{on=0}on' "$f" | grep -q "Escape"
        # /clear が届く
        grep -q -x "/clear" "$BATS_FILE_TMPDIR/matrix/new_${scene}_${flag}.recv"
    done
    done
    # 薄字の例外で通したことがログに残る
    grep -q "\[KEY-GATE\].*placeholder=dim" "$BATS_FILE_TMPDIR/matrix/new_fx_idle_placeholder_present.log"
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
    # 実画面の写し: 確認画面・作業中・打ちかけは idle flag あり(最悪)で、待機の提案文つきは両方
    for scene in fx_confirm_bash fx_confirm_exit_dialog fx_working_stream fx_working_tool fx_typed_text; do
        matrix_run prod "$scene" present
        local f="$BATS_FILE_TMPDIR/matrix/prod_${scene}_present.keys"
        echo "--- prod / $scene / flag=present: KEY 行 $(grep -c '^KEY' "$f")、うち Enter $(grep -c -P '^KEY\t1\t' "$f") ---"
    done
    for scene in fx_idle_placeholder fx_idle_suggestion_after_turn; do
        for flag in present absent; do matrix_run prod "$scene" "$flag"; done
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
    # 実画面の確認画面(Claude Code の『Do you want to proceed?』)にも本番版は Enter を送る
    f="$BATS_FILE_TMPDIR/matrix/prod_fx_confirm_bash_present.keys"
    [ "$(port_count "$f" nudge enter)" -ge 1 ]
    [ "$(grep -c -P '^KEY\t1\t' "$f")" -ge 1 ]
    grep -q -x "inbox1" "$BATS_FILE_TMPDIR/matrix/prod_fx_confirm_bash_present.recv"
}

@test "T-KG-M5: 【表】場面×送信口の送信回数(Enter を含む送信)— 直す前(本番版)/ 直した後(.new)" {
    local f
    for f in prod_confirm_present new_confirm_present prod_fx_confirm_bash_present new_fx_confirm_bash_present; do [ -f "$BATS_FILE_TMPDIR/matrix/$f.keys" ]; done
    local who scene flag p
    printf '\n| 場面 | idle flag | 版 | %s |\n' "$(echo $PORTS | sed 's/ / | /g')"
    printf '|---|---|---|%s\n' "$(for p in $PORTS; do printf -- '---|'; done)"
    for scene in confirm working noprompt $(echo $ZERO_SCENES | cut -d' ' -f4-) idle fx_idle_placeholder fx_idle_suggestion_after_turn; do
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

@test "T-KG-M6: 待機の画面(薄字の提案文つきの実画面の写しを含む)では 本番版と .new の送信が同じ(退行なし) — 各送信口の送信回数と、偽ペインが受け取った入力列が一致" {
    local flag p scene
    for scene in $IDLE_SCENES; do
    for flag in present absent; do
        local fp="$BATS_FILE_TMPDIR/matrix/prod_${scene}_${flag}.keys" fn="$BATS_FILE_TMPDIR/matrix/new_${scene}_${flag}.keys"
        [ -f "$fp" ] && [ -f "$fn" ]
        for p in $PORTS; do
            echo "$scene / flag=$flag / $p: prod=$(port_count "$fp" "$p" total) new=$(port_count "$fn" "$p" total)"
            [ "$(port_count "$fp" "$p" total)" = "$(port_count "$fn" "$p" total)" ]
        done
        diff "$BATS_FILE_TMPDIR/matrix/prod_${scene}_${flag}.recv" "$BATS_FILE_TMPDIR/matrix/new_${scene}_${flag}.recv"
    done
    done
}

# ═══════════════════════════════════════════════════════════════
# A. cmd_232 の非待機29場面+確認画面の実画面を当て直す(S-23/S-24)— 直す前(本番版)/ 直した後(.new)を一つの表で
# ═══════════════════════════════════════════════════════════════
# 29場面の出典: queue/reports/cmd232_watcher_keystroke_audit.md ②-1。各場面の『送った物』を送信口に、『判定』の画面を実画面の写しに対応させる
#   Ctrl-C→/clear(Phase 3)=phase3-clear / 起こし inboxN+Enter=nudge / /clear+Enter(CONTEXT-RESET)=context-reset
#   作業中=fx_working_tool(長い Bash 実行中)または fx_working_stream(思考・生成中) / 確認画面=fx_confirm_bash
#   idle flag は全場面で『あり』(cmd232: 29回全て path=flag verdict=idle が根拠)。

SCENES29='1|10-12 20:03:04|足軽3|phase3-clear|fx_working_tool
2|10-12 20:15:32|足軽1|phase3-clear|fx_working_stream
3|10-12 20:24:41|軍師|nudge|fx_working_tool
4|10-12 20:25:45|軍師|nudge|fx_working_tool
5|10-12 20:45:39|軍師|nudge|fx_working_tool
6|10-12 20:46:43|軍師|nudge|fx_working_tool
7|10-12 20:47:48|軍師|nudge|fx_working_tool
8|10-12 20:50:56|軍師|nudge|fx_working_tool
9|10-12 20:52:00|軍師|nudge|fx_working_tool
10|10-12 20:53:04|軍師|nudge|fx_working_tool
11|10-12 20:54:09|軍師|nudge|fx_working_tool
12|10-12 21:01:15|足軽2|phase3-clear|fx_working_tool
13|10-12 21:23:39|足軽3|phase3-clear|fx_working_stream
14|10-12 21:32:06|足軽2|phase3-clear|fx_working_stream
15|10-12 22:07:41|足軽3|phase3-clear|fx_working_tool
16|10-12 22:08:00|足軽1|phase3-clear|fx_working_tool
17|10-12 22:21:19|軍師|nudge|fx_working_tool
18|10-12 22:22:23|軍師|nudge|fx_working_tool
19|10-12 22:23:27|軍師|nudge|fx_working_tool
20|10-12 22:26:36|軍師|nudge|fx_working_tool
21|10-12 22:27:40|軍師|nudge|fx_working_tool
22|10-12 22:28:44|軍師|nudge|fx_working_tool
23|10-12 22:29:48|軍師|nudge|fx_working_tool
24|10-12 23:26:53|足軽1|phase3-clear|fx_working_tool
25|10-12 23:52:05|軍師|nudge|fx_working_tool
26|10-12 23:54:26|家老|nudge|fx_working_stream
27|10-13 00:10:12|足軽2|context-reset|fx_confirm_bash
28|10-13 00:11:00|足軽2|nudge|fx_working_tool
29|10-13 00:12:05|足軽2|nudge|fx_working_tool'

# scene_counts <who> <scene> <port> → "total/enter"(同じ入力は実走結果を使い回さず、行ごとに実走する。.new は必ず行ごとに実走)
scene_counts() {
    local who="$1" scene="$2" port="$3"
    matrix_run "$who" "$scene" present "$port"
    local f="$BATS_FILE_TMPDIR/matrix/${who}_${scene}_present_${port}.keys"
    echo "$(port_count "$f" "$port" total)/$(port_count "$f" "$port" enter)"
}

@test "T-KG-A1: 【表】cmd_232 の非待機29場面を、実画面の写しで当て直す — .new は全場面 0 回(Enter も 0)、本番版は全場面で送る" {
    local row n tm who port scene new prod
    local -A PRODCACHE=()
    local bad=0
    printf '\n| # | 時刻 | 者 | 送った物(送信口) | 画面(実画面の写し) | 直す前(本番版) 送信/Enter | 直した後(.new) 送信/Enter |\n|--|--|--|--|--|--|--|\n'
    while IFS='|' read -r n tm who port scene; do
        new="$(scene_counts new "$scene" "$port")"
        if [ -z "${PRODCACHE[$scene:$port]:-}" ]; then PRODCACHE[$scene:$port]="$(scene_counts prod "$scene" "$port")"; fi
        prod="${PRODCACHE[$scene:$port]}"
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$n" "$tm" "$who" "$port" "$scene" "$prod" "$new"
        [ "$new" = "0/0" ] || bad=$((bad + 1))
        [ "${prod%%/*}" -ge 1 ] || bad=$((bad + 1))
    done <<< "$SCENES29"
    echo "(本番版は同じ『画面×送信口』を1度実走して全行に当てた。.new は29行を行ごとに実走)"
    [ "$bad" -eq 0 ]
}

@test "T-KG-A2: 【表】確認画面の実画面(2種)× 全送信口 — 薄字の例外を入れた後も .new は 0 回(Enter も 0)。直す前の本番版は送る" {
    local scene flag p who f
    printf '\n| 確認画面(実画面) | idle flag | 版 | %s |\n|---|---|---|%s\n' "$(echo $PORTS | sed 's/ / | /g')" "$(for p in $PORTS; do printf -- '---|'; done)"
    for scene in fx_confirm_bash fx_confirm_exit_dialog; do
        for flag in present absent; do
            for who in prod new; do
                if [ "$who" = prod ] && [ "$flag" = absent ]; then continue; fi
                matrix_run "$who" "$scene" "$flag"
                f="$BATS_FILE_TMPDIR/matrix/${who}_${scene}_${flag}.keys"
                printf '| %s | %s | %s |' "$scene" "$flag" "$who"
                for p in $PORTS; do printf ' %s/%s |' "$(port_count "$f" "$p" total)" "$(port_count "$f" "$p" enter)"; done
                printf '\n'
                if [ "$who" = new ]; then [ "$(grep -c '^KEY' "$f")" -eq 0 ]; fi
                if [ "$who" = prod ]; then [ "$(grep -c -P '^KEY\t1\t' "$f")" -ge 1 ]; fi
            done
        done
    done
    echo "(セルは『送信回数/うち Enter を含む回数』)"
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

@test "T-KG-N6: 【S-24】薄字の見分けが外れて(提案文つきの待機画面を undetermined と判じて)伝言が届かぬときも、黙って溜めず settings の目安で殿へ知らせが届く" {
    install_watcher "$NEW_WATCHER"
    # 薄字の属性が読めなくなった状況を再現: 実画面の写しから薄字の属性(ESC[2m)を落とす
    sed $'s/\x1b\\[2m//' "$FX_DIR/idle_placeholder.ansi" > "$WORK/placeholder_undetected.ansi"
    start_pane fxfile claude "$WORK/placeholder_undetected.ansi"
    # (a) 既定の目安(30分): 29分59秒までは出ず、30分で1回、続く間は60分ごと
    tick_run 3 "0 600 1200 1799"
    [ "$(ncount)" -eq 0 ]
    tick_run 3 "1800 1860 3000"
    echo "--- 既定(30分) notify.out ---"; cat "$WORK/notify.out"
    [ "$(ncount)" -eq 1 ]
    grep -q "待機と判じられぬ画面" "$WORK/notify.out"
    grep -q "ashigaru9" "$WORK/notify.out"
    grep -q "subtask_999_A" "$WORK/notify.out"
    grep -q "未読3件" "$WORK/notify.out"
    ! grep -qiE "topic|token|bearer|password" "$WORK/notify.out"
    tick_run 3 "5399"
    [ "$(ncount)" -eq 1 ]
    tick_run 3 "5400"
    [ "$(ncount)" -eq 2 ]
    # この間に一度もキーは送られていない(黙って溜めるが、送りもしない)
    [ ! -s "$WORK/recv.log" ]
    [ "$(grep -c '^KEY' "$KEYLOG")" -eq 0 ]
    # (b) settings の目安を変えると、その分数で知らせる(busy_guard.unread_notify_minutes: 10)
    : > "$WORK/notify.out"; rm -f "$WORK/logs/watcher_busy/ashigaru9.state"
    sed -i '/^busy_guard:/,/^[a-z_]*:/{/^busy_guard:/d;/^  /d}' "$WORK/config/settings.yaml"
    printf 'busy_guard:\n  unread_notify_minutes: 10\n' >> "$WORK/config/settings.yaml"
    tick_run 3 "0 599"
    [ "$(ncount)" -eq 0 ]
    tick_run 3 "600"
    echo "--- settings 10分 notify.out ---"; cat "$WORK/notify.out"
    [ "$(ncount)" -eq 1 ]
    grep -q "10分" "$WORK/notify.out"
    stop_pane
    # (c) 対照: 薄字の属性が読めるとき(元の実画面)は idle ゆえ送れる。知らせは要らず、何時間経っても出ない
    : > "$WORK/notify.out"; rm -f "$WORK/logs/watcher_busy/ashigaru9.state"
    start_pane fx_idle_placeholder
    tick_run 3 "0 1800 3600 10800"
    [ "$(ncount)" -eq 0 ]
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
    [ "$(grep -c -E "wk_send_(keys|soft)" "$NEW_WATCHER")" -ge 30 ]
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
