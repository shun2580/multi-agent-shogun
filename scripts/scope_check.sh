#!/bin/bash

# scripts/scope_check.sh
# Purpose: Compare allowed_paths from a task YAML with actual git changed files
#          to detect changes outside declared paths.

# Arguments:
#   $1 = Path to task YAML (e.g., queue/tasks/ashigaru3.yaml)
#   $2 = git_baseline (commit SHA or HEAD. Defaults to HEAD if not specified)

# Exit Codes:
#   0 = OK (only declared files changed or SKIP)
#   1 = Violation detected (undeclared files changed)
#   2 = SKIP (allowed_paths and target_path not set, or git error)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- YAML Parsing (using grep/sed) ---

# Function to parse YAML array into bash array
parse_yaml_array() {
  local yaml_file="$1"
  local key="$2"
  # Extract lines under the key, remove leading/trailing whitespace and '- '
  grep -A 100000 -E "^\s*${key}:" "$yaml_file" | \
    grep -E '^\s*-\s*\S+' | \
    sed -E 's/^\s*-\s*//' | \
    while IFS= read -r line; do
      echo "$line"
    done
}

# Repo root used to normalize absolute allowed_paths entries to repo-relative
# form before comparison (git diff --name-only always returns repo-relative
# paths regardless of invocation CWD, so only the pattern side can drift).
# Set once in the main block below; empty if not inside a git repo.
REPO_ROOT=""

# Strip REPO_ROOT prefix from a path if present, leaving it untouched otherwise.
# Applied to both sides of the comparison so absolute and relative allowed_paths
# notations are both accepted without requiring existing YAML to be rewritten.
normalize_to_repo_relative() {
  local path="$1"
  if [[ -n "$REPO_ROOT" && "$path" == "$REPO_ROOT"/* ]]; then
    echo "${path#"$REPO_ROOT"/}"
  else
    echo "$path"
  fi
}

# Function to perform extended pattern matching (glob and directory)
# Returns 0 if match, 1 otherwise
match_pattern() {
  local file
  local pattern
  file="$(normalize_to_repo_relative "$1")"
  pattern="$(normalize_to_repo_relative "$2")"

  if [[ "$pattern" == */ ]]; then # Directory match (e.g., "path/dir/")
    [[ "$file" == "$pattern"* ]]
  elif [[ "$pattern" == *"*"* || "$pattern" == *"?"* || "$pattern" == *"["* ]]; then # Glob pattern
    case "$file" in
      $pattern) return 0 ;;
      *) return 1 ;;
    esac
  else # Exact match
    [[ "$file" == "$pattern" ]]
  fi
}

# cmd_151: 生成物パス除外リスト(gunshi_audit_144 agenda2の一次資料に基づく静的保持方式)。
# 「instructions/{role}.md編集タスクはallowed_pathsに生成物パスも追記する」運用規約方式は
# 徹底が難しい(gunshi_audit_144推奨は静的リスト方式)ため不採用。静的リストの弱点(新規
# 生成物パス追加時に本リストの更新漏れが起きうる)は、下のexclusion effectログ(fail-loud
# 検知機構)で除外の実効果を可視化することで補う。
GENERATED_PATH_EXCLUSIONS=(
  "instructions/generated/*"
  ".opencode/agents/*.md"
  "AGENTS.md"
  "agents/default/system.md"
  ".github/copilot-instructions.md"
)

