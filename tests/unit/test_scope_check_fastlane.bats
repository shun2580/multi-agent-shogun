#!/usr/bin/env bats
# cmd_086 Part C: scope_check_fastlane_eligible() のテスト
# (軍師design item3準拠、tests/test_scope_check.batsの慣習に倣う)

setup() {
  TEST_DIR=$(mktemp -d /tmp/scope_fastlane_test_XXXXXX)
  cd "$TEST_DIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  touch .gitkeep
  git add .gitkeep
  git commit -q -m "initial"
  BASE_SHA=$(git rev-parse HEAD)

  SCOPE_CHECK_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/scope_check.sh"
  REAL_SCRIPT_DIR="$(dirname "$SCOPE_CHECK_SCRIPT")"

  # scope_check.sh のメイン処理部は必ず exit で終了するため、そのまま source すると
  # scope_check_fastlane_eligible() に到達する前にプロセスが終了してしまう。
  # そのため関数定義だけを sed で抽出し、bash -c 内で再定義して呼び出す。
  FASTLANE_FUNC=$(sed -n '/^scope_check_fastlane_eligible()/,/^}/p' "$SCOPE_CHECK_SCRIPT")

  # cmd_181-C: fastlane_enabled flag読取の追加により、既存テスト(条件0以外を
  # 検証する組1〜4)が本番config/settings.yamlの実値に左右されないよう、
  # デフォルトでflag=trueの一時設定ファイルを用意する(run_fastlaneの3引数目を
  # 省略した場合はこれを使う)。
  DEFAULT_FASTLANE_SETTINGS="$TEST_DIR/settings_fastlane_enabled_true.yaml"
  printf 'features:\n  fastlane_enabled: true\n' > "$DEFAULT_FASTLANE_SETTINGS"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_DIR"
}

run_fastlane() {
  local cmd_yaml="$1"
  local git_baseline="$2"
  local fastlane_settings="${3:-$DEFAULT_FASTLANE_SETTINGS}"
  run bash -c "SCRIPT_DIR='$REAL_SCRIPT_DIR'
SCOPE_CHECK_FASTLANE_SETTINGS='$fastlane_settings'
$FASTLANE_FUNC
scope_check_fastlane_eligible '$cmd_yaml' '$git_baseline'"
}

# --- 組1: 単一ドキュメントファイル ---

@test "Group1-OK: single doc file (articles/foo.md) only → fast-lane applicable (exit 0)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/foo.md
EOF
  mkdir -p articles
  echo "content" > articles/foo.md
  git add articles/foo.md
  git commit -q -m "add doc"

  run_fastlane task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Group1-NG: doc + code file changed together → code detected, fast-lane blocked (exit 1)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/foo.md
  - scripts/foo.sh
EOF
  mkdir -p articles scripts
  echo "content" > articles/foo.md
  echo "#!/bin/bash" > scripts/foo.sh
  git add articles/foo.md scripts/foo.sh
  git commit -q -m "add doc and code"

  run_fastlane task.yaml "$BASE_SHA"
  [ "$status" -eq 1 ]
}

# --- 組2: ファイル数条件(単一ファイルのみ許可) ---

@test "Group2-OK: single file (dashboard.md) only → fast-lane applicable (exit 0)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - dashboard.md
EOF
  echo "status" > dashboard.md
  git add dashboard.md
  git commit -q -m "update dashboard"

  run_fastlane task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Group2-NG: dashboard.md + queue/reports/x.yaml (2 files, both look safe) → blocked for multi-file crossing (exit 1)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - dashboard.md
  - queue/reports/x.yaml
EOF
  mkdir -p queue/reports
  echo "status" > dashboard.md
  echo "report: ok" > queue/reports/x.yaml
  git add dashboard.md queue/reports/x.yaml
  git commit -q -m "update dashboard and report"

  run_fastlane task.yaml "$BASE_SHA"
  [ "$status" -eq 1 ]
}

# --- 組3: 設定ファイルの除外(単一ファイルでも拡張子/パスで判定) ---

@test "Group3-OK: single doc file (articles/2026-review.md) only → fast-lane applicable (exit 0)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/2026-review.md
EOF
  mkdir -p articles
  echo "review" > articles/2026-review.md
  git add articles/2026-review.md
  git commit -q -m "add review article"

  run_fastlane task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Group3-NG: single config file (config/settings.yaml) → blocked despite being a single file (exit 1)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - config/settings.yaml
EOF
  mkdir -p config
  echo "key: value" > config/settings.yaml
  git add config/settings.yaml
  git commit -q -m "update settings"

  run_fastlane task.yaml "$BASE_SHA"
  [ "$status" -eq 1 ]
}

# --- 組4: スコープ外・SKIPの安全側変換(cmd_038との非対称性) ---

@test "Group4-NG-a: change outside allowed_paths → underlying scope_check.sh exit 1 propagates (exit 1)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/allowed.md
EOF
  echo "content" > undeclared.md
  git add undeclared.md
  git commit -q -m "add undeclared file"

  run_fastlane task.yaml "$BASE_SHA"
  [ "$status" -eq 1 ]
}

@test "Group4-NG-b: invalid git_baseline → underlying scope_check.sh SKIP(exit 2) is converted to fast-lane exit 1 (intentionally asymmetric to cmd_038 Independent Verification Rule, where SKIP=pass)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/foo.md
EOF
  mkdir -p articles
  echo "content" > articles/foo.md
  git add articles/foo.md
  git commit -q -m "add doc"

  run_fastlane task.yaml "invalid_sha_that_does_not_exist"
  [ "$status" -eq 1 ]
}

# --- 組5(cmd_181-C): features.fastlane_enabled killスイッチの接続確認 ---

@test "Group5-i: fastlane_enabled=false blocks an otherwise-eligible single doc file change (exit 1, kill-switch works)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/foo.md
EOF
  mkdir -p articles
  echo "content" > articles/foo.md
  git add articles/foo.md
  git commit -q -m "add doc"

  FALSE_SETTINGS="$TEST_DIR/settings_fastlane_enabled_false.yaml"
  printf 'features:\n  fastlane_enabled: false\n' > "$FALSE_SETTINGS"

  run_fastlane task.yaml "$BASE_SHA" "$FALSE_SETTINGS"
  [ "$status" -eq 1 ]
}

@test "Group5-ii: fastlane_enabled=true preserves existing eligible verdict for the same single doc file change (exit 0)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/foo.md
EOF
  mkdir -p articles
  echo "content" > articles/foo.md
  git add articles/foo.md
  git commit -q -m "add doc"

  TRUE_SETTINGS="$TEST_DIR/settings_fastlane_enabled_true_explicit.yaml"
  printf 'features:\n  fastlane_enabled: true\n' > "$TRUE_SETTINGS"

  run_fastlane task.yaml "$BASE_SHA" "$TRUE_SETTINGS"
  [ "$status" -eq 0 ]
}
