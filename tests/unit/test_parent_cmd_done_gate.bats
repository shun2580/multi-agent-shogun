#!/usr/bin/env bats
# cmd_164 subtask_164_C: scripts/pretooluse_yaml_guard.sh の
# check_parent_cmd_done_gate() 専用テスト。
#
# 対象: queue/shogun_to_karo.yaml上であるcmdのstatusをdoneへ変更しようと
# したとき、queue/tasks/*.yaml中のparent_cmd一致エントリの全statusがdoneで
# あることを機械確認し、未完了/判定不能が1件でもあればfail-loudでdenyする
# ゲート(cmd_164 subtask_164_B、独立の副flag parent_cmd_done_gate_enabled
# ・off|observe|enforceの3値・既定off)。
#
# 既存test_pretooluse_yaml_guard.batsのcheck_affects_runtime_done_gate()系
# テストと同型のfixture隔離パターン(setup()でのmktemp -d・YAML_GUARD_*環境
# 変数差し替え・teardown()での一時ディレクトリ削除)に倣う。本ファイルは
# ユニットテストレベルの検証であり、実CLI起動は伴わない。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GUARD_SCRIPT="$PROJECT_ROOT/scripts/pretooluse_yaml_guard.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/queue/tasks" "$TEST_TMP/queue/reports" "$TEST_TMP/logs"
    LOG_FILE="$TEST_TMP/logs/yaml_guard.log"
    TIMING_LOG="$TEST_TMP/logs/timing_events.jsonl"
    NTFY_LOG="$TEST_TMP/ntfy.log"
    NTFY_STUB="$TEST_TMP/ntfy_stub.sh"

    # 外側yaml_guard_enabled=enforce・副flag parent_cmd_done_gate_enabled=off
    SETTINGS_PG_OFF="$TEST_TMP/settings_pg_off.yaml"
    cat > "$SETTINGS_PG_OFF" <<'EOF'
features:
  yaml_guard_enabled: enforce
  parent_cmd_done_gate_enabled: off
EOF

    # 外側yaml_guard_enabled=enforce・副flag parent_cmd_done_gate_enabled=enforce
    SETTINGS_PG_ENFORCE="$TEST_TMP/settings_pg_enforce.yaml"
    cat > "$SETTINGS_PG_ENFORCE" <<'EOF'
features:
  yaml_guard_enabled: enforce
  parent_cmd_done_gate_enabled: enforce
EOF

    # 外側yaml_guard_enabled=enforce・副flag parent_cmd_done_gate_enabled=observe
    SETTINGS_PG_OBSERVE="$TEST_TMP/settings_pg_observe.yaml"
    cat > "$SETTINGS_PG_OBSERVE" <<'EOF'
features:
  yaml_guard_enabled: enforce
  parent_cmd_done_gate_enabled: observe
EOF

    cat > "$NTFY_STUB" <<EOF
#!/usr/bin/env bash
echo "NOTIFIED \$1" >> "$NTFY_LOG"
EOF
    chmod +x "$NTFY_STUB"
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_guard_pg() {
    local settings_file="$1"
    local payload="$2"
    run env \
        YAML_GUARD_SETTINGS="$settings_file" \
        YAML_GUARD_REPO_ROOT="$TEST_TMP" \
        YAML_GUARD_LOG="$LOG_FILE" \
        YAML_GUARD_TIMING_LOG="$TIMING_LOG" \
        YAML_GUARD_PYTHON="$PROJECT_ROOT/.venv/bin/python3" \
        YAML_GUARD_NTFY_SCRIPT="$NTFY_STUB" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
}

# ケース1: 副flag=off時は検証ロジックに一切入らず即exit 0
# (本来ならdenyされるはずの「配下subtaskがassignedのまま残るdone遷移」を
# あえて与えても、ゲート固有のログタグが一切出現しないことを確認する)
@test "parent_cmd_done_gate=off: cmd done transition with an assigned subtask is allowed silently, no gate log emitted" {
    printf -- '- id: cmd_999\n  status: in_progress\n  note: dummy\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    printf 'task:\n  task_id: subtask_999_A\n  parent_cmd: cmd_999\n  status: assigned\n' > "$TEST_TMP/queue/tasks/_test_dummy1.yaml"

    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"status: in_progress","new_string":"status: done","replace_all":false}}'
    run_guard_pg "$SETTINGS_PG_OFF" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "PARENT-GATE" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

# ケース2: 副flag=enforce・配下subtask全done → ALLOW
@test "parent_cmd_done_gate=enforce: all subtasks done → allowed silently" {
    printf -- '- id: cmd_999\n  status: in_progress\n  note: dummy\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    printf 'task:\n  task_id: subtask_999_A\n  parent_cmd: cmd_999\n  status: done\n' > "$TEST_TMP/queue/tasks/_test_dummy1.yaml"
    printf 'task:\n  task_id: subtask_999_B\n  parent_cmd: cmd_999\n  status: done\n' > "$TEST_TMP/queue/tasks/_test_dummy2.yaml"

    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"status: in_progress","new_string":"status: done","replace_all":false}}'
    run_guard_pg "$SETTINGS_PG_ENFORCE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "^\[.*\] ALLOW mode=enforce" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# ケース3: 副flag=enforce・配下subtaskにassignedが1件でも残る → DENY
