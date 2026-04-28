#!/bin/bash
# Run this on the Hetzner BSC node AFTER the AWS box is up.
# Adds the Hetzner side of the WireGuard tunnel and opens the firewall
# port for it. Idempotent.
#
# Inputs (env or .env):
#   HETZNER_PRIVATE_KEY    WireGuard private key for THIS box
#   AWS_PUBLIC_KEY         WireGuard public key of the AWS peer
#
# Usage:
#   sudo ./scripts/phase2-setup-hetzner-wg.sh
#
# After this you should be able to:
#   ping 10.0.0.2
#   wg show

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
  set -a; . "$REPO_DIR/.env"; set +a
fi

: "${HETZNER_PRIVATE_KEY:?HETZNER_PRIVATE_KEY missing}"
: "${AWS_PUBLIC_KEY:?AWS_PUBLIC_KEY missing}"

echo "[1/4] apt deps"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq wireguard wireguard-tools

echo "[2/4] WireGuard config at /etc/wireguard/wg0.conf"
sed -e "s|__HETZNER_PRIVATE_KEY__|$HETZNER_PRIVATE_KEY|g" \
    -e "s|__AWS_PUBLIC_KEY__|$AWS_PUBLIC_KEY|g" \
    "$REPO_DIR/config/wireguard/hetzner-wg0.conf.template" \
    > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

echo "[3/4] UFW: open 51820/udp"
ufw allow 51820/udp comment 'wireguard from aws-sg' || true

echo "[4/4] bring up tunnel"
systemctl enable --now wg-quick@wg0
sleep 2
wg show

echo
echo "tunnel up. Test from this box:"
echo "  ping 10.0.0.2"
