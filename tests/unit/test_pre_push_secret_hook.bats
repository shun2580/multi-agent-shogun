#!/usr/bin/env bats
# cmd_213: scripts/githooks/pre-push (置場の値照合) のテスト。
# 値はすべてダミー。実際の秘匿値・実置場(~/.config/multi-agent-shogun)には一切触れない。

DUMMY_TOPIC="dummy-topic-value-0123456789"
DUMMY_TOKEN="dummy-token-abcdefghij"

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HOOK_DIR="$PROJECT_ROOT/scripts/githooks"
    T="$BATS_TEST_TMPDIR"
    export SHOGUN_SECRETS_FILE="$T/secrets.env"
    cat > "$SHOGUN_SECRETS_FILE" <<EOF
# dummy secrets for pre-push hook test
NTFY_TOPIC=$DUMMY_TOPIC
API_TOKEN="$DUMMY_TOKEN"
EOF
    REMOTE="$T/remote.git"
    WORK="$T/work"
    git init -q --bare "$REMOTE"
    git init -q -b main "$WORK"
    git -C "$WORK" config user.email "test@example.com"
    git -C "$WORK" config user.name "Test User"
    git -C "$WORK" config core.hooksPath "$HOOK_DIR"
    git -C "$WORK" remote add origin "$REMOTE"
    echo "base" > "$WORK/base.txt"
    git -C "$WORK" add base.txt
    git -C "$WORK" commit -q -m "base"
    git -C "$WORK" push -q origin main
}

commit_file() { # $1=file $2=content $3=message
    printf '%s\n' "$2" > "$WORK/$1"
    git -C "$WORK" add -- "$1"
    git -C "$WORK" commit -q -m "${3:-add $1}"
}

# テスト内の準備用: hook を通さずに push する(過去に公開済みの履歴を再現するため)
push_nohook() {
    git -C "$WORK" -c core.hooksPath=/dev/null push -q "$@"
}

@test "1) 値を含まないcommitは通過する" {
    commit_file a.txt "hello world" "add a"
    run git -C "$WORK" push origin main
    [ "$status" -eq 0 ]
    [ "$(git -C "$REMOTE" rev-parse main)" = "$(git -C "$WORK" rev-parse HEAD)" ]
}

@test "2) 追加行にダミー値があれば拒否し、鍵名とcommit idを出し値は出さない" {
    commit_file secret.txt "topic is $DUMMY_TOPIC here" "add config"
    sha="$(git -C "$WORK" rev-parse HEAD)"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC"* ]]
    [[ "$output" == *"${sha:0:12}"* ]]
    [[ "$output" == *"secret.txt:1"* ]]
    [[ "$output" == *"git rebase -i"* ]]
    run grep -c -F "$DUMMY_TOPIC" <<< "$output"
    [ "$output" = "0" ]
    # remote は更新されていない
    [ "$(git -C "$REMOTE" rev-parse main)" != "$sha" ]
}

@test "3) コミットメッセージにダミー値があれば拒否する" {
    commit_file b.txt "clean" "note: $DUMMY_TOKEN leaked"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"API_TOKEN"* ]]
    [[ "$output" == *"commit message"* ]]
    run grep -c -F "$DUMMY_TOKEN" <<< "$output"
    [ "$output" = "0" ]
}

@test "4) ファイル名にダミー値があれば拒否し、パス自体は出力しない" {
    commit_file "name-$DUMMY_TOPIC.txt" "clean content" "add file"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC"* ]]
    [[ "$output" == *"file path"* ]]
    run grep -c -F "$DUMMY_TOPIC" <<< "$output"
    [ "$output" = "0" ]
}

@test "4b) 追加行にも値がある場合、パスに値が含まれるときは withheld 表示でパスを出さない" {
    commit_file "name-$DUMMY_TOPIC.txt" "x $DUMMY_TOPIC" "add file"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"path withheld"* ]]
    run grep -c -F "$DUMMY_TOPIC" <<< "$output"
    [ "$output" = "0" ]
}

@test "5a) 新規ブランチpushでも値入りcommitは拒否される" {
    git -C "$WORK" checkout -q -b feature
    commit_file c.txt "$DUMMY_TOPIC" "add c"
    run git -C "$WORK" push origin feature
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC"* ]]
    run git -C "$REMOTE" rev-parse --verify -q refs/heads/feature
    [ "$status" -ne 0 ]
}

@test "5b) 新規ブランチpushでクリーンなら通過する" {
    git -C "$WORK" checkout -q -b feature
    commit_file c.txt "clean" "add c"
    run git -C "$WORK" push origin feature
    [ "$status" -eq 0 ]
    git -C "$REMOTE" rev-parse --verify -q refs/heads/feature
}

@test "6) 過去にpush済みのcommitに値があっても、新たな範囲に無ければ通過する" {
    commit_file old.txt "legacy $DUMMY_TOPIC" "old leak"
    push_nohook origin main
    commit_file new.txt "clean" "new clean"
    run git -C "$WORK" push origin main
    [ "$status" -eq 0 ]
}

