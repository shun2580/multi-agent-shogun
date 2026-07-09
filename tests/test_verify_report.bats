#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="/home/nishikawa/projects/multi-agent-shogun"
    cd "$PROJECT_ROOT"
}

@test "Case 1: Fabrication detection - test file not found returns exit 1" {
    # Setup: verify that test_scope_check_nonexistent.bats does NOT exist
    [ ! -f "tests/test_scope_check_nonexistent.bats" ]

    # Execute: run verify_report.sh with fabricated_report.yaml
    run bash scripts/verify_report.sh tests/fixtures/fabricated_report.yaml

    # Expect: exit 1 and stderr contains error message
    [ "$status" -eq 1 ]
    [[ "$output" == *"test file not found"* ]] || [[ "$output" == *"not found"* ]]
}

@test "Case 2: Valid report execution returns exit 0" {
    # Setup: verify that test_scope_check.bats exists
    [ -f "tests/test_scope_check.bats" ]

    # Execute: run verify_report.sh with valid_report.yaml
    run bash scripts/verify_report.sh tests/fixtures/valid_report.yaml

    # Expect: exit 0 (test passes)
    [ "$status" -eq 0 ]
}

@test "Case 3: Old format backward compatibility returns exit 2" {
    # Setup: verify old_format_report.yaml exists with tests_status: not_applicable
    grep -q "tests_status: not_applicable" tests/fixtures/old_format_report.yaml

    # Execute: run verify_report.sh with old_format_report.yaml
    run bash scripts/verify_report.sh tests/fixtures/old_format_report.yaml

    # Expect: exit 2 (skip/backward compatible)
    [ "$status" -eq 2 ]
}
