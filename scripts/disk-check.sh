#!/bin/bash
# Logs /data usage to disk-status.log on every run; writes an alert line
# (and journalctl warning) when usage exceeds DISK_ALERT_THRESHOLD.
#
# Run on a 15-minute systemd timer (see config/systemd/bsc-disk-check.timer).
set -euo pipefail

# Load .env from the install directory if present.
if [ -f "$(dirname "$0")/../.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$(dirname "$0")/../.env"; set +a
fi

THRESHOLD="${DISK_ALERT_THRESHOLD:-80}"
DATADIR="${DATADIR:-/data/bsc-rpc}"
MOUNT="${MOUNT:-$(df -P "$DATADIR" | awk 'NR==2{print $6}')}"
LOG_DIR="$DATADIR/logs"
ALERT_LOG="$LOG_DIR/disk-alerts.log"
STATUS_LOG="$LOG_DIR/disk-status.log"

mkdir -p "$LOG_DIR"

USE=$(df --output=pcent "$MOUNT" | tail -1 | tr -dc '0-9')
AVAIL=$(df -h --output=avail "$MOUNT" | tail -1 | tr -d ' ')
TS=$(date -u +%FT%TZ)

echo "$TS use=${USE}% avail=$AVAIL mount=$MOUNT" >> "$STATUS_LOG"

if [ "$USE" -ge "$THRESHOLD" ]; then
    MSG="$MOUNT at ${USE}% (avail $AVAIL, threshold ${THRESHOLD}%)"
    logger -t bsc-disk-check -p user.warn "$MSG"
    echo "$TS ALERT: $MSG" >> "$ALERT_LOG"
fi