@test "6b) 過去にpush済みの値入りcommitがあっても、そこから切った新規ブランチのクリーンなcommitは通過する" {
    commit_file old.txt "legacy $DUMMY_TOPIC" "old leak"
    push_nohook origin main
    git -C "$WORK" fetch -q origin
    git -C "$WORK" checkout -q -b feature
    commit_file new.txt "clean" "new clean"
    run git -C "$WORK" push origin feature
    [ "$status" -eq 0 ]
}

@test "7) 置場が無ければ拒否し、置場を作る手順を出す" {
    export SHOGUN_SECRETS_FILE="$T/not-exist.env"
    commit_file a.txt "clean" "add a"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"置場を作る"* ]]
    [[ "$output" == *"secrets.env"* ]]
}

@test "7b) 置場に照合可能な値が1件も無ければ拒否する" {
    printf 'SHORT=abc\n# only comment\n\nEMPTY=\n' > "$SHOGUN_SECRETS_FILE"
    commit_file a.txt "clean" "add a"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"照合可能な値"* ]]
}

@test "8) 空値・短い値・コメント行は無視され、正規の値だけが効く" {
    cat > "$SHOGUN_SECRETS_FILE" <<EOF
# comment line
EMPTY=
SHORT=abc
export QUOTED='$DUMMY_TOKEN'

NTFY_TOPIC=$DUMMY_TOPIC
EOF
    commit_file a.txt "abc EMPTY SHORT comment" "mention abc and EMPTY"
    run git -C "$WORK" push origin main
    [ "$status" -eq 0 ]
    commit_file b.txt "tok $DUMMY_TOKEN" "add b"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"QUOTED"* ]]
}

@test "8b) 行末コメント付きの引用符なし値も、コメント抜きの値で照合される" {
    printf 'NTFY_TOPIC=%s # my topic\n' "$DUMMY_TOPIC" > "$SHOGUN_SECRETS_FILE"
    commit_file a.txt "$DUMMY_TOPIC" "add a"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC"* ]]
}

@test "8c) CRLFの置場でも値が効く" {
    printf 'NTFY_TOPIC=%s\r\n' "$DUMMY_TOPIC" > "$SHOGUN_SECRETS_FILE"
    commit_file a.txt "$DUMMY_TOPIC" "add a"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC"* ]]
}

@test "9) 複数refのpush: 値入りが1つでもあれば全体を拒否し、該当commitだけ示す" {
    git -C "$WORK" checkout -q -b clean-branch
    commit_file a.txt "clean" "clean one"
    clean_sha="$(git -C "$WORK" rev-parse HEAD)"
    git -C "$WORK" checkout -q main
    commit_file b.txt "$DUMMY_TOPIC" "dirty one"
    dirty_sha="$(git -C "$WORK" rev-parse HEAD)"
    run git -C "$WORK" push origin main clean-branch
    [ "$status" -ne 0 ]
    [[ "$output" == *"${dirty_sha:0:12}"* ]]
    [[ "$output" != *"${clean_sha:0:12}"* ]]
    run grep -c -F "$DUMMY_TOPIC" <<< "$output"
    [ "$output" = "0" ]
}

@test "9b) 複数ref: すべてクリーンなら通過する" {
    git -C "$WORK" checkout -q -b clean-branch
    commit_file a.txt "clean" "clean one"
    git -C "$WORK" checkout -q main
    commit_file b.txt "clean too" "clean two"
    run git -C "$WORK" push origin main clean-branch
    [ "$status" -eq 0 ]
}

@test "9c) 複数commitのうち途中のcommitだけが値入りでも検出する" {
    commit_file a.txt "clean" "c1"
    commit_file b.txt "$DUMMY_TOPIC" "c2 dirty"
    mid_sha="$(git -C "$WORK" rev-parse HEAD)"
    commit_file c.txt "clean again" "c3"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"${mid_sha:0:12}"* ]]
}

@test "10) worktree: core.hooksPath 相対設定で main/worktree 双方に効く" {
    # hook を作業リポジトリに追跡させ、相対パス scripts/githooks で導入する
    mkdir -p "$WORK/scripts/githooks"
    cp "$HOOK_DIR/pre-push" "$WORK/scripts/githooks/pre-push"
    chmod 755 "$WORK/scripts/githooks/pre-push"
    git -C "$WORK" add scripts/githooks/pre-push
    git -C "$WORK" commit -q -m "add hook"
    git -C "$WORK" config core.hooksPath scripts/githooks
    git -C "$WORK" push -q origin main

    # (a) main 側
    commit_file m.txt "$DUMMY_TOPIC" "dirty on main"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC"* ]]
    git -C "$WORK" reset -q --hard HEAD~1

    # (b) worktree 側
    WT="$T/wt"
    git -C "$WORK" worktree add -q "$WT" -b wt-branch
    printf '%s\n' "$DUMMY_TOKEN" > "$WT/w.txt"
    git -C "$WT" add w.txt
    git -C "$WT" commit -q -m "dirty in worktree"
    run git -C "$WT" push origin wt-branch
    [ "$status" -ne 0 ]
    [[ "$output" == *"API_TOKEN"* ]]
    run grep -c -F "$DUMMY_TOKEN" <<< "$output"
    [ "$output" = "0" ]

    # (c) worktree 側でクリーンなら通過
    git -C "$WT" reset -q --hard HEAD~1
    printf 'clean\n' > "$WT/w2.txt"
    git -C "$WT" add w2.txt
    git -C "$WT" commit -q -m "clean in worktree"
    run git -C "$WT" push origin wt-branch
    [ "$status" -eq 0 ]
}

