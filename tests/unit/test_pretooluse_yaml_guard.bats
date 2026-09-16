#!/usr/bin/env bats
# cmd_113 Part2: scripts/pretooluse_yaml_guard.sh のテスト
# deny判定ロジック・fail-open経路・非対象パス早期リターンをユニットテストレベルで
# 検証する(実CLI起動は伴わない。実CLI起動を伴う受け入れ検証は隔離サンドボックスで
# 別途実施し、報告書に実出力を記録する)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    GUARD_SCRIPT="$PROJECT_ROOT/scripts/pretooluse_yaml_guard.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/queue/tasks" "$TEST_TMP/queue/reports" "$TEST_TMP/logs"
    SETTINGS_ON="$TEST_TMP/settings_on.yaml"
    SETTINGS_OFF="$TEST_TMP/settings_off.yaml"
    SETTINGS_OBSERVE="$TEST_TMP/settings_observe.yaml"
    SETTINGS_UNKNOWN="$TEST_TMP/settings_unknown.yaml"
    LOG_FILE="$TEST_TMP/logs/yaml_guard.log"
    TIMING_LOG="$TEST_TMP/logs/timing_events.jsonl"
    NTFY_LOG="$TEST_TMP/ntfy.log"
    NTFY_STUB="$TEST_TMP/ntfy_stub.sh"

    # SETTINGS_ON: 旧bool値(true)。後方互換でenforceへ読み替わる想定のfixture。
    cat > "$SETTINGS_ON" <<'EOF'
features:
  yaml_guard_enabled: true
EOF
    # SETTINGS_OFF: 旧bool値(false)。後方互換でoffへ読み替わる想定のfixture。
    cat > "$SETTINGS_OFF" <<'EOF'
features:
  yaml_guard_enabled: false
EOF
    cat > "$SETTINGS_OBSERVE" <<'EOF'
features:
  yaml_guard_enabled: observe
EOF
    cat > "$SETTINGS_UNKNOWN" <<'EOF'
features:
  yaml_guard_enabled: some_bogus_value
EOF
    cat > "$NTFY_STUB" <<EOF
#!/usr/bin/env bash
echo "NOTIFIED \$1" >> "$NTFY_LOG"
EOF
    chmod +x "$NTFY_STUB"

    # --- cmd_192 工程7-guard: notify_on_done_required_enabled fixtures ---
    # 外側yaml_guard_enabled=enforce固定・副flag notify_on_done_required_enabled
    # のみ3値+未設定+実settings.yamlの計5パターンを用意する
    # (parent_cmd_done_gate_enabled系テストのfixture隔離パターンに倣う)。
    SETTINGS_NDR_OFF="$TEST_TMP/settings_ndr_off.yaml"
    cat > "$SETTINGS_NDR_OFF" <<'EOF'
features:
  yaml_guard_enabled: enforce
  notify_on_done_required_enabled: off
EOF
    SETTINGS_NDR_OBSERVE="$TEST_TMP/settings_ndr_observe.yaml"
    cat > "$SETTINGS_NDR_OBSERVE" <<'EOF'
features:
  yaml_guard_enabled: enforce
  notify_on_done_required_enabled: observe
EOF
    SETTINGS_NDR_ENFORCE="$TEST_TMP/settings_ndr_enforce.yaml"
    cat > "$SETTINGS_NDR_ENFORCE" <<'EOF'
features:
  yaml_guard_enabled: enforce
  notify_on_done_required_enabled: enforce
EOF
    # notify_on_done_required_enabled行そのものが無い(未設定)fixture。
    # 未知値・空値・欠落は必ずoffへ倒すfail-safe設計の実証用。
    SETTINGS_NDR_UNSET="$TEST_TMP/settings_ndr_unset.yaml"
    cat > "$SETTINGS_NDR_UNSET" <<'EOF'
features:
  yaml_guard_enabled: enforce
EOF

    # --- cmd_194 工程3: verified_evidence_required_enabled fixtures ---
    SETTINGS_VER_OFF="$TEST_TMP/settings_ver_off.yaml"
    cat > "$SETTINGS_VER_OFF" <<'EOF'
