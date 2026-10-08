#!/usr/bin/env bats
# cmd_210 E-1: scripts/dispatch.sh (task YAML書込 + inbox通知を1コマンドで) のテスト。
#
# 本番の queue/ は一切触らない。DISPATCH_ROOT で一時ディレクトリへルートを差し替え、
# INBOX_WRITE で偽の inbox_write.sh（引数を記録するスタブ）へ差し替える。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    DISPATCH="$PROJECT_ROOT/scripts/dispatch.sh"

    TEST_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$TEST_ROOT/queue/tasks" "$TEST_ROOT/scripts"
    export DISPATCH_ROOT="$TEST_ROOT"

    CALL_LOG="$BATS_TEST_TMPDIR/inbox_calls.log"
    : > "$CALL_LOG"
    export CALL_LOG

    # スタブ: 呼出引数を1行1引数で記録。STUB_FAIL=1 なら失敗。
    # 呼出時点の task YAML の内容も記録し、「書込→通知」の順序を検証できるようにする。
    STUB="$TEST_ROOT/scripts/inbox_write.sh"
    cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
{
    echo "CALL"
    for a in "$@"; do echo "ARG:$a"; done
    if [ -f "$DISPATCH_ROOT/queue/tasks/$1.yaml" ]; then
        echo "YAML_AT_CALL:$(tr '\n' '|' < "$DISPATCH_ROOT/queue/tasks/$1.yaml")"
    fi
} >> "$CALL_LOG"
[ "${STUB_FAIL:-0}" = "1" ] && exit 1
exit 0
EOF
    chmod +x "$STUB"
    export INBOX_WRITE="$STUB"
}

valid_yaml() {
    cat <<'EOF'
task:
  task_id: subtask_999_A
  parent_cmd: cmd_999
  status: assigned
  description: |
    テスト用タスク
EOF
}

@test "正常: task YAMLが書込まれ、inbox_write.shが正しい引数で呼ばれる" {
    run bash -c "valid_yaml() { cat <<'EOF'
task:
  task_id: subtask_999_A
  parent_cmd: cmd_999
  status: assigned
EOF
}; valid_yaml | bash '$DISPATCH' ashigaru3"
    [ "$status" -eq 0 ]
    [ -f "$TEST_ROOT/queue/tasks/ashigaru3.yaml" ]
    grep -q 'task_id: subtask_999_A' "$TEST_ROOT/queue/tasks/ashigaru3.yaml"
    [ "$(grep -c '^CALL$' "$CALL_LOG")" -eq 1 ]
    grep -qx 'ARG:ashigaru3' "$CALL_LOG"
    grep -qx 'ARG:タスクYAMLを読んで作業開始せよ。' "$CALL_LOG"
    grep -qx 'ARG:task_assigned' "$CALL_LOG"
    grep -qx 'ARG:karo' "$CALL_LOG"
    # cmd_id/task_id は YAML の parent_cmd / task_id から補われる
    grep -qx 'ARG:--cmd_id=cmd_999' "$CALL_LOG"
    grep -qx 'ARG:--task_id=subtask_999_A' "$CALL_LOG"
}

@test "順序: inbox通知の呼出時点で新しいtask YAMLが既に書込済み" {
    valid_yaml | bash "$DISPATCH" gunshi
    grep -q 'YAML_AT_CALL:.*task_id: subtask_999_A' "$CALL_LOG"
}

@test "オプション: --cmd_id/--task_id/--type/--message が通知に反映される" {
    run bash -c "cat <<'EOF' | bash '$DISPATCH' ashigaru1 --cmd_id=cmd_777 --task_id=subtask_777 --type=clear_command --message='再開せよ'
task:
  task_id: subtask_777
  parent_cmd: cmd_999
EOF"
    [ "$status" -eq 0 ]
    grep -qx 'ARG:再開せよ' "$CALL_LOG"
    grep -qx 'ARG:clear_command' "$CALL_LOG"
    grep -qx 'ARG:--cmd_id=cmd_777' "$CALL_LOG"
    grep -qx 'ARG:--task_id=subtask_777' "$CALL_LOG"
}

@test "空入力: exit 1・何も書かず通知もしない" {
    run bash -c "printf '' | bash '$DISPATCH' ashigaru2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"empty"* ]]
    [ ! -e "$TEST_ROOT/queue/tasks/ashigaru2.yaml" ]
    [ ! -s "$CALL_LOG" ]
}

@test "空白のみの入力も空入力として拒否する" {
    run bash -c "printf '  \n\n' | bash '$DISPATCH' ashigaru2"
    [ "$status" -eq 1 ]
    [ ! -e "$TEST_ROOT/queue/tasks/ashigaru2.yaml" ]
}

