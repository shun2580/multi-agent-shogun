#!/usr/bin/env bash
# check_flag_silent_off.sh — off|observe|enforce型flag機構のoff分岐が
# 「無言でexit/return」していないかを機械的に検査する(Fable裁定Q20(a)、
# cmd_161)。
#
# 「文書は沈黙して破られる」(Q20)への対抗策として、instructions追記では
# なくコードとして存在させる。既存のbats一括実行経路
# (bats tests/unit/*.bats)に組み込まれることで、実行し忘れても他目的で
# batsを回した瞬間に失敗が音を立てる(fail-loud)設計とする。
#
# 🔴運用注記: 新規flag機構が追加された場合は、下記 DEFAULT_TARGETS 配列
# へ1行追加すること。追加漏れ自体は人的規律に依存するが、追加さえ
# されれば以後は本スクリプトにより機械判定される。
#
# 使い方:
#   scripts/check_flag_silent_off.sh                # 既定4対象を検査
#   scripts/check_flag_silent_off.sh <file>[:<function>] ...  # 対象を指定
#
# 判定方法: 対象内でoff判定条件式( `[ "$MODE" = "off" ]` や
# `[ "$mode" != "observe" ] && [ "$mode" != "enforce" ]` 等、値が
# off/observe/enforceの文字列比較になっているif条件)を探し、その行から
# 直後10行以内にecho/printfによるログ出力が存在するかを検査する。
# 1件でも欠落していれば非0で終了し、欠落ファイル(:関数)名を列挙する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_TARGETS=(
    "scripts/pretooluse_yaml_guard.sh"
    "scripts/pretooluse_reversibility_check.sh"
    "scripts/pretooluse_git_push_block.sh"
    "scripts/inbox_watcher.sh:check_fleet_idle_notify"
)

if [ "$#" -gt 0 ]; then
    TARGETS=("$@")
else
    TARGETS=("${DEFAULT_TARGETS[@]}")
fi

# off分岐条件式のパターン(実測書式に基づく; cmd_161-A時点でgrepにより
# 確認した2種類を包含する)。observe/enforceの単体比較は対象外とする
# (それらはoff以外の分岐であり本検査の対象ではない):
#   1) [ "$MODE" = "off" ]  等の直接off比較
#   2) [ "$mode" != "observe" ] && [ "$mode" != "enforce" ] のように、
#      observeとenforceの両方を同一行で否定している(=実質off)否定合成
OFF_EQ_REGEX='\[[[:space:]]*"?\$[A-Za-z_][A-Za-z0-9_]*"?[[:space:]]*=[[:space:]]*"off"'
OFF_NEG_OBSERVE_REGEX='!=[[:space:]]*"observe"'
OFF_NEG_ENFORCE_REGEX='!=[[:space:]]*"enforce"'
LOG_REGEX='^[[:space:]]*(echo|printf)[[:space:]]'
LOOKAHEAD=10

is_off_condition_line() {
    local line="$1"
    if printf '%s' "$line" | grep -qE "$OFF_EQ_REGEX"; then
        return 0
    fi
    if printf '%s' "$line" | grep -qE "$OFF_NEG_OBSERVE_REGEX" && \
       printf '%s' "$line" | grep -qE "$OFF_NEG_ENFORCE_REGEX"; then
        return 0
    fi
    return 1
}

missing=()

# 指定した関数の本文のみをブレースの対応で抽出する(bash関数定義:
# `funcname() {` 〜 対応する `}`)
extract_function_body() {
    local file="$1" func="$2"
    awk -v fn="$func" '
        BEGIN { in_func = 0; depth = 0 }
        in_func == 0 && $0 ~ ("^" fn "\\(\\)[[:space:]]*\\{") {
            in_func = 1
        }
        in_func == 1 {
            print
            line = $0
            gsub(/[^{]/, "", line); depth += length(line)
            line = $0
            gsub(/[^}]/, "", line); depth -= length(line)
            if (depth <= 0) { exit }
        }
    ' "$file"
}

check_target() {
    local spec="$1" file func content label
    label="$spec"
    file="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
        func="${spec#*:}"
    else
        func=""
    fi

    if [ ! -f "$SCRIPT_DIR/$file" ]; then
        missing+=("$label (対象ファイルが存在しない)")
        return
    fi

    if [ -n "$func" ]; then
        content="$(extract_function_body "$SCRIPT_DIR/$file" "$func")"
        if [ -z "$content" ]; then
            missing+=("$label (関数 ${func}() が見つからない)")
            return
        fi
    else
        content="$(cat "$SCRIPT_DIR/$file")"
    fi

    local found_off_cond=0 found_log=0 lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        if is_off_condition_line "$line"; then
            found_off_cond=1
            local window
            window="$(printf '%s\n' "$content" | sed -n "$((lineno + 1)),$((lineno + LOOKAHEAD))p")"
            if printf '%s' "$window" | grep -qE "$LOG_REGEX"; then
                found_log=1
            fi
        fi
    done <<< "$content"

    if [ "$found_off_cond" -eq 0 ]; then
        missing+=("$label (off判定条件式が見つからない — 目視確認要)")
    elif [ "$found_log" -eq 0 ]; then
        missing+=("$label (off分岐直後${LOOKAHEAD}行以内にログ出力なし)")
    fi
}

for t in "${TARGETS[@]}"; do
    check_target "$t"
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "[check_flag_silent_off] FAIL: off時ログ欠落 ${#missing[@]}件"
    for m in "${missing[@]}"; do
        echo "  - $m"
    done
    exit 1
fi

echo "[check_flag_silent_off] PASS: 全${#TARGETS[@]}件でoff時ログ出力を確認"
exit 0