features:
  yaml_guard_enabled: enforce
  verified_evidence_required_enabled: off
EOF
    SETTINGS_VER_OBSERVE="$TEST_TMP/settings_ver_observe.yaml"
    cat > "$SETTINGS_VER_OBSERVE" <<'EOF'
features:
  yaml_guard_enabled: enforce
  verified_evidence_required_enabled: observe
EOF
    SETTINGS_VER_ENFORCE="$TEST_TMP/settings_ver_enforce.yaml"
    cat > "$SETTINGS_VER_ENFORCE" <<'EOF'
features:
  yaml_guard_enabled: enforce
  verified_evidence_required_enabled: enforce
EOF
}

teardown() {
    rm -rf "$TEST_TMP"
}

run_guard() {
    local payload="$1"
    local python_bin="${2:-$PROJECT_ROOT/.venv/bin/python3}"
    local timing_log="${3:-$TIMING_LOG}"
    run env \
        YAML_GUARD_SETTINGS="$SETTINGS_ON" \
        YAML_GUARD_REPO_ROOT="$TEST_TMP" \
        YAML_GUARD_LOG="$LOG_FILE" \
        YAML_GUARD_TIMING_LOG="$timing_log" \
        YAML_GUARD_PYTHON="$python_bin" \
        YAML_GUARD_NTFY_SCRIPT="$NTFY_STUB" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
}

run_guard_with_settings() {
    local settings_file="$1"
    local payload="$2"
    local timing_log="${3:-$TIMING_LOG}"
    run env \
        YAML_GUARD_SETTINGS="$settings_file" \
        YAML_GUARD_REPO_ROOT="$TEST_TMP" \
        YAML_GUARD_LOG="$LOG_FILE" \
        YAML_GUARD_TIMING_LOG="$timing_log" \
        YAML_GUARD_PYTHON="$PROJECT_ROOT/.venv/bin/python3" \
        YAML_GUARD_NTFY_SCRIPT="$NTFY_STUB" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
}

