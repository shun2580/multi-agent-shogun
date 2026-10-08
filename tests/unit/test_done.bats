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
