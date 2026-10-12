#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-011: slim_reports retention behavior
# ═══════════════════════════════════════════════════════════════
# Verifies slim_yaml.py keeps unprocessed reports for active cmds,
# archives old reports for done cmds, and preserves canonical reports.
#
# ── ガード(cmd_225)の対象外である理由と、将来の約束 (cmd_229) ──
# tests/e2e の他の bats は tmux へキーを送るため、setup_file で e2e_require_disposable
# (tests/e2e/helpers/disposable_guard.bash) を呼び、scripts/run_e2e_isolated.sh が立てた
# 使い捨てサーバの中でしか走らぬ。このファイルは tmux を一切使わず(python3 で slim_yaml.py を
# 一時ディレクトリに対して走らせるだけ)、生きた陣へ届く経路が無いので、そのガードを呼ばず、
# 素の `bats tests/e2e/e2e_slim_retention.bats` でも走る。これは意図した例外である。
# ★ 将来ここで tmux を使い始めるなら、同じ変更で setup_file に e2e_require_disposable を足し、
#    他の tmux 系 e2e と同じく runner 経由に限らねばならぬ。足さずに tmux を書けば、
#    tests/unit/test_e2e_disposable_guard.bats の静的試験
#    (「static: the one e2e bats that never touches tmux ...」)が落ちる構造になっている。
#    その試験を緩めて通すな——ガードを載せよ。
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup_file() {
    resolve_project_root() {
        local c d abs git_root
        local -a candidates

        candidates=(
            "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
            "$BATS_TEST_DIRNAME"
            "$(dirname "$BATS_TEST_FILENAME")"
            "$BATS_TEST_FILENAME"
            "$PWD"
        )

        for c in "${candidates[@]}"; do
            [ -z "$c" ] && continue

            if [ -f "$c" ]; then
                c="$(dirname "$c")"
            fi

            for d in "$c" "$c/../.." "$c/../../.."; do
                if [ ! -d "$d" ] && [ -d "$PWD/$d" ]; then
                    d="$PWD/$d"
                fi

                abs="$(cd "$d" 2>/dev/null && pwd || true)"
                if [ -n "$abs" ] && [ -f "$abs/scripts/slim_yaml.py" ]; then
                    printf '%s\n' "$abs"
                    return 0
                fi
            done
        done

        git_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$git_root" ] && [ -f "$git_root/scripts/slim_yaml.py" ]; then
            printf '%s\n' "$git_root"
            return 0
        fi

        return 1
    }

    PROJECT_ROOT="$(resolve_project_root)" || skip "Unable to locate project root for slim retention test"
    export PROJECT_ROOT
    [ -f "$PROJECT_ROOT/scripts/slim_yaml.py" ] || skip "slim_yaml.py not found at $PROJECT_ROOT"
    command -v python3 &>/dev/null || skip "python3 not available"
}

# 作業dir の置場(cmd_230): runner 経由なら E2E_DISPOSABLE_DIR 配下(置場ごと消える)。
# 素の `bats` 実行(E2E_DISPOSABLE_DIR 未設定)では bats 自身の BATS_TEST_TMPDIR を使う
# (bats が試験の成否を問わず消す)。どちらでも /tmp へ自前のパスは作らぬ。
# 結果は SLIM_ROOT に入れる(teardown が失敗時にも消せるよう、サブシェルを使わぬ)。
make_work_root() {
    SLIM_ROOT=""
    if [ -n "${E2E_DISPOSABLE_DIR:-}" ]; then
        [ -d "$E2E_DISPOSABLE_DIR" ] || return 1
        mkdir -p "$E2E_DISPOSABLE_DIR/scratch" || return 1
        SLIM_ROOT="$(mktemp -d "$E2E_DISPOSABLE_DIR/scratch/slim_retention.XXXXXX")" || return 1
        SLIM_ROOT_OWNED=1
    else
        SLIM_ROOT="$BATS_TEST_TMPDIR/work"
        mkdir -p "$SLIM_ROOT" || return 1
        SLIM_ROOT_OWNED=0
    fi
}