run_guard_ndr() {
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

run_guard_ver() {
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

# --- 早期リターン: feature flag無効 ---

@test "feature flag disabled: exits 0 with no output even for target path + broken YAML" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":": broken : ["}}'
    run env \
        YAML_GUARD_SETTINGS="$SETTINGS_OFF" \
        YAML_GUARD_REPO_ROOT="$TEST_TMP" \
        YAML_GUARD_LOG="$LOG_FILE" \
        bash -c "printf '%s' '$payload' | bash '$GUARD_SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- flagの3値化(off|observe|enforce, cmd_120) ---

@test "flag=observe: broken YAML is NOT denied (no deny output) but WOULD-DENY is logged" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard_with_settings "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY" "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep "WOULD-DENY" "$LOG_FILE"
    [[ "$output" == *"YAML parse failure"* ]]
}

@test "flag=observe: valid YAML allowed silently, no WOULD-DENY logged" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  status: idle\n"}}'
    run_guard_with_settings "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

# --- 機械集計ログ基盤(cmd_121 A-2): 1評価1行・grep -cで機械集計可能な形式 ---

@test "machine-parseable log: every evaluated target-path call logs exactly 1 line with mode=/session=/file=/tool=" {
    local payload='{"session_id":"test-session-abc","tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  status: idle\n"}}'
    run_guard_with_settings "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]
    run grep -c "^\[.*\] ALLOW mode=observe session=test-session-abc file=.*ashigaru9.yaml tool=Write$" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "machine-parseable log: session_id missing from payload falls back to 'unknown' (no crash)" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  status: idle\n"}}'
    run_guard_with_settings "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]
    run grep -c "session=unknown" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "machine-parseable log: ALLOW/WOULD-DENY/FAIL-OPEN counts are independently grep -c countable" {
    # 1件ALLOW
    run_guard_with_settings "$SETTINGS_OBSERVE" '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  status: idle\n"}}'
    # 1件WOULD-DENY
    run_guard_with_settings "$SETTINGS_OBSERVE" '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    # 1件FAIL-OPEN(python欠落)
    run env \
        YAML_GUARD_SETTINGS="$SETTINGS_OBSERVE" \
        YAML_GUARD_REPO_ROOT="$TEST_TMP" \
        YAML_GUARD_LOG="$LOG_FILE" \
        YAML_GUARD_PYTHON="/nonexistent/python3" \
        YAML_GUARD_NTFY_SCRIPT="$NTFY_STUB" \
        bash -c "printf '%s' '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TEST_TMP/queue/tasks/ashigaru9.yaml\",\"content\":\"a: 1\\n\"}}' | bash '$GUARD_SCRIPT'"

    run grep -c "^\[.*\] ALLOW " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "^\[.*\] WOULD-DENY " "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep -c "^\[.*\] FAIL-OPEN " "$LOG_FILE"
    [ "$output" -eq 1 ]
    # 評価総数(enforce移行判定の分母) = ALLOW + WOULD-DENY (+DENY) 件数
    run grep -cE "^\[.*\] (ALLOW|WOULD-DENY|DENY) " "$LOG_FILE"
    [ "$output" -eq 2 ]
}

@test "flag=unknown value: fail-safe falls back to off, broken YAML allowed silently" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":": broken : ["}}'
    run_guard_with_settings "$SETTINGS_UNKNOWN" "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$LOG_FILE" ]
}

@test "flag=enforce (new explicit value): broken YAML denied same as legacy true" {
    mkdir -p "$TEST_TMP/queue/tasks2"
    local SETTINGS_ENFORCE="$TEST_TMP/settings_enforce.yaml"
    cat > "$SETTINGS_ENFORCE" <<'EOF'
features:
  yaml_guard_enabled: enforce
EOF
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard_with_settings "$SETTINGS_ENFORCE" "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# --- 早期リターン: 非対象パス ---

@test "non-target path: exits 0 with no output even with broken content" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/README.md","content":": broken : ["}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "non-target tool_name (Read): exits 0 with no output" {
    local payload='{"tool_name":"Read","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- Write検証 ---

@test "Write target path with valid YAML: allowed silently" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  status: idle\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Write target path with invalid YAML: denied with reason" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"YAML parse failure"* ]]
}

@test "Write target path (queue/inbox): invalid YAML denied" {
    mkdir -p "$TEST_TMP/queue/inbox"
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/inbox/ashigaru9.yaml","content":"messages: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "Write target path (saytask): invalid YAML denied" {
    mkdir -p "$TEST_TMP/saytask"
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/saytask/tasks.yaml","content":"a: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# --- Edit検証(cmd_110事故の再現: 未クォートコロン) ---

@test "Edit simulated replacement introduces unquoted colon: denied" {
    printf 'task:\n  status: idle\n  note: original\n' > "$TEST_TMP/queue/reports/ashigaru9_report.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/ashigaru9_report.yaml","old_string":"note: original","new_string":"note: bad: unquoted: colon","replace_all":false}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "Edit simulated replacement stays valid YAML: allowed silently" {
    printf 'task:\n  status: idle\n  note: original\n' > "$TEST_TMP/queue/reports/ashigaru9_report.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/ashigaru9_report.yaml","old_string":"note: original","new_string":"note: updated","replace_all":false}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Edit replace_all=true across multiple occurrences: validated on final result" {
    printf 'a: x\nb: x\nc: x\n' > "$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","old_string":"x","new_string":"y","replace_all":true}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Edit replace_all=true introducing broken YAML across all occurrences: denied" {
    printf 'a: x\nb: x\n' > "$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","old_string":"x","new_string":"[unclosed","replace_all":true}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# --- grep空白許容(cmd_120 Q2-6是正: 整形JSON対応) ---

@test "formatted JSON (space after colon): valid YAML still allowed silently" {
    local payload='{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml",
    "content": "task:\n  status: idle\n"
  }
}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "formatted JSON (space after colon): broken YAML still denied (regression for fail-open bug)" {
    local payload='{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml",
    "content": "task:\n  bad: [unclosed\n"
  }
}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "unformatted JSON (no space after colon): still works as before (no regression)" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# --- safe_load_all全面化(cmd_120 Q2-1: マルチドキュメントYAML誤検知の是正) ---

@test "multi-document YAML (---separated), both docs valid: allowed silently" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/ashigaru9_report.yaml","content":"report:\n  status: done\n---\nreport:\n  status: done\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "multi-document YAML (---separated), second doc broken: denied" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/ashigaru9_report.yaml","content":"report:\n  status: done\n---\nreport:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# --- ANSI混入の回帰テスト(cmd_120 Q5裁定: queue/reports/ashigaru2_report.yaml
#     151行目・subtask_052c2事故の恒久資産化) ---

@test "ANSI escape sequence (\\x1b) in write content: denied via ReaderError (YAMLError subclass)" {
    printf 'task:\n  status: idle\n  note: original\n' > "$TEST_TMP/queue/reports/ashigaru9_report.yaml"
    # new_stringにJSONエスケープ形式(\u001b)でESCを含める。cmd_052c2/
    # ashigaru2_report.yaml:151相当の生端末出力貼り付け事故を模した回帰ケース。
    # 実際のClaude Code CLIはtool_input中の制御文字をJSON仕様に沿った
    # エスケープ形式でフックへ渡す(生バイト直書きはJSON仕様違反でjson.load
    # 自体がJSONDecodeErrorになりfail-open経路に落ちてしまい、本テストの
    # 意図と異なる検証になる)。json.load()が実ESC文字へ復元した後、
    # simulated file content内でyaml Readerがそれを検知しReaderError
    # (YAMLErrorのサブクラス)を送出する経路を検証する。
    local payload
    payload="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/queue/reports/ashigaru9_report.yaml","old_string":"note: original","new_string":"note: bad\\u001b[31mcolor\\u001b[0m","replace_all":false}}' "$TEST_TMP")"
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"YAML parse failure"* ]]
}

