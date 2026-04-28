#!/bin/bash
# rsync the running BSC node's chaindata + configs to a Hetzner Storage Box
# (or any rsync-over-ssh target). Two flavors:
#
#   1. live-rsync:  rsync while geth is running. Fast, weekly. NOT a clean
#      snapshot (open files mid-write); use only as the seed for a future
#      "shutdown-rsync" run.
#
#   2. shutdown-rsync:  systemctl stop bsc, rsync, systemctl start bsc.
#      Downtime = a few minutes (depending on chaindata diff size). Run before
#      destroying the host.
#
# Usage:
#   ./backup-to-storage-box.sh live
#   ./backup-to-storage-box.sh shutdown
#
# Environment (or .env):
#   DATADIR          Default /data/bsc-rpc.
#   SB_USER          Storage box user, e.g. u584696.
#   SB_HOST          e.g. u584696.your-storagebox.de.
#   SB_PORT          Default 23.
#   SB_KEY           SSH key path. Default /root/.ssh/id_ed25519.
#   SB_REMOTE_DIR    Remote dir, default ./bsc-backup.

set -euo pipefail

if [ -f "$(dirname "$0")/../.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$(dirname "$0")/../.env"; set +a
fi

MODE="${1:-live}"
DATADIR="${DATADIR:-/data/bsc-rpc}"
SB_USER="${SB_USER:?set SB_USER (e.g. u584696)}"
SB_HOST="${SB_HOST:?set SB_HOST (e.g. u584696.your-storagebox.de)}"
SB_PORT="${SB_PORT:-23}"
SB_KEY="${SB_KEY:-/root/.ssh/id_ed25519}"
SB_REMOTE_DIR="${SB_REMOTE_DIR:-./bsc-backup}"

RSYNC_SSH="ssh -p $SB_PORT -i $SB_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
RSYNC_OPTS=(-aH --partial --info=progress2 --delete)

remote () {
  rsync "${RSYNC_OPTS[@]}" -e "$RSYNC_SSH" "$@"
}

case "$MODE" in
  live)
    echo "[live] rsync chaindata while geth is running (NOT a clean snapshot)"
    remote "$DATADIR/node/geth/" "${SB_USER}@${SB_HOST}:${SB_REMOTE_DIR}/geth/"
    remote "$DATADIR/config/"     "${SB_USER}@${SB_HOST}:${SB_REMOTE_DIR}/config/"
    remote "$DATADIR/scripts/"    "${SB_USER}@${SB_HOST}:${SB_REMOTE_DIR}/scripts/"
    ;;
  shutdown)
    echo "[shutdown] stopping bsc.service for clean rsync"
    systemctl stop bsc.service
    trap 'systemctl start bsc.service' EXIT
    remote "$DATADIR/node/geth/" "${SB_USER}@${SB_HOST}:${SB_REMOTE_DIR}/geth/"
    remote "$DATADIR/config/"     "${SB_USER}@${SB_HOST}:${SB_REMOTE_DIR}/config/"
    remote "$DATADIR/scripts/"    "${SB_USER}@${SB_HOST}:${SB_REMOTE_DIR}/scripts/"
    echo "[shutdown] backup complete; restarting bsc.service"
    ;;
  *)
    echo "usage: $0 {live|shutdown}"
    exit 2
    ;;
esac
