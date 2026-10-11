#!/usr/bin/env bats
# test_cli_adapter_audit.bats — cmd_224: 全10体への mods/audit 宣言と SHOGUN_AGENT_ID の受け渡し試験
# 実プロジェクトの mods/ の有無に依らぬよう、偽のプロジェクトルート(mods/audit・mods/status を持つ)で確かめる。

bats_require_minimum_version 1.5.0

ROSTER="shogun karo gunshi ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7"

setup() {
    unset PERMISSION_FLAG
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # 偽ルート: lib/cli_adapter.sh と .venv を借り、mods/audit・mods/status を実在させる
    FAKE="${TEST_TMP}/fakeroot"
    mkdir -p "${FAKE}/lib" "${FAKE}/mods/audit" "${FAKE}/mods/status"
    cp "${PROJECT_ROOT}/lib/cli_adapter.sh" "${FAKE}/lib/"
    ln -s "${PROJECT_ROOT}/.venv" "${FAKE}/.venv"

    # 全10体宣言あり(将軍は status と audit の2本、他9体は audit のみ)
    cat > "${TEST_TMP}/settings_audit.yaml" << 'YAML'
cli:
  agents:
    karo: {type: claude, model: claude-sonnet-5-5, effort: high, mods: [mods/audit]}
    gunshi: {type: claude, model: claude-sonnet-5-5, effort: high, mods: [mods/audit]}
    ashigaru1: {type: claude, model: claude-sonnet-5-5, effort: high, mods: [mods/audit]}
    ashigaru2: {type: claude, model: claude-sonnet-5-5, effort: high, mods: [mods/audit]}
    ashigaru3: {type: claude, model: claude-sonnet-5-5, effort: high, mods: [mods/audit]}
    ashigaru4: {type: claude, model: claude-sonnet-5-5, effort: high, mods: [mods/audit]}
    ashigaru5: {type: claude, model: claude-sonnet-5-5, effort: high, mods: [mods/audit]}
    ashigaru6: {type: claude, model: claude-haiku-4-5-20251001, mods: [mods/audit]}
    ashigaru7: {type: claude, model: claude-haiku-4-5-20251001, mods: [mods/audit]}
    shogun: {type: claude, model: claude-opus-5-5, effort: high, mods: [mods/status, mods/audit]}
  default: claude
YAML
    # 同じ設定から mods 欄だけ除いたもの(宣言前の姿)
    sed -E 's/, mods: \[[^]]*\]//' "${TEST_TMP}/settings_audit.yaml" > "${TEST_TMP}/settings_nomods.yaml"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# 偽ルートの cli_adapter.sh を source して build_cli_command(switch_cli.sh と同じ source 方式)
_build() {
    local settings="$1" agent="$2"
    CLI_ADAPTER_SETTINGS="$settings" bash -c "source '${FAKE}/lib/cli_adapter.sh'; build_cli_command '$agent'"
}

@test "audit: 全10体の起動コマンドに --plugin-dir <mods/audit> と SHOGUN_AGENT_ID=<自分の名> が入る" {
    for a in $ROSTER; do
        run _build "${TEST_TMP}/settings_audit.yaml" "$a"
        [ "$status" -eq 0 ]
        [[ "$output" == "SHOGUN_AGENT_ID=${a} claude "* ]]
        [[ "$output" == *"--plugin-dir ${FAKE}/mods/audit"* ]]
        # 他の者の名は混ざらない
        [ "$(grep -o 'SHOGUN_AGENT_ID=' <<<"$output" | wc -l)" -eq 1 ]
    done
}

@test "audit: 将軍は mods/status と mods/audit の2本、他9体は mods/audit の1本だけ" {
    run _build "${TEST_TMP}/settings_audit.yaml" shogun
    [ "$output" = "SHOGUN_AGENT_ID=shogun claude --model claude-opus-5-5 --effort high --plugin-dir ${FAKE}/mods/status --plugin-dir ${FAKE}/mods/audit --dangerously-skip-permissions" ]
    for a in karo gunshi ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7; do
        run _build "${TEST_TMP}/settings_audit.yaml" "$a"
        [ "$(grep -o -e '--plugin-dir' <<<"$output" | wc -l)" -eq 1 ]
        [[ "$output" != *"mods/status"* ]]
    done
}

@test "audit: 宣言の無いエージェントの起動コマンドは変更前と完全一致(SHOGUN_AGENT_ID も足さない)" {
    expected_sonnet="claude --model claude-sonnet-5-5 --effort high --dangerously-skip-permissions"
    expected_haiku="claude --model claude-haiku-4-5-20251001 --dangerously-skip-permissions"
    expected_opus="claude --model claude-opus-5-5 --effort high --dangerously-skip-permissions"
    for a in karo gunshi ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5; do
        run _build "${TEST_TMP}/settings_nomods.yaml" "$a"
        [ "$output" = "$expected_sonnet" ]
    done
    for a in ashigaru6 ashigaru7; do
        run _build "${TEST_TMP}/settings_nomods.yaml" "$a"
        [ "$output" = "$expected_haiku" ]
    done
    run _build "${TEST_TMP}/settings_nomods.yaml" shogun
    [ "$output" = "$expected_opus" ]
}

@test "audit: 宣言を足しても他の部分(model・effort・フラグ)は不変 — 差分は SHOGUN_AGENT_ID と --plugin-dir だけ" {
    for a in $ROSTER; do
        run _build "${TEST_TMP}/settings_nomods.yaml" "$a"
        before="$output"
        run _build "${TEST_TMP}/settings_audit.yaml" "$a"
        after="$output"
        # 宣言後から mods 由来の2種を取り除くと、宣言前と完全一致する
        stripped="${after#SHOGUN_AGENT_ID=${a} }"
        stripped="${stripped// --plugin-dir ${FAKE}\/mods\/status/}"
        stripped="${stripped// --plugin-dir ${FAKE}\/mods\/audit/}"
        [ "$stripped" = "$before" ]
    done
}

@test "audit: thinking:false の MAX_THINKING_TOKENS=0 前置と SHOGUN_AGENT_ID が両立する" {
    cat > "${TEST_TMP}/settings_think.yaml" << 'YAML'
cli:
  agents:
    shogun: {type: claude, model: claude-opus-5-5, effort: high, thinking: false, mods: [mods/audit]}
  default: claude
YAML
    run _build "${TEST_TMP}/settings_think.yaml" shogun
    [ "$status" -eq 0 ]
    [ "$output" = "MAX_THINKING_TOKENS=0 SHOGUN_AGENT_ID=shogun claude --model claude-opus-5-5 --effort high --plugin-dir ${FAKE}/mods/audit --dangerously-skip-permissions" ]
}

@test "audit: 名簿外の agent_id には SHOGUN_AGENT_ID を前置せず stderr に警告する" {
    for bad in ashigaru8 ashigaru0 ashigaru10 Shogun 'x y' karo2; do
        cat > "${TEST_TMP}/settings_bad.yaml" << YAML
cli:
  agents:
    "${bad}": {type: claude, model: claude-sonnet-5-5, mods: [mods/audit]}
  default: claude
YAML
        run --separate-stderr _build "${TEST_TMP}/settings_bad.yaml" "$bad"
        [ "$status" -eq 0 ]
        [[ "$output" != *"SHOGUN_AGENT_ID"* ]]
        [[ "$output" == "claude --model claude-sonnet-5-5 --plugin-dir ${FAKE}/mods/audit --dangerously-skip-permissions" ]]
        [[ "$stderr" == *"WARN: agent_id not in roster"* ]]
    done
}

@test "audit: Mod ディレクトリが不在で1本も読み込まぬときは SHOGUN_AGENT_ID も足さない" {
    cat > "${TEST_TMP}/settings_gone.yaml" << YAML
cli:
  agents:
    karo: {type: claude, model: claude-sonnet-5-5, effort: high, mods: [mods/gone]}
  default: claude
YAML
    run --separate-stderr _build "${TEST_TMP}/settings_gone.yaml" karo
    [ "$output" = "claude --model claude-sonnet-5-5 --effort high --dangerously-skip-permissions" ]
    [[ "$stderr" == *"mod dir not found"* ]]
}

@test "audit: 非 claude CLI には SHOGUN_AGENT_ID を足さない" {
    cat > "${TEST_TMP}/settings_codex.yaml" << YAML
cli:
  agents:
    karo: {type: codex, model: gpt-5.4, mods: [mods/audit]}
  default: claude
YAML
    run _build "${TEST_TMP}/settings_codex.yaml" karo
    [[ "$output" != *"SHOGUN_AGENT_ID"* ]]
    [[ "$output" != *"--plugin-dir"* ]]
}

@test "audit: switch_cli.sh 経路(PROJECT_ROOT 設定→source→build_cli_command→send-keys)でも前置が外れない" {
    # 静的確認: switch_cli.sh・出陣スクリプトとも build_cli_command の戻り値をそのまま send-keys でシェルへ送る
    grep -q 'TARGET_CMD=$(build_cli_command "$AGENT_ID")' "${PROJECT_ROOT}/scripts/switch_cli.sh"
    grep -q 'tmux send-keys -t "$PANE_TARGET" "$TARGET_CMD"' "${PROJECT_ROOT}/scripts/switch_cli.sh"
    grep -q 'tmux send-keys -t shogun:main "$_shogun_cmd"' "${PROJECT_ROOT}/shutsujin_departure.sh"
    grep -q 'tmux send-keys -t "multiagent:agents.${p}" "$_karo_cmd"' "${PROJECT_ROOT}/shutsujin_departure.sh"
    # 動的確認: switch_cli.sh と同じ手順で組み、実際にシェルが環境変数として解釈することまで確かめる
    run bash -c "PROJECT_ROOT='${FAKE}'; export CLI_ADAPTER_SETTINGS='${TEST_TMP}/settings_audit.yaml'; source \"\${PROJECT_ROOT}/lib/cli_adapter.sh\"; TARGET_CMD=\$(build_cli_command ashigaru3); echo \"\$TARGET_CMD\""
    [ "$status" -eq 0 ]
    [[ "$output" == "SHOGUN_AGENT_ID=ashigaru3 claude "* ]]
    # claude を関数に差し替え、前置がシェルで環境変数として働くこと(送られた文字列をそのまま解釈)を確認
    cmd="$output"
    run bash -c "claude() { echo \"seen=\$SHOGUN_AGENT_ID\"; }; $cmd"
    [ "$output" = "seen=ashigaru3" ]
}
