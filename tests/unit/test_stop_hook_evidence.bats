#!/usr/bin/env bats
# cmd_192 工程8(完了ゲート): scripts/stop_hook_evidence.sh のユニットテスト。
# stop_hook_inbox.shとは別のStop hookエントリとして、足軽・軍師・家老の
# 完了報告に対する(a)〜(d)機械判定と、工程8-2の6回連続block通知を検証する。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HOOK_SCRIPT="$PROJECT_ROOT/scripts/stop_hook_evidence.sh"
    PYTHON_BIN="$PROJECT_ROOT/.venv/bin/python3"

    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/tasks" "$TEST_TMP/reports" "$TEST_TMP/logs" "$TEST_TMP/blocks"
    LOG_FILE="$TEST_TMP/logs/stop_hook_evidence.log"
    TASKS_DIR="$TEST_TMP/tasks"
    REPORTS_DIR="$TEST_TMP/reports"
    BLOCK_COUNT_DIR="$TEST_TMP/blocks"
    STUB_NTFY="$TEST_TMP/stub_ntfy.sh"
    STUB_NTFY_LOG="$TEST_TMP/stub_ntfy_calls.log"

    cat > "$STUB_NTFY" <<EOF
#!/usr/bin/env bash
echo "[\$(date -Iseconds)] NTFY-CALLED msg=\$1" >> "$STUB_NTFY_LOG"
EOF
    chmod +x "$STUB_NTFY"

    SETTINGS_OFF="$TEST_TMP/settings_off.yaml"
    SETTINGS_OBSERVE="$TEST_TMP/settings_observe.yaml"
    SETTINGS_ENFORCE="$TEST_TMP/settings_enforce.yaml"
    SETTINGS_UNKNOWN="$TEST_TMP/settings_unknown.yaml"
    SETTINGS_MISSING="$TEST_TMP/does_not_exist.yaml"

    cat > "$SETTINGS_OFF" <<'EOF'
features:
  evidence_gate_enabled: off
EOF
    cat > "$SETTINGS_OBSERVE" <<'EOF'
features:
  evidence_gate_enabled: observe
EOF
    cat > "$SETTINGS_ENFORCE" <<'EOF'
features:
  evidence_gate_enabled: enforce
EOF
    cat > "$SETTINGS_UNKNOWN" <<'EOF'
features:
  evidence_gate_enabled: banana
EOF
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_hook() {
    local settings_file="$1" agent_id="$2" payload="${3:-{\}}"
    run env \
        STOP_HOOK_EVIDENCE_SETTINGS="$settings_file" \
        STOP_HOOK_EVIDENCE_AGENT_ID="$agent_id" \
        STOP_HOOK_EVIDENCE_TASKS_DIR="$TASKS_DIR" \
        STOP_HOOK_EVIDENCE_REPORTS_DIR="$REPORTS_DIR" \
        STOP_HOOK_EVIDENCE_LOG="$LOG_FILE" \
        STOP_HOOK_EVIDENCE_PYTHON="$PYTHON_BIN" \
        STOP_HOOK_EVIDENCE_BLOCK_COUNT_DIR="$BLOCK_COUNT_DIR" \
        STOP_HOOK_EVIDENCE_NTFY_SCRIPT="$STUB_NTFY" \
        bash -c "printf '%s' '$payload' | bash '$HOOK_SCRIPT'"
}

write_task() {
    local agent="$1" task_id="$2" status="$3"
    cat > "$TASKS_DIR/${agent}.yaml" <<EOF
task:
  task_id: $task_id
  status: $status
EOF
}

# ─── flag=off: 検証ロジックに一切入らず即exit 0(cmd_190標準化に倣う) ───

