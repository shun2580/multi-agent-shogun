#!/usr/bin/env bats

# Tests for scripts/done.sh (cmd_210 E-2: done化とarchive移管を1操作に)
# 本番queueは触らない: DONE_ROOT を BATS_TEST_TMPDIR 配下に差し替える。

setup() {
  export DONE_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$DONE_ROOT/queue/reports"
  export SCRIPT_PATH="$BATS_TEST_DIRNAME/../../scripts/done.sh"
  export BODY="$DONE_ROOT/queue/shogun_to_karo.yaml"

  cat > "$BODY" <<'EOF'
commands:
- id: cmd_001
  timestamp: '2026-01-01T00:00:00Z'
  status: done
  purpose: 既に完了したcmd
- id: cmd_002
  timestamp: '2026-01-02T00:00:00Z'
  priority: high
  status: in_progress
  purpose: |
    複数行の目的
    status: pending と書いてあっても本文は無関係
  acceptance_criteria:
  - 条件A
  - 条件B
- id: cmd_003
  timestamp: '2026-01-03T00:00:00Z'
  status: pending
  purpose: 未着手のcmd
EOF
  cp "$BODY" "$BATS_TEST_TMPDIR/body.orig"
}

# cmd_id のブロックを元ファイルから切り出す(比較用)
block_of() {
  awk -v id="$1" '
    /^- id:/ { on = ($0 == "- id: " id) }
    on { print }
  ' "$2"
}

@test "(a) cmd done: archiveに移り本体から消える" {
  run bash "$SCRIPT_PATH" cmd cmd_002
  [ "$status" -eq 0 ]
  archive="$DONE_ROOT/queue/archive/cmds/cmd_002.yaml"
  [ -f "$archive" ]
  grep -q '^- id: cmd_002$' "$archive"
  grep -q '^  status: done$' "$archive"
  ! grep -q 'status: in_progress' "$archive"
  ! grep -q '^- id: cmd_002$' "$BODY"
  # 本文中の "status: pending" 文字列(インデント4)は書換対象外
  grep -q '^    status: pending と書いてあっても' "$archive"
}

@test "(b) 他cmdブロックのバイト列が変わらない" {
  run bash "$SCRIPT_PATH" cmd cmd_002
  [ "$status" -eq 0 ]
  for id in cmd_001 cmd_003; do
    diff <(block_of "$id" "$BATS_TEST_TMPDIR/body.orig") <(block_of "$id" "$BODY")
  done
  head -n 1 "$BODY" | grep -qx 'commands:'
  [ "$(grep -c '^- id:' "$BODY")" -eq 2 ]
}

@test "(b2) 末尾ブロックも移管でき、他ブロックは無変更" {
  run bash "$SCRIPT_PATH" cmd cmd_003
  [ "$status" -eq 0 ]
  [ -f "$DONE_ROOT/queue/archive/cmds/cmd_003.yaml" ]
  ! grep -q 'cmd_003' "$BODY"
  for id in cmd_001 cmd_002; do
    diff <(block_of "$id" "$BATS_TEST_TMPDIR/body.orig") <(block_of "$id" "$BODY")
  done
}

@test "(c) 存在しないcmd_id: exit 1 かつ本体無変更・archive無し" {
  run bash "$SCRIPT_PATH" cmd cmd_999
  [ "$status" -eq 1 ]
  [[ "$output" == *"cmd_999"* ]]
  cmp "$BODY" "$BATS_TEST_TMPDIR/body.orig"
  [ ! -e "$DONE_ROOT/queue/archive/cmds/cmd_999.yaml" ]
}

@test "(c2) 不正なcmd_id / 引数不足: exit 1 かつ本体無変更" {
  run bash "$SCRIPT_PATH" cmd "../etc/passwd"
  [ "$status" -eq 1 ]
  run bash "$SCRIPT_PATH" cmd
  [ "$status" -eq 1 ]
  run bash "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  cmp "$BODY" "$BATS_TEST_TMPDIR/body.orig"
}

@test "(d) archive書込失敗時: 本体が壊れず exit 非0 + 理由" {
  mkdir -p "$DONE_ROOT/queue/archive"
  : > "$DONE_ROOT/queue/archive/cmds"   # ディレクトリになれない通常ファイル → mkdir/書込不能
  run bash "$SCRIPT_PATH" cmd cmd_002
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
  cmp "$BODY" "$BATS_TEST_TMPDIR/body.orig"
}

@test "(d2) archive先に同名ファイルが既存: 上書きせず失敗、本体無変更" {
  mkdir -p "$DONE_ROOT/queue/archive/cmds"
  echo "preexisting" > "$DONE_ROOT/queue/archive/cmds/cmd_002.yaml"
  run bash "$SCRIPT_PATH" cmd cmd_002
  [ "$status" -ne 0 ]
  cmp "$BODY" "$BATS_TEST_TMPDIR/body.orig"
  [ "$(cat "$DONE_ROOT/queue/archive/cmds/cmd_002.yaml")" = "preexisting" ]
}

