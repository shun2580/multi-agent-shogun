#!/usr/bin/env bats

# Tests for `scripts/done.sh task` and the report_received auto-close in inbox_write.sh (cmd_222)
# 本番queueは触らない: DONE_ROOT / スクラッチ root を BATS_TEST_TMPDIR 配下に差し替える。

setup() {
  export DONE_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$DONE_ROOT/queue/tasks" "$DONE_ROOT/queue/reports" "$DONE_ROOT/queue/inbox"
  export SCRIPT_PATH="$BATS_TEST_DIRNAME/../../scripts/done.sh"
  export TASK="$DONE_ROOT/queue/tasks/ashigaru1.yaml"

  cat > "$TASK" <<'YAML'
task:
  task_id: subtask_900_A
  parent_cmd: cmd_900
  assigned_to: ashigaru1
  status: assigned
  timestamp: "2026-10-12T00:00:00"
  description: |
    本文に status: blocked や task_id: subtask_999 と書いてあっても無関係
    status: failed
  target_path: "x/"
YAML
}

report_with() {  # $1=status  (ashigaru1 の報告ファイルに subtask_900_A の1件を足す)
  cat >> "$DONE_ROOT/queue/reports/ashigaru1_report.yaml" <<YAML
---
report:
  task_id: subtask_900_A
  status: $1
  summary: "x"
YAML
}

status_of() { awk '/^  status:/ {print $2; exit}' "$1"; }

# ---- done.sh task ----

@test "task: assigned -> done, other lines byte-identical" {
  cp "$TASK" "$BATS_TEST_TMPDIR/before.yaml"
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "done" ]
  run diff "$BATS_TEST_TMPDIR/before.yaml" "$TASK"
  [ "$(printf '%s\n' "$output" | grep -c '^<')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^>')" -eq 1 ]
  grep -q "status: blocked や task_id: subtask_999" "$TASK"
}

@test "task: task_id omitted still closes the current task" {
  run bash "$SCRIPT_PATH" task ashigaru1
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "done" ]
}

@test "task: in_progress -> done" {
  sed -i 's/^  status: assigned/  status: in_progress/' "$TASK"
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "done" ]
}

@test "task: terminal values are kept (done_with_caveat / failed / superseded_x)" {
  for v in done_with_caveat failed superseded_by_cmd_075 cancelled; do
    sed -i "s/^  status: .*/  status: $v/" "$TASK"
    cp "$TASK" "$BATS_TEST_TMPDIR/before.yaml"
    run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/before.yaml" "$TASK"
  done
}

@test "task: task_id mismatch is rejected and nothing is written" {
  cp "$TASK" "$BATS_TEST_TMPDIR/before.yaml"
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_B
  [ "$status" -ne 0 ]
  [[ "$output" == *"subtask_900_A"* ]]
  cmp "$BATS_TEST_TMPDIR/before.yaml" "$TASK"
}

@test "task: a task_id only in the description body does not match" {
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_999
  [ "$status" -ne 0 ]
  [ "$(status_of "$TASK")" = "assigned" ]
}

@test "task: unknown or invalid agent is rejected" {
  run bash "$SCRIPT_PATH" task ashigaru9 subtask_900_A
  [ "$status" -ne 0 ]
  run bash "$SCRIPT_PATH" task karo subtask_900_A
  [ "$status" -ne 0 ]
  run bash "$SCRIPT_PATH" task "../tasks/ashigaru1" subtask_900_A
  [ "$status" -ne 0 ]
  [ "$(status_of "$TASK")" = "assigned" ]
}

@test "task: valid agent whose task YAML does not exist is rejected" {
  run bash "$SCRIPT_PATH" task ashigaru2 subtask_900_A
  [ "$status" -ne 0 ]
  [ ! -e "$DONE_ROOT/queue/tasks/ashigaru2.yaml" ]
}

@test "task: file without a status line is rejected and left untouched" {
  printf 'task:\n  task_id: subtask_900_A\n' > "$TASK"
  cp "$TASK" "$BATS_TEST_TMPDIR/before.yaml"
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A
  [ "$status" -ne 0 ]
  cmp "$BATS_TEST_TMPDIR/before.yaml" "$TASK"
}

@test "task: file mode is preserved" {
  chmod 640 "$TASK"
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$TASK")" = "640" ]
}

@test "task: DONE_ROOT is honoured (real queue untouched)" {
  real="$BATS_TEST_DIRNAME/../../queue/tasks/ashigaru1.yaml"
  before=""; [ -f "$real" ] && before=$(cksum < "$real")
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A
  [ "$status" -eq 0 ]
  after=""; [ -f "$real" ] && after=$(cksum < "$real")
  [ "$before" = "$after" ]
}