# (理由文言に該当ファイル・task_id・statusが含まれること)
@test "parent_cmd_done_gate=enforce: one subtask still assigned → denied with file/task_id/status in reason" {
    printf -- '- id: cmd_999\n  status: in_progress\n  note: dummy\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    printf 'task:\n  task_id: subtask_999_A\n  parent_cmd: cmd_999\n  status: done\n' > "$TEST_TMP/queue/tasks/_test_dummy1.yaml"
    printf 'task:\n  task_id: subtask_999_B\n  parent_cmd: cmd_999\n  status: assigned\n' > "$TEST_TMP/queue/tasks/_test_dummy2.yaml"

    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"status: in_progress","new_string":"status: done","replace_all":false}}'
    run_guard_pg "$SETTINGS_PG_ENFORCE" "$payload"

    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    # json.dumps既定(ensure_ascii=True)により理由文言中の日本語部分は
    # \uXXXXへエスケープされる。ASCIIで残るcmd_id・ファイルパス・task_id・
    # statusの各値で該当ファイル/task_id/statusが含まれることを確認する。
    [[ "$output" == *"cmd_id=cmd_999"* ]]
    [[ "$output" == *"_test_dummy2.yaml"* ]]
    [[ "$output" == *"subtask_999_B"* ]]
    [[ "$output" == *"status=assigned"* ]]
}

# ケース4: 該当parent_cmdを持つtaskが1件も存在しない → ALLOW
# (無関係なcmdの誤denyを避けることの回帰確認)
@test "parent_cmd_done_gate=enforce: no task references this parent_cmd → allowed silently (no false deny)" {
    printf -- '- id: cmd_999\n  status: in_progress\n  note: dummy\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    printf 'task:\n  task_id: subtask_888_A\n  parent_cmd: cmd_888\n  status: assigned\n' > "$TEST_TMP/queue/tasks/_test_dummy1.yaml"

    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"status: in_progress","new_string":"status: done","replace_all":false}}'
    run_guard_pg "$SETTINGS_PG_ENFORCE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "^\[.*\] ALLOW mode=enforce" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# ケース5: 副flag=observe・条件③相当(assigned残存)のDENYケース →
# WOULD-DENY-PARENT-GATE相当のログのみ記録され、実際のdeny出力(exit時の
# JSON)は発生しない
@test "parent_cmd_done_gate=observe: assigned subtask logs WOULD-DENY-PARENT-GATE only, no deny output" {
    printf -- '- id: cmd_999\n  status: in_progress\n  note: dummy\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    printf 'task:\n  task_id: subtask_999_A\n  parent_cmd: cmd_999\n  status: done\n' > "$TEST_TMP/queue/tasks/_test_dummy1.yaml"
    printf 'task:\n  task_id: subtask_999_B\n  parent_cmd: cmd_999\n  status: assigned\n' > "$TEST_TMP/queue/tasks/_test_dummy2.yaml"

    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"status: in_progress","new_string":"status: done","replace_all":false}}'
    run_guard_pg "$SETTINGS_PG_OBSERVE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run grep -c "WOULD-DENY-PARENT-GATE" "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep "WOULD-DENY-PARENT-GATE" "$LOG_FILE"
    [[ "$output" == *"mode=observe"* ]]
    [[ "$output" == *"cmd_id=cmd_999のdone遷移拒否"* ]]
    [[ "$output" == *"subtask_999_B"* ]]

    # 外側yaml_guard_enabledはenforceなのでALLOW行が別途1件記録される
    # (副flagのobserve判定は既存deny()を経由しないため外側ログには現れない)
    run grep -c "^\[.*\] ALLOW mode=enforce" "$LOG_FILE"
    [ "$output" -eq 1 ]
    # 通常のDENY行(実deny)は出現しない
    run grep -c "^\[.*\] DENY mode=" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

# ケース6: 判定不能ケース(該当task YAMLの読取/パース失敗)→ deny側
# (subtask_164_Bの設計どおりunknown=deny側に倒れることを確認。
# check_parent_cmd_done_gate()はfound_anyの真偽に関わらず、queue/tasks/配下
# にパース不能ファイルが1件でもあればincompleteへ追加しdenyする)
@test "parent_cmd_done_gate=enforce: unparseable task YAML in queue/tasks → denied (unknown defaults to deny)" {
    printf -- '- id: cmd_999\n  status: in_progress\n  note: dummy\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    printf 'task:\n  bad: [unclosed\n' > "$TEST_TMP/queue/tasks/_test_broken.yaml"

    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"status: in_progress","new_string":"status: done","replace_all":false}}'
    run_guard_pg "$SETTINGS_PG_ENFORCE" "$payload"

    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    # json.dumps既定(ensure_ascii=True)により日本語部分はエスケープされる。
    # ASCIIで残るcmd_id・対象ファイル名で判定不能→deny側の分岐を確認する。
    [[ "$output" == *"cmd_id=cmd_999"* ]]
    [[ "$output" == *"_test_broken.yaml"* ]]
}

# --- 回帰確認: queue/tasks/*.yaml側の書込(check_affects_runtime_done_gateの
# 対象パス)には本ゲートが一切作用しないこと(file_pathが
# queue/shogun_to_karo.yamlでない限りcheck_parent_cmd_done_gate()は即return) ---

@test "parent_cmd_done_gate=enforce: writes to queue/tasks/*.yaml are not affected by this gate" {
    printf 'task:\n  task_id: subtask_999_A\n  parent_cmd: cmd_999\n  status: assigned\n' > "$TEST_TMP/queue/tasks/ashigaru9.yaml"

    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","old_string":"status: assigned","new_string":"status: done","replace_all":false}}'
    run_guard_pg "$SETTINGS_PG_ENFORCE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "PARENT-GATE" "$LOG_FILE"
    [ "$status" -ne 0 ]
}
