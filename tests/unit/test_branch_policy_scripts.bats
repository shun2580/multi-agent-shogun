#!/usr/bin/env bats

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/branch_policy.XXXXXX")"
    export TEST_REPO="$TEST_TMPDIR/repo"
    export TEST_SETTINGS="$TEST_TMPDIR/settings.yaml"

    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -q
    git -C "$TEST_REPO" config user.email "test@example.com"
    git -C "$TEST_REPO" config user.name "Test User"

    echo "base" > "$TEST_REPO/file.txt"
    git -C "$TEST_REPO" add file.txt
    GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000" \
    GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000" \
        git -C "$TEST_REPO" commit -q -m "base"
    git -C "$TEST_REPO" branch -M main
    git -C "$TEST_REPO" update-ref refs/remotes/origin/main HEAD
    git -C "$TEST_REPO" update-ref refs/remotes/origin/codd/demo-20000101 HEAD

    # cmd_213: ntfy topic は settings.yaml ではなく secrets.env (ダミー値) から読む
    export SHOGUN_SECRETS_FILE="$TEST_TMPDIR/secrets.env"
    printf 'NTFY_TOPIC=test-topic-12345\n' > "$SHOGUN_SECRETS_FILE"

    cat > "$TEST_SETTINGS" <<EOF
branch_policy:
  allowed_long_lived:
    - main
  short_lived_pattern: "^codd/[^/]+-[0-9]{8}$"
  max_age_seconds: 1
  monitored_repos:
    - path: $TEST_REPO
EOF
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "pre_deploy_verify passes on configured primary branch" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/pre_deploy_verify.sh" --repo "$TEST_REPO" --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] deploy branch confirmed: main"* ]]
}

@test "branch_drift_check reports stale non-primary remote branch in dry-run" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/branch_drift_check.sh" --dry-run --no-fetch

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRIFT] branch drift: origin/codd/demo-20000101"* ]]
    [[ "$output" == *"[DRY-RUN] notify:"* ]]
}

@test "auto_merge_short_lived previews stale matching branch without mutation" {
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash "$PROJECT_ROOT/scripts/auto_merge_short_lived.sh" --dry-run --no-fetch

    [ "$status" -eq 0 ]
    [[ "$output" == *"[CANDIDATE]"* ]]
    [[ "$output" == *"[DRY-RUN] would merge origin/codd/demo-20000101 into main"* ]]
    git -C "$TEST_REPO" show-ref --verify --quiet refs/remotes/origin/codd/demo-20000101
}

# cmd_213: branch_policy の ntfy topic 読出しは secrets.env から (settings.yaml は見ない)
@test "branch_policy_query ntfy_topic reads NTFY_TOPIC from secrets.env" {
    run bash -c 'source "$1/lib/branch_policy.sh"; branch_policy_query ntfy_topic' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "test-topic-12345" ]
}

@test "branch_policy_query ntfy_topic ignores a legacy ntfy_topic in settings.yaml" {
    printf 'ntfy_topic: "legacy-topic-in-settings"\n' >> "$TEST_SETTINGS"
    printf 'NTFY_TOPIC=from-secrets-env-1\n' > "$SHOGUN_SECRETS_FILE"
    run env BRANCH_POLICY_SETTINGS="$TEST_SETTINGS" \
        bash -c 'source "$1/lib/branch_policy.sh"; branch_policy_query ntfy_topic' _ "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "from-secrets-env-1" ]
}

@test "branch_policy_query ntfy_topic fails loud when secrets.env is missing (no value printed)" {
    export SHOGUN_SECRETS_FILE="$TEST_TMPDIR/none.env"
    run bash -c 'source "$1/lib/branch_policy.sh"; branch_policy_query ntfy_topic' _ "$PROJECT_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"secrets.env not found"* ]]
    [[ "$output" != *"test-topic-12345"* ]]
}