@test "task: gunshi is accepted" {
  printf 'task:\n  task_id: gq_1\n  status: assigned\n' > "$DONE_ROOT/queue/tasks/gunshi.yaml"
  run bash "$SCRIPT_PATH" task gunshi gq_1
  [ "$status" -eq 0 ]
  [ "$(status_of "$DONE_ROOT/queue/tasks/gunshi.yaml")" = "done" ]
}

# ---- --if-reported / --mentioned-in (inbox_write 自動閉じの部品) ----

@test "task --if-reported: closes only when the report's last record for that task is done" {
  report_with in_progress
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A --if-reported
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "assigned" ]
  report_with done
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A --if-reported
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "done" ]
}

@test "task --if-reported: failed report / no report file leaves the task as is" {
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A --if-reported
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "assigned" ]
  report_with failed
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A --if-reported
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "assigned" ]
}

@test "task --if-reported: blocked task is not turned into done" {
  sed -i 's/^  status: assigned/  status: blocked/' "$TASK"
  report_with done
  run bash "$SCRIPT_PATH" task ashigaru1 subtask_900_A --if-reported
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "blocked" ]
}

@test "task --mentioned-in: closes only when the text names the task's own id" {
  report_with done
  run bash "$SCRIPT_PATH" task ashigaru1 --if-reported --mentioned-in "subtask_123_Z完了"
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "assigned" ]
  run bash "$SCRIPT_PATH" task ashigaru1 --if-reported --mentioned-in "subtask_900_A完了。QCを仰ぎたし。"
  [ "$status" -eq 0 ]
  [ "$(status_of "$TASK")" = "done" ]
}

# ---- inbox_write.sh: report_received で『報告したのに assigned』を残さない ----

setup_inbox_root() {
  export ROOT2="$BATS_TEST_TMPDIR/iw"
  mkdir -p "$ROOT2/scripts" "$ROOT2/queue/inbox" "$ROOT2/queue/tasks" "$ROOT2/queue/reports"
  sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$ROOT2\"|" \
    "$BATS_TEST_DIRNAME/../../scripts/inbox_write.sh" > "$ROOT2/scripts/inbox_write.sh"
  cp "$SCRIPT_PATH" "$ROOT2/scripts/done.sh"
  ln -sf "$BATS_TEST_DIRNAME/../../.venv" "$ROOT2/.venv"
  cp "$TASK" "$ROOT2/queue/tasks/ashigaru1.yaml"
  cp "$DONE_ROOT/queue/reports/ashigaru1_report.yaml" "$ROOT2/queue/reports/" 2>/dev/null || true
}

@test "inbox_write: report_received from the owner with done report closes the task" {
  report_with done
  setup_inbox_root
  run bash "$ROOT2/scripts/inbox_write.sh" gunshi "subtask_900_A完了。QCを仰ぎたし。" report_received ashigaru1
  [ "$status" -eq 0 ]
  [ "$(status_of "$ROOT2/queue/tasks/ashigaru1.yaml")" = "done" ]
  grep -q "subtask_900_A完了" "$ROOT2/queue/inbox/gunshi.yaml"
}

@test "inbox_write: other message types / senders / unnamed tasks never close a task" {
  report_with done
  setup_inbox_root
  run bash "$ROOT2/scripts/inbox_write.sh" gunshi "subtask_900_A完了" info ashigaru1
  [ "$status" -eq 0 ]
  run bash "$ROOT2/scripts/inbox_write.sh" ashigaru1 "subtask_900_A完了" report_received karo
  [ "$status" -eq 0 ]
  run bash "$ROOT2/scripts/inbox_write.sh" gunshi "別件の報告" report_received ashigaru1
  [ "$status" -eq 0 ]
  [ "$(status_of "$ROOT2/queue/tasks/ashigaru1.yaml")" = "assigned" ]
}

@test "inbox_write: delivery succeeds even when the auto-close cannot run" {
  report_with done
  setup_inbox_root
  rm "$ROOT2/scripts/done.sh"
  run bash "$ROOT2/scripts/inbox_write.sh" gunshi "subtask_900_A完了" report_received ashigaru1
  [ "$status" -eq 0 ]
  grep -q "subtask_900_A完了" "$ROOT2/queue/inbox/gunshi.yaml"
  [ "$(status_of "$ROOT2/queue/tasks/ashigaru1.yaml")" = "assigned" ]
}
