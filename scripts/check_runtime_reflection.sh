#!/bin/bash
# check_runtime_reflection.sh <PID> <検索文字列> [--fd=<N>(既定255)] [--min-count=<N>(既定1)]
#
# /proc/<PID>/fd/<N> 経由で、稼働中プロセスに変更内容が反映済みかを確認する。
# 出力: REFLECTED / NOT_REFLECTED / UNKNOWN のいずれか1行。
# 終了コード: REFLECTED=0 NOT_REFLECTED=1 UNKNOWN=2
set -u

PID=""
SEARCH=""
FD=255
MIN_COUNT=1

for arg in "$@"; do
  case "$arg" in
    --fd=*)
      FD="${arg#--fd=}"
      ;;
    --min-count=*)
      MIN_COUNT="${arg#--min-count=}"
      ;;
    *)
      if [ -z "$PID" ]; then
        PID="$arg"
      elif [ -z "$SEARCH" ]; then
        SEARCH="$arg"
      fi
      ;;
  esac
done

if [ -z "$PID" ] || [ -z "$SEARCH" ]; then
  echo "UNKNOWN"
  echo "usage: check_runtime_reflection.sh <PID> <検索文字列> [--fd=<N>] [--min-count=<N>]" >&2
  exit 2
fi

FD_PATH="/proc/$PID/fd/$FD"

if ! [ -e "/proc/$PID" ]; then
  echo "UNKNOWN"
  echo "error: PID $PID not found" >&2
  exit 2
fi

if ! [ -e "$FD_PATH" ]; then
  echo "UNKNOWN"
  echo "error: fd $FD not found for PID $PID" >&2
  exit 2
fi

LS_OUT=$(ls -la "$FD_PATH" 2>&1)
if echo "$LS_OUT" | grep -q "(deleted)"; then
  DELETED_STATE="deleted"
else
  DELETED_STATE="not_deleted"
fi
echo "info: fd_state=$DELETED_STATE ($LS_OUT)" >&2

COUNT=$(grep -c "$SEARCH" "$FD_PATH" 2>/dev/null)
if [ -z "$COUNT" ]; then
  echo "UNKNOWN"
  echo "error: grep against $FD_PATH failed" >&2
  exit 2
fi

if [ "$COUNT" -ge "$MIN_COUNT" ]; then
  echo "REFLECTED"
  exit 0
else
  echo "NOT_REFLECTED"
  exit 1
fi
