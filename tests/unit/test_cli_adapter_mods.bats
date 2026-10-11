#!/usr/bin/env bats
# test_cli_adapter_mods.bats — cmd_220: cli.agents.<名>.mods → --plugin-dir の配線試験
# 期待値(欄の無いエージェントの起動コマンド)は cmd_220 着手前の build_cli_command 出力を採取した固定値。

bats_require_minimum_version 1.5.0

setup() {
    unset PERMISSION_FLAG
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # 実運用 settings.yaml と同形(将軍のみ mods 宣言あり)
    cat > "${TEST_TMP}/settings_mods.yaml" << 'YAML'
cli:
  agents:
    karo:
      type: claude
      model: claude-sonnet-5-5
      effort: high
    gunshi:
      type: claude
      model: claude-sonnet-5-5
      effort: high
    ashigaru1: {type: claude, model: claude-sonnet-5-5, effort: high}
    ashigaru2: {type: claude, model: claude-sonnet-5-5, effort: high}
    ashigaru3: {type: claude, model: claude-sonnet-5-5, effort: high}
    ashigaru4: {type: claude, model: claude-sonnet-5-5, effort: high}
    ashigaru5: {type: claude, model: claude-sonnet-5-5, effort: high}
    ashigaru6: {type: claude, model: claude-haiku-4-5-20251001}
    ashigaru7: {type: claude, model: claude-haiku-4-5-20251001}
    shogun:
      type: claude
      model: claude-opus-5-5
      effort: high
      mods:
        - mods/status
  default: claude
YAML
    # 同じ設定から mods 欄だけ除いたもの
    grep -v -e '^      mods:' -e '^        - mods/status' "${TEST_TMP}/settings_mods.yaml" > "${TEST_TMP}/settings_nomods.yaml"

    # Mod ディレクトリ(プロジェクトルートは偽ルートを使わず、絶対パスで宣言して存在/不在を作り分ける)
    mkdir -p "${TEST_TMP}/modroot/mods/status/.claude-plugin"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# settings を指定して build_cli_command を実行(別プロセス=switch_cli.sh と同じ source 方式)
_build() {
    local settings="$1" agent="$2"
    CLI_ADAPTER_SETTINGS="$settings" bash -c "source '${PROJECT_ROOT}/lib/cli_adapter.sh'; build_cli_command '$agent'"
}

@test "mods: shogun の起動コマンドに --plugin-dir <mods/status の絶対パス> が入る" {
    # 実プロジェクトの mods/status の有無に依らないよう、絶対パス宣言で確かめる
    cat > "${TEST_TMP}/settings_abs.yaml" << YAML
cli:
  agents:
    shogun:
      type: claude
      model: claude-opus-5-5
      effort: high
      mods:
        - ${TEST_TMP}/modroot/mods/status
YAML
    run _build "${TEST_TMP}/settings_abs.yaml" shogun
    [ "$status" -eq 0 ]
    # cmd_224: Mod を読み込むエージェントには SHOGUN_AGENT_ID=<名> が前置される(それ以外は不変)
    [ "$output" = "SHOGUN_AGENT_ID=shogun claude --model claude-opus-5-5 --effort high --plugin-dir ${TEST_TMP}/modroot/mods/status --dangerously-skip-permissions" ]
}

@test "mods: 相対パス宣言はプロジェクトルート基準で絶対化される(起動 cwd に依らない)" {
    # 偽のプロジェクトルート(実プロジェクトの mods/ には触れない)
    mkdir -p "${TEST_TMP}/fakeroot/lib" "${TEST_TMP}/fakeroot/mods/status"
    cp "${PROJECT_ROOT}/lib/cli_adapter.sh" "${TEST_TMP}/fakeroot/lib/"
    ln -s "${PROJECT_ROOT}/.venv" "${TEST_TMP}/fakeroot/.venv"
    cd /
    run env CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings_mods.yaml" bash -c "source '${TEST_TMP}/fakeroot/lib/cli_adapter.sh'; build_cli_command shogun"
    cd "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "SHOGUN_AGENT_ID=shogun claude --model claude-opus-5-5 --effort high --plugin-dir ${TEST_TMP}/fakeroot/mods/status --dangerously-skip-permissions" ]
}

@test "mods: 欄の無い全エージェントの起動コマンドが着手前と完全一致する" {
    expected_sonnet="claude --model claude-sonnet-5-5 --effort high --dangerously-skip-permissions"
    expected_haiku="claude --model claude-haiku-4-5-20251001 --dangerously-skip-permissions"
    for a in karo gunshi ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5; do
        run _build "${TEST_TMP}/settings_mods.yaml" "$a"
        [ "$status" -eq 0 ]
        [ "$output" = "$expected_sonnet" ]
    done
    for a in ashigaru6 ashigaru7; do
        run _build "${TEST_TMP}/settings_mods.yaml" "$a"
        [ "$status" -eq 0 ]
        [ "$output" = "$expected_haiku" ]
    done
}

@test "mods: 欄の無い将軍の起動コマンドも着手前と完全一致する(mods 欄を消せば元に戻る)" {
    run _build "${TEST_TMP}/settings_nomods.yaml" shogun
    [ "$status" -eq 0 ]
    [ "$output" = "claude --model claude-opus-5-5 --effort high --dangerously-skip-permissions" ]
}

@test "mods: Mod ディレクトリ不在は stderr に警告し、起動コマンドは --plugin-dir 無しで返る" {
    cat > "${TEST_TMP}/settings_missing.yaml" << YAML
cli:
  agents:
    shogun:
      type: claude
      model: claude-opus-5-5
      effort: high
      mods:
        - ${TEST_TMP}/does/not/exist
YAML
    stdout=$(CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings_missing.yaml" bash -c "source '${PROJECT_ROOT}/lib/cli_adapter.sh'; build_cli_command shogun" 2>"${TEST_TMP}/err.txt")
    [ "$stdout" = "claude --model claude-opus-5-5 --effort high --dangerously-skip-permissions" ]
    grep -q "WARN: mod dir not found" "${TEST_TMP}/err.txt"
    grep -q "does/not/exist" "${TEST_TMP}/err.txt"
}

@test "mods: 複数宣言は宣言順に --plugin-dir を繰り返し、不在分だけ飛ばす" {
    mkdir -p "${TEST_TMP}/modroot/mods/second"
    cat > "${TEST_TMP}/settings_multi.yaml" << YAML
cli:
  agents:
    shogun:
      type: claude
      model: claude-opus-5-5
      mods:
        - ${TEST_TMP}/modroot/mods/status
        - ${TEST_TMP}/modroot/mods/gone
        - ${TEST_TMP}/modroot/mods/second
YAML
    run --separate-stderr _build "${TEST_TMP}/settings_multi.yaml" shogun
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"mods/gone"* ]]
    [[ "$output" == "SHOGUN_AGENT_ID=shogun claude --model claude-opus-5-5 --plugin-dir ${TEST_TMP}/modroot/mods/status --plugin-dir ${TEST_TMP}/modroot/mods/second --dangerously-skip-permissions" ]]
}

