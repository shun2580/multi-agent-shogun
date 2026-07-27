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

# 送信抑止(dry-run)判定 (cmd_119/cmd_117欠陥2):
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