@test "(f) 同じcmdを二度done化: 2回目は明確に失敗し壊れない" {
  run bash "$SCRIPT_PATH" cmd cmd_002
  [ "$status" -eq 0 ]
  cp "$BODY" "$BATS_TEST_TMPDIR/body.after1"
  cp "$DONE_ROOT/queue/archive/cmds/cmd_002.yaml" "$BATS_TEST_TMPDIR/arch.after1"
  run bash "$SCRIPT_PATH" cmd cmd_002
  [ "$status" -eq 1 ]
  [[ "$output" == *"既にarchive済み"* ]]
  cmp "$BODY" "$BATS_TEST_TMPDIR/body.after1"
  cmp "$DONE_ROOT/queue/archive/cmds/cmd_002.yaml" "$BATS_TEST_TMPDIR/arch.after1"
}

@test "(e) report: archive作成 + status done + 冪等 (インデント付きstatus)" {
  report="$DONE_ROOT/queue/reports/ashigaru9_report.yaml"
  cat > "$report" <<'EOF'
report:
  task_id: subtask_x
  status: in_progress
  summary: "テスト"
EOF
  run bash "$SCRIPT_PATH" report "$report"
  [ "$status" -eq 0 ]
  grep -q '^  status: done$' "$report"
  ! grep -q 'in_progress' "$report"
  # archiveは書換前(in_progress)のスナップショット
  archived=$(ls "$DONE_ROOT/queue/reports/archive/"ashigaru9_report_*.yaml)
  [ -f "$archived" ]
  grep -q 'in_progress' "$archived"

  # 冪等: 再実行しても status done のまま・内容不変・エラー無し
  cp "$report" "$BATS_TEST_TMPDIR/report.after1"
  run bash "$SCRIPT_PATH" report "$report"
  [ "$status" -eq 0 ]
  cmp "$report" "$BATS_TEST_TMPDIR/report.after1"
  grep -c '^  status: done$' "$report" | grep -qx 1
}

@test "(e2) report: top-level status 形式にも対応" {
  report="$DONE_ROOT/queue/reports/flat.yaml"
  printf 'status: assigned\nnote: x\n' > "$report"
  run bash "$SCRIPT_PATH" report "$report"
  [ "$status" -eq 0 ]
  grep -qx 'status: done' "$report"
  ls "$DONE_ROOT/queue/reports/archive/"flat_*.yaml
}

@test "(e3) report: 存在しないファイル / status無し は exit 1" {
  run bash "$SCRIPT_PATH" report "$DONE_ROOT/queue/reports/nope.yaml"
  [ "$status" -eq 1 ]
  printf 'foo: bar\n' > "$DONE_ROOT/queue/reports/nostatus.yaml"
  run bash "$SCRIPT_PATH" report "$DONE_ROOT/queue/reports/nostatus.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"status"* ]]
}

# ---- cmd_215: 終端 status (done_with_caveat/superseded/cancelled/failed) を done へ潰さない ----

# 2ブロックの shogun_to_karo.yaml を作る: $1=id $2=status行の値部分(行末コメント込み可)
make_body_with_status() {
  cat > "$BODY" <<YAML
commands:
- id: $1
  timestamp: '2026-02-01T00:00:00Z'
  status: $2
  purpose: |
    本文
    status: pending と書いてあっても無関係
- id: cmd_other
  timestamp: '2026-02-02T00:00:00Z'
  status: pending
  purpose: 他のcmd
YAML
  cp "$BODY" "$BATS_TEST_TMPDIR/body.t215"
}

@test "(g) cmd: 終端 status (done_with_caveat/superseded/cancelled/failed) は archive 先でも元の値のまま・本体から除去" {
  for st in done_with_caveat superseded cancelled failed; do
    make_body_with_status cmd_t215 "$st"
    run bash "$SCRIPT_PATH" cmd cmd_t215
    [ "$status" -eq 0 ]
    archive="$DONE_ROOT/queue/archive/cmds/cmd_t215.yaml"
    grep -qx "  status: $st" "$archive"
    ! grep -qx '  status: done' "$archive"
    ! grep -q '^- id: cmd_t215$' "$BODY"
    [[ "$output" == *"(本体から除去済み"* ]]
    [[ "$output" == *"status 保持: $st"* ]]
    rm -f "$archive"
  done
}

@test "(g2) cmd: 行末コメント付き終端 status 行はバイト不変" {
  make_body_with_status cmd_t215 'done_with_caveat  # 理由: 一部未達'
  run bash "$SCRIPT_PATH" cmd cmd_t215
  [ "$status" -eq 0 ]
  grep -qxF '  status: done_with_caveat  # 理由: 一部未達' "$DONE_ROOT/queue/archive/cmds/cmd_t215.yaml"
  # archive 全体も元ブロックとバイト一致 (先頭の commands: 行を除く)
  diff <(tail -n +2 "$DONE_ROOT/queue/archive/cmds/cmd_t215.yaml") <(block_of cmd_t215 "$BATS_TEST_TMPDIR/body.t215")
}

