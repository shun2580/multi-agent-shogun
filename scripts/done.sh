#!/bin/bash
# done.sh — done化とarchive移管を1操作にする (cmd_210 E-2)
#
# Usage:
#   bash scripts/done.sh cmd <cmd_id>          # shogun_to_karo.yaml の該当cmdを done 化し archive へ移管
#   bash scripts/done.sh report <report_file>  # report YAML を archive_report.sh でアーカイブしてから done 化
#
# 環境変数:
#   DONE_ROOT  書込先ルート (既定=このスクリプトのリポジトリルート)。テストで本番queueを触らないための差替口。
#
# cmd の移管先: $DONE_ROOT/queue/archive/cmds/<cmd_id>.yaml  (`commands:` 配下の1要素。status: done 済み)
# 手順: (1) archive先へ書込・検証 → (2) 本体からブロック除去。失敗時は本体を壊さず exit 非0 (部分成功を残さない)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DONE_ROOT="${DONE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

die() { echo "done.sh: ERROR: $*" >&2; exit 1; }

usage() {
  echo "Usage: done.sh cmd <cmd_id> | done.sh report <report_file>" >&2
  exit 1
}

# 先頭の status: 行(top-level優先、無ければ最初のインデント付き)を done に置換して標準出力へ。
# 引数 $1=indent_mode (top|any)。置換対象が無ければ何も変えない。
set_status_done() {
  awk -v mode="$1" '
    !done && mode == "block" && /^  status:/ { print "  status: done"; done = 1; next }
    !done && mode == "top"   && /^status:/   { print "status: done"; done = 1; next }
    !done && mode == "nested" && /^  status:/ { print "  status: done"; done = 1; next }
    { print }
  '
}

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

  echo "done: $id → $archive_file (本体から除去済み)"
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
  if ! grep -qE '^(status|  status):[[:space:]]*done[[:space:]]*$' "$file"; then
    grep -qE '^(status|  status):' "$file" || die "status 行が見つからない: $file"
    local tmp="$file.tmp.$$"
    set_status_done "$mode" < "$file" > "$tmp" || { rm -f "$tmp"; die "status書換に失敗: $file"; }
    mv "$tmp" "$file" || { rm -f "$tmp"; die "status書換の確定に失敗: $file"; }
  fi
  echo "done: $file (status: done)"
}

[[ $# -ge 2 ]] || usage
case "$1" in
  cmd)    cmd_done "$2" ;;
  report) report_done "$2" ;;
  *)      usage ;;
esac
