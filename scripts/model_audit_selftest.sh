#!/usr/bin/env bash
# model_audit_selftest.sh - scripts/model_audit.sh の試験(cmd_264 ■1)。
# 一致・不一致・記録なし・サブエージェント混在・別名表記の5ケース(+対応不明1ケース)と、
# 対応づけの5ケース(他人への偶然の1件一致で取り違えぬ・同数1位は対応取れず・同数で取りこぼした新しい方があれば対応取れず・
# 本人の一致0で他人の偶然の1件一致は他人に帰属させぬ・一致1件だけ(下限2件未満)は対応取れず・
# --days の窓の外の古い audit 記録は数えぬ(窓の内なら数える)・窓の内の全件で突き合わせる(直近40件で切らぬ))を、
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
    # 帰属には一致 2 件以上が要る(MIN_MATCHES)ゆえ 2 件
    printf '%s\n' "{\"ts\":\"$AUDIT_TS\",\"agent\":\"karo\",\"event\":\"tool.call\",\"tool\":\"Read\",\"ok\":true,\"file_path\":\"/x/queue/tasks/karo.yaml\"}" \
      > "$dir/audit/2026-11/karo.jsonl"
    printf '%s\n' "{\"ts\":\"$AUDIT_TS\",\"agent\":\"karo\",\"event\":\"tool.call\",\"tool\":\"Read\",\"ok\":true,\"file_path\":\"/x/queue/tasks/karo2.yaml\"}" \
      >> "$dir/audit/2026-11/karo.jsonl"
  fi
  if [ -n "$act_model" ]; then
    {
      # tool_use(突き合わせ用。本文は含めない)
      printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$SESS_TS\",\"effort\":\"high\",\"message\":{\"model\":\"$act_model\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"/x/queue/tasks/karo.yaml\"}},{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"/x/queue/tasks/karo2.yaml\"}}],\"usage\":{\"output_tokens\":1}}}"
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

# --- 対応づけ(セッションを一致数が最多のエージェントに帰属させる)の試験: karo と gunshi の2体 ---
# mk2 <dir>: 2体とも settings は opus/high。audit・セッションは後から追記する。
mk2() {
  local dir="$1"
  mkdir -p "$dir/projects/p" "$dir/audit/2026-11"
  cat > "$dir/settings.yaml" <<EOF
cli:
  agents:
    karo:
      type: claude
      model: claude-opus-5-5
      effort: high
    gunshi:
      type: claude
      model: claude-opus-5-5
      effort: high
EOF
}
# aud <dir> <agent> <ts(Z)> <file>: audit に Read の tool.call を1行足す
aud() {
  printf '%s\n' "{\"ts\":\"$3\",\"agent\":\"$2\",\"event\":\"tool.call\",\"tool\":\"Read\",\"ok\":true,\"file_path\":\"$4\"}" >> "$1/audit/2026-11/$2.jsonl"
}
# tu <jsonl> <model> <ts(Z)> <file>: セッションに Read の tool_use を1行足す(本文なし)
tu() {
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$3\",\"effort\":\"high\",\"message\":{\"model\":\"$2\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"$4\"}}],\"usage\":{\"output_tokens\":1}}}" >> "$1"
}
# ev <jsonl> <model> <ts(Z)>: 最後の assistant+usage 記録
ev() {
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$3\",\"effort\":\"high\",\"message\":{\"model\":\"$2\",\"content\":[],\"usage\":{\"output_tokens\":2}}}" >> "$1"
}
# audit_out <dir>: 表(stdout)だけを返す
audit_out() {
  bash "$AUDIT_SH" --settings "$1/settings.yaml" --projects-dir "$1/projects" --audit-dir "$1/audit" --days 100000 2>/dev/null
}

# 7. 他人のセッションに1件だけ偶然一致しても取り違えぬ(同じモデル同士)
#    karo の本当のセッション(k1〜k3 に一致3・実測 sonnet=不一致のはず)は古い。
#    gunshi のセッション(g1〜g3 に一致3・opus)は新しく、karo の audit の1件(k1)にも偶然一致する。
#    取り違えれば karo に gunshi の opus が当たり、誤って「一致」と出る。
mk2 "$WORK/c7"
aud "$WORK/c7" karo 2026-11-01T01:00:00.000Z /x/k1
aud "$WORK/c7" karo 2026-11-01T01:10:00.000Z /x/k2
aud "$WORK/c7" karo 2026-11-01T01:20:00.000Z /x/k3
aud "$WORK/c7" gunshi 2026-11-01T02:00:00.000Z /x/g1
aud "$WORK/c7" gunshi 2026-11-01T02:10:00.000Z /x/g2
aud "$WORK/c7" gunshi 2026-11-01T02:20:00.000Z /x/g3
tu "$WORK/c7/projects/p/karo_sess.jsonl" claude-sonnet-5-5 2026-11-01T01:00:01.000Z /x/k1
tu "$WORK/c7/projects/p/karo_sess.jsonl" claude-sonnet-5-5 2026-11-01T01:10:01.000Z /x/k2
tu "$WORK/c7/projects/p/karo_sess.jsonl" claude-sonnet-5-5 2026-11-01T01:20:01.000Z /x/k3
ev "$WORK/c7/projects/p/karo_sess.jsonl" claude-sonnet-5-5 2026-11-01T01:30:00.000Z
tu "$WORK/c7/projects/p/gunshi_sess.jsonl" claude-opus-5-5 2026-11-01T01:00:01.000Z /x/k1
tu "$WORK/c7/projects/p/gunshi_sess.jsonl" claude-opus-5-5 2026-11-01T02:00:01.000Z /x/g1
tu "$WORK/c7/projects/p/gunshi_sess.jsonl" claude-opus-5-5 2026-11-01T02:10:01.000Z /x/g2
tu "$WORK/c7/projects/p/gunshi_sess.jsonl" claude-opus-5-5 2026-11-01T02:20:01.000Z /x/g3
ev "$WORK/c7/projects/p/gunshi_sess.jsonl" claude-opus-5-5 2026-11-01T02:30:00.000Z
run_case "7 他人への偶然の1件一致で取り違えぬ" "$WORK/c7" 1 "不一致 1 件" "MISMATCH karo: .*実測=claude-sonnet-5-5"
out7="$(audit_out "$WORK/c7")"
if printf '%s\n' "$out7" | grep '^karo ' | grep -q 'karo_sess.jsonl' \
   && printf '%s\n' "$out7" | grep '^gunshi ' | grep -q 'gunshi_sess.jsonl' \
   && printf '%s\n' "$out7" | grep '^gunshi ' | grep -q '一致'; then
  PASS=$((PASS + 1)); echo "PASS: 7b karo=karo_sess / gunshi=gunshi_sess に帰属"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 7b 帰属が違う"; printf '%s\n' "$out7" | sed 's/^/    out: /'
fi

# 8. 同数1位(どちらの audit も同じ2件に一致)→ 誰にも帰属させず、2人とも対応取れず → 3
mk2 "$WORK/c8"
aud "$WORK/c8" karo 2026-11-01T01:00:00.000Z /x/shared
aud "$WORK/c8" karo 2026-11-01T01:00:10.000Z /x/shared2
aud "$WORK/c8" gunshi 2026-11-01T01:00:00.000Z /x/shared
aud "$WORK/c8" gunshi 2026-11-01T01:00:10.000Z /x/shared2
tu "$WORK/c8/projects/p/only_sess.jsonl" claude-opus-5-5 2026-11-01T01:00:01.000Z /x/shared
tu "$WORK/c8/projects/p/only_sess.jsonl" claude-opus-5-5 2026-11-01T01:00:11.000Z /x/shared2
ev "$WORK/c8/projects/p/only_sess.jsonl" claude-opus-5-5 2026-11-01T01:05:00.000Z
run_case "8 同数1位は対応取れず" "$WORK/c8" 3 "判定できぬ者 2 人" ""
if [ "$(audit_out "$WORK/c8" | grep -c '対応取れず(.*同数')" = "2" ]; then
  PASS=$((PASS + 1)); echo "PASS: 8b 2人とも『同数』の理由つき対応取れず(一致とは出ない)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 8b 同数の理由が2行出ていない"; audit_out "$WORK/c8" | sed 's/^/    out: /'
fi

# 9. 同数で取りこぼしたセッションの方が、単独で帰属した古いセッションより新しい
#    → 古い方を黙って採らず対応取れず。karo: 古い karo_old(k1,k2・単独)と新しい tied_new(shared,shared2・gunshi と同数)。
mk2 "$WORK/c9"
aud "$WORK/c9" karo 2026-11-01T01:00:00.000Z /x/k1
aud "$WORK/c9" karo 2026-11-01T01:00:10.000Z /x/k2
aud "$WORK/c9" karo 2026-11-01T03:00:00.000Z /x/shared
aud "$WORK/c9" karo 2026-11-01T03:00:10.000Z /x/shared2
aud "$WORK/c9" gunshi 2026-11-01T03:00:00.000Z /x/shared
aud "$WORK/c9" gunshi 2026-11-01T03:00:10.000Z /x/shared2
tu "$WORK/c9/projects/p/karo_old.jsonl" claude-opus-5-5 2026-11-01T01:00:01.000Z /x/k1
tu "$WORK/c9/projects/p/karo_old.jsonl" claude-opus-5-5 2026-11-01T01:00:11.000Z /x/k2
ev "$WORK/c9/projects/p/karo_old.jsonl" claude-opus-5-5 2026-11-01T01:05:00.000Z
tu "$WORK/c9/projects/p/tied_new.jsonl" claude-opus-5-5 2026-11-01T03:00:01.000Z /x/shared
tu "$WORK/c9/projects/p/tied_new.jsonl" claude-opus-5-5 2026-11-01T03:00:11.000Z /x/shared2
ev "$WORK/c9/projects/p/tied_new.jsonl" claude-opus-5-5 2026-11-01T03:05:00.000Z
run_case "9 同数で取りこぼした新しい方があれば古い方を採らず対応取れず" "$WORK/c9" 3 "判定できぬ者 2 人" ""
if audit_out "$WORK/c9" | grep '^karo ' | grep -q '対応取れず'; then
  PASS=$((PASS + 1)); echo "PASS: 9b karo の行が対応取れず(古い karo_old を採っていない)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 9b karo が古いセッションを採った疑い"; audit_out "$WORK/c9" | sed 's/^/    out: /'
fi

# 10. 下限: 本人の一致が 0(そのセッションで file_path つきの記録が無い)で、他人が偶然1件だけ一致するセッション
#     → 他人に帰属させぬ。karo の本当のセッション karo_sess(一致3・sonnet=不一致)は古い。
#     gunshi の新しいセッション gunshi_sess は Bash のみ+karo の audit の1件(k1)に偶然一致(opus)。
#     下限が無ければ gunshi_sess が karo に帰属し、誤って karo が「一致」と出る。
mk2 "$WORK/c10"
aud "$WORK/c10" karo 2026-11-01T01:00:00.000Z /x/k1
aud "$WORK/c10" karo 2026-11-01T01:10:00.000Z /x/k2
aud "$WORK/c10" karo 2026-11-01T01:20:00.000Z /x/k3
aud "$WORK/c10" gunshi 2026-11-01T02:00:00.000Z /x/g1
tu "$WORK/c10/projects/p/karo_sess.jsonl" claude-sonnet-5-5 2026-11-01T01:00:01.000Z /x/k1
tu "$WORK/c10/projects/p/karo_sess.jsonl" claude-sonnet-5-5 2026-11-01T01:10:01.000Z /x/k2
tu "$WORK/c10/projects/p/karo_sess.jsonl" claude-sonnet-5-5 2026-11-01T01:20:01.000Z /x/k3
ev "$WORK/c10/projects/p/karo_sess.jsonl" claude-sonnet-5-5 2026-11-01T01:30:00.000Z
tu "$WORK/c10/projects/p/gunshi_sess.jsonl" claude-opus-5-5 2026-11-01T01:00:01.000Z /x/k1
printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"2026-11-01T02:00:01.000Z\",\"effort\":\"high\",\"message\":{\"model\":\"claude-opus-5-5\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}],\"usage\":{\"output_tokens\":1}}}" \
  >> "$WORK/c10/projects/p/gunshi_sess.jsonl"
ev "$WORK/c10/projects/p/gunshi_sess.jsonl" claude-opus-5-5 2026-11-01T02:30:00.000Z
run_case "10 本人の一致0・他人の偶然の1件一致は他人に帰属させぬ" "$WORK/c10" 1 "不一致 1 件" "MISMATCH karo: .*実測=claude-sonnet-5-5"
out10="$(audit_out "$WORK/c10")"
if printf '%s\n' "$out10" | grep '^karo ' | grep -q 'karo_sess.jsonl' \
   && ! printf '%s\n' "$out10" | grep '^karo ' | grep -q 'gunshi_sess.jsonl' \
   && printf '%s\n' "$out10" | grep '^gunshi ' | grep -q '対応取れず'; then
  PASS=$((PASS + 1)); echo "PASS: 10b karo=karo_sess(gunshi_sess を奪わぬ) / gunshi=対応取れず"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 10b 帰属が違う"; printf '%s\n' "$out10" | sed 's/^/    out: /'
fi

# 11. 下限: 本人の一致が1件だけのセッション(下限 2 件未満)→ 誰にも帰属させず『対応取れず』・終了コード 3
mk_case "$WORK/c11" claude-opus-5-5 high claude-opus-5-5 1
head -n 1 "$WORK/c11/audit/2026-11/karo.jsonl" > "$WORK/c11/audit/one.jsonl" \
  && mv -- "$WORK/c11/audit/one.jsonl" "$WORK/c11/audit/2026-11/karo.jsonl"
run_case "11 一致1件だけは対応取れず(下限2件)" "$WORK/c11" 3 "判定できぬ者 1 人" ""
if audit_out "$WORK/c11" | grep '^karo ' | grep -q '対応取れず'; then
  PASS=$((PASS + 1)); echo "PASS: 11b karo の行が対応取れず(一致とは出ない)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 11b 一致1件で帰属した疑い"; audit_out "$WORK/c11" | sed 's/^/    out: /'
fi

# 12. 窓: --days の窓の外の古い audit 記録は数えぬ。karo の audit 2件(k1,k2)に一致するセッションがあっても、
#     記録が窓(--days 3)より古ければ、窓の内に記録が無いので『対応取れず』・終了コード 3。
#     12b: 同じ組を窓の内の時刻にすれば一致し 0(窓の内は数える)。
#     ts は現在からの相対で作る(--days が現在基準のため)。
iso_ago() { date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z; }
run_days3() {
  bash "$AUDIT_SH" --settings "$1/settings.yaml" --projects-dir "$1/projects" --audit-dir "$1/audit" --days 3 2>/dev/null
}
mk2 "$WORK/c12"
OLD1="$(iso_ago $((10 * 86400)))"; OLD2="$(iso_ago $((10 * 86400 - 10)))"
aud "$WORK/c12" karo "$OLD1" /x/k1
aud "$WORK/c12" karo "$OLD2" /x/k2
aud "$WORK/c12" gunshi "$(iso_ago 600)" /x/g1
tu "$WORK/c12/projects/p/karo_sess.jsonl" claude-opus-5-5 "$OLD1" /x/k1
tu "$WORK/c12/projects/p/karo_sess.jsonl" claude-opus-5-5 "$OLD2" /x/k2
ev "$WORK/c12/projects/p/karo_sess.jsonl" claude-opus-5-5 "$(iso_ago 300)"
out12="$(run_days3 "$WORK/c12")"; rc12=$?
if [ "$rc12" = "3" ] && printf '%s\n' "$out12" | grep '^karo ' | grep -q '対応取れず'; then
  PASS=$((PASS + 1)); echo "PASS: 12 窓の外の古い audit 記録は数えぬ(karo=対応取れず, exit 3)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 12 窓の外の記録を数えた疑い (exit $rc12)"; printf '%s\n' "$out12" | sed 's/^/    out: /'
fi
mk_case "$WORK/c12b" claude-opus-5-5 high "" 0   # settings の枠だけ使う
rm -rf -- "$WORK/c12b/audit" && mkdir -p "$WORK/c12b/audit/2026-11"
N1="$(iso_ago 7200)"; N2="$(iso_ago 7190)"
printf '%s\n' "{\"ts\":\"$N1\",\"agent\":\"karo\",\"event\":\"tool.call\",\"tool\":\"Read\",\"ok\":true,\"file_path\":\"/x/k1\"}" > "$WORK/c12b/audit/2026-11/karo.jsonl"
printf '%s\n' "{\"ts\":\"$N2\",\"agent\":\"karo\",\"event\":\"tool.call\",\"tool\":\"Read\",\"ok\":true,\"file_path\":\"/x/k2\"}" >> "$WORK/c12b/audit/2026-11/karo.jsonl"
tu "$WORK/c12b/projects/p/karo_sess.jsonl" claude-opus-5-5 "$N1" /x/k1
tu "$WORK/c12b/projects/p/karo_sess.jsonl" claude-opus-5-5 "$N2" /x/k2
ev "$WORK/c12b/projects/p/karo_sess.jsonl" claude-opus-5-5 "$(iso_ago 300)"
out12b="$(run_days3 "$WORK/c12b")"; rc12b=$?
if [ "$rc12b" = "0" ] && printf '%s\n' "$out12b" | grep -q '全員一致'; then
  PASS=$((PASS + 1)); echo "PASS: 12b 窓の内の記録は数える(一致, exit 0)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 12b 窓の内の記録を数えぬ (exit $rc12b)"; printf '%s\n' "$out12b" | sed 's/^/    out: /'
fi

# 13. 窓の内の全件で突き合わせる(直近40件で切らぬ): karo の audit は、古い順に k1,k2(セッションと一致)のあと
#     無関係な記録(/x/pad<i>)を50件。直近40件で切る旧実装ならこの50件に押し出されて一致0=対応取れず。全件なら 2 件一致し 0。
mk_case "$WORK/c13" claude-opus-5-5 high "" 0
rm -rf -- "$WORK/c13/audit" && mkdir -p "$WORK/c13/audit/2026-11"
P1="$(iso_ago 7200)"; P2="$(iso_ago 7190)"
aud "$WORK/c13" karo "$P1" /x/k1
aud "$WORK/c13" karo "$P2" /x/k2
for i in $(seq 1 50); do aud "$WORK/c13" karo "$(iso_ago $((3000 - i)))" "/x/pad$i"; done
tu "$WORK/c13/projects/p/karo_sess.jsonl" claude-opus-5-5 "$P1" /x/k1
tu "$WORK/c13/projects/p/karo_sess.jsonl" claude-opus-5-5 "$P2" /x/k2
ev "$WORK/c13/projects/p/karo_sess.jsonl" claude-opus-5-5 "$(iso_ago 300)"
out13="$(run_days3 "$WORK/c13")"; rc13=$?
if [ "$rc13" = "0" ] && printf '%s\n' "$out13" | grep -q '全員一致'; then
  PASS=$((PASS + 1)); echo "PASS: 13 窓の内の全件で突き合わせる(直近40件で切らぬ, exit 0)"
else
  FAIL=$((FAIL + 1)); echo "FAIL: 13 件数の上限で切った疑い (exit $rc13)"; printf '%s\n' "$out13" | sed 's/^/    out: /'
fi

echo "---"
echo "結果: PASS=$PASS FAIL=$FAIL SKIP=0"
[ "$FAIL" = "0" ] || exit 1
exit 0
