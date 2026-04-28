#!/bin/bash
# Streams a BSC pruned snapshot through a FIFO into lz4 -> tar without ever
# storing the multi-TB compressed file on disk.
#
# Why this exists:
#   - The current BSC pruned PBSS snapshot is ~1.5 TB compressed in a single
#     .tar.lz4 file. On a 1.7-1.8 TB disk you cannot store the compressed file
#     AND its extraction simultaneously.
#   - Cloudflare R2 (where BNB Chain hosts the snapshots) closes long single
#     transfers after a while. We saw the connection drop every 30-60 GB.
#
# How this works:
#   - A FIFO is opened with `lz4 -d - | tar --strip-components=2 -xf -` on the
#     read side and a write FD held open by this script on the write side.
#   - A loop runs curl with `Range: bytes=$OFFSET-`. When R2 drops the
#     connection, curl exits non-zero, the loop increments OFFSET by however
#     many bytes were received, and a new curl picks up where we left off.
#   - Because the script keeps the FIFO writer FD open across iterations, lz4
#     never sees EOF and the extraction pipeline keeps running unbroken.
#
# Usage:
#   ./download-snapshot.sh
#   (reads BASE_URL, BLOCKS_URL, DATADIR, LOGDIR from env or .env)
#
# To pick a fresh snapshot URL: see https://github.com/bnb-chain/bsc-snapshots
# Read the latest CSV under dist/ for filenames, sizes, and md5 checksums.

set -uo pipefail

# Load .env if present (for DATADIR etc).
if [ -f "$(dirname "$0")/../.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$(dirname "$0")/../.env"; set +a
fi

DATADIR="${DATADIR:-/data/bsc-rpc}/node"
LOGDIR="${LOGDIR:-${DATADIR%/node}/logs}"
BASE_URL="${BASE_URL:-https://pub-c0627345c16f47ab858c9469133073a8.r2.dev/mainnet-geth-pbss-base-90778787.tar.lz4}"
BLOCKS_URL="${BLOCKS_URL:-https://pub-c0627345c16f47ab858c9469133073a8.r2.dev/mainnet-geth-pbss-blocks-pruneancient-90688787.tar.lz4}"
FIFO=/tmp/bsc-snap.fifo
SIZE_FILE=/tmp/bsc-snap.bytes

mkdir -p "$LOGDIR"
exec >>"$LOGDIR/snapshot_download.log" 2>&1
echo
echo "=== $(date -u +%FT%TZ) snapshot stream begin ==="
df -h "$(dirname "$DATADIR")" || true

if [ -d "$DATADIR/geth" ] && [ "$(ls -A "$DATADIR/geth" 2>/dev/null)" ]; then
  echo "Removing pre-existing $DATADIR/geth before stream extract..."
  rm -rf "$DATADIR/geth"
fi
mkdir -p "$DATADIR"

stream_url () {
  local url="$1" total offset attempt got curl_exit
  total=$(curl -sLI "$url" | awk -v IGNORECASE=1 '/^[Cc]ontent-[Ll]ength:/{gsub(/\r/,""); print $2}' | tail -1)
  if [ -z "${total:-}" ]; then echo "ERR: could not fetch Content-Length for $url"; return 1; fi
  echo "url=$url"
  echo "total_bytes=$total"

  rm -f "$FIFO" "$SIZE_FILE"
  mkfifo "$FIFO"

  ( lz4 -d - < "$FIFO" | tar --strip-components=2 -xf - -C "$DATADIR" ; echo "extractor_exit=$?" ) &
  local extract_pid=$!

  exec 3>"$FIFO"
  offset=0
  attempt=0
  while [ "$offset" -lt "$total" ]; do
    attempt=$((attempt+1))
    echo "$(date -u +%FT%TZ) attempt=$attempt offset=$offset/$total ($((offset*100/total))%)"
    curl --silent --fail --location \
         --connect-timeout 30 \
         --max-time 0 \
         --header "Range: bytes=${offset}-" \
         -o /dev/fd/3 \
         -w '%{size_download}' \
         "$url" > "$SIZE_FILE"
    curl_exit=$?
    got=$(cat "$SIZE_FILE" 2>/dev/null || echo 0)
    got=${got:-0}
    offset=$((offset + got))
    echo "$(date -u +%FT%TZ) curl_exit=$curl_exit got=$got new_offset=$offset"
    if [ "$offset" -ge "$total" ]; then break; fi
    if [ "$got" -eq 0 ]; then
      echo "no progress this attempt; sleeping 15s before retry"
      sleep 15
    else
      sleep 3
    fi
  done
  exec 3>&-

  echo "wait extractor pid=$extract_pid"
  wait "$extract_pid"
  local ec=$?
  echo "extractor wait exit=$ec"
  rm -f "$FIFO" "$SIZE_FILE"
  return $ec
}

echo "[1/2] base state"
stream_url "$BASE_URL" || { echo "FATAL: base stream failed"; exit 1; }
df -h "$(dirname "$DATADIR")" || true

echo "[2/2] blocks"
stream_url "$BLOCKS_URL" || { echo "FATAL: blocks stream failed"; exit 1; }

echo "=== $(date -u +%FT%TZ) snapshot stream done ==="
df -h "$(dirname "$DATADIR")" || true
ls -la "$DATADIR/geth" | head -20
touch "$DATADIR/.snapshot-complete"
