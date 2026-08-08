#!/usr/bin/env bats
# test_flag_silent_off.bats — cmd_161-A: flag機構off時1行ログの機械検査
#
# Fable裁定Q20(a)「off|observe|enforce型flag機構のoff分岐は無言でexit
# してはならない」を、instructions追記ではなくコードで検査する
# scripts/check_flag_silent_off.sh の緑テスト。
#
# 既存の「bats tests/unit/*.bats を回す」定着済み検証慣行に組み込む
# ことで、実行し忘れても他目的でbatsを回した瞬間に失敗が音を立てる
# (fail-loud)設計とする。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/scripts/check_flag_silent_off.sh"

setup_file() {
    [ -f "$CHECK_SCRIPT" ] || return 1
}

@test "check_flag_silent_off: 既定4対象すべてでoff時ログ出力を確認できる" {
    run bash "$CHECK_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}
