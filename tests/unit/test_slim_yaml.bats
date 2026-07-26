#!/usr/bin/env bats

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/slim_yaml.XXXXXX")"
    export SHOGUN_QUEUE_DIR="$TEST_TMPDIR/queue"
    export TEST_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -x "$TEST_PYTHON" ] || TEST_PYTHON="python3"
    mkdir -p "$SHOGUN_QUEUE_DIR"/{tasks,reports,inbox}

    # Fail-loud parse-error alerts (cmd_111 Part B) call ntfy.sh and append
    # to dashboard.md. Override both so tests never fire a real push
    # notification and can assert on what would have been sent.
    export SLIM_YAML_NTFY_LOG="$TEST_TMPDIR/ntfy.log"
    export SLIM_YAML_NTFY_SCRIPT="$TEST_TMPDIR/fake_ntfy.sh"
    cat > "$SLIM_YAML_NTFY_SCRIPT" <<'EOS'
#!/bin/bash
echo "$*" >> "$SLIM_YAML_NTFY_LOG"
EOS
    chmod +x "$SLIM_YAML_NTFY_SCRIPT"
    export SLIM_YAML_DASHBOARD_MD="$TEST_TMPDIR/dashboard.md"
    printf '## 🚨 要対応\n' > "$SLIM_YAML_DASHBOARD_MD"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

write_yaml() {
    local file="$1" value="$2"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$value" > "$file"
}

run_slim() {
    "$TEST_PYTHON" "$PROJECT_ROOT/scripts/slim_yaml.py" "$@"
}

run_slim_wrapper() {
    bash "$PROJECT_ROOT/scripts/slim_yaml.sh" "$@"
}

yaml_value() {
    local file="$1" expr="$2"
    "$TEST_PYTHON" - "$file" "$expr" <<'PY'
import sys
import yaml

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

value = data
for key in expr.split("."):
    if isinstance(value, dict):
        value = value.get(key)
    else:
        value = None
        break
print("" if value is None else value)
PY
}

@test "dry-run does not mutate commands tasks reports inbox migration or create archive dir" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_done\n  status: done\n- id: cmd_pending\n  status: pending\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_done.yaml" $'parent_cmd: cmd_done\nstatus: done\n'
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_done.yaml"
    write_yaml "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" $'messages:\n- id: m1\n  read: true\n- id: m2\n  read: false\n'
    mkdir -p "$SHOGUN_QUEUE_DIR/reports/archive"
    write_yaml "$SHOGUN_QUEUE_DIR/reports/archive/old.yaml" "status: done"

    before="$(find "$SHOGUN_QUEUE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum)"

    run run_slim karo --dry-run
    assert_success
    assert_output --partial "[DRY-RUN] would archive"

    after="$(find "$SHOGUN_QUEUE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum)"
    [ "$before" = "$after" ]
    [ ! -d "$SHOGUN_QUEUE_DIR/archive" ]
    [ -f "$SHOGUN_QUEUE_DIR/reports/archive/old.yaml" ]
}

@test "wrapper dry-run does not create queue lock file" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_done\n  status: done\n'

    run run_slim_wrapper karo --dry-run
    assert_success

    [ ! -e "$SHOGUN_QUEUE_DIR/.slim_yaml.lock" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue.0.id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert data["queue"][0]["id"] == "cmd_done"
PY
}

@test "archives terminal commands using canonical statuses and keeps non-terminal commands" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_done\n  status: done\n- id: cmd_cancelled\n  status: cancelled\n- id: cmd_paused\n  status: paused\n- id: cmd_pending\n  status: pending\n- id: cmd_in_progress\n  status: in_progress\n- id: cmd_blocked\n  status: blocked\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue.0.id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["queue"]]
assert ids == ["cmd_pending", "cmd_in_progress", "cmd_blocked"], ids
PY
    archive_count="$(find "$SHOGUN_QUEUE_DIR/archive" -name 'shogun_to_karo_*.yaml' | wc -l)"
    [ "$archive_count" -eq 1 ]
}

@test "supports current top-level task status and resets canonical task to top-level idle" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\ntask_id: subtask_done\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/subtask_done.yaml" $'task_id: subtask_done\nstatus: done\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "status")" = "idle" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "worker_id")" = "ashigaru1" ]
    [ ! -f "$SHOGUN_QUEUE_DIR/tasks/subtask_done.yaml" ]
    [ -f "$SHOGUN_QUEUE_DIR/archive/tasks/subtask_done.yaml" ]
}