# 成否を問わず(失敗した試験の後も)、自分が置場に作った作業dir を消す。
# 消すのは「E2E_DISPOSABLE_DIR/scratch の直下で slim_retention.* の名前」と確かめられた物だけ。
teardown() {
    if [ "${SLIM_ROOT_OWNED:-0}" = 1 ] && [ -n "${SLIM_ROOT:-}" ] && [ -n "${E2E_DISPOSABLE_DIR:-}" ]; then
        local parent real
        parent="$(cd "$E2E_DISPOSABLE_DIR/scratch" 2>/dev/null && pwd -P)" || return 0
        real="$(cd "$SLIM_ROOT" 2>/dev/null && pwd -P)" || return 0
        case "$real" in
            "$parent"/slim_retention.*) rm -rf -- "$real" ;;
        esac
    fi
    SLIM_ROOT=""
    SLIM_ROOT_OWNED=0
}

build_tmp_project() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/queue"/{inbox,tasks,reports,archive,reports,archive/reports}
}

run_slim_yaml() {
    local root="$1"
    local agent="$2"
    python3 "$root/scripts/slim_yaml.py" "$agent"
}

seed_yaml() {
    local file="$1" value="$2"
    printf '%s\n' "$value" > "$file"
}

@test "E2E-011-A: unprocessed report with active cmd is kept" {
    local root
    make_work_root || return 1
    root="$SLIM_ROOT"
    build_tmp_project "$root"
    cp "$PROJECT_ROOT/scripts/slim_yaml.py" "$root/scripts/"

    seed_yaml "$root/queue/shogun_to_karo.yaml" $'commands:\n  - id: cmd_test\n    status: pending\n'
    seed_yaml "$root/queue/reports/ashigaru1_cmd_test_report.yaml" $'parent_cmd: cmd_test\nstatus: done\n'
    seed_yaml "$root/queue/reports/ashigaru1_report.yaml" $'parent_cmd: cmd_ignored\nstatus: done\n'

    touch -d "2 days ago" "$root/queue/reports/ashigaru1_cmd_test_report.yaml"
    touch -d "2 days ago" "$root/queue/reports/ashigaru1_report.yaml"

    run run_slim_yaml "$root" karo
    assert_success

    # Active parent_cmd means this report is kept.
    [ -f "$root/queue/reports/ashigaru1_cmd_test_report.yaml" ]
    # Canonical report is always preserved.
    [ -f "$root/queue/reports/ashigaru1_report.yaml" ]
}

@test "E2E-011-B: old report for done cmd is archived" {
    local root
    make_work_root || return 1
    root="$SLIM_ROOT"
    build_tmp_project "$root"
    cp "$PROJECT_ROOT/scripts/slim_yaml.py" "$root/scripts/"

    seed_yaml "$root/queue/shogun_to_karo.yaml" $'commands:\n  - id: cmd_test\n    status: done\n'
    seed_yaml "$root/queue/reports/ashigaru1_cmd_test_report.yaml" $'parent_cmd: cmd_test\nstatus: done\n'
    seed_yaml "$root/queue/reports/ashigaru1_report.yaml" $'parent_cmd: cmd_ignored\nstatus: done\n'

    touch -d "2 days ago" "$root/queue/reports/ashigaru1_cmd_test_report.yaml"
    touch -d "2 days ago" "$root/queue/reports/ashigaru1_report.yaml"

    run run_slim_yaml "$root" karo
    assert_success

    # Non-canonical report is archived.
    [ ! -f "$root/queue/reports/ashigaru1_cmd_test_report.yaml" ]
    [ -f "$root/queue/archive/reports/ashigaru1_cmd_test_report.yaml" ]
    # Canonical report remains.
    [ -f "$root/queue/reports/ashigaru1_report.yaml" ]
}

@test "E2E-011-C: canonical report remains even if old and complete" {
    local root
    make_work_root || return 1
    root="$SLIM_ROOT"
    build_tmp_project "$root"
    cp "$PROJECT_ROOT/scripts/slim_yaml.py" "$root/scripts/"

    seed_yaml "$root/queue/shogun_to_karo.yaml" $'commands:\n  - id: cmd_test\n    status: done\n'
    seed_yaml "$root/queue/reports/ashigaru1_report.yaml" $'parent_cmd: cmd_done\nstatus: done\n'
    touch -d "2 days ago" "$root/queue/reports/ashigaru1_report.yaml"

    run run_slim_yaml "$root" karo
    assert_success

    # Canonical report is always retained.
    [ -f "$root/queue/reports/ashigaru1_report.yaml" ]
}
