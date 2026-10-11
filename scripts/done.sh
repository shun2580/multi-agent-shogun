#!/bin/bash
# done.sh — done化とarchive移管を1操作にする (cmd_210 E-2)
#
# Usage:
#   bash scripts/done.sh cmd <cmd_id>          # shogun_to_karo.yaml の該当cmdを done 化し archive へ移管
#   bash scripts/done.sh report <report_file>  # report YAML を archive_report.sh でアーカイブしてから done 化
#   bash scripts/done.sh task <agent_id> [task_id] [--if-reported] [--mentioned-in <text>]
#                                              # queue/tasks/<agent_id>.yaml の status を done 化 (cmd_222)
#
# 環境変数:
#   DONE_ROOT  書込先ルート (既定=このスクリプトのリポジトリルート)。テストで本番queueを触らないための差替口。
#
# task の規則 (足軽・軍師が任務を終えたとき『報告したのに task YAML が assigned のまま』を残さないための1操作):
#   - agent_id は ashigaru1-7 / gunshi のみ。task YAML が無ければ拒否 (新規作成しない)。
#   - task_id を渡したときは YAML の task.task_id と完全一致を検証し、不一致なら何も書かず exit 非0。
#   - 終端 status (TERMINAL_STATUSES 等) は書き換えない。最初の `  status:` 行だけを置換し他の行はバイト不変。
#   - --if-reported : 『task が assigned / in_progress』かつ『queue/reports/<agent_id>_report.yaml の当該 task_id の
#                    最後の記録が done / done_with_caveat』のときだけ書く。他は何もせず exit 0 (inbox_write.sh の自動閉じ用。
#                    blocked / failed の報告を done にしてしまわないための安全弁)。
#   - --mentioned-in <text> : <text> に task_id (YAML の現在値) が文字列として含まれるときだけ進む。含まなければ何もせず exit 0。
#
# cmd の移管先: $DONE_ROOT/queue/archive/cmds/<cmd_id>.yaml  (`commands:` 配下の1要素。status: done 済み)
# 手順: (1) archive先へ書込・検証 → (2) 本体からブロック除去。失敗時は本体を壊さず exit 非0 (部分成功を残さない)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DONE_ROOT="${DONE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

die() { echo "done.sh: ERROR: $*" >&2; exit 1; }

usage() {
  echo "Usage: done.sh cmd <cmd_id> | done.sh report <report_file> | done.sh task <agent_id> [task_id] [--if-reported] [--mentioned-in <text>]" >&2
  exit 1
}

# 終端 status (空白区切り)。これらの値を持つ status 行は done.sh が一切書き換えない (cmd_215)。
# 終端 = 『TERMINAL_STATUSES との完全一致』または『TERMINAL_PREFIXES のいずれかで始まる値』
# (superseded_by_cmd_075 等を保持)。done_ 前方一致は採らない (done_with_caveat は完全一致のみ)。
# paused / idle / blocked 等は非終端のまま (従来どおり done へ置換)。
# 判定は is_terminal() と status_awk 内 terminal() の2箇所に在る。規則を変えるときは必ず両方を揃えること。
TERMINAL_STATUSES="done done_with_caveat superseded cancelled failed"
TERMINAL_PREFIXES="superseded_ cancelled_ failed_"

is_terminal() {
  local v="${1:-}" p
  [[ -n "$v" ]] || return 1
  [[ " $TERMINAL_STATUSES " == *" $v "* ]] && return 0
  for p in $TERMINAL_PREFIXES; do
    [[ "$v" == "$p"* ]] && return 0
  done
  return 1
}