# --- 反復DENY警報 (cmd_134 工程2): 同一ファイルへの実DENYが直近10分以内に
#     3件以上でntfy警報。判定対象は実DENY行のみ(WOULD-DENY/FAIL-OPEN/ALLOWは
#     対象外)。 ---

@test "repeated DENY: same file 3 times within 10 minutes fires ntfy alert" {
    local target="$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local ts1 ts2
    ts1="$(date -d '-2 minutes' -Iseconds)"
    ts2="$(date -d '-5 minutes' -Iseconds)"
    echo "[$ts1] DENY mode=enforce session=fake1 file=$target tool=Write reason={}" >> "$LOG_FILE"
    echo "[$ts2] DENY mode=enforce session=fake2 file=$target tool=Write reason={}" >> "$LOG_FILE"

    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$target"'","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]

    run cat "$NTFY_LOG"
    [[ "$output" == *"同一ファイルへの実DENYが直近10分で"* ]]
}

@test "repeated DENY: 3 DENYs across different files does NOT fire alert" {
    local ts1 ts2
    ts1="$(date -d '-2 minutes' -Iseconds)"
    ts2="$(date -d '-3 minutes' -Iseconds)"
    echo "[$ts1] DENY mode=enforce session=fake1 file=$TEST_TMP/queue/tasks/other1.yaml tool=Write reason={}" >> "$LOG_FILE"
    echo "[$ts2] DENY mode=enforce session=fake2 file=$TEST_TMP/queue/tasks/other2.yaml tool=Write reason={}" >> "$LOG_FILE"

    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]

    run cat "$NTFY_LOG" 2>/dev/null
    [[ "$output" != *"同一ファイルへの実DENYが直近10分で"* ]]
}

@test "repeated DENY: same file but 3 events spread beyond 10 minutes does NOT fire alert" {
    local target="$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local ts1 ts2
    ts1="$(date -d '-15 minutes' -Iseconds)"
    ts2="$(date -d '-20 minutes' -Iseconds)"
    echo "[$ts1] DENY mode=enforce session=fake1 file=$target tool=Write reason={}" >> "$LOG_FILE"
    echo "[$ts2] DENY mode=enforce session=fake2 file=$target tool=Write reason={}" >> "$LOG_FILE"

    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$target"'","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]

    run cat "$NTFY_LOG" 2>/dev/null
    [[ "$output" != *"同一ファイルへの実DENYが直近10分で"* ]]
}