@test "(g3) cmd: 終端でない status (pending/in_progress/assigned) は従来どおり done になる" {
  for st in pending in_progress assigned; do
    make_body_with_status cmd_t215 "$st"
    run bash "$SCRIPT_PATH" cmd cmd_t215
    [ "$status" -eq 0 ]
    archive="$DONE_ROOT/queue/archive/cmds/cmd_t215.yaml"
    grep -qx '  status: done' "$archive"
    [[ "$output" == *"(本体から除去済み)"* ]]
    [[ "$output" != *"status 保持"* ]]
    rm -f "$archive"
  done
}

@test "(g4) cmd: 本文中の深いインデントの終端風文字列は判定に影響しない (最初の status 行が in_progress なら done)" {
  cat > "$BODY" <<'YAML'
commands:
- id: cmd_t215
  timestamp: '2026-02-01T00:00:00Z'
  status: in_progress
  purpose: |
    本文
    status: done_with_caveat と書いてあっても無関係
      status: cancelled
YAML
  run bash "$SCRIPT_PATH" cmd cmd_t215
  [ "$status" -eq 0 ]
  archive="$DONE_ROOT/queue/archive/cmds/cmd_t215.yaml"
  grep -qx '  status: done' "$archive"
  ! grep -q '^  status: in_progress' "$archive"
  # 本文中の文字列は無変更
  grep -qx '    status: done_with_caveat と書いてあっても無関係' "$archive"
  grep -qx '      status: cancelled' "$archive"
}

@test "(g5) cmd: 最初の status 行が終端なら本文中の status: pending に引きずられない" {
  make_body_with_status cmd_t215 cancelled
  run bash "$SCRIPT_PATH" cmd cmd_t215
  [ "$status" -eq 0 ]
  grep -qx '  status: cancelled' "$DONE_ROOT/queue/archive/cmds/cmd_t215.yaml"
}

@test "(h) report (インデント付き): 終端 status は書き換えられない・表示も実際の値" {
  for st in done_with_caveat superseded cancelled failed; do
    report="$DONE_ROOT/queue/reports/r_$st.yaml"
    printf 'report:\n  task_id: subtask_x\n  status: %s\n  summary: "テスト"\n' "$st" > "$report"
    cp "$report" "$BATS_TEST_TMPDIR/r.orig"
    run bash "$SCRIPT_PATH" report "$report"
    [ "$status" -eq 0 ]
    cmp "$report" "$BATS_TEST_TMPDIR/r.orig"
    [[ "$output" == *"(status: $st)"* ]]
    ls "$DONE_ROOT/queue/reports/archive/"r_${st}_*.yaml
  done
}

@test "(h2) report (top-level): 終端 status は書き換えられない・行末コメントもバイト不変" {
  for st in done_with_caveat superseded cancelled failed; do
    report="$DONE_ROOT/queue/reports/t_$st.yaml"
    printf 'status: %s  # 理由あり\nnote: x\n' "$st" > "$report"
    cp "$report" "$BATS_TEST_TMPDIR/t.orig"
    run bash "$SCRIPT_PATH" report "$report"
    [ "$status" -eq 0 ]
    cmp "$report" "$BATS_TEST_TMPDIR/t.orig"
    [[ "$output" == *"(status: $st)"* ]]
  done
}

@test "(h3) report: status: done は冪等 (両形式)・表示は (status: done)" {
  r1="$DONE_ROOT/queue/reports/idem_top.yaml"
  r2="$DONE_ROOT/queue/reports/idem_nested.yaml"
  printf 'status: done\nnote: x\n' > "$r1"
  printf 'report:\n  status: done\n' > "$r2"
  for r in "$r1" "$r2"; do
    cp "$r" "$BATS_TEST_TMPDIR/idem.orig"
    run bash "$SCRIPT_PATH" report "$r"
    [ "$status" -eq 0 ]
    cmp "$r" "$BATS_TEST_TMPDIR/idem.orig"
    [[ "$output" == *"(status: done)"* ]]
  done
}

@test "(h4) report: 終端でない status (blocked) は done へ書き換わる" {
  report="$DONE_ROOT/queue/reports/blk.yaml"
  printf 'report:\n  status: blocked  # x\n  n: 1\n' > "$report"
  run bash "$SCRIPT_PATH" report "$report"
  [ "$status" -eq 0 ]
  grep -qx '  status: done' "$report"
  ! grep -q blocked "$report"
  [[ "$output" == *"(status: done)"* ]]
}

@test "(h5) report: 引用符付き終端値も書き換えない" {
  report="$DONE_ROOT/queue/reports/quoted.yaml"
  printf 'status: "done_with_caveat"\n' > "$report"
  cp "$report" "$BATS_TEST_TMPDIR/q.orig"
  run bash "$SCRIPT_PATH" report "$report"
  [ "$status" -eq 0 ]
  cmp "$report" "$BATS_TEST_TMPDIR/q.orig"
}
