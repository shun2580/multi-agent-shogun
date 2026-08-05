#!/usr/bin/env bats
# cmd_151: scope_check.sh 生成物パス除外ロジックのテスト
# (tests/test_scope_check_fastlane.batsの慣習に倣う)

setup() {
  TEST_DIR=$(mktemp -d /tmp/scope_exclusion_test_XXXXXX)
  cd "$TEST_DIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  touch .gitkeep
  git add .gitkeep
  git commit -q -m "initial"
  BASE_SHA=$(git rev-parse HEAD)

  SCOPE_CHECK_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/scope_check.sh"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_DIR"
}

# --- 組1: 生成物パス単独 → 除外されexit 0 ---

@test "Generated-OK: .opencode/agents/*.md + instructions/generated/* only → excluded, exit 0" {
  mkdir -p .opencode/agents instructions/generated instructions
  echo "content" > instructions/karo.md
  echo "generated" > .opencode/agents/karo.md
  echo "generated" > instructions/generated/opencode-karo.md
  git add instructions/karo.md .opencode/agents/karo.md instructions/generated/opencode-karo.md
  git commit -q -m "edit instructions plus generated sync"

  # task.yaml itself is written after the commit so it never enters git diff
  echo "allowed_paths:
  - instructions/karo.md" > task.yaml
  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]

  run cat logs/scope_check_exclusion_effect.jsonl
  [[ "$output" == *'"flipped_to_pass":true'* ]]
  [[ "$output" == *".opencode/agents/karo.md"* ]]
  [[ "$output" == *"instructions/generated/opencode-karo.md"* ]]
}

@test "Generated-OK: AGENTS.md alone (no allowed_paths match) → excluded, exit 0" {
  echo "generated" > AGENTS.md
  git add AGENTS.md
  git commit -q -m "sync AGENTS.md"

  echo "allowed_paths:
  - dummy/placeholder.md" > task.yaml

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Generated-OK: .github/copilot-instructions.md alone → excluded, exit 0" {
  mkdir -p .github
  echo "generated" > .github/copilot-instructions.md
  git add .github/copilot-instructions.md
  git commit -q -m "sync copilot instructions"

  echo "allowed_paths:
  - dummy/placeholder.md" > task.yaml

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Generated-OK: agents/default/system.md alone → excluded, exit 0" {
  mkdir -p agents/default
  echo "generated" > agents/default/system.md
  git add agents/default/system.md
  git commit -q -m "sync default system.md"

  echo "allowed_paths:
  - dummy/placeholder.md" > task.yaml

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

# --- 組2: 生成物パス除外対象外は従来どおり検知される ---

@test "Generated-NG: non-generated undeclared file still detected as violation (exit 1)" {
  mkdir -p instructions
  echo "content" > instructions/karo.md
  echo "undeclared" > undeclared.md
  git add instructions/karo.md undeclared.md
  git commit -q -m "edit instructions plus undeclared file"

  echo "allowed_paths:
  - instructions/karo.md" > task.yaml

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"undeclared.md"* ]]
}

@test "Generated-NG: mixed generated + non-generated undeclared files → exclusion partial, exit 1 with only real violation listed" {
  mkdir -p .opencode/agents instructions queue/tasks
  echo "content" > instructions/karo.md
  echo "generated" > .opencode/agents/karo.md
  echo "real violation" > queue/tasks/gunshi.yaml
  git add instructions/karo.md .opencode/agents/karo.md queue/tasks/gunshi.yaml
  git commit -q -m "edit instructions plus generated sync plus real out-of-scope file"

  echo "allowed_paths:
  - instructions/karo.md" > task.yaml

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"queue/tasks/gunshi.yaml"* ]]
  [[ "$output" != *".opencode/agents/karo.md"* ]]

  run cat logs/scope_check_exclusion_effect.jsonl
  [[ "$output" == *'"flipped_to_pass":false'* ]]
  [[ "$output" == *'"remaining_violating_files":["queue/tasks/gunshi.yaml"]'* ]]
}

@test "Generated-neutral: no generated-path files changed → no exclusion effect log written" {
  mkdir -p instructions
  echo "content" > instructions/karo.md
  git add instructions/karo.md
  git commit -q -m "edit instructions only"

  echo "allowed_paths:
  - instructions/karo.md" > task.yaml

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
  [ ! -f logs/scope_check_exclusion_effect.jsonl ]
}
