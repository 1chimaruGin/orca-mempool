#!/bin/bash
# Run this on a fresh AWS Lightsail / EC2 Singapore Ubuntu 24.04 instance.
# Brings up WireGuard + nginx tx-submit relay. Requires you to have already
# generated keypairs and edited config/wireguard/aws-wg0.conf.template.
#
# Inputs (env vars or .env):
#   AWS_PRIVATE_KEY        WireGuard private key for THIS box
#   HETZNER_PUBLIC_KEY     WireGuard public key of the Hetzner peer
#   HETZNER_PUBLIC_IP      Public IPv4 of the Hetzner box
#   API_KEY                Same X-API-Key the bot uses on the Hetzner relay
#                          (so the AWS relay enforces the same auth)
#
# Usage:
#   git clone git@github.com:1chimaruGin/orca-mempool.git
#   cd orca-mempool
#   cp .env.example .env && $EDITOR .env  # set the four vars above
#   sudo ./scripts/phase2-setup-aws-relay.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
  set -a; . "$REPO_DIR/.env"; set +a
fi

: "${AWS_PRIVATE_KEY:?AWS_PRIVATE_KEY missing}"
: "${HETZNER_PUBLIC_KEY:?HETZNER_PUBLIC_KEY missing}"
: "${HETZNER_PUBLIC_IP:?HETZNER_PUBLIC_IP missing}"
: "${API_KEY:?API_KEY missing}"

echo "[1/5] apt deps"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools nginx ufw curl jq

echo "[2/5] WireGuard config"
sed -e "s|__AWS_PRIVATE_KEY__|$AWS_PRIVATE_KEY|g" \
    -e "s|__HETZNER_PUBLIC_KEY__|$HETZNER_PUBLIC_KEY|g" \
    -e "s|__HETZNER_PUBLIC_IP__|$HETZNER_PUBLIC_IP|g" \
    "$REPO_DIR/config/wireguard/aws-wg0.conf.template" \
    > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
sleep 2
echo "  wg state:"
wg show

echo "[3/5] nginx tx-submit relay"
sed -e "s|__API_KEY__|$API_KEY|g" \
    "$REPO_DIR/config/nginx/aws-relay.conf.template" \
    > /etc/nginx/sites-available/bsc-aws-relay
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/bsc-aws-relay /etc/nginx/sites-enabled/bsc-aws-relay
nginx -t
systemctl restart nginx

echo "[4/5] UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp        comment 'ssh (lock to your IP later)'
ufw allow 51820/udp     comment 'wireguard from hetzner'
# nginx :8545 should be accessible ONLY via the WireGuard tunnel; the
# nginx config also enforces `allow 10.0.0.1/32`. We do NOT open 8545 on
# the public internet.
echo "y" | ufw enable
ufw status verbose

echo "[5/5] sanity"
curl -sSf "http://10.0.0.1:8645/" -H "X-API-Key: $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  || echo "  (warning: could not reach Hetzner from here. Tunnel may need Hetzner-side config first.)"

cat <<'EOF'

==================================================
phase 2 AWS relay ready

From the Hetzner box you can now:
  ping 10.0.0.2
  curl -H "X-API-Key: $API_KEY" -d '{...JSON-RPC...}' http://10.0.0.2:8545/

The bot should add http://10.0.0.2:8545/ to its parallel tx-submit list.
Submit signed tx to all of:
  - http://127.0.0.1:8545/  (Hetzner local geth)
  - https://puissant-bsc.48.club/
  - BlockRazor bundle endpoint
  - http://10.0.0.2:8545/   (AWS via WireGuard)
==================================================
EOF