@test "不正YAML: exit 1・既存のtask YAMLを壊さず通知もしない" {
    echo "task: {task_id: OLD}" > "$TEST_ROOT/queue/tasks/ashigaru2.yaml"
    run bash -c "printf 'task:\n  task_id: [unclosed\n  bad: : :\n' | bash '$DISPATCH' ashigaru2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid YAML"* ]]
    [ "$(cat "$TEST_ROOT/queue/tasks/ashigaru2.yaml")" = "task: {task_id: OLD}" ]
    [ ! -s "$CALL_LOG" ]
}

@test "task_id欠落: exit 1・書込も通知もしない" {
    run bash -c "printf 'task:\n  parent_cmd: cmd_1\n' | bash '$DISPATCH' ashigaru4"
    [ "$status" -eq 1 ]
    [[ "$output" == *"task_id"* ]]
    [ ! -e "$TEST_ROOT/queue/tasks/ashigaru4.yaml" ]
    [ ! -s "$CALL_LOG" ]
}

@test "トップレベルが task: マップでない: exit 1" {
    run bash -c "printf 'foo:\n  task_id: x\n' | bash '$DISPATCH' ashigaru4"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'task:' mapping"* ]]
    [ ! -e "$TEST_ROOT/queue/tasks/ashigaru4.yaml" ]
}

@test "agent_id不正: exit 1・理由を出力" {
    run bash -c "printf 'task:\n  task_id: x\n' | bash '$DISPATCH' ashigaru8"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid agent_id"* ]]
    run bash -c "printf 'task:\n  task_id: x\n' | bash '$DISPATCH' karo"
    [ "$status" -eq 1 ]
    run bash -c "printf 'task:\n  task_id: x\n' | bash '$DISPATCH' ../etc"
    [ "$status" -eq 1 ]
    [ -z "$(ls -A "$TEST_ROOT/queue/tasks")" ]
    [ ! -s "$CALL_LOG" ]
}

@test "agent_id未指定: exit 1" {
    run bash -c "printf 'task:\n  task_id: x\n' | bash '$DISPATCH'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"agent_id is required"* ]]
}

@test "--task_idがYAMLのtask_idと不一致: exit 1・書込も通知もしない" {
    run bash -c "printf 'task:\n  task_id: subtask_1\n' | bash '$DISPATCH' ashigaru5 --task_id=subtask_2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not match"* ]]
    [ ! -e "$TEST_ROOT/queue/tasks/ashigaru5.yaml" ]
    [ ! -s "$CALL_LOG" ]
}

@test "通知失敗: exit 非0 かつ「書込済みだが通知失敗」を警告する(YAMLは書込済み)" {
    export STUB_FAIL=1
    run bash -c "printf 'task:\n  task_id: subtask_55\n  parent_cmd: cmd_55\n' | bash '$DISPATCH' ashigaru6"
    [ "$status" -ne 0 ]
    [[ "$output" == *"task YAMLは書込済みだが通知失敗"* ]]
    [[ "$output" == *"inbox_write.shを手動で再実行せよ"* ]]
    grep -q 'task_id: subtask_55' "$TEST_ROOT/queue/tasks/ashigaru6.yaml"
}

@test "原子性: 成功後・検証失敗後ともに一時ファイルが残らない" {
    valid_yaml | bash "$DISPATCH" ashigaru7
    run bash -c "printf 'not: [valid' | bash '$DISPATCH' ashigaru7"
    [ "$status" -eq 1 ]
    run bash -c "printf '' | bash '$DISPATCH' ashigaru7"
    [ "$status" -eq 1 ]
    # tasksディレクトリには ashigaru7.yaml だけ(隠しファイル含む)
    [ "$(ls -A "$TEST_ROOT/queue/tasks")" = "ashigaru7.yaml" ]
    # 失敗した上書き試行後も直前の正常内容が残る
    grep -q 'task_id: subtask_999_A' "$TEST_ROOT/queue/tasks/ashigaru7.yaml"
}

@test "通知失敗時も一時ファイルは残らない" {
    export STUB_FAIL=1
    run bash -c "printf 'task:\n  task_id: t1\n' | bash '$DISPATCH' ashigaru1"
    [ "$status" -ne 0 ]
    [ "$(ls -A "$TEST_ROOT/queue/tasks")" = "ashigaru1.yaml" ]
}

@test "構文チェック: bash -n scripts/dispatch.sh" {
    run bash -n "$DISPATCH"
    [ "$status" -eq 0 ]
}