@test "supports legacy task.status and preserves legacy idle shape" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" $'task:\n  task_id: subtask_legacy\n  status: done\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" "task.status")" = "idle" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" "status")" = "" ]
}

@test "archives read inbox messages and preserves unread messages" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" $'messages:\n- id: read-msg\n  read: true\n- id: unread-msg\n  read: false\n'

    run run_slim karo
    assert_success

    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["messages"]]
assert ids == ["unread-msg"], ids
PY
    archive_count="$(find "$SHOGUN_QUEUE_DIR/archive" -name 'inbox_karo_*.yaml' | wc -l)"
    [ "$archive_count" -eq 1 ]
}

@test "ntfy inbox old pending entries are inventoried but not deleted" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" $'inbox:\n- id: pending-old\n  status: pending\n  timestamp: "2000-01-01T00:00:00+09:00"\n- id: done-old\n  status: done\n  timestamp: "2000-01-01T00:00:00+09:00"\n'

    run run_slim karo --dry-run
    assert_success
    assert_output --partial "old ntfy pending/non-terminal entries kept"
    assert_output --partial "old ntfy terminal entries available for explicit cleanup"

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" "inbox.0.id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["inbox"]]
assert ids == ["pending-old", "done-old"], ids
PY
}

# --- cmd_111 Part B: load_yaml() fail-loud on parse failure ---

@test "corrupt shogun_to_karo.yaml fires the fail-loud alert path (ntfy + dashboard) and exits non-zero" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n  bad: [unclosed\n'

    run run_slim karo
    assert_failure
    assert_output --partial "Error: failed to parse"

    # ntfy.sh (stubbed) was invoked with a parse-failure alert
    assert [ -f "$SLIM_YAML_NTFY_LOG" ]
    run cat "$SLIM_YAML_NTFY_LOG"
    assert_output --partial "YAML破損検知"
    assert_output --partial "shogun_to_karo.yaml"

    # dashboard.md 🚨要対応 section got an entry a deadman/human can see
    run cat "$SLIM_YAML_DASHBOARD_MD"
    assert_output --partial "YAMLパース失敗検知"
    assert_output --partial "shogun_to_karo.yaml"
}

@test "corrupt single task file is skipped without blocking other agents' task files, exit non-zero" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" $'worker_id: ashigaru2\nstatus: [unclosed\n'

    run run_slim karo
    assert_failure
    assert_output --partial "failed to parse task file ashigaru2.yaml"

    # Healthy file still processed (reset to idle) despite the sibling's corruption
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "status")" = "idle" ]
    # Corrupt file left untouched, not silently emptied or archived
    run cat "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml"
    assert_output --partial "[unclosed"
}

@test "empty file and inbox: with no value are normal-empty, do not fire the fail-loud alert" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    : > "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml"

    run run_slim karo --dry-run
    assert_success
    refute_output --partial "failed to parse"
    [ ! -s "$SLIM_YAML_NTFY_LOG" ]
    run cat "$SLIM_YAML_DASHBOARD_MD"
    refute_output --partial "YAMLパース失敗検知"

    # `inbox:` present with no value parses to {'inbox': None} -- syntactically
    # valid YAML, not a parse failure, so the fail-loud path must not fire.
    write_yaml "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" $'inbox:\n'
    run run_slim karo --dry-run
    assert_success
    refute_output --partial "failed to parse"
    refute_output --partial "ntfy inbox is not a list"
}

@test "regression: queue/ntfy_inbox.yaml 'inbox:' empty-value no longer reports 'not a list' (the cmd_111 incident case)" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    # Exact real-world shape that broke for ~2 months: `inbox:` key present
    # with no value -> yaml.safe_load gives {'inbox': None}. The old
    # `data.get('inbox', [])` only substitutes the default when the key is
    # ABSENT, so it returned None -> isinstance(None, list) is False ->
    # "ntfy inbox is not a list" -> return False -> exit 1, silently, forever.
    write_yaml "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" $'inbox:\n'

    run run_slim karo
    assert_success
    refute_output --partial "ntfy inbox is not a list"
}
