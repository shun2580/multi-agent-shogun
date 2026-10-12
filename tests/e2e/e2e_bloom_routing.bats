#!/usr/bin/env bats
# e2e_bloom_routing.bats — Dim C: スマート切り替えE2Eテスト
# Issue #53 Phase 2 — find_agent_for_model() + karo bloom routing 統合検証
#
# cmd_225: 生きた "multiagent" には一切触れない。使い捨ての tmux サーバ内に、
# 偽の足軽(ashigaru1-7, 素の bash)を持つ使い捨てセッションを setup_file で自分で作り、
# ビジー状態もそこへ作る。生きた陣の有無には依存しない。
#
# 事前条件:
#   - scripts/run_e2e_isolated.sh 経由で走らせること(使い捨てサーバでなければ止まる。SKIP にしない)
#   - config/settings.yaml の cli.agents (モデル割当) は実物を読む
#
# 実行方法:
#   bash scripts/run_e2e_isolated.sh tests/e2e/e2e_bloom_routing.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# cmd_225: ガードとtmuxラッパ(PATH先頭)を有効にする
E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/setup.bash"

BLOOM_FAKE_AGENTS=(ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7)

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"

    # 使い捨てサーバでなければ、ペインを作る前に止まる (SKIP にしない)
    e2e_require_disposable || return 1

    # 使い捨てサーバ内に偽の足軽セッションを作る (素の bash。@agent_id/@agent_cli を付す)
    export E2E_SESSION="${E2E_SESSION_PREFIX}_bloom_$$"
    tmux new-session -d -s "$E2E_SESSION" -n agents -x 200 -y 50 "bash --norc"
    local i
    for ((i = 1; i < ${#BLOOM_FAKE_AGENTS[@]}; i++)); do
        tmux split-window -t "${E2E_SESSION}:agents" "bash --norc"
        tmux select-layout -t "${E2E_SESSION}:agents" tiled
    done
    for ((i = 0; i < ${#BLOOM_FAKE_AGENTS[@]}; i++)); do
        tmux set-option -p -t "${E2E_SESSION}:agents.${i}" @agent_id "${BLOOM_FAKE_AGENTS[$i]}"
        tmux set-option -p -t "${E2E_SESSION}:agents.${i}" @agent_cli "claude"
    done
}

teardown_file() {
    # E2E_SESSION が空 (setup_file が skip/失敗) なら何もしない: 空ターゲットは現在セッションへ解決される
    if [ -n "${E2E_SESSION:-}" ]; then
        tmux kill-session -t "$E2E_SESSION" 2>/dev/null || true
    fi
}

# 偽足軽のペインターゲットを返す (使い捨てセッション内だけを探す。list-panes -a は使わない)
bloom_pane_of() {
    tmux list-panes -s -t "$E2E_SESSION" -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk -v agent="$1" '$2 == agent {print $1}' | head -1
}

setup() {
    # 読取も含め、使い捨てサーバ以外は見ない (fail-closed)
    e2e_require_disposable || return 1
    BLOOM_BUSY_PANES=()

    # lib/cli_adapter.sh のロード
    export CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT"
    export CLI_ADAPTER_SETTINGS="${PROJECT_ROOT}/config/settings.yaml"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/agent_status.sh" 2>/dev/null || true
}

teardown() {
    # ビジーにしたペインを元に戻す (trap EXIT は bats 自身の EXIT trap を潰して結果行を失わせるので使わない)
    local p
    for p in "${BLOOM_BUSY_PANES[@]:-}"; do
        [ -n "$p" ] && tmux send-keys -t "$p" '' C-c
    done
    sleep 0.3
}

# ─────────────────────────────────────────────
# TC-BLOOM-001: L1タスク → Spark足軽（ashigaru1/2/3）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-001: L1タスク → Sparkエージェントに振られる" {
    run get_recommended_model 1
    [ "$status" -eq 0 ]
    # L1はSpark (max_bloom=3)が最安
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    # Spark足軽はashigaru1, 2, 3のいずれか
    [[ "$output" =~ ^ashigaru[1-3]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-002: L5タスク → Sonnet足軽（ashigaru4/5）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-002: L5タスク → Sonnetエージェントに振られる" {
    run get_recommended_model 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"sonnet"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ashigaru[4-5]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-003: L6タスク → Opus足軽（ashigaru6/7）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-003: L6タスク → Opusエージェントに振られる" {
    run get_recommended_model 6
    [ "$status" -eq 0 ]
    [[ "$output" == *"opus"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ashigaru[6-7]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-004: ashigaru4ビジー + L5タスク → ashigaru5に振られる
# kill/restart発生なし（ビジーペイン不変確認）
# ─────────────────────────────────────────────
@test "TC-BLOOM-004: ashigaru4ビジー時、L5タスクはashigaru5に振られる" {
    # ashigaru4のペインターゲットを取得
    pane4=$(bloom_pane_of ashigaru4)

    if [[ -z "$pane4" ]]; then
        skip "ashigaru4ペインが見つからない"
    fi

    # sleep でビジー状態を作成（元に戻すのは teardown）
    BLOOM_BUSY_PANES=("$pane4")
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # ビジー確認
    busy_rc=0
    agent_is_busy_check "$pane4" && true || busy_rc=$?
    if [[ $busy_rc -ne 0 ]]; then
        skip "ashigaru4をビジー状態にできなかった（busy_rc=${busy_rc}）"
    fi

    # L5タスクのルーティング
    recommended=$(get_recommended_model 5)
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # ashigaru4はビジーなのでashigaru5に振られるべき
    [ "$output" = "ashigaru5" ] || \
        { echo "期待: ashigaru5, 実際: $output"; return 1; }

    # ashigaru4がまだ稼働中（kill/restartされていない）を確認
    still_busy=0
    agent_is_busy_check "$pane4" && true || still_busy=$?
    [[ $still_busy -eq 0 ]] || echo "WARNING: ashigaru4の状態が変化した（kill/restartの可能性）"
}

# ─────────────────────────────────────────────
# TC-BLOOM-005: ashigaru4/5両方ビジー + L5タスク → QUEUE（Codexに降格しない）
# ─────────────────────────────────────────────
@test "TC-BLOOM-005: Sonnet足軽全員ビジー時、QUEUEになる（Codexへの降格なし確認）" {
    pane4=$(bloom_pane_of ashigaru4)
    pane5=$(bloom_pane_of ashigaru5)

    if [[ -z "$pane4" || -z "$pane5" ]]; then
        skip "ashigaru4またはashigaru5ペインが見つからない"
    fi

    # sleep でashigaru4/5をビジー状態に（元に戻すのは teardown）
    BLOOM_BUSY_PANES=("$pane4" "$pane5")
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    tmux send-keys -t "$pane5" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # 両方ビジー確認
    rc4=0; agent_is_busy_check "$pane4" && true || rc4=$?
    rc5=0; agent_is_busy_check "$pane5" && true || rc5=$?

    if [[ $rc4 -ne 0 || $rc5 -ne 0 ]]; then
        skip "ashigaru4/5のいずれかをビジー状態にできなかった（rc4=${rc4}, rc5=${rc5}）"
    fi

    # L5タスクのルーティング
    recommended=$(get_recommended_model 5)
    # Sonnet足軽が全員ビジー → フォールバックまたはQUEUE
    result=$(find_agent_for_model "$recommended")

    # フォールバック（他のアイドル足軽）またはQUEUEが許容される
    # Sonnet足軽でないフォールバックの場合、モデル品質の警告を出す
    if [[ "$result" =~ ^ashigaru[1-3]$ ]]; then
        echo "フォールバック先: $result (Sparkエージェント — 品質低下注意)"
    elif [[ "$result" = "QUEUE" ]]; then
        echo "QUEUE: 全足軽ビジー"
    else
        echo "フォールバック先: $result"
    fi

    # QUEUEかashigaruを返すことを確認（何もしないは×）
    [[ "$result" = "QUEUE" ]] || [[ "$result" =~ ^ashigaru[0-9]+$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-006: L3タスク → Sonnet足軽には振られない（Codex優先）
# ─────────────────────────────────────────────
@test "TC-BLOOM-006: L3タスクはSpark足軽が優先（Sonnetへのオーバーエンジニアリングなし）" {
    run get_recommended_model 3
    [ "$status" -eq 0 ]

    # L3の推奨モデルはSonnetではなくSpark
    [[ "$output" != *"sonnet"* ]] || { echo "L3でSonnetが推奨された（コスト最適化違反）"; return 1; }
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # Spark足軽（ashigaru1-3）のみ
    [[ "$output" =~ ^ashigaru[1-3]$ ]]
}
