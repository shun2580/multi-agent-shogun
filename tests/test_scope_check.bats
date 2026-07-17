#!/usr/bin/env bats

SCOPE_CHECK_SCRIPT="$BATS_TEST_DIRNAME/../scripts/scope_check.sh"

setup() {
  TEST_DIR=$(mktemp -d /tmp/scope_test_XXXXXX)
  cd "$TEST_DIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  touch .gitkeep
  git add .gitkeep
  git commit -q -m "initial"
  BASE_SHA=$(git rev-parse HEAD)
}

teardown() {
  cd /tmp
  rm -rf "$TEST_DIR"
}

@test "Case 1: Violation detected (undeclared file changed, exit 1)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/test_article.md
EOF
  touch undeclared_file.txt
  git add undeclared_file.txt
  git commit -q -m "add undeclared file"

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"undeclared_file.txt"* ]]
}

@test "Case 2: Normal (declared file only, exit 0)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/test_article.md
EOF
  mkdir -p articles
  echo "content" > articles/test_article.md
  git add articles/test_article.md
  git commit -q -m "add declared file"

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Case 3: SKIP (no allowed_paths or target_path, exit 2)" {
  cat > task.yaml <<'EOF'
description: test task
EOF
  touch some_file.txt
  git add some_file.txt
  git commit -q -m "add some file"

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA" 2>&1
  [ "$status" -eq 2 ]
}

# --- cmd_095 Part B: path normalization regression/bugfix cases ---

@test "Case 4 (i): absolute allowed_paths x relative diff (bugfix case, exit 0)" {
  cat > task.yaml <<EOF
allowed_paths:
  - $TEST_DIR/articles/test_article.md
EOF
  mkdir -p articles
  echo "content" > articles/test_article.md
  git add articles/test_article.md
  git commit -q -m "add declared file"

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Case 5 (ii): relative allowed_paths x relative diff (regression check, exit 0)" {
  cat > task.yaml <<'EOF'
allowed_paths:
  - articles/test_article.md
EOF
  mkdir -p articles
  echo "content" > articles/test_article.md
  git add articles/test_article.md
  git commit -q -m "add declared file"

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Case 6 (iii): absolute allowed_paths, comparison consistency (exit 0)" {
  cat > task.yaml <<EOF
allowed_paths:
  - $TEST_DIR/scripts/foo.sh
EOF
  mkdir -p scripts
  echo "#!/bin/bash" > scripts/foo.sh
  git add scripts/foo.sh
  git commit -q -m "add declared script"

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Case 7 (iv): mixed absolute and relative allowed_paths in one YAML (exit 0)" {
  cat > task.yaml <<EOF
allowed_paths:
  - $TEST_DIR/articles/test_article.md
  - scripts/foo.sh
EOF
  mkdir -p articles scripts
  echo "content" > articles/test_article.md
  echo "#!/bin/bash" > scripts/foo.sh
  git add articles/test_article.md scripts/foo.sh
  git commit -q -m "add declared files (mixed notation)"

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA"
  [ "$status" -eq 0 ]
}

@test "Case 8 (v): absolute allowed_paths, undeclared absolute-form file still violates (exit 1)" {
  cat > task.yaml <<EOF
allowed_paths:
  - $TEST_DIR/articles/test_article.md
EOF
  mkdir -p articles
  echo "content" > articles/undeclared.md
  git add articles/undeclared.md
  git commit -q -m "add undeclared file despite absolute allowed_paths"

  run bash "$SCOPE_CHECK_SCRIPT" task.yaml "$BASE_SHA" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"undeclared.md"* ]]
}
