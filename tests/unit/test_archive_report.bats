#!/usr/bin/env bats

# Tests for scripts/archive_report.sh

setup() {
  # Create a temporary directory for test files
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR

  # Source the script being tested
  export SCRIPT_PATH="scripts/archive_report.sh"
}

teardown() {
  # Clean up temporary directory
  rm -rf "$TEST_DIR"
}

@test "nonexistent file: exit 0 and create no archive" {
  nonexistent="$TEST_DIR/nonexistent_report.yaml"

  run bash "$SCRIPT_PATH" "$nonexistent"

  [ "$status" -eq 0 ]
  [ ! -d "$TEST_DIR/archive" ]
}

@test "empty file: exit 0 and create no archive" {
  empty_file="$TEST_DIR/empty_report.yaml"
  touch "$empty_file"

  run bash "$SCRIPT_PATH" "$empty_file"

  [ "$status" -eq 0 ]
  [ ! -d "$TEST_DIR/archive" ]
}

@test "file with content: archive created with timestamp, content matches original" {
  report_file="$TEST_DIR/test_report.yaml"
  echo "test: content" > "$report_file"
  echo "nested: data" >> "$report_file"

  # Capture the archive path from stdout
  run bash "$SCRIPT_PATH" "$report_file"

  [ "$status" -eq 0 ]
  archive_path="$output"

  # Verify archive file exists
  [ -f "$archive_path" ]

  # Verify content matches
  diff "$report_file" "$archive_path"

  # Verify original file is unchanged
  [ "$(wc -l < "$report_file")" -eq 2 ]
}

@test "no arguments: exit 1 with error message" {
  run bash "$SCRIPT_PATH"

  [ "$status" -eq 1 ]
  [[ "$output" =~ "file path argument required" ]]
}