@test "repeated DENY: same file only 2 events total does NOT fire alert" {
    local target="$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local ts1
    ts1="$(date -d '-2 minutes' -Iseconds)"
    echo "[$ts1] DENY mode=enforce session=fake1 file=$target tool=Write reason={}" >> "$LOG_FILE"

    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$target"'","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]

    run cat "$NTFY_LOG" 2>/dev/null
    [[ "$output" != *"同一ファイルへの実DENYが直近10分で"* ]]
}

@test "repeated DENY: observe mode with 3+ WOULD-DENY for same file does NOT fire alert (regression: inactive during observe)" {
    local target="$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$target"'","content":"task:\n  bad: [unclosed\n"}}'
    run_guard_with_settings "$SETTINGS_OBSERVE" "$payload"
    run_guard_with_settings "$SETTINGS_OBSERVE" "$payload"
    run_guard_with_settings "$SETTINGS_OBSERVE" "$payload"

    run grep -c "WOULD-DENY" "$LOG_FILE"
    [ "$output" -eq 3 ]
    run grep -c " DENY " "$LOG_FILE"
    [ "$status" -ne 0 ]

    run cat "$NTFY_LOG" 2>/dev/null
    [[ "$output" != *"同一ファイルへの実DENYが直近10分で"* ]]
}

# --- DENY自己修正計測 emitter (cmd_139): 実DENY発生時のみ
#     logs/timing_events.jsonl へ event=yaml_guard_deny_self_correction を
#     1行追記する(受動収集・判定ロジックには一切関与しない)。 ---

@test "DENY自己修正計測: real DENY appends yaml_guard_deny_self_correction event to timing_events.jsonl" {
    local payload='{"session_id":"test-session-emitter","tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]

    run grep -c '"event": "yaml_guard_deny_self_correction"' "$TIMING_LOG"
    [ "$output" -eq 1 ]

    run grep '"event": "yaml_guard_deny_self_correction"' "$TIMING_LOG"
    [[ "$output" == *'"session_id": "test-session-emitter"'* ]]
    [[ "$output" == *"ashigaru9.yaml"* ]]
    [[ "$output" == *'"tool": "Write"'* ]]
    [[ "$output" == *"YAML parse failure"* ]]

    # 追記された行がvalid JSONであること
    run "$PROJECT_ROOT/.venv/bin/python3" -c "import json; json.loads(open('$TIMING_LOG').read().strip().splitlines()[-1])"
    [ "$status" -eq 0 ]
}

@test "DENY自己修正計測: WOULD-DENY (observe mode) does NOT append event" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard_with_settings "$SETTINGS_OBSERVE" "$payload"
    [ "$status" -eq 0 ]

    [ ! -s "$TIMING_LOG" ]
}

@test "DENY自己修正計測: ALLOW (valid YAML) does NOT append event" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  status: idle\n"}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    [ ! -s "$TIMING_LOG" ]
}

@test "DENY自己修正計測: timing log write failure does not affect DENY decision or exit code" {
    : > "$TEST_TMP/blocked_timing_target"
    local broken_timing_log="$TEST_TMP/blocked_timing_target/timing_events.jsonl"
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"task:\n  bad: [unclosed\n"}}'
    run_guard "$payload" "$PROJECT_ROOT/.venv/bin/python3" "$broken_timing_log"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

# --- fail-open経路 ---

