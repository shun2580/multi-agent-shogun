#!/usr/bin/env bash
# SayTask通知 — ntfy.sh経由でスマホにプッシュ通知
# FR-066: ntfy認証対応 (Bearer token / Basic auth)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"

# ntfy_auth.sh読み込み
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

TOPIC=$(grep 'ntfy_topic:' "$SETTINGS" | awk '{print $2}' | tr -d '"')
if [ -z "$TOPIC" ]; then
  echo "ntfy_topic not configured in settings.yaml" >&2
  exit 1
fi

# 送信抑止(dry-run)判定 (cmd_119/cmd_117欠陥2、cmd_122で設計反転):
# - 明示指定: NTFY_DRY_RUN=1 (または true)
# - 既存の隔離テスト環境マーカーを継承した場合の自動抑止
#   (preflight_check.sh/inbox_watcher.shのテストが実プロセスとして本スクリプトを
#    起動すると、export済みのこれらの変数は子プロセスへそのまま継承される)
DRY_RUN=0
case "${NTFY_DRY_RUN:-}" in
  1|true|TRUE|True) DRY_RUN=1 ;;
esac
if [ "${__PREFLIGHT_TESTING__:-}" = "1" ] || [ "${__INBOX_WATCHER_TESTING__:-}" = "1" ]; then
  DRY_RUN=1
fi

# cmd_122: 実行コンテキスト判定(列挙方式→既定抑止方式への反転)。
# 背景: 上記のマーカー列挙方式は、マーカーを立てない新しいテスト経路が
# 増えるたびに既定で漏れる。実例: yaml_guardの隔離セッション試験(mktemp -dで
# 作った一時プロジェクトへcdして実行)がどちらのマーカーも立てないまま
# 本番のscripts/ntfy.shを直接叩き、fail-open警報が本番ntfyトピックへ実送信
# された(2026-07-27 21:53、logs/ntfy.log参照)。この試験ではNTFY_SCRIPT自体は
# 常に本番リポジトリ実体を指す(pretooluse_yaml_guard.shのSCRIPT_DIRはBASH_SOURCE
# 由来で不変)ため、ntfy.sh自身の設置場所チェックでは検知できない。異常の実体は
# 「呼び出し元のカレントディレクトリが本番リポジトリの外にある」ことなので、
# 判定基準もそこに置く: CWDが本番リポジトリ(SCRIPT_DIR)配下でなければ、
# マーカーの有無を問わず既定でdry-runとする(列挙方式→包含方式への反転)。
CALLER_CWD="$(pwd)"
case "$CALLER_CWD" in
  "$SCRIPT_DIR"|"$SCRIPT_DIR"/*) ;;
  *) DRY_RUN=1 ;;
esac

# 認証引数を取得（設定がなければ空 = 後方互換）
AUTH_ARGS=()
while IFS= read -r line; do
    [ -n "$line" ] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

LOG_FILE="$SCRIPT_DIR/logs/ntfy.log"
mkdir -p "$SCRIPT_DIR/logs"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
MSG_SUMMARY="${1:0:80}"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$TIMESTAMP] DRY-RUN (no send) topic=$TOPIC msg=$MSG_SUMMARY" >> "$LOG_FILE"
    exit 0
fi

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "${AUTH_ARGS[@]}" \
    -H "Tags: outbound" \
    -d "$1" \
    "https://ntfy.sh/$TOPIC" 2>/dev/null)
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
    echo "[$TIMESTAMP] FAIL (curl error=$CURL_EXIT) topic=$TOPIC msg=$MSG_SUMMARY" >> "$LOG_FILE"
    echo "ntfy送信失敗: curl exit=$CURL_EXIT" >&2
    exit 1
fi

if [[ "$HTTP_STATUS" != 2* ]]; then
    echo "[$TIMESTAMP] FAIL (HTTP $HTTP_STATUS) topic=$TOPIC msg=$MSG_SUMMARY" >> "$LOG_FILE"
    echo "ntfy送信失敗: HTTP status=$HTTP_STATUS" >&2
    exit 1
fi

echo "[$TIMESTAMP] OK (HTTP $HTTP_STATUS) topic=$TOPIC msg=$MSG_SUMMARY" >> "$LOG_FILE"
