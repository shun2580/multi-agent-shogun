#!/usr/bin/env bats
# test_mod_toolrow.bats — cmd_228 / subtask_228_A
# The tool-row Mod (mods/toolrow) must stay display-only (journal S-14). These tests pin that from outside:
#   - the events it handles and the mods-API calls it makes (what `claude plugin validate` lists)
#   - its own unit tests (`claude plugin test`: names, brackets, pass-through, plan A / plan B)
#   - the source: no tool.* hook, no Spinner / ToolGroup, no I/O, plan A shipped, the names in one place
#   - the .gitignore lines that make mods/ trackable
# A missing `claude` is a FAIL, not a skip (Test Rules: SKIP = FAIL). No tmux is used here.

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export MOD_DIR="$REPO_ROOT/mods/toolrow"
    command -v claude >/dev/null 2>&1 || { echo "claude CLI is required" >&2; return 1; }
    export VALIDATE_OUT="$BATS_FILE_TMPDIR/validate.txt"
    claude plugin validate "$MOD_DIR" >"$VALIDATE_OUT" 2>&1 || true
}

@test "validate: the Mod passes claude plugin validate" {
    run grep -F "Validation passed" "$VALIDATE_OUT"
    [ "$status" -eq 0 ]
}

@test "validate: handles only the ToolUse render site" {
    hooks="$(grep -E '^\s*❯ \./register\.js hooks:' "$VALIDATE_OUT" | sed 's/.*hooks: //')"
    [ "$hooks" = "ui.render{component=ToolUse}" ]
}

@test "validate: makes only ui.resolve (no env, read, write, process, http, prompt, tool)" {
    calls="$(grep -E '^\s*❯ \./register\.js calls:' "$VALIDATE_OUT" | sed 's/.*calls: //; s/ (via [^,)]*)//g')"
    [ -n "$calls" ]
    allowed=' $.ui.resolve '
    IFS=',' read -ra items <<<"$calls"
    for c in "${items[@]}"; do
        c="$(echo "$c" | tr -d ' ')"
        [[ "$allowed" == *" $c "* ]] || { echo "unexpected call: $c"; false; }
    done
}

@test "validate: reads no environment variable and writes none" {
    run grep -E '^\s*❯ \./register\.js env reads:' "$VALIDATE_OUT"
    [ -z "$output" ] || [[ "$output" == *"env reads: nothing"* ]]
    run grep -E '^\s*❯ \./register\.js env writes:' "$VALIDATE_OUT"
    [ -z "$output" ] || [[ "$output" == *"env writes: nothing"* ]]
}

@test "source: no tool.*, prompt, session, turn, config or classic hook (call, check and describe are not registered)" {
    cd "$MOD_DIR/hooks"
    run grep -nE "on\(\s*'(tool\.|prompt\.|skill\.|command\.|session\.|turn\.|config\.|agent\.|classic\.|env\.)" register.js lib.js config.js
    [ "$status" -eq 1 ]
    run grep -nE "\bdeny\b|\bdrop\b|\bconsumed\b|\bdecision\b|\bprompt\.(submit|fill)|fs\.(read|write)|process\.(run|spawn)|http\.fetch|\\\$\.env|\\\$\.tool|\\\$\.state" register.js lib.js config.js
    [ "$status" -eq 1 ]
}

@test "source: Spinner, spinnerVerbs and ToolGroup are never named in code (comments may say we leave them alone)" {
    cd "$MOD_DIR/hooks"
    run bash -c "cat register.js lib.js config.js | grep -vE '^[[:space:]]*//' | grep -nE 'Spinner|spinnerVerbs|ToolGroup|ToolResult|ToolProgress'"
    [ "$status" -eq 1 ]
}

@test "source: plan A is shipped, and the switch and the names live only in config.js" {
    cd "$MOD_DIR/hooks"
    run grep -nE "^export const MODE = 'props'$" config.js
    [ "$status" -eq 0 ]
    run grep -nE "^export const NAMES = \{" config.js
    [ "$status" -eq 0 ]
    # no name table or mode literal outside config.js
    run bash -c "cat lib.js register.js | grep -vE '^[[:space:]]*//' | grep -nE '陣触れ|巻物拝見|遠国の技|MODE = '"
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

@test "gitignore: mods/toolrow sources are trackable, node_modules and test output are not" {
    cd "$REPO_ROOT"
    run git check-ignore -q mods/toolrow/hooks/register.js
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/toolrow/hooks/config.js
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/toolrow/.claude-plugin/plugin.json
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/toolrow/tests/toolrow.test.ts
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/toolrow/node_modules/x/index.js
    [ "$status" -eq 0 ]
    run git check-ignore -q mods/toolrow/test-results/out.xml
    [ "$status" -eq 0 ]
}