@test "internal error (python binary missing): fails open (allow) and fires ntfy warning" {
    printf 'a: 1\n' > "$TEST_TMP/queue/tasks/ashigaru9.yaml"
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/ashigaru9.yaml","content":"a: 1\nb: 2\n"}}'
    run_guard "$payload" "/nonexistent/python3"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run cat "$NTFY_LOG"
    [[ "$output" == *"NOTIFIED"* ]]
    run grep -c "FAIL-OPEN" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "internal error (Edit target file unreadable): fails open (allow) and fires ntfy warning" {
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/tasks/does_not_exist.yaml","old_string":"a","new_string":"b","replace_all":false}}'
    run_guard "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run cat "$NTFY_LOG"
    [[ "$output" == *"NOTIFIED"* ]]
}

# --- cmd_192 工程7-guard: notify_on_done_required_enabled ---
# queue/shogun_to_karo.yamlへ新規追記されるcmdエントリのnotify_on_done欠落を
# fail-loudに検知する副flag(off|observe|enforce・PARENT_GATE_MODEと同型)。
# 🔴既定値補完はしない——値が無ければ「無い」と検知するのが設計であり、
# 既存エントリ(追記前から存在するid)には一切作用しない。

@test "notify_on_done_required=enforce: newly appended cmd entry missing notify_on_done → denied with new id in reason" {
    printf 'commands:\n- id: cmd_999\n  status: in_progress\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"  status: in_progress\n","new_string":"  status: in_progress\n- id: cmd_1000\n  status: assigned\n","replace_all":false}}'
    run_guard_ndr "$SETTINGS_NDR_ENFORCE" "$payload"

    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"cmd_1000"* ]]
    [[ "$output" == *"notify_on_done"* ]]
}

@test "notify_on_done_required=observe: newly appended cmd entry missing notify_on_done → WOULD-DENY-NOTIFY-REQUIRED logged only, not denied" {
    printf 'commands:\n- id: cmd_999\n  status: in_progress\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"  status: in_progress\n","new_string":"  status: in_progress\n- id: cmd_1000\n  status: assigned\n","replace_all":false}}'
    run_guard_ndr "$SETTINGS_NDR_OBSERVE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY-NOTIFY-REQUIRED" "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep "WOULD-DENY-NOTIFY-REQUIRED" "$LOG_FILE"
    [[ "$output" == *"mode=observe"* ]]
    [[ "$output" == *"cmd_1000"* ]]
    # 通常のDENY行(実deny)は出現しない
    run grep -c "^\[.*\] DENY mode=" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "notify_on_done_required=off (explicit): validation logic is never entered, no gate log tag" {
    printf 'commands:\n- id: cmd_999\n  status: in_progress\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"  status: in_progress\n","new_string":"  status: in_progress\n- id: cmd_1000\n  status: assigned\n","replace_all":false}}'
    run_guard_ndr "$SETTINGS_NDR_OFF" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "NOTIFY-REQUIRED" "$LOG_FILE"
    [ "$status" -ne 0 ]
    # 外側yaml_guard_enabled=enforceは働くのでALLOW行自体は記録される
    run grep -c "^\[.*\] ALLOW mode=enforce" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "notify_on_done_required unset (line absent from settings): fail-safe defaults to off, same as explicit off" {
    printf 'commands:\n- id: cmd_999\n  status: in_progress\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"  status: in_progress\n","new_string":"  status: in_progress\n- id: cmd_1000\n  status: assigned\n","replace_all":false}}'
    run_guard_ndr "$SETTINGS_NDR_UNSET" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "NOTIFY-REQUIRED" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "notify_on_done_required: real project config/settings.yaml default (observe) flags a missing-field new entry" {
    printf 'commands:\n- id: cmd_999\n  status: in_progress\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"  status: in_progress\n","new_string":"  status: in_progress\n- id: cmd_1000\n  status: assigned\n","replace_all":false}}'
    run_guard_ndr "$PROJECT_ROOT/config/settings.yaml" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY-NOTIFY-REQUIRED" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "notify_on_done_required=enforce: existing cmd entry (id present before edit, no notify_on_done) status update is unaffected (regression)" {
    printf 'commands:\n- id: cmd_999\n  status: in_progress\n' > "$TEST_TMP/queue/shogun_to_karo.yaml"
    local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_TMP"'/queue/shogun_to_karo.yaml","old_string":"status: in_progress","new_string":"status: done","replace_all":false}}'
    run_guard_ndr "$SETTINGS_NDR_ENFORCE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "NOTIFY-REQUIRED" "$LOG_FILE"
    [ "$status" -ne 0 ]
    run grep -c "^\[.*\] ALLOW mode=enforce" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# --- cmd_194 工程3: verified_evidence_required_enabled ---
# queue/reports/gunshi_report.yamlへの書込のうち、result.type=quality_check
# のドキュメント(軍師のQC報告)にverified_evidence欠落を検知する副flag
# (off|observe|enforce・既定observe)。strategy等の非QC報告(軍師のCategory1
# 報告)は過検知防止のため対象外。

# ケースB: verified_evidence欠落 → observeでWOULD-DENY-VERIFIED-EVIDENCEのみ
@test "verified_evidence_required=observe: QC report missing verified_evidence → WOULD-DENY-VERIFIED-EVIDENCE logged only, not denied" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/gunshi_report.yaml","content":"worker_id: gunshi\ntask_id: gunshi_qc_x\nresult:\n  type: quality_check\n  summary: ok\n"}}'
    run_guard_ver "$SETTINGS_VER_OBSERVE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "WOULD-DENY-VERIFIED-EVIDENCE" "$LOG_FILE"
    [ "$output" -eq 1 ]
    run grep "WOULD-DENY-VERIFIED-EVIDENCE" "$LOG_FILE"
    [[ "$output" == *"mode=observe"* ]]
    # 通常のDENY行(実deny)は出現しない
    run grep -c "^\[.*\] DENY mode=" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "verified_evidence_required=enforce: QC report missing verified_evidence → denied" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/gunshi_report.yaml","content":"worker_id: gunshi\ntask_id: gunshi_qc_x\nresult:\n  type: quality_check\n  summary: ok\n"}}'
    run_guard_ver "$SETTINGS_VER_ENFORCE" "$payload"

    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"verified_evidence"* ]]
}