@test "mods: mods 欄が list でない/空/不正 YAML でも起動コマンドは変わらない" {
    for body in "mods: mods/status" "mods: []" "mods: {a: b}" "mods:"; do
        cat > "${TEST_TMP}/settings_bad.yaml" << YAML
cli:
  agents:
    shogun:
      type: claude
      model: claude-opus-5-5
      effort: high
      ${body}
YAML
        run _build "${TEST_TMP}/settings_bad.yaml" shogun
        [ "$status" -eq 0 ]
        [ "$output" = "claude --model claude-opus-5-5 --effort high --dangerously-skip-permissions" ]
    done
}

@test "mods: 非 claude CLI に mods 宣言があっても起動コマンドへ足さない" {
    cat > "${TEST_TMP}/settings_codex.yaml" << YAML
cli:
  agents:
    shogun:
      type: codex
      model: gpt-5.4
      mods:
        - ${TEST_TMP}/modroot/mods/status
YAML
    run _build "${TEST_TMP}/settings_codex.yaml" shogun
    [ "$status" -eq 0 ]
    [[ "$output" != *"--plugin-dir"* ]]
}

@test "mods: switch_cli.sh 経路(source して build_cli_command)でも --plugin-dir が外れない" {
    # switch_cli.sh は lib/cli_adapter.sh を source し、build_cli_command を呼ぶ(静的確認)
    grep -q 'source "${PROJECT_ROOT}/lib/cli_adapter.sh"' "${PROJECT_ROOT}/scripts/switch_cli.sh"
    grep -q 'build_cli_command "$AGENT_ID"' "${PROJECT_ROOT}/scripts/switch_cli.sh"
    # 出陣スクリプトも同じ関数で将軍の起動コマンドを組む
    grep -q 'lib/cli_adapter.sh' "${PROJECT_ROOT}/shutsujin_departure.sh"
    grep -q 'build_cli_command "shogun"' "${PROJECT_ROOT}/shutsujin_departure.sh"
    # 動的確認: switch_cli.sh と同じ手順(PROJECT_ROOT 設定→source→build)
    cat > "${TEST_TMP}/settings_abs2.yaml" << YAML
cli:
  agents:
    shogun:
      type: claude
      model: claude-opus-5-5
      effort: high
      mods:
        - ${TEST_TMP}/modroot/mods/status
YAML
    run bash -c "PROJECT_ROOT='${PROJECT_ROOT}'; export CLI_ADAPTER_SETTINGS='${TEST_TMP}/settings_abs2.yaml'; source \"\${PROJECT_ROOT}/lib/cli_adapter.sh\"; TARGET_CMD=\$(build_cli_command shogun); echo \"\$TARGET_CMD\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"--plugin-dir ${TEST_TMP}/modroot/mods/status"* ]]
}
