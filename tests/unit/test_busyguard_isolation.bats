#!/usr/bin/env bats
# test_busyguard_isolation.bats — cmd_234 工程B(再発防止の静的試験)
#   scripts/inbox_watcher.sh は BUSYGUARD_STATE_DIR が未設定だと <SCRIPT_DIR>/logs/watcher_busy(本番の置場)を使う
#   (scripts/inbox_watcher.sh:238)。試験の harness が SCRIPT_DIR を実repoに固定したまま置場を差し替えぬと、
#   process_unread などを呼んだ試験が本番の置場へ test_agent.state を書く(原因: queue/reports/cmd231_test_agent_state_origin.md)。
#   本試験は tests/unit/*.bats を静的に走査し、inbox_watcher.sh を source/実行する bats が
#   BUSYGUARD_STATE_DIR を差し替えていなければ落とす。走査は読むだけで、本番の置場にも tests/ にも何も書かない。
#
# 「inbox_watcher.sh を使う bats」の判定(コメント行は除く。単なる言及・grep・cp・chmod・bash -n は使うに数えぬ):
#   a) 命令位置の `source` / `.` が inbox_watcher*.sh のパス、または inbox_watcher を代入した変数(WATCHER_SCRIPT 等)を指す
#   b) 命令位置の `bash` / `sh`(-n を含む引数は構文検査のみゆえ除く)が同じものを実行する
#   c) 命令位置でパス自体を直接実行する(./scripts/inbox_watcher.sh args)
#   命令位置 = 行頭、または ; & | ( { の直後、または run/then/do/else/exec/eval/nohup の直後。
#   例: test_watcher_supervisor_dedup.bats の `[[ "$output" == *"SPAWNED bash scripts/inbox_watcher.sh ..."* ]]` は
#       bash が命令位置にないので誤検出しない。
# 「差し替えている」の判定: コメント以外の行に `BUSYGUARD_STATE_DIR=`(代入。export 付き可)がある。
#   `${BUSYGUARD_STATE_DIR:-...}` のような読み出しは差替に数えぬ。
#   限界: 判定はファイル単位(harness が複数ある bats で一部だけ差し替えても通る)。差替先が使い捨てかも見ない。
#
# T-BGI-D1〜D7 : 検出関数の自己証明(一時ディレクトリの偽bats。差替なし→落とす / 差替あり→通す / 言及だけ→通す ほか)
# T-BGI-R1     : 実repoの tests/unit/*.bats に、差替なしで inbox_watcher.sh を source/実行するものが無い
# T-BGI-R2     : 検出が空振りしていない(既知の使用者を「使う」と判定し、差替済みの2本は通す)

# ─── 検出関数(第1引数 = 走査するディレクトリ。試験が偽fixtureへ差し替えられる) ───

# bgi_code FILE : コメント行を除いた本体
bgi_code() {
    grep -vE '^[[:space:]]*#' "$1" || true
}

# bgi_uses_watcher FILE : inbox_watcher.sh を source / 実行するなら 0
bgi_uses_watcher() {
    local code vars var_alt target cmdpos
    code="$(bgi_code "$1")"
    # inbox_watcher を右辺に含む代入の左辺(WATCHER_SCRIPT / NEW_WATCHER 等)
    vars="$(printf '%s\n' "$code" \
        | sed -nE 's/^[[:space:]]*((export|local|readonly)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*inbox_watcher.*/\3/p' \
        | sort -u | paste -sd'|' -)"
    target='[^[:space:]]*inbox_watcher[^[:space:]]*'
    if [ -n "$vars" ]; then
        target="(${target}|[\"']*\\\$\\{?(${vars})([^A-Za-z0-9_]|\$))"
    fi
    cmdpos='(^|[;&|({]|[[:space:]](then|do|else|run|exec|eval|nohup))[[:space:]]*'
    # a) source / .   b) bash / sh(-n を含む引数を除く)   c) パスの直接実行
    printf '%s\n' "$code" | grep -qE \
        "${cmdpos}(source|\\.)[[:space:]]+[\"']*${target}" && return 0
    printf '%s\n' "$code" | grep -qE \
        "${cmdpos}(bash|sh)[[:space:]]+(-[A-Za-mo-z]+[[:space:]]+)*[\"']*${target}" && return 0
    printf '%s\n' "$code" | grep -qE \
        "${cmdpos}[\"']*[^[:space:]=]*scripts/inbox_watcher[^[:space:]=]*\\.sh" && return 0
    return 1
}