@test "flag off (explicit): exits 0 with no output, no log" {
    write_task agX subtask_x assigned
    run_hook "$SETTINGS_OFF" agX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "flag off (missing settings file): fail-safe to off, no log" {
    write_task agX subtask_x assigned
    run_hook "$SETTINGS_MISSING" agX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "flag off (unknown value): fail-safe to off, no log" {
    write_task agX subtask_x assigned
    run_hook "$SETTINGS_UNKNOWN" agX
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# ─── 対象外エージェント・対象外status ───

@test "shogun is always skipped even in enforce mode" {
    write_task shogun subtask_s assigned
    : > "$REPORTS_DIR/shogun_report.yaml"
    run_hook "$SETTINGS_ENFORCE" shogun
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "status other than assigned (the actual in-progress marker) is skipped" {
    write_task agIdle subtask_idle idle
    run_hook "$SETTINGS_OBSERVE" agIdle
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "missing task yaml is skipped (e.g. karo has no queue/tasks/karo.yaml convention)" {
    run_hook "$SETTINGS_OBSERVE" karo
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# ─── (a) 担当タスクに対応するreport YAMLエントリが存在する ───

@test "(a) no matching report entry: observe logs WOULD-BLOCK, exits 0 with no stdout" {
    write_task agA subtask_a assigned
    : > "$REPORTS_DIR/agA_report.yaml"
    run_hook "$SETTINGS_OBSERVE" agA
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-BLOCK mode=observe agent=agA reason=(a)" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(a) no matching report entry: enforce blocks with decision JSON" {
    write_task agA subtask_a assigned
    : > "$REPORTS_DIR/agA_report.yaml"
    run_hook "$SETTINGS_ENFORCE" agA
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision": "block"'* ]]
    [[ "$output" == *'(a)'* ]]
}

# ─── (b) 非空の *evidence フィールド ───

@test "(b) report entry exists but no *_evidence field: observe logs WOULD-BLOCK" {
    write_task agB subtask_b assigned
    cat > "$REPORTS_DIR/agB_report.yaml" <<'EOF'
report:
  task_id: subtask_b
  status: done
  summary: |
    done, no evidence field here.
EOF
    run_hook "$SETTINGS_OBSERVE" agB
    [ "$status" -eq 0 ]
    run grep -c "reason=(b)" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(b) report entry with non-empty suffixed *_evidence field passes" {
    write_task agB2 subtask_b2 assigned
    cat > "$REPORTS_DIR/agB2_report.yaml" <<'EOF'
report:
  task_id: subtask_b2
  status: done
  test_results:
    syntax_check: "PASS"
    syntax_evidence: "python3 -m py_compile foo.py -> OK"
EOF
    run_hook "$SETTINGS_OBSERVE" agB2
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW-STOP mode=observe agent=agB2" "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "WOULD-BLOCK" "$LOG_FILE"
    [ "$output" -eq 0 ]
}

# ─── (c) committed:true / commitハッシュ主張の実在検証 ───

@test "(c) claimed commit hash not found in git log: observe logs WOULD-BLOCK" {
    write_task agC subtask_c assigned
    cat > "$REPORTS_DIR/agC_report.yaml" <<'EOF'
report:
  task_id: subtask_c
  status: done
  commit_evidence: |
    committed at commit deadbeef1234
EOF
    run_hook "$SETTINGS_OBSERVE" agC
    [ "$status" -eq 0 ]
    run grep -c "reason=(c)" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(c) claimed commit hash that exists in this repo's git log passes" {
    write_task agC2 subtask_c2 assigned
    local real_hash
    real_hash="$(git -C "$PROJECT_ROOT" log -1 --format=%H)"
    cat > "$REPORTS_DIR/agC2_report.yaml" <<EOF
report:
  task_id: subtask_c2
  status: done
  commit_evidence: |
    committed at commit ${real_hash}
EOF
    run_hook "$SETTINGS_OBSERVE" agC2
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW-STOP mode=observe agent=agC2" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(c) no commit claim at all is vacuously satisfied" {
    write_task agC3 subtask_c3 assigned
    cat > "$REPORTS_DIR/agC3_report.yaml" <<'EOF'
report:
  task_id: subtask_c3
  status: done
  test_results:
    syntax_check: "PASS"
    syntax_evidence: "OK"
EOF
    run_hook "$SETTINGS_OBSERVE" agC3
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-BLOCK" "$LOG_FILE"
    [ "$output" -eq 0 ]
}

# ─── (d) tests/test_results 配下のSKIP非ゼロ件数(SKIP=FAIL則の機械化) ───

@test "(d) SKIP present with nonzero/undetermined count: observe logs WOULD-BLOCK" {
    write_task agD subtask_d assigned
    cat > "$REPORTS_DIR/agD_report.yaml" <<'EOF'
report:
  task_id: subtask_d
  status: done
  test_results:
    bats_evidence: |
      1..3
      ok 1 case1
      ok 2 Case 2: SKIP (missing dep)
      ok 3 case3
EOF
    run_hook "$SETTINGS_OBSERVE" agD
    [ "$status" -eq 0 ]
    run grep -c "reason=(d)" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(d) SKIP explicitly zero (SKIP 0件) passes" {
    write_task agD2 subtask_d2 assigned
    cat > "$REPORTS_DIR/agD2_report.yaml" <<'EOF'
report:
  task_id: subtask_d2
  status: done
  test_results:
    bats_evidence: |
      1..3 全PASS、SKIP 0件(全実行・全PASS)。
EOF
    run_hook "$SETTINGS_OBSERVE" agD2
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW-STOP mode=observe agent=agD2" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(d) cmd_192 工程8追加是正: English words 'skipped'/'skipping' in prose are NOT mistaken for a SKIP indication" {
    write_task agD4 subtask_d4 assigned
    cat > "$REPORTS_DIR/agD4_report.yaml" <<'EOF'
report:
  task_id: subtask_d4
  status: done
  test_results:
    bats_evidence: |
      1..4
      ok 1 case1
      ok 2 case2
      ok 3 case3
      ok 4 shogun is always skipped even in enforce mode
EOF
    run_hook "$SETTINGS_OBSERVE" agD4
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-BLOCK" "$LOG_FILE"
    [ "$output" -eq 0 ]
    run grep -c "ALLOW-STOP mode=observe agent=agD4" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(d) cmd_192 工程8追加是正: a genuine bare-word SKIP mark is still detected as before (non-regression)" {
    write_task agD5 subtask_d5 assigned
    cat > "$REPORTS_DIR/agD5_report.yaml" <<'EOF'
report:
  task_id: subtask_d5
  status: done
  test_results:
    bats_evidence: |
      1..3
      ok 1 case1
      ok 2 Case 2: SKIP (missing dep)
      ok 3 case3
EOF
    run_hook "$SETTINGS_OBSERVE" agD5
    [ "$status" -eq 0 ]
    run grep -c "reason=(d)" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(d) cmd_192 工程8追加是正: no-space nonzero notation SKIP1 is still detected as before (non-regression)" {
    write_task agD6 subtask_d6 assigned
    cat > "$REPORTS_DIR/agD6_report.yaml" <<'EOF'
report:
  task_id: subtask_d6
  status: done
  test_results:
    bats_evidence: |
      advisory31件=適合17/逸脱13/SKIP1
EOF
    run_hook "$SETTINGS_OBSERVE" agD6
    [ "$status" -eq 0 ]
    run grep -c "reason=(d)" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(d) cmd_192 工程8追加是正: no-space zero notation SKIP0 still passes (non-regression)" {
    write_task agD7 subtask_d7 assigned
    cat > "$REPORTS_DIR/agD7_report.yaml" <<'EOF'
report:
  task_id: subtask_d7
  status: done
  test_results:
    bats_evidence: |
      25/25 ok・SKIP0を独立に再現
EOF
    run_hook "$SETTINGS_OBSERVE" agD7
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-BLOCK" "$LOG_FILE"
    [ "$output" -eq 0 ]
    run grep -c "ALLOW-STOP mode=observe agent=agD7" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "(d) no test_results/tests key at all is vacuously satisfied (doc-only task)" {
    write_task agD3 subtask_d3 assigned
    cat > "$REPORTS_DIR/agD3_report.yaml" <<'EOF'
report:
  task_id: subtask_d3
  status: done
  commit_evidence: |
    ドキュメント更新のみ、テストなし。
EOF
    run_hook "$SETTINGS_OBSERVE" agD3
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-BLOCK" "$LOG_FILE"
    [ "$output" -eq 0 ]
}

# ─── enforce: 全条件充足でpass、JSON出力なし ───

@test "enforce mode: all conditions satisfied passes silently" {
    write_task agP subtask_p assigned
    cat > "$REPORTS_DIR/agP_report.yaml" <<'EOF'
report:
  task_id: subtask_p
  status: done
  test_results:
    syntax_check: "PASS"
    syntax_evidence: "OK"
EOF
    run_hook "$SETTINGS_ENFORCE" agP
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "ALLOW-STOP mode=enforce agent=agP" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# ─── 工程8-2: 6回連続blockでntfy通知、8回目より前に届く ───

@test "工程8-2: 6th consecutive block in enforce mode fires ntfy exactly once" {
    write_task agE subtask_e assigned
    : > "$REPORTS_DIR/agE_report.yaml"
    for _ in 1 2 3 4 5 6; do
        run_hook "$SETTINGS_ENFORCE" agE
        [ "$status" -eq 0 ]
    done
    [ "$(cat "$BLOCK_COUNT_DIR/agE.count")" -eq 6 ]
    [ -f "$STUB_NTFY_LOG" ]
    run grep -c "NTFY-CALLED" "$STUB_NTFY_LOG"
    [ "$output" -eq 1 ]
    run grep -c "NOTIFY-THRESHOLD mode=enforce agent=agE count=6" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "工程8-2: block count resets to 0 after a passing stop, no re-notify below threshold" {
    write_task agR subtask_r assigned
    : > "$REPORTS_DIR/agR_report.yaml"
    for _ in 1 2 3; do
        run_hook "$SETTINGS_ENFORCE" agR
    done
    [ "$(cat "$BLOCK_COUNT_DIR/agR.count")" -eq 3 ]

    cat > "$REPORTS_DIR/agR_report.yaml" <<'EOF'
report:
  task_id: subtask_r
  status: done
  test_results:
    syntax_check: "PASS"
    syntax_evidence: "OK"
EOF
    run_hook "$SETTINGS_ENFORCE" agR
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$BLOCK_COUNT_DIR/agR.count")" -eq 0 ]
    [ ! -f "$STUB_NTFY_LOG" ]
}

@test "observe mode never touches the block counter (no real block occurs)" {
    write_task agO subtask_o assigned
    : > "$REPORTS_DIR/agO_report.yaml"
    for _ in 1 2 3 4 5 6 7; do
        run_hook "$SETTINGS_OBSERVE" agO
    done
    [ ! -f "$BLOCK_COUNT_DIR/agO.count" ]
    [ ! -f "$STUB_NTFY_LOG" ]
}

# ─── JSON安全性・堅牢性(cmd_186教訓) ───

@test "malformed stdin JSON does not crash, fails safe" {
    write_task agM subtask_m assigned
    : > "$REPORTS_DIR/agM_report.yaml"
    run env \
        STOP_HOOK_EVIDENCE_SETTINGS="$SETTINGS_ENFORCE" \
        STOP_HOOK_EVIDENCE_AGENT_ID="agM" \
        STOP_HOOK_EVIDENCE_TASKS_DIR="$TASKS_DIR" \
        STOP_HOOK_EVIDENCE_REPORTS_DIR="$REPORTS_DIR" \
        STOP_HOOK_EVIDENCE_LOG="$LOG_FILE" \
        STOP_HOOK_EVIDENCE_PYTHON="$PYTHON_BIN" \
        STOP_HOOK_EVIDENCE_BLOCK_COUNT_DIR="$BLOCK_COUNT_DIR" \
        STOP_HOOK_EVIDENCE_NTFY_SCRIPT="$STUB_NTFY" \
        bash -c "printf '{not valid json' | bash '$HOOK_SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "stop_hook_active=true (loop prevention) skips the gate this cycle" {
    write_task agL subtask_l assigned
    : > "$REPORTS_DIR/agL_report.yaml"
    run env \
        STOP_HOOK_EVIDENCE_SETTINGS="$SETTINGS_ENFORCE" \
        STOP_HOOK_EVIDENCE_AGENT_ID="agL" \
        STOP_HOOK_EVIDENCE_TASKS_DIR="$TASKS_DIR" \
        STOP_HOOK_EVIDENCE_REPORTS_DIR="$REPORTS_DIR" \
        STOP_HOOK_EVIDENCE_LOG="$LOG_FILE" \
        STOP_HOOK_EVIDENCE_PYTHON="$PYTHON_BIN" \
        STOP_HOOK_EVIDENCE_BLOCK_COUNT_DIR="$BLOCK_COUNT_DIR" \
        STOP_HOOK_EVIDENCE_NTFY_SCRIPT="$STUB_NTFY" \
        bash -c "printf '{\"stop_hook_active\": true}' | bash '$HOOK_SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

# ─── 実配線の確認(cmd_091標準) ───

@test "wiring: stop_hook_evidence.sh is registered in .claude/settings.json Stop array" {
    run grep -n "stop_hook_evidence.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "wiring: stop_hook_inbox.sh remains registered and unmodified as a separate entry" {
    run grep -n "stop_hook_inbox.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "wiring: evidence_gate_enabled is present in config/settings.yaml and defaults to observe" {
    run grep -E '^\s*evidence_gate_enabled:\s*observe' "$PROJECT_ROOT/config/settings.yaml"
    [ "$status" -eq 0 ]
}
