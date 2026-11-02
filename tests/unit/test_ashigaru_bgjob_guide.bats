#!/usr/bin/env bats
# test_ashigaru_bgjob_guide.bats — cmd_252: 足軽の手引きの「裏の長い処理は終了時に自分宛て inbox で知らせる」明文化の試験
#
# 確かめること:
#   1. 手引きの生成元 instructions/ashigaru.md に明文化がある (終了通知・F004・例文)
#   2. 生成物 instructions/generated/opencode-ashigaru.md (生成元の本文をそのまま写す) に同じ記述がある
#   3. 例文が self-send REJECT を避ける形 (from=bgjob, type=info) である
#   4. 例文の形が実際に届く (使い捨ての inbox。本番の queue/inbox には書かない)
# SKIP は使用しない (SKIP=0)。

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SRC="$PROJECT_ROOT/instructions/ashigaru.md"
    GEN="$PROJECT_ROOT/instructions/generated/opencode-ashigaru.md"
    PY="$PROJECT_ROOT/.venv/bin/python3"
}

@test "guide-src: ashigaru.md tells to start long background jobs so that a completion inbox arrives" {
    grep -q "裏で動かす" "$SRC"
    grep -q "終了時に自分宛て" "$SRC"
}

@test "guide-src: ashigaru.md ties the rule to F004 (no polling => stalls until notified)" {
    grep -E "裏で動かす" -A8 "$SRC" | grep -q "F004"
}

@test "guide-src: ashigaru.md example uses from=bgjob and type=info" {
    grep -q 'inbox_write.sh ashigaru[0-9N]* "処理完了 exit=\$?" info bgjob' "$SRC"
}

@test "guide-src: ashigaru.md warns not to use report_received / own id as from" {
    grep -E "裏で動かす" -A12 "$SRC" | grep -q "report_received"
    grep -E "裏で動かす" -A12 "$SRC" | grep -q "self-send"
}

@test "guide-gen: opencode-ashigaru.md (generated from the source) carries the same guidance" {
    grep -q "終了時に自分宛て" "$GEN"
    grep -q 'inbox_write.sh ashigaru[0-9N]* "処理完了 exit=\$?" info bgjob' "$GEN"
}

@test "guide-gen: generated file is in sync with a fresh build of the source" {
    tmp="$(mktemp -d)"
    cp "$GEN" "$tmp/before.md"
    bash "$PROJECT_ROOT/scripts/build_instructions.sh" > /dev/null 2>&1 || true
    run diff "$tmp/before.md" "$GEN"
    rm -rf "$tmp"
    [ "$status" -eq 0 ]
}

@test "guide-example: the documented example form is delivered to a throwaway inbox (exit code carried)" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts" "$tmp/queue/inbox"
    cp "$PROJECT_ROOT/scripts/inbox_write.sh" "$tmp/scripts/"
    ln -s "$PROJECT_ROOT/.venv" "$tmp/.venv"
    cd "$tmp"
    # 手引きの例文の形をそのまま、エージェントの Bash ツールと同じ errexit 無しのシェルで実行する
    bash -c '( bash -c "exit 3" ; bash scripts/inbox_write.sh ashigaru4 "処理完了 exit=$?" info bgjob )'
    run "$PY" -c "
import yaml
m = yaml.safe_load(open('queue/inbox/ashigaru4.yaml'))['messages']
assert len(m) == 1, m
assert m[0]['from'] == 'bgjob' and m[0]['type'] == 'info' and m[0]['read'] is False, m[0]
assert m[0]['content'] == '処理完了 exit=3', m[0]
print('ok')
"
    cd "$PROJECT_ROOT"
    rm -rf "$tmp"
    [ "$status" -eq 0 ]
}

@test "guide-example: from=<self> is rejected as self-send (why the example must not use it)" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts" "$tmp/queue/inbox"
    cp "$PROJECT_ROOT/scripts/inbox_write.sh" "$tmp/scripts/"
    ln -s "$PROJECT_ROOT/.venv" "$tmp/.venv"
    cd "$tmp"
    run bash scripts/inbox_write.sh ashigaru4 "x" info ashigaru4
    cd "$PROJECT_ROOT"
    rm -rf "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"self-send"* ]]
}