# ケースB': result.typeがQC以外(strategy)ならverified_evidence欠落でも
# 何もログされない(過検知防止の回帰)
@test "verified_evidence_required=observe: non-QC report (result.type=strategy) missing verified_evidence → nothing logged" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/gunshi_report.yaml","content":"worker_id: gunshi\ntask_id: gunshi_design_x\nresult:\n  type: strategy\n  summary: ok\n"}}'
    run_guard_ver "$SETTINGS_VER_OBSERVE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "VERIFIED-EVIDENCE" "$LOG_FILE"
    [ "$status" -ne 0 ]
    run grep -c "^\[.*\] ALLOW mode=enforce" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

# ケースB'': verified_evidenceが非空ならWOULD-DENYが出ない
@test "verified_evidence_required=observe: QC report with non-empty verified_evidence → nothing logged" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/gunshi_report.yaml","content":"worker_id: gunshi\ntask_id: gunshi_qc_x\nresult:\n  type: quality_check\n  summary: ok\nverified_evidence:\n  - queue/reports/ashigaru1_report.yaml: confirmed test_evidence present\n"}}'
    run_guard_ver "$SETTINGS_VER_OBSERVE" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "VERIFIED-EVIDENCE" "$LOG_FILE"
    [ "$status" -ne 0 ]
    run grep -c "^\[.*\] ALLOW mode=enforce" "$LOG_FILE"
    [ "$output" -eq 1 ]
}

@test "verified_evidence_required=off (explicit): validation logic is never entered, no gate log tag" {
    local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_TMP"'/queue/reports/gunshi_report.yaml","content":"worker_id: gunshi\ntask_id: gunshi_qc_x\nresult:\n  type: quality_check\n  summary: ok\n"}}'
    run_guard_ver "$SETTINGS_VER_OFF" "$payload"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -c "VERIFIED-EVIDENCE" "$LOG_FILE"
    [ "$status" -ne 0 ]
}

# --- cmd_091標準: 実配線の確認(実settings.jsonへの登録実在) ---

@test "wiring: pretooluse_yaml_guard.sh is registered in .claude/settings.json PreToolUse array" {
    run grep -n "pretooluse_yaml_guard.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "wiring: existing pretooluse_clear_idle.sh entry is still present unchanged" {
    run grep -n "pretooluse_clear_idle.sh" "$PROJECT_ROOT/.claude/settings.json"
    [ "$status" -eq 0 ]
}
