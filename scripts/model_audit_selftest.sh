#!/usr/bin/env bash
# model_audit_selftest.sh - scripts/model_audit.sh の試験(cmd_264 ■1)。
# 一致・不一致・記録なし・サブエージェント混在・別名表記の5ケース(+対応不明1ケース)を、
# mktemp -d の一時ディレクトリに作った jsonl で固定する。本物のセッション記録・audit ログには触れない。
# 使い方: bash scripts/model_audit_selftest.sh   (全件通れば終了コード 0)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SH="$SCRIPT_DIR/model_audit.sh"

WORK="$(mktemp -d)" || { echo "mktemp -d に失敗" >&2; exit 2; }
trap 'rm -rf -- "$WORK"' EXIT

PASS=0
FAIL=0

# 固定の時刻(audit の ts と、セッション jsonl の timestamp は 1 秒差 = 突き合わせ窓の内側)
AUDIT_TS="2026-11-01T10:00:00.000+09:00"
SESS_TS="2026-11-01T01:00:01.000Z"          # 上と同じ時刻(UTC 表記)
LAST_TS="2026-11-01T01:05:00.000Z"          # 最後の assistant+usage 記録

# mk_case <dir> <model_in_settings> <effort_in_settings> <model_in_session|""> <with_audit:1|0>
#   karo 1体だけの settings と、audit ログ・セッション jsonl を作る。
mk_case() {
  local dir="$1" exp_model="$2" exp_effort="$3" act_model="$4" with_audit="$5"
  mkdir -p "$dir/projects/p" "$dir/audit/2026-11"
  cat > "$dir/settings.yaml" <<EOF
cli:
  agents:
    karo:
      type: claude
      model: $exp_model
      effort: $exp_effort
EOF
  if [ "$with_audit" = "1" ]; then
    printf '%s\n' "{\"ts\":\"$AUDIT_TS\",\"agent\":\"karo\",\"event\":\"tool.call\",\"tool\":\"Read\",\"ok\":true,\"file_path\":\"/x/queue/tasks/karo.yaml\"}" \
      > "$dir/audit/2026-11/karo.jsonl"
  fi
  if [ -n "$act_model" ]; then
    {
      # tool_use(突き合わせ用。本文は含めない)
      printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$SESS_TS\",\"effort\":\"high\",\"message\":{\"model\":\"$act_model\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"/x/queue/tasks/karo.yaml\"}}],\"usage\":{\"output_tokens\":1}}}"
      # 最後の assistant+usage 記録
      printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$LAST_TS\",\"effort\":\"high\",\"message\":{\"model\":\"$act_model\",\"content\":[],\"usage\":{\"output_tokens\":2}}}"
    } > "$dir/projects/p/sess1.jsonl"
  fi
}

# run_case <name> <dir> <expected_exit> <stdout_grep|""> <stderr_grep|"">
run_case() {
  local name="$1" dir="$2" want_rc="$3" out_pat="$4" err_pat="$5"
  local out err rc ok=1
  out="$(bash "$AUDIT_SH" --settings "$dir/settings.yaml" --projects-dir "$dir/projects" \
        --audit-dir "$dir/audit" --days 100000 2>"$dir/stderr")"
  rc=$?
  err="$(cat "$dir/stderr")"
  [ "$rc" = "$want_rc" ] || { ok=0; echo "  ! 終了コード: 期待 $want_rc 実測 $rc"; }
  if [ -n "$out_pat" ] && ! printf '%s\n' "$out" | grep -q -- "$out_pat"; then
    ok=0; echo "  ! stdout に '$out_pat' が無い"
  fi
  if [ -n "$err_pat" ] && ! printf '%s\n' "$err" | grep -q -- "$err_pat"; then
    ok=0; echo "  ! stderr に '$err_pat' が無い"
  fi
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1)); echo "PASS: $name (exit $rc)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name"; printf '%s\n' "$out" | sed 's/^/    out: /'; printf '%s\n' "$err" | sed 's/^/    err: /'
  fi
}

# 1. 一致
mk_case "$WORK/c1" claude-opus-5-5 high claude-opus-5-5 1
run_case "1 一致" "$WORK/c1" 0 "全員一致" ""

# 2. 不一致(設定は opus、実測は sonnet)→ 1、該当行を stderr に
mk_case "$WORK/c2" claude-opus-5-5 high claude-sonnet-5-5 1
run_case "2 不一致" "$WORK/c2" 1 "不一致 1 件" "MISMATCH karo"

# 3. 記録なし(audit ログが無い)→ 3、人数を出す
mk_case "$WORK/c3" claude-opus-5-5 high "" 0
run_case "3 記録なし" "$WORK/c3" 3 "判定できぬ者 1 人" ""

# 4. サブエージェント混在(親は一致・subagents/ は haiku)→ 親の判定は 0、sub は別行
mk_case "$WORK/c4" claude-opus-5-5 high claude-opus-5-5 1
mkdir -p "$WORK/c4/projects/p/sess1/subagents"
printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$LAST_TS\",\"message\":{\"model\":\"claude-haiku-4-5-20251001\",\"content\":[],\"usage\":{\"output_tokens\":3}}}" \
  > "$WORK/c4/projects/p/sess1/subagents/agent-a1.jsonl"
run_case "4 サブエージェント混在" "$WORK/c4" 0 "karo/sub:agent-a1.jsonl .*claude-haiku-4-5-20251001" ""
# 親の行に haiku が混ざっていないこと(親の行は opus のまま)
if bash "$AUDIT_SH" --settings "$WORK/c4/settings.yaml" --projects-dir "$WORK/c4/projects" \
     --audit-dir "$WORK/c4/audit" --days 100000 2>/dev/null | grep '^karo ' | grep -q 'claude-opus-5-5.*一致'; then
  PASS=$((PASS + 1)); echo "PASS: 4b 親の行は opus のまま(sub を混ぜない)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 4b 親の行に sub が混ざった疑い"
fi

# 5. 別名表記(設定は正式ID、記録は 'opus')→ 揃えて一致
mk_case "$WORK/c5" claude-opus-5-5 high opus 1
run_case "5 別名表記" "$WORK/c5" 0 "全員一致" ""

# 6. 対応表に無い名前 → 対応不明(一致にも不一致にも数えず)→ 3
mk_case "$WORK/c6" claude-opus-5-5 high mystery-model-9 1
run_case "6 対応不明" "$WORK/c6" 3 "対応不明" ""

echo "---"
echo "結果: PASS=$PASS FAIL=$FAIL SKIP=0"
[ "$FAIL" = "0" ] || exit 1
exit 0