@test "11) 拒否時の出力全体にダミー値が1文字列も含まれない(メッセージ・パス・追加行・複数鍵)" {
    printf '%s %s\n' "$DUMMY_TOPIC" "$DUMMY_TOKEN" > "$WORK/both-$DUMMY_TOPIC.txt"
    git -C "$WORK" add --all -- .
    git -C "$WORK" commit -q -m "leak $DUMMY_TOPIC and $DUMMY_TOKEN"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC"* ]]
    [[ "$output" == *"API_TOKEN"* ]]
    printf '%s\n' "$output" > "$T/out.txt"
    printf '%s\n%s\n' "$DUMMY_TOPIC" "$DUMMY_TOKEN" > "$T/vals.txt"
    run grep -c -F -f "$T/vals.txt" "$T/out.txt"
    [ "$output" = "0" ]
}

@test "12) ref削除のpushは通過する" {
    git -C "$WORK" checkout -q -b tmp-branch
    commit_file a.txt "clean" "c"
    git -C "$WORK" push -q origin tmp-branch
    git -C "$WORK" checkout -q main
    run git -C "$WORK" push origin --delete tmp-branch
    [ "$status" -eq 0 ]
}

@test "13) 注釈付きtagのメッセージに値があれば拒否する" {
    git -C "$WORK" tag -a v1 -m "release $DUMMY_TOPIC"
    run git -C "$WORK" push origin v1
    [ "$status" -ne 0 ]
    [[ "$output" == *"tag object"* ]]
    run grep -c -F "$DUMMY_TOPIC" <<< "$output"
    [ "$output" = "0" ]
}

@test "14) mergeコミットの衝突解決に混入した値も検出する(取り込み側の履歴は責めない)" {
    git -C "$WORK" checkout -q -b side
    commit_file conflict.txt "side" "side change"
    git -C "$WORK" checkout -q main
    commit_file conflict.txt "main" "main change"
    git -C "$WORK" push -q origin main
    run git -C "$WORK" merge side
    [ "$status" -ne 0 ]
    printf 'resolved %s\n' "$DUMMY_TOPIC" > "$WORK/conflict.txt"
    git -C "$WORK" add conflict.txt
    git -C "$WORK" commit -q -m "merge side"
    run git -C "$WORK" push origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC"* ]]
}

@test "14b) 公開済みの値入り履歴を取り込むだけのmergeは責めない" {
    git -C "$WORK" checkout -q -b side
    commit_file old.txt "legacy $DUMMY_TOPIC" "old leak"
    push_nohook origin side
    git -C "$WORK" checkout -q main
    commit_file other.txt "clean" "main work"
    git -C "$WORK" merge -q --no-ff side -m "merge side"
    run git -C "$WORK" push origin main
    [ "$status" -eq 0 ]
}

@test "15) hook は bash -n を通り実行権限を持つ" {
    run bash -n "$HOOK_DIR/pre-push"
    [ "$status" -eq 0 ]
    [ -x "$HOOK_DIR/pre-push" ]
    [ "$(head -1 "$HOOK_DIR/pre-push")" = "#!/usr/bin/env bash" ]
}

@test "16) hook は git のインデックス上で実行権限(100755)を持つ" {
    # core.fileMode=false(WSL等)では作業ツリーの mode が 755 でも tree は 100644 になり得る。
    # tree が 644 だと ff で取り込んだ先で git が hook を黙って無視する。作業ツリーの mode
    # ではなく git の記録(ls-files -s)を見る。skip しない: git 管理下でなければ明示的に fail。
    run git -C "$PROJECT_ROOT" rev-parse --show-toplevel
    if [ "$status" -ne 0 ] || [ "$output" != "$PROJECT_ROOT" ]; then
        echo "git 管理下(リポジトリ根=$PROJECT_ROOT)でないため mode を検証できない。git clone / worktree 上で実行せよ" >&2
        return 1
    fi
    run git -C "$PROJECT_ROOT" ls-files -s -- scripts/githooks/pre-push
    [ "$status" -eq 0 ]
    [ -n "$output" ] || { echo "scripts/githooks/pre-push が git に追跡されていない" >&2; return 1; }
    [[ "$output" == 100755\ * ]] || { echo "git tree 上の mode が 100755 でない: ${output%% *}" >&2; return 1; }
}