# Returns 0 if the file matches a known generated-path exclusion pattern.
is_generated_path_excluded() {
  local file="$1"
  local pattern
  for pattern in "${GENERATED_PATH_EXCLUSIONS[@]}"; do
    if match_pattern "$file" "$pattern"; then
      return 0
    fi
  done
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  TASK_YAML="$1"
  GIT_BASELINE="${2:-HEAD}" # Default to HEAD if $2 is not provided

  # Extract allowed_paths
  readarray -t ALLOWED_PATHS < <(parse_yaml_array "$TASK_YAML" "allowed_paths")

  # Extract target_path
  TARGET_PATH=$(grep -E '^\s*target_path:' "$TASK_YAML" | sed -E 's/^\s*target_path:\s*//')

  # Logic for allowed_paths and target_path
  if [ ${#ALLOWED_PATHS[@]} -eq 0 ] && [ -z "$TARGET_PATH" ]; then
    echo "Neither allowed_paths nor target_path found. Exiting with SKIP (2)." >&2
    exit 2
  elif [ ${#ALLOWED_PATHS[@]} -eq 0 ] && [ -n "$TARGET_PATH" ]; then
    # If only target_path exists, treat target_path as allowed_paths
    ALLOWED_PATHS=("$TARGET_PATH")
  fi

  # Get changed files from git
  CHANGED_FILES=$(git diff --name-only "$GIT_BASELINE" HEAD 2>/dev/null)
  GIT_EXIT_CODE=$?

  if [ "$GIT_EXIT_CODE" -ne 0 ]; then
    echo "Git command failed. Exiting with SKIP (2)." >&2
    exit 2
  fi

  # Resolve repo root for path normalization (see match_pattern above).
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"

  VIOLATION_DETECTED=0
  NON_ALLOWED_FILES=()
  EXCLUDED_FILES=()

  # Iterate through changed files
  while IFS= read -r changed_file; do
    if [ -z "$changed_file" ]; then
      continue
    fi

    IS_ALLOWED=0
    for allowed_pattern in "${ALLOWED_PATHS[@]}"; do
      if match_pattern "$changed_file" "$allowed_pattern"; then
        IS_ALLOWED=1
        break
      fi
    done

    if [ "$IS_ALLOWED" -eq 0 ]; then
      if is_generated_path_excluded "$changed_file"; then
        EXCLUDED_FILES+=("$changed_file")
        continue
      fi
      VIOLATION_DETECTED=1
      NON_ALLOWED_FILES+=("$changed_file")
    fi
  done <<< "$CHANGED_FILES"

  # cmd_151 検知機構(殿必須条件・原則5 fail-loud): 除外が1件でも適用された実行は、
  # 除外で判定が反転(逸脱→適合)したか否かに関わらず専用ログへ記録する。除外が
  # 広すぎて真陽性まで消す事故を、後から気づけるようにするため。
  if [ ${#EXCLUDED_FILES[@]} -gt 0 ]; then
    mkdir -p logs
    EXCLUSION_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$VIOLATION_DETECTED" -eq 1 ]; then
      VERDICT_AFTER_EXCLUSION=1
      FLIPPED_TO_PASS="false"
    else
      VERDICT_AFTER_EXCLUSION=0
      FLIPPED_TO_PASS="true"
    fi
    EXCLUDED_JSON=$(printf '"%s", ' "${EXCLUDED_FILES[@]}")
    EXCLUDED_JSON="[${EXCLUDED_JSON%, }]"
    if [ ${#NON_ALLOWED_FILES[@]} -gt 0 ]; then
      REMAINING_JSON=$(printf '"%s", ' "${NON_ALLOWED_FILES[@]}")
      REMAINING_JSON="[${REMAINING_JSON%, }]"
    else
      REMAINING_JSON="[]"
    fi
    printf '{"timestamp":"%s","task_yaml":"%s","excluded_files":%s,"remaining_violating_files":%s,"verdict_before_exclusion":1,"verdict_after_exclusion":%s,"flipped_to_pass":%s}\n' \
      "$EXCLUSION_TS" "$TASK_YAML" "$EXCLUDED_JSON" "$REMAINING_JSON" "$VERDICT_AFTER_EXCLUSION" "$FLIPPED_TO_PASS" \
      >> logs/scope_check_exclusion_effect.jsonl
  fi

  if [ "$VIOLATION_DETECTED" -eq 1 ]; then
    echo "Violation detected: The following files are changed but not in allowed_paths:" >&2
    for f in "${NON_ALLOWED_FILES[@]}"; do
      echo "- $f" >&2
    done
    exit 1
  else
    exit 0
  fi
fi

# cmd_086 Part C: fast-lane適用可否判定。既存scope_check.shの通常ロジックとは
# SKIPの扱いが逆(cmd_038 Independent Verification RuleのSKIP=通過とは意図的に逆)。
# 出力(exit code): 0=fast-lane適用可, 1=不可(通常フローへfail-safe)
scope_check_fastlane_eligible() {
    local cmd_yaml="$1"
    local git_baseline="${2:-HEAD}"

    # 条件0(cmd_181-C): features.fastlane_enabledをkillスイッチとして接続。
    # instructions/karo.mdの手順(誤判定1件でfalseへ変更し通常フローへrevert)が
    # 実際に効くよう、pretooluse_git_push_block.sh/pretooluse_staged_ignore_guard.sh
    # と同じgrep-based早期リターン方式を用いる。未知値・空値・欠落は全てfail-safe
    # (通常フローへrevert=不適格)。
    local settings_file raw_line raw_value
    settings_file="${SCOPE_CHECK_FASTLANE_SETTINGS:-$SCRIPT_DIR/../config/settings.yaml}"
    raw_line=$(grep -E '^[[:space:]]*fastlane_enabled:' "$settings_file" 2>/dev/null | head -1)
    raw_value=$(printf '%s' "$raw_line" | sed -E \
        -e 's/^[[:space:]]*fastlane_enabled:[[:space:]]*//' \
        -e 's/[[:space:]]*#.*$//' \
        -e 's/[[:space:]]*$//' \
        -e 's/^"(.*)"$/\1/' \
        -e "s/^'(.*)'\$/\1/")
    [ "$raw_value" != "true" ] && return 1

    # 条件3: 既存scope_check.shのパス許可ロジックをそのまま再利用
    bash "${SCRIPT_DIR}/scope_check.sh" "$cmd_yaml" "$git_baseline"
    local scope_rc=$?
    # 既存は 0=OK/1=違反/2=SKIP。fast-lane判定ではSKIPも「不可」として扱う(安全側)
    [ "$scope_rc" -ne 0 ] && return 1

    # 条件2: 変更ファイルがコード/設定でないこと
    local changed
    changed=$(git diff --name-only "$git_baseline" HEAD 2>/dev/null) || return 1
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in
            *.sh|*.py|*.js|*.ts|*.json|*.yaml|*.yml|config/*|scripts/*|lib/*|.github/*)
                return 1 ;;
        esac
    done <<< "$changed"

    # 条件1: 単一ファイルの単一git操作であること(複数ファイル横断は対象外)
    local n_changed
    n_changed=$(grep -c . <<< "$changed")
    [ "$n_changed" -ne 1 ] && return 1

    return 0
}