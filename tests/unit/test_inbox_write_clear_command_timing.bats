#!/usr/bin/env bats
# cmd_206 工程1: scripts/inbox_write.sh の clear_command dispatch 時
# timing_events.jsonl「assigned」失報型欠陥の是正テスト。
#
# 背景(2026-09-09 subtask_192_stall_gap実測・mandate/decisions_journal.md参照):
# `type: clear_command`かつ`--redo_of`無しの初回下達でtiming_events.jsonlへ
# 「assigned」が一切記帳されない欠陥はcmd_203工程2(commit b11623c)で是正済み
# (inbox_write.sh 68-74行のcase文)。しかし本cmdの実測再現(2026-10-03)で、
# instructions/karo.md STEP4記載の標準下達コマンド
# (`inbox_write.sh ashigaru{N} "タスクYAMLを読んで作業開始せよ。" clear_command karo`)
# は--cmd_id=/--task_id=を渡さず、CONTENTにもcmd_/subtask_パターンを含まないため、
# 「assigned」は記帳されるがtask_id=None/cmd_id=Noneとなり、
# deadman_watcher.shのget_in_flight_tasks()(task_id必須キー)からは
# 追跡対象として見えないままだった(別種の失報)。本テストはこの別種の失報の
# 再現確認と、是正(queue/tasks/{target}.yamlからのfallback解決)の検証を行う。
#
# 実本番のqueue/・logs/は一切使わない(mktemp -d隔離。tests/test_inbox_write.bats
# のSCRIPT_DIR上書き手法を踏襲)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    TEST_TMPDIR="$(mktemp -d)"
    TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR" "$TEST_TMPDIR/queue/inbox" "$TEST_TMPDIR/queue/tasks" "$TEST_TMPDIR/logs"

    # inbox_write.sh本体をSCRIPT_DIR上書き版としてコピー(tests/test_inbox_write.bats T-003と同じ手法)
    sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TEST_TMPDIR\"|" \
        "$PROJECT_ROOT/scripts/inbox_write.sh" > "$TEST_SCRIPT_DIR/inbox_write.sh"
    chmod +x "$TEST_SCRIPT_DIR/inbox_write.sh"

    # log_timing_event.sh / check_event_escalation.sh / ntfy.sh は自身のBASH_SOURCEから
    # SCRIPT_DIRを再計算するため、$TEST_SCRIPT_DIR配下へコピーするだけで隔離される。
    cp "$PROJECT_ROOT/scripts/log_timing_event.sh" "$TEST_SCRIPT_DIR/"
    cp "$PROJECT_ROOT/scripts/check_event_escalation.sh" "$TEST_SCRIPT_DIR/" 2>/dev/null || true
    cp "$PROJECT_ROOT/scripts/ntfy.sh" "$TEST_SCRIPT_DIR/" 2>/dev/null || true

    ln -sf "$PROJECT_ROOT/.venv" "$TEST_TMPDIR/.venv"

    TEST_INBOX_WRITE="$TEST_SCRIPT_DIR/inbox_write.sh"
    TEST_TIMING_LOG="$TEST_TMPDIR/logs/timing_events.jsonl"
    TEST_TASKS_DIR="$TEST_TMPDIR/queue/tasks"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

write_task_yaml() {
    local agent="$1" task_id="$2" cmd_id="$3" status="${4:-assigned}"
    cat > "$TEST_TASKS_DIR/${agent}.yaml" <<EOF
task:
  task_id: $task_id
  parent_cmd: $cmd_id
  status: $status
EOF
}

count_events_for_task() {
    # $TEST_TIMING_LOG中、指定task_id・eventに一致する行数を返す
    local task_id="$1" event="$2"
    grep -c "\"event\": \"${event}\".*\"task_id\": \"${task_id}\"" "$TEST_TIMING_LOG" 2>/dev/null || true
}

# =============================================================================
# R-001: 標準clear_command下達(instructions/karo.md STEP4どおり、--cmd_id=/
#        --task_id=無し・CONTENTにパターン無し)でも、queue/tasks/{target}.yamlが
#        既に新タスクで更新されていれば、記帳されるassignedイベントにtask_id/
#        cmd_idが解決されること(是正の主効果)。
# =============================================================================

@test "R-001: clear_command dispatch with no explicit ids resolves task_id/cmd_id from target task YAML" {
    write_task_yaml "ashigaru1" "subtask_206_1" "cmd_206"

    run bash "$TEST_INBOX_WRITE" ashigaru1 "タスクYAMLを読んで作業開始せよ。" clear_command karo
    [ "$status" -eq 0 ]

    [ -f "$TEST_TIMING_LOG" ]
    run grep '"event": "assigned"' "$TEST_TIMING_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "\"task_id\": \"subtask_206_1\"" ]]
    [[ "$output" =~ "\"cmd_id\": \"cmd_206\"" ]]

    # 埋め込みメッセージ自体にもtask_id/cmd_idが反映される(Fix5/cmd_072の意図どおり、
    # agent_started等のダウンストリーム消費者が読める)
    run "$VENV_PYTHON" -c "
import yaml
with open('$TEST_TMPDIR/queue/inbox/ashigaru1.yaml') as f:
    data = yaml.safe_load(f)
msg = data['messages'][0]
assert msg['task_id'] == 'subtask_206_1', msg
assert msg['cmd_id'] == 'cmd_206', msg
print('OK')
"
    [ "$status" -eq 0 ]
}

# =============================================================================
# R-002: queue/tasks/{target}.yamlが存在しない場合(例: karo自身への
#        自己clear_command)は、是正前と同じくtask_id=None/cmd_id=Noneで
#        記帳され、エラーにならないこと(既存挙動の保持・無回帰)。
# =============================================================================

@test "R-002: self clear_command with no target task YAML still logs assigned with null ids (no regression)" {
    # NOTE: instructions/karo.md 1082行の自己clear_command例はCONTENT=""(空文字列)だが、
    # これはinbox_write.sh 22行目の `[ -z "$CONTENT" ]` 引数検証により本件の修正と無関係に
    # exit 1する既存の別バグ(本cmdのスコープ外・未修正)。本テストではfallbackの無回帰性
    # そのもの(target task YAML不在でもエラーにならない)を検証するため、検証を通す
    # 非空文字列を用いる。
    run bash "$TEST_INBOX_WRITE" karo "self clear" clear_command karo
    [ "$status" -eq 0 ]

    [ -f "$TEST_TIMING_LOG" ]
    run grep '"event": "assigned"' "$TEST_TIMING_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "\"task_id\": null" ]]
    [[ "$output" =~ "\"cmd_id\": null" ]]
}

# =============================================================================
# R-003: 明示的に--cmd_id=/--task_id=が渡された場合は、target task YAMLの
#        内容より明示引数が常に優先されること(fallbackが上書きしない)。
# =============================================================================

@test "R-003: explicit --cmd_id=/--task_id= always take precedence over target task YAML fallback" {
    write_task_yaml "ashigaru1" "subtask_WRONG" "cmd_WRONG"

    run bash "$TEST_INBOX_WRITE" ashigaru1 "テスト" clear_command karo \
        --cmd_id=cmd_206 --task_id=subtask_206_1
    [ "$status" -eq 0 ]

    run grep '"event": "assigned"' "$TEST_TIMING_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "\"task_id\": \"subtask_206_1\"" ]]
    [[ "$output" =~ "\"cmd_id\": \"cmd_206\"" ]]
    [[ ! "$output" =~ "subtask_WRONG" ]]
}

# =============================================================================
# R-004(殿裁定の条件1・二重記帳回避): --redo_of付きclear_commandでは
#        「redo_dispatched」のみが記帳され、「assigned」が別途二重記帳
#        されないこと。同一(task_id, agent)にassigned相当は1件のみ。
# =============================================================================

@test "R-004: clear_command with --redo_of logs exactly one redo_dispatched event, no duplicate assigned" {
    write_task_yaml "ashigaru1" "subtask_206_1" "cmd_206"

    run bash "$TEST_INBOX_WRITE" ashigaru1 "再割当" clear_command karo \
        --redo_of=subtask_206_1_orig
    [ "$status" -eq 0 ]

    # redo_dispatchedが1件のみ(grep -cは0件時にexit 1を返すため || true でbatsのerrexitを回避)
    local redo_count
    redo_count=$(grep -c '"event": "redo_dispatched"' "$TEST_TIMING_LOG" || true)
    [ "$redo_count" -eq 1 ]

    # assigned相当(assigned自体)は0件(redo_dispatchedへ昇格済みのため)
    local assigned_count
    assigned_count=$(grep -c '"event": "assigned"' "$TEST_TIMING_LOG" || true)
    [ "$assigned_count" -eq 0 ]

    # fallbackはredo_dispatchedの行にもtask_id/cmd_idを正しく埋める
    run grep '"event": "redo_dispatched"' "$TEST_TIMING_LOG"
    [[ "$output" =~ "\"task_id\": \"subtask_206_1\"" ]]
    [[ "$output" =~ "\"cmd_id\": \"cmd_206\"" ]]
}

# =============================================================================
# R-005: 通常のtask_assigned型(既に--cmd_id=/--task_id=を明示する既存の
#        正常経路)はfallbackの影響を受けず、従来通り1件のみassignedが
#        記帳されること(回帰無し)。
# =============================================================================

@test "R-005: task_assigned with explicit ids is unaffected by the fallback (no regression)" {
    run bash "$TEST_INBOX_WRITE" ashigaru2 "新規タスク" task_assigned karo \
        --cmd_id=cmd_999 --task_id=subtask_999_1
    [ "$status" -eq 0 ]

    local assigned_count
    assigned_count=$(grep -c '"event": "assigned"' "$TEST_TIMING_LOG" || true)
    [ "$assigned_count" -eq 1 ]

    run grep '"event": "assigned"' "$TEST_TIMING_LOG"
    [[ "$output" =~ "\"task_id\": \"subtask_999_1\"" ]]
    [[ "$output" =~ "\"cmd_id\": \"cmd_999\"" ]]
}

# =============================================================================
# R-006: report_received等、dispatch方向でないtype(assigned/redo_dispatched
#        以外)ではfallback探索自体が走らないこと(target task YAMLが
#        紛れ込んで誤ったtask_id/cmd_idがreport_submittedイベントに
#        混入しないことの確認)。
# =============================================================================

@test "R-006: report_received type does not trigger the target-task-YAML fallback" {
    write_task_yaml "karo" "subtask_SHOULD_NOT_LEAK" "cmd_SHOULD_NOT_LEAK"

    run bash "$TEST_INBOX_WRITE" karo "完了報告" report_received ashigaru1
    [ "$status" -eq 0 ]

    run grep '"event": "report_submitted"' "$TEST_TIMING_LOG"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "subtask_SHOULD_NOT_LEAK" ]]
    [[ "$output" =~ "\"task_id\": null" ]]
}
