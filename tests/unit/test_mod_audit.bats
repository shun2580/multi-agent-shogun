#!/usr/bin/env bats
# test_mod_audit.bats — cmd_224 / subtask_224_A
# The audit-log Mod (mods/audit, loaded by all 10 agents) must stay observe-only and must never write a secret.
# These tests pin that from outside:
#   - the events it handles and the mods-API calls it makes (what `claude plugin validate` lists)
#   - its own unit tests (`claude plugin test`: no secret written, name handling, write failure, pass-through)
#   - the source: no deny/answer/rewrite, no draw, only mkdir and tee are ever started
#   - the log directory is untracked, and the mod's sources are trackable
# A missing `claude` is a FAIL, not a skip (Test Rules: SKIP = FAIL).

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export MOD_DIR="$REPO_ROOT/mods/audit"
    command -v claude >/dev/null 2>&1 || { echo "claude CLI is required" >&2; return 1; }
    # validate output is read by several tests; compute it once
    export VALIDATE_OUT="$BATS_FILE_TMPDIR/validate.txt"
    claude plugin validate "$MOD_DIR" >"$VALIDATE_OUT" 2>&1 || true
}

@test "validate: the Mod passes claude plugin validate" {
    run grep -F "Validation passed" "$VALIDATE_OUT"
    [ "$status" -eq 0 ]
}

@test "validate: handles only tool.call, turn.start and turn.complete (no prompt.*, no ui.render, no tool.check)" {
    hooks="$(grep -E '^\s*❯ \./register\.js hooks:' "$VALIDATE_OUT" | sed 's/.*hooks: //')"
    [ "$hooks" = "tool.call, turn.start, turn.complete" ]
}

@test "validate: makes only env.get, process.run and ui.log (no fs.write, http, prompt, tool, session, store)" {
    calls="$(grep -E '^\s*❯ \./register\.js calls:' "$VALIDATE_OUT" | sed 's/.*calls: //; s/ (via [^)]*)//g')"
    [ -n "$calls" ]
    allowed=' $.env.get $.process.run $.ui.log '
    IFS=',' read -ra items <<<"$calls"
    for c in "${items[@]}"; do
        c="$(echo "$c" | tr -d ' ')"
        [[ "$allowed" == *" $c "* ]] || { echo "unexpected call: $c"; false; }
    done
}

@test "validate: reads only SHOGUN_AGENT_ID and SHOGUN_AUDIT_ROOT and writes no environment variable" {
    run grep -E '^\s*❯ \./register\.js env reads:' "$VALIDATE_OUT"
    [ "$(echo "$output" | sed 's/.*env reads: //')" = "SHOGUN_AGENT_ID, SHOGUN_AUDIT_ROOT" ]
    run grep -E '^\s*❯ \./register\.js env writes:' "$VALIDATE_OUT"
    [[ "$output" == *"env writes: nothing"* ]]
}

@test "source: no hook that could answer, rewrite or draw; no prompt/skill/command/session hook" {
    cd "$MOD_DIR/hooks"
    # comments are not code: they say what the mod does NOT do
    code="$(sed 's#//.*##' register.js lib.js)"
    run grep -nE "on\(\s*'(tool\.check|prompt\.|skill\.|command\.|session\.|ui\.|model\.|config\.|agent\.|classic\.)" <<<"$code"
    [ "$status" -eq 1 ]
    run grep -nE "\bdrop\b|\bconsumed\b|\bdecision\b|\bprompt\.(submit|fill)|fs\.write|process\.spawn|http\.fetch|ui\.render|ui\.ask" <<<"$code"
    [ "$status" -eq 1 ]
}

@test "source: a tool.call result is only ever returned as it came (no deny in the mod)" {
    cd "$MOD_DIR/hooks"
    # 'deny' is read from a result (typeof result.deny) but never produced
    run grep -nE "\{\s*deny\s*:|deny\s*:" register.js lib.js
    [ "$status" -eq 1 ]
}

@test "source: the only processes the Mod starts are mkdir and tee" {
    cd "$MOD_DIR/hooks"
    run grep -noE "runOk\(\\\$, \[[^]]*\]" register.js
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    [[ "$output" == *"'mkdir'"* ]]
    [[ "$output" == *"'tee'"* ]]
    run grep -c "process\.run" register.js
    [ "$output" -eq 1 ]
}

@test "plugin test: the Mod's own tests pass with 0 fail" {
    cd "$MOD_DIR"
    run claude plugin test
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *" 0 fail"* ]]
    [[ "$output" =~ ([1-9][0-9]*)\ pass ]]
}

@test "gitignore: logs/audit output is untracked; the Mod's sources are trackable" {
    cd "$REPO_ROOT"
    run git check-ignore -q logs/audit/2026-10/shogun.jsonl
    [ "$status" -eq 0 ]
    run git check-ignore -q logs/audit/2026-10/_unknown.jsonl
    [ "$status" -eq 0 ]
    run git check-ignore -q mods/audit/hooks/register.js
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/audit/.claude-plugin/plugin.json
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/audit/tests/audit.test.ts
    [ "$status" -eq 1 ]
    run git check-ignore -q mods/audit/node_modules/x/index.js
    [ "$status" -eq 0 ]
}

@test "no instruction file tells an agent to read the audit log" {
    cd "$REPO_ROOT"
    run grep -rlE "logs/audit" CLAUDE.md instructions .claude/skills 2>/dev/null
    [ "$status" -eq 1 ]
}