# bgi_has_override FILE : BUSYGUARD_STATE_DIR を代入していれば 0(読み出し ${BUSYGUARD_STATE_DIR:-..} は数えぬ)
bgi_has_override() {
    bgi_code "$1" | grep -qE '(^|[^A-Za-z0-9_$])BUSYGUARD_STATE_DIR='
}

# bgi_unsafe_files DIR : DIR/*.bats(自分自身を除く)のうち、watcher を使うのに差し替えていないものの名を1行ずつ出す
bgi_unsafe_files() {
    local dir="$1" f self
    self="$(basename "$BATS_TEST_FILENAME")"
    for f in "$dir"/*.bats; do
        [ -e "$f" ] || continue
        [ "$(basename "$f")" = "$self" ] && continue
        if bgi_uses_watcher "$f" && ! bgi_has_override "$f"; then
            basename "$f"
        fi
    done
}

setup() {
    FX="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$FX"
}

# ─── 検出関数の自己証明(偽fixture) ───

@test "T-BGI-D1: 差替なしで source する偽bats を落とす(直書きパス)" {
    cat > "$FX/test_fake_unsafe.bats" <<'EOF'
#!/usr/bin/env bats
setup() {
    cat > "$BATS_TEST_TMPDIR/h.sh" <<'H'
SCRIPT_DIR="/somewhere/repo"
source "$SCRIPT_DIR/scripts/inbox_watcher.sh"
H
}
EOF
    run bgi_unsafe_files "$FX"
    [ "$status" -eq 0 ]
    [ "$output" = "test_fake_unsafe.bats" ]
}

@test "T-BGI-D2: 差替ありで source する偽bats は通す(export / 代入のどちらも)" {
    cat > "$FX/test_fake_safe_export.bats" <<'EOF'
#!/usr/bin/env bats
setup() {
    cat > "$BATS_TEST_TMPDIR/h.sh" <<'H'
export BUSYGUARD_STATE_DIR="$TEST_TMPDIR/watcher_busy"
source "$SCRIPT_DIR/scripts/inbox_watcher.sh"
H
}
EOF
    cat > "$FX/test_fake_safe_assign.bats" <<'EOF'
#!/usr/bin/env bats
BUSYGUARD_STATE_DIR="$BATS_TEST_TMPDIR/busy"
setup() { . "$WORK/scripts/inbox_watcher.sh"; }
EOF
    run bgi_unsafe_files "$FX"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-BGI-D3: 変数経由(WATCHER_SCRIPT)の source も、差替がなければ落とす" {
    cat > "$FX/test_fake_var.bats" <<'EOF'
#!/usr/bin/env bats
setup() {
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    cat > "$BATS_TEST_TMPDIR/h.sh" <<'H'
source "$WATCHER_SCRIPT"
H
}
EOF
    run bgi_unsafe_files "$FX"
    [ "$status" -eq 0 ]
    [ "$output" = "test_fake_var.bats" ]
}

@test "T-BGI-D4: bash での実行(run bash / 直接実行)も、差替がなければ落とす" {
    cat > "$FX/test_fake_exec_bash.bats" <<'EOF'
#!/usr/bin/env bats
t() { run bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" ashigaru9 multiagent:agents.9 claude; }
EOF
    cat > "$FX/test_fake_exec_direct.bats" <<'EOF'
#!/usr/bin/env bats
t() { ./scripts/inbox_watcher.sh ashigaru9 multiagent:agents.9 claude & }
EOF
    run bgi_unsafe_files "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test_fake_exec_bash.bats"* ]]
    [[ "$output" == *"test_fake_exec_direct.bats"* ]]
}

@test "T-BGI-D5: 言及・grep・cp・chmod・bash -n・出力文字列だけの偽bats は誤検出しない" {
    cat > "$FX/test_fake_mention.bats" <<'EOF'
#!/usr/bin/env bats
# source scripts/inbox_watcher.sh  ← コメントは数えぬ
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"
t() {
    grep -q "send_wakeup()" "$WATCHER_SCRIPT"
    grep -q 'refactor. inbox_watcher.sh' "$WATCHER_SCRIPT"
    cp "$1" "$WORK/scripts/inbox_watcher.sh"
    chmod +x "$WORK/scripts/inbox_watcher.sh"
    bash -n "$SCRIPT_DIR/scripts/inbox_watcher.sh"
    [[ "$output" == *"SPAWNED bash scripts/inbox_watcher.sh shogun"* ]]
    pgrep -f 'scripts/inbox_watcher.sh'
    cat > "$TEST_TMP/scripts/inbox_watcher.sh" << 'MOCK'
echo mock
MOCK
}
EOF
    run bgi_unsafe_files "$FX"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-BGI-D6: 読み出し \${BUSYGUARD_STATE_DIR:-..} は差替に数えず、落とす" {
    cat > "$FX/test_fake_readonly.bats" <<'EOF'
#!/usr/bin/env bats
setup() {
    echo "state dir is ${BUSYGUARD_STATE_DIR:-unset}"
    source "$SCRIPT_DIR/scripts/inbox_watcher.sh"
}
EOF
    run bgi_unsafe_files "$FX"
    [ "$status" -eq 0 ]
    [ "$output" = "test_fake_readonly.bats" ]
}

@test "T-BGI-D7: 走査は読むだけ(偽fixtureの木にも何も増やさず、自分自身は除外する)" {
    cp "$BATS_TEST_FILENAME" "$FX/$(basename "$BATS_TEST_FILENAME")"   # 自分自身と同名は走査対象外
    cat > "$FX/test_fake_unsafe.bats" <<'EOF'
source "$SCRIPT_DIR/scripts/inbox_watcher.sh"
EOF
    before="$(ls -1 "$FX" | sort | paste -sd' ' -)"
    run bgi_unsafe_files "$FX"
    after="$(ls -1 "$FX" | sort | paste -sd' ' -)"
    [ "$output" = "test_fake_unsafe.bats" ]
    [ "$before" = "$after" ]
}

# ─── 実repoの走査 ───

@test "T-BGI-R1: tests/unit/*.bats に、BUSYGUARD_STATE_DIR を差し替えず inbox_watcher.sh を source/実行するものが無い" {
    run bgi_unsafe_files "$BATS_TEST_DIRNAME"
    [ "$status" -eq 0 ]
    if [ -n "$output" ]; then
        echo "BUSYGUARD_STATE_DIR を使い捨てへ差し替えていない bats(本番の logs/watcher_busy を汚しうる):" >&2
        printf '  - %s\n' $output >&2
        echo "直し方: harness の source 前に export BUSYGUARD_STATE_DIR=\"\$TEST_TMPDIR/watcher_busy\" を足す" >&2
        return 1
    fi
}

@test "T-BGI-R2: 検出が空振りしていない(既知の使用者を『使う』と判定し、差替済みの2本は通す)" {
    for f in test_inbox_watcher_busyguard.bats test_inbox_watcher_keygate.bats test_send_wakeup.bats test_inbox_watcher_nudge.bats; do
        [ -f "$BATS_TEST_DIRNAME/$f" ]
        bgi_uses_watcher "$BATS_TEST_DIRNAME/$f"
    done
    for f in test_inbox_watcher_busyguard.bats test_inbox_watcher_keygate.bats; do
        bgi_has_override "$BATS_TEST_DIRNAME/$f"
    done
    # 単に名を挙げるだけの bats は使用者に数えぬ
    ! bgi_uses_watcher "$BATS_TEST_DIRNAME/test_watcher_supervisor_dedup.bats"
    ! bgi_uses_watcher "$BATS_TEST_DIRNAME/test_agent_registry.bats"
}
