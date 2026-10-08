#!/usr/bin/env bash
# dispatch.sh — task YAMLの書込とinbox通知を1コマンドで行う（家老の配信手順の一本化 / cmd_210 E-1）
#
# Usage:
#   bash scripts/dispatch.sh <agent_id> [--cmd_id=<id>] [--task_id=<id>] [--type=<inbox type>] [--message="<本文>"] <<'EOF'
#   task:
#     task_id: ...
#     ...
#   EOF
#
# - <agent_id>: ashigaru1〜7 | gunshi
# - 標準入力 = task YAML本体。書込先は queue/tasks/<agent_id>.yaml
# - 順序は「task YAML書込 → inbox通知」固定（逆順だとwatcherが前タスクのYAMLを足軽に読ませる）
# - 書込前に入力検証（空/YAML構文/トップレベルtask:マップ+task_id/--task_id一致）。違反は何も書かず exit 1
# - 書込は同ディレクトリの一時ファイル→mv で原子的
# - inbox_write.sh が失敗したら exit 非0 + 「YAMLは書込済みだが通知失敗」をstderrに明示（サイレント片側成功を許さない）
# - 送信元(from)は karo 固定。scripts/inbox_write.sh は無改変で呼ぶ
#
# テスト用の差し替え:
#   DISPATCH_ROOT  リポジトリルート（既定=このスクリプトの1つ上）。queue/tasks はここ基準
#   INBOX_WRITE    inbox_write.sh のパス（既定=$DISPATCH_ROOT/scripts/inbox_write.sh）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${DISPATCH_ROOT:-$SCRIPT_DIR}"
INBOX_WRITE="${INBOX_WRITE:-$ROOT/scripts/inbox_write.sh}"
PYTHON="${DISPATCH_PYTHON:-}"
if [ -z "$PYTHON" ]; then
    if [ -x "$ROOT/.venv/bin/python3" ]; then
        PYTHON="$ROOT/.venv/bin/python3"
    else
        PYTHON="python3"
    fi
fi

DEFAULT_MESSAGE="タスクYAMLを読んで作業開始せよ。"
FROM="karo"

die() {
    echo "[dispatch] ERROR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: dispatch.sh <agent_id> [--cmd_id=<id>] [--task_id=<id>] [--type=<inbox type>] [--message=\"<本文>\"] < task.yaml" >&2
}

AGENT_ID=""
ARG_CMD_ID=""
ARG_TASK_ID=""
MSG_TYPE="task_assigned"
MESSAGE="$DEFAULT_MESSAGE"

for arg in "$@"; do
    case "$arg" in
        --cmd_id=*) ARG_CMD_ID="${arg#--cmd_id=}" ;;
        --task_id=*) ARG_TASK_ID="${arg#--task_id=}" ;;
        --type=*) MSG_TYPE="${arg#--type=}" ;;
        --message=*) MESSAGE="${arg#--message=}" ;;
        -h|--help) usage; exit 0 ;;
        --*) usage; die "unknown option: $arg" ;;
        *)
            if [ -n "$AGENT_ID" ]; then
                usage
                die "unexpected extra argument: $arg"
            fi
            AGENT_ID="$arg"
            ;;
    esac
done

if [ -z "$AGENT_ID" ]; then
    usage
    die "agent_id is required"
fi

case "$AGENT_ID" in
    ashigaru[1-7]|gunshi) ;;
    *) die "invalid agent_id '$AGENT_ID' (allowed: ashigaru1-7, gunshi)" ;;
esac

[ -n "$MSG_TYPE" ] || die "--type must not be empty"
[ -n "$MESSAGE" ] || die "--message must not be empty"
# inbox_write.sh は本文を python の '''...''' に直埋めするため ''' を含むと3回失敗する
case "$MESSAGE" in
    *"'''"*) die "--message must not contain ''' (inbox_write.sh embeds it in a python literal)" ;;
esac

TASKS_DIR="$ROOT/queue/tasks"
TARGET="$TASKS_DIR/${AGENT_ID}.yaml"
mkdir -p "$TASKS_DIR" || die "cannot create $TASKS_DIR"

TMP_FILE="$(mktemp "$TASKS_DIR/.dispatch.${AGENT_ID}.XXXXXX")" || die "cannot create temp file in $TASKS_DIR"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

# 標準入力を一時ファイルへ（検証と書込で同一内容を使う）
cat > "$TMP_FILE" || die "failed to read stdin"

if ! grep -q '[^[:space:]]' "$TMP_FILE"; then
    die "stdin is empty (task YAML required); nothing written"
fi

# 検証: YAML構文 / トップレベル task: マップ / task_id。stdoutに task_id と parent_cmd を1行ずつ返す
VALIDATE_OUT="$("$PYTHON" - "$TMP_FILE" <<'PY'
import sys
import yaml

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
except Exception as e:
    print("invalid YAML syntax: %s" % str(e).replace("\n", " "), file=sys.stderr)
    sys.exit(2)
if not isinstance(doc, dict) or not isinstance(doc.get("task"), dict):
    print("top level must be a 'task:' mapping", file=sys.stderr)
    sys.exit(3)
task = doc["task"]
tid = task.get("task_id")
if tid is None or str(tid).strip() == "":
    print("task.task_id is missing", file=sys.stderr)
    sys.exit(4)
pc = task.get("parent_cmd")
print(str(tid).strip())
print("" if pc is None else str(pc).strip())
PY
)" || die "task YAML validation failed (see above); nothing written"

YAML_TASK_ID="$(printf '%s\n' "$VALIDATE_OUT" | sed -n '1p')"
YAML_PARENT_CMD="$(printf '%s\n' "$VALIDATE_OUT" | sed -n '2p')"

if [ -n "$ARG_TASK_ID" ] && [ "$ARG_TASK_ID" != "$YAML_TASK_ID" ]; then
    die "--task_id=$ARG_TASK_ID does not match YAML task_id=$YAML_TASK_ID; nothing written"
fi

CMD_ID="${ARG_CMD_ID:-$YAML_PARENT_CMD}"
TASK_ID="${ARG_TASK_ID:-$YAML_TASK_ID}"

# 原子的書込: 同ディレクトリの一時ファイルを mv（trap の rm -f は mv 後は無害）
chmod 644 "$TMP_FILE" 2>/dev/null || true
mv -f "$TMP_FILE" "$TARGET" || die "failed to move task YAML into place: $TARGET"

# 通知
NOTIFY_ARGS=()
[ -n "$CMD_ID" ] && NOTIFY_ARGS+=("--cmd_id=$CMD_ID")
[ -n "$TASK_ID" ] && NOTIFY_ARGS+=("--task_id=$TASK_ID")

if ! bash "$INBOX_WRITE" "$AGENT_ID" "$MESSAGE" "$MSG_TYPE" "$FROM" "${NOTIFY_ARGS[@]}"; then
    echo "[dispatch] WARNING: task YAMLは書込済みだが通知失敗: inbox_write.shを手動で再実行せよ" >&2
    echo "[dispatch]   task YAML: $TARGET (task_id=$TASK_ID)" >&2
    echo "[dispatch]   retry: bash scripts/inbox_write.sh $AGENT_ID \"$MESSAGE\" $MSG_TYPE $FROM ${NOTIFY_ARGS[*]}" >&2
    exit 2
fi

echo "[dispatch] wrote $TARGET (task_id=$TASK_ID)"
echo "[dispatch] notified $AGENT_ID via inbox_write.sh (type=$MSG_TYPE, cmd_id=${CMD_ID:-none})"
exit 0