# 最初の status: 行を対象に (対象行の選び方は mode: block|nested=インデント2 / top=行頭)、
#   action=set (既定): 終端でなければ done へ置換、終端なら行を無変更で出力。標準入力→標準出力。
#   action=get       : その行の status 値 (status: 直後の最初の語。先頭の引用符は除く) だけを出力。
# 終端の判定は 完全一致 または 接頭辞一致 (is_terminal 参照。done_with_caveat を done と誤判定しない)。
# 対象行が無ければ何も変えない/何も出さない。
# 引数 $1=mode, $2=action
status_awk() {
  awk -v mode="$1" -v action="${2:-set}" -v terms="$TERMINAL_STATUSES" -v prefixes="$TERMINAL_PREFIXES" -v q="'" '
    function value(line,   v) {
      v = line
      sub(/^ *status:[ \t]*/, "", v)
      if (substr(v, 1, 1) == "\"" || substr(v, 1, 1) == q) v = substr(v, 2)
      if (match(v, /^[A-Za-z0-9_]+/)) return substr(v, 1, RLENGTH)
      return ""
    }
    function terminal(v,   i, n, t) {
      if (v == "") return 0
      n = split(terms, t, " ")
      for (i = 1; i <= n; i++) if (t[i] == v) return 1
      n = split(prefixes, t, " ")
      for (i = 1; i <= n; i++) if (substr(v, 1, length(t[i])) == t[i]) return 1
      return 0
    }
    !seen && ((mode == "top" && /^status:/) || (mode != "top" && /^  status:/)) {
      seen = 1
      v = value($0)
      if (action == "get") { print v; next }
      if (terminal(v)) { print; next }
      print (mode == "top" ? "" : "  ") "status: done"
      next
    }
    action != "get" { print }
  '
}

set_status_done() { status_awk "$1" set; }
status_value()    { status_awk "$1" get; }

