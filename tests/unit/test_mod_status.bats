#!/usr/bin/env bats
# test_mod_status.bats — cmd_220 / subtask_220_A
# The shogun-only status Mod (mods/status) must stay observe-only. These tests pin that from outside:
#   - the events it handles and the mods-API calls it makes (what `claude plugin validate` lists)
#   - its own unit tests (`claude plugin test`: parsing, every '?' case, observe-only, no read on redraw)
#   - the .gitignore lines that make mods/ trackable
# A missing `claude` is a FAIL, not a skip (Test Rules: SKIP = FAIL).

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export MOD_DIR="$REPO_ROOT/mods/status"
    command -v claude >/dev/null 2>&1 || { echo "claude CLI is required" >&2; return 1; }
    # validate output is read by several tests; compute it once
    export VALIDATE_OUT="$BATS_FILE_TMPDIR/validate.txt"
    claude plugin validate "$MOD_DIR" >"$VALIDATE_OUT" 2>&1 || true
}

@test "validate: the Mod passes claude plugin validate" {
    run grep -F "Validation passed" "$VALIDATE_OUT"
    [ "$status" -eq 0 ]
}

@test "validate: handles only session.start and the AbovePrompt render site" {
    hooks="$(grep -E '^\s*❯ \./register\.js hooks:' "$VALIDATE_OUT" | sed 's/.*hooks: //')"
    [ "$hooks" = "session.start, ui.render{component=AbovePrompt}" ]
}

@test "validate: makes only the read-only mods-API calls (no write, process, http, prompt, tool, session)" {
    calls="$(grep -E '^\s*❯ \./register\.js calls:' "$VALIDATE_OUT" | sed 's/.*calls: //; s/ (via [^,)]*)//g')"
    [ -n "$calls" ]
    allowed=' $.clock.every $.env.get $.fs.read $.ui.invalidate $.ui.resolve '
    IFS=',' read -ra items <<<"$calls"
    for c in "${items[@]}"; do
        c="$(echo "$c" | tr -d ' ')"
        [[ "$allowed" == *" $c "* ]] || { echo "unexpected call: $c"; false; }
    done
}

@test "validate: reads only SHOGUN_STATUS_ROOT and writes no environment variable" {
    run grep -E '^\s*❯ \./register\.js env reads:' "$VALIDATE_OUT"
    [[ "$output" == *"env reads: SHOGUN_STATUS_ROOT"* ]]
    [ "$(echo "$output" | sed 's/.*env reads: //')" = "SHOGUN_STATUS_ROOT" ]
    run grep -E '^\s*❯ \./register\.js env writes:' "$VALIDATE_OUT"
    [[ "$output" == *"env writes: nothing"* ]]
}

@test "source: no hook that could deny, approve, answer or rewrite" {
    cd "$MOD_DIR/hooks"
    run grep -nE "on\(\s*'(tool\.|prompt\.|skill\.|command\.|session\.(receive|send|append|compact)|turn\.|config\.|agent\.|classic\.)" register.js lib.js
    [ "$status" -eq 1 ]
    run grep -nE "\bdeny\b|\bdrop\b|\bconsumed\b|\bdecision\b|\bprompt\.(submit|fill)|fs\.write|process\.(run|spawn)|http\.fetch" register.js lib.js
    [ "$status" -eq 1 ]
}

@test "plugin test: the Mod's own tests pass with 0 fail" {
    cd "$MOD_DIR"
    run claude plugin test
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *" 0 fail"* ]]
    [[ "$output" =~ ([1-9][0-9]*)\ pass ]]
}

@test "gitignore: mods/ sources are trackable, node_modules and test output are not" {
    cd "$REPO_ROOT"
    run git check-ignore -q mods/status/hooks/register.js
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/status/.claude-plugin/plugin.json
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/status/tests/status.test.ts
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/status/node_modules/x/index.js
    [ "$status" -eq 0 ]
    run git check-ignore -q mods/status/test-results/out.xml
    [ "$status" -eq 0 ]
    run git check-ignore -q mods/status/tests/run.log
    [ "$status" -eq 0 ]
}