cmd_done() {
  local id="${1:-}"
  [[ "$id" =~ ^cmd_[A-Za-z0-9_]+$ ]] || die "invalid cmd_id: '$id'"

  local body="$DONE_ROOT/queue/shogun_to_karo.yaml"
  local archive_dir="$DONE_ROOT/queue/archive/cmds"
  local archive_file="$archive_dir/$id.yaml"
  [[ -f "$body" ]] || die "not found: $body"

  # ブロック検出: `- id: <id>` (行頭) から次の `- id:` 直前(またはEOF)まで
  local first_line
  first_line=$(awk -v id="$id" '
    $0 ~ "^- id: *[\"\x27]?" id "[\"\x27]? *$" { print NR; exit }
  ' "$body")
  if [[ -z "$first_line" ]]; then
    if [[ -f "$archive_file" ]]; then
      die "$id は本体に無い (既にarchive済み: $archive_file)"
    fi
    die "$id が $body に存在しない"
  fi
  [[ ! -e "$archive_file" ]] || die "archive先が既に存在する (上書きしない): $archive_file"

  local last_line
  last_line=$(awk -v start="$first_line" '
    NR > start && /^- id:/ { print NR - 1; found = 1; exit }
    END { if (!found) print NR }
  ' "$body")

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/done.XXXXXX")" || die "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" EXIT

  # 元の status 値 (終端なら set_status_done が行を変えない。完了行の表示に使う)
  local orig_status
  orig_status=$(sed -n "${first_line},${last_line}p" "$body" | status_value block) || die "status 値の取得に失敗"

  # (1) archive先へ書込
  { echo "commands:"; sed -n "${first_line},${last_line}p" "$body" | set_status_done block; } > "$tmp_dir/block.yaml" \
    || die "ブロック抽出に失敗"
  grep -q "^- id: " "$tmp_dir/block.yaml" || die "ブロック抽出結果が不正"

  mkdir -p "$archive_dir" 2>/dev/null || die "archive先を作成できない: $archive_dir"
  local staged="$archive_dir/.$id.yaml.tmp.$$"
  if ! cp "$tmp_dir/block.yaml" "$staged" 2>/dev/null; then
    rm -f "$staged" 2>/dev/null || true
    die "archiveへ書込できない: $archive_dir (本体は無変更)"
  fi
  if ! mv "$staged" "$archive_file" 2>/dev/null; then
    rm -f "$staged" 2>/dev/null || true
    die "archiveの確定に失敗: $archive_file (本体は無変更)"
  fi
  cmp -s "$tmp_dir/block.yaml" "$archive_file" || {
    rm -f "$archive_file"
    die "archive内容の検証に失敗 (本体は無変更)"
  }

  # (2) 本体からブロック除去 (他ブロックはバイト不変)
  local new_body="$tmp_dir/body.new"
  if ! sed "${first_line},${last_line}d" "$body" > "$new_body"; then
    rm -f "$archive_file"
    die "本体の再構成に失敗 (本体は無変更・archiveを巻戻し)"
  fi
  # 検証: 行数が除去分だけ減り、対象idが消え、他のid数が1減っている
  local before after removed expected_ids actual_ids
  before=$(wc -l < "$body"); after=$(wc -l < "$new_body")
  removed=$((last_line - first_line + 1))
  expected_ids=$(( $(grep -c '^- id:' "$body") - 1 ))
  actual_ids=$(grep -c '^- id:' "$new_body" || true)
  if [[ $((before - after)) -ne $removed || "$expected_ids" -ne "$actual_ids" ]]; then
    rm -f "$archive_file"
    die "本体除去後の検証に失敗 (本体は無変更・archiveを巻戻し)"
  fi
  if ! cat "$new_body" > "$body.tmp.$$" || ! mv "$body.tmp.$$" "$body"; then
    rm -f "$body.tmp.$$" "$archive_file"
    die "本体の書換に失敗 (archiveを巻戻し)"
  fi

  if is_terminal "$orig_status"; then
    echo "done: $id → $archive_file (本体から除去済み、status 保持: $orig_status)"
  else
    echo "done: $id → $archive_file (本体から除去済み)"
  fi
}

report_done() {
  local file="${1:-}"
  [[ -n "$file" ]] || usage
  if [[ ! -f "$file" && "$file" != /* && -f "$DONE_ROOT/$file" ]]; then
    file="$DONE_ROOT/$file"
  fi
  [[ -f "$file" ]] || die "report file not found: $file"

  local dir name latest
  dir=$(dirname "$file"); name=$(basename "$file"); name="${name%.*}"

  # 同内容の最新archiveが既にあれば再archiveしない (冪等: 重複スナップショットを作らない)
  latest=$(ls -1 "$dir/archive/${name}"_[0-9]*.yaml 2>/dev/null | sort | tail -n 1 || true)
  if [[ -n "$latest" ]] && cmp -s "$file" "$latest"; then
    echo "archive: 既に同内容あり ($latest)"
  else
    local out
    out=$(bash "$SCRIPT_DIR/archive_report.sh" "$file") || die "archive_report.sh が失敗: $file"
    [[ -z "$out" ]] || echo "archive: $out"
  fi

  local mode=top
  grep -q '^status:' "$file" || mode=nested
  grep -qE '^(status|  status):' "$file" || die "status 行が見つからない: $file"
  # 終端 status (done 含む) は書き換えない。未完了 status のみ done へ (冪等)。
  local cur shown=done
  cur=$(status_value "$mode" < "$file") || die "status 値の取得に失敗: $file"
  if is_terminal "$cur"; then
    shown="$cur"
  else
    local tmp="$file.tmp.$$"
    set_status_done "$mode" < "$file" > "$tmp" || { rm -f "$tmp"; die "status書換に失敗: $file"; }
    mv "$tmp" "$file" || { rm -f "$tmp"; die "status書換の確定に失敗: $file"; }
  fi
  echo "done: $file (status: $shown)"
}

# task YAML (`task:` 直下・インデント2) の最初の値 $2 (task_id 等) を出す。引用符と行末コメントは除く。
task_field() {
  awk -v key="$2" -v q="'" '
    !seen && $0 ~ "^  " key ":" {
      seen = 1
      v = $0
      sub("^  " key ":[ \t]*", "", v)
      gsub("\"", "", v); gsub(q, "", v)
      sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      print v
    }
  ' "$1"
}

# 報告ファイル $1 のうち task_id==$2 の最後の記録の status 値を出す (無ければ空)。
# 記録 = `task_id:` 行から次の `task_id:` 行 (または `---`) の手前まで。その中の最初の `status:` を採る。
reported_status() {
  awk -v tid="$2" -v q="'" '
    function clean(s) {
      gsub("\"", "", s); gsub(q, "", s)
      sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s)
      return s
    }
    /^---[ \t]*$/ { found = 0; next }
    /^[ ]*(- )?task_id:/ {
      v = $0; sub(/^[ ]*(- )?task_id:[ \t]*/, "", v)
      found = (clean(v) == tid)
      if (found) { out = ""; got = 0 }
      next
    }
    found && !got && /^[ ]*status:/ {
      v = $0; sub(/^[ ]*status:[ \t]*/, "", v)
      if (substr(v, 1, 1) == "\"" || substr(v, 1, 1) == q) v = substr(v, 2)
      if (match(v, /^[A-Za-z0-9_]+/)) out = substr(v, 1, RLENGTH)
      got = 1
    }
    END { print out }
  ' "$1"
}

task_done() {
  local agent="" tid="" if_reported=0 have_mention=0 mention="" arg
  while [[ $# -gt 0 ]]; do
    arg="$1"; shift
    case "$arg" in
      --if-reported)  if_reported=1 ;;
      --mentioned-in) [[ $# -ge 1 ]] || die "--mentioned-in には本文が要る"
                      have_mention=1; mention="$1"; shift ;;
      -*)             die "unknown option: $arg" ;;
      *)              if [[ -z "$agent" ]]; then agent="$arg"
                      elif [[ -z "$tid" ]]; then tid="$arg"
                      else die "余分な引数: $arg"; fi ;;
    esac
  done
  [[ "$agent" =~ ^(ashigaru[1-7]|gunshi)$ ]] || die "invalid agent_id: '$agent' (allowed: ashigaru1-7, gunshi)"
  [[ -z "$tid" || "$tid" =~ ^[A-Za-z0-9_]+$ ]] || die "invalid task_id: '$tid'"

  local file="$DONE_ROOT/queue/tasks/$agent.yaml"
  [[ -f "$file" ]] || die "task YAML が無い: $file"
  grep -q '^task:' "$file" || die "task: 行が見つからない: $file"
  grep -q '^  status:' "$file" || die "status 行が見つからない: $file"

  local cur_tid cur
  cur_tid=$(task_field "$file" task_id)
  [[ -n "$cur_tid" ]] || die "task_id が読めない: $file"
  if [[ -n "$tid" && "$tid" != "$cur_tid" ]]; then
    die "task_id 不一致: 指定=$tid / $file の現在値=$cur_tid (何も書かない)"
  fi
  tid="$cur_tid"

  # 自動閉じ用の絞り込み。条件を満たさぬときは何もせず成功で返る (呼び元の配信を妨げない)。
  if [[ $have_mention -eq 1 && "$mention" != *"$tid"* ]]; then
    return 0
  fi

  cur=$(status_value nested < "$file") || die "status 値の取得に失敗: $file"
  if is_terminal "$cur"; then
    [[ $if_reported -eq 1 ]] || echo "done: $file (task_id: $tid, status: $cur のまま・終端につき無変更)"
    return 0
  fi
  if [[ $if_reported -eq 1 ]]; then
    [[ "$cur" == "assigned" || "$cur" == "in_progress" ]] || return 0
    local rep="$DONE_ROOT/queue/reports/${agent}_report.yaml" rs
    [[ -f "$rep" ]] || return 0
    rs=$(reported_status "$rep" "$tid")
    [[ "$rs" == "done" || "$rs" == "done_with_caveat" ]] || return 0
  fi

  # cp -p で権限を引き継いだ一時ファイルへ書き、検証してから置換する (書込中の半端な内容を見せない)
  local tmp="$file.tmp.$$"
  cp -p "$file" "$tmp" || die "一時ファイルを作れない: $tmp"
  if ! set_status_done nested < "$file" > "$tmp"; then
    rm -f "$tmp"; die "status書換に失敗: $file"
  fi
  local changed
  changed=$(diff "$file" "$tmp" | grep -c '^<' || true)
  if [[ "$(wc -l < "$file")" -ne "$(wc -l < "$tmp")" || "$changed" -ne 1 \
        || "$(status_value nested < "$tmp")" != "done" || "$(task_field "$tmp" task_id)" != "$tid" ]]; then
    rm -f "$tmp"; die "書換結果の検証に失敗 (無変更): $file"
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; die "status書換の確定に失敗: $file"; }
  echo "done: $file (task_id: $tid, status: $cur → done)"
}

[[ $# -ge 2 ]] || usage
case "$1" in
  cmd)    cmd_done "$2" ;;
  report) report_done "$2" ;;
  task)   shift; task_done "$@" ;;
  *)      usage ;;
esac
