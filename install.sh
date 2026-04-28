#!/bin/bash
# Idempotent bring-up for a BSC dedicated RPC + mempool node on Ubuntu 24.04.
# Reads .env (or env vars). Re-running is safe.
#
# Phases:
#   1  apt deps
#   2  build BSC geth from source ($GETH_VERSION)
#   3  download genesis.json + config.toml from BSC release
#   4  init genesis (cheap; snapshot import will overwrite chaindata)
#   5  install tuned config.toml (txpool / cache / RPC bound to 127.0.0.1)
#   6  install systemd unit (NOT started; you start it after the snapshot)
#   7  install nginx reverse proxy with X-API-Key gate
#   8  configure UFW (do not run if you're not ready to lock the firewall)
#   9  install disk-usage timer
#   10 SSH hardening drop-in (disables password auth)
#
# After install:
#   ./scripts/download-snapshot.sh   # 1.5 TB stream, ~10h
#   systemctl enable --now bsc.service
#
# What this script does NOT do:
#   - run the snapshot download (call it yourself; long-running)
#   - start bsc.service (chaindata isn't there yet on a fresh box)
#   - manage TLS (this stack is HTTP-only with API key, by design)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- load .env ---
if [ -f "$REPO_DIR/.env" ]; then
  set -a; . "$REPO_DIR/.env"; set +a
else
  echo "WARN: $REPO_DIR/.env not found; using defaults from .env.example."
  set -a; . "$REPO_DIR/.env.example"; set +a
fi

DATADIR="${DATADIR:-/data/bsc-rpc}"
GETH_VERSION="${GETH_VERSION:-v1.7.3}"
RPC_HTTP_PORT="${RPC_HTTP_PORT:-8645}"
RPC_WS_PORT="${RPC_WS_PORT:-8646}"
P2P_PORT="${P2P_PORT:-30311}"
GETH_CACHE_MB="${GETH_CACHE_MB:-49152}"
DISK_ALERT_THRESHOLD="${DISK_ALERT_THRESHOLD:-80}"
SSH_ALLOW_FROM="${SSH_ALLOW_FROM:-}"
BOT_ALLOW_FROM="${BOT_ALLOW_FROM:-}"

PHASES="${PHASES:-all}"  # set to e.g. "1,5,7" to run a subset

run_phase () {
  local n="$1"
  if [ "$PHASES" = "all" ] || [[ ",$PHASES," == *",$n,"* ]]; then
    return 0
  fi
  return 1
}

log () { echo "[install] $*"; }

# --- phase 1: deps ---
if run_phase 1; then
  log "phase 1: apt deps"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    golang-go build-essential git curl wget unzip jq \
    aria2 lz4 pv \
    nginx ufw fail2ban sshpass \
    screen htop
fi

# --- phase 2: build geth ---
if run_phase 2; then
  log "phase 2: build BSC geth $GETH_VERSION"
  mkdir -p "$DATADIR/build"
  if [ ! -d "$DATADIR/build/bsc" ]; then
    git clone --depth 1 https://github.com/bnb-chain/bsc.git "$DATADIR/build/bsc"
  fi
  ( cd "$DATADIR/build/bsc"
    git fetch --tags --depth 1 origin "$GETH_VERSION"
    git checkout "$GETH_VERSION"
    make geth )
  install -m 0755 "$DATADIR/build/bsc/build/bin/geth" /usr/local/bin/geth-bsc
  /usr/local/bin/geth-bsc version | head -3
fi

# --- phase 3: genesis + original config ---
if run_phase 3; then
  log "phase 3: download mainnet.zip"
  mkdir -p "$DATADIR/config"
  if [ ! -f "$DATADIR/config/genesis.json" ]; then
    curl -sLO --output-dir "$DATADIR/config" \
      "https://github.com/bnb-chain/bsc/releases/download/$GETH_VERSION/mainnet.zip"
    ( cd "$DATADIR/config" && unzip -o mainnet.zip && mv mainnet/genesis.json . && rm -rf mainnet mainnet.zip )
  fi
fi

# --- phase 4: init genesis ---
if run_phase 4; then
  log "phase 4: init genesis"
  if [ ! -d "$DATADIR/node/geth" ]; then
    /usr/local/bin/geth-bsc --datadir "$DATADIR/node" init "$DATADIR/config/genesis.json"
  else
    log "  $DATADIR/node/geth already exists, skipping init"
  fi
fi

# --- phase 5: tuned config ---
if run_phase 5; then
  log "phase 5: install tuned config.toml"
  install -m 0644 "$REPO_DIR/config/geth/config.toml" "$DATADIR/config/config.toml"
fi

# --- phase 6: systemd unit ---
if run_phase 6; then
  log "phase 6: systemd unit"
  sed -e "s|__BIN_PATH__|/usr/local/bin/geth-bsc|g" \
      -e "s|__DATADIR__|$DATADIR|g" \
      -e "s|__CACHE_MB__|$GETH_CACHE_MB|g" \
      "$REPO_DIR/config/systemd/bsc.service.template" \
      > /etc/systemd/system/bsc.service
  systemctl daemon-reload
  systemd-analyze verify /etc/systemd/system/bsc.service
fi

# --- phase 7: nginx ---
if run_phase 7; then
  log "phase 7: nginx reverse proxy + API key"
  if [ -z "${API_KEY:-}" ]; then
    API_KEY=$(openssl rand -hex 32)
    log "  generated new API key"
    if [ -f "$REPO_DIR/.env" ]; then
      if grep -q '^API_KEY=' "$REPO_DIR/.env"; then
        sed -i "s|^API_KEY=.*|API_KEY=$API_KEY|" "$REPO_DIR/.env"
      else
        echo "API_KEY=$API_KEY" >> "$REPO_DIR/.env"
      fi
    fi
  fi
  umask 077
  install -m 0600 -D /dev/null "$DATADIR/config/api.key"
  echo -n "$API_KEY" > "$DATADIR/config/api.key"
  log "  API key saved to $DATADIR/config/api.key"

  sed -e "s|__API_KEY__|$API_KEY|g" \
      -e "s|__RPC_HTTP_PORT__|$RPC_HTTP_PORT|g" \
      -e "s|__RPC_WS_PORT__|$RPC_WS_PORT|g" \
      "$REPO_DIR/config/nginx/bsc-rpc.conf.template" \
      > /etc/nginx/sites-available/bsc-rpc
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/bsc-rpc /etc/nginx/sites-enabled/bsc-rpc
  nginx -t
  systemctl restart nginx
  log "  nginx listening on $RPC_HTTP_PORT (HTTP) and $RPC_WS_PORT (WS)"
fi

# --- phase 8: UFW ---
if run_phase 8; then
  log "phase 8: UFW"
  ufw default deny incoming
  ufw default allow outgoing

  if [ -n "$SSH_ALLOW_FROM" ]; then
    for cidr in $SSH_ALLOW_FROM; do ufw allow from "$cidr" to any port 22 proto tcp comment 'ssh'; done
  else
    ufw allow 22/tcp comment 'ssh'
  fi

  if [ -n "$BOT_ALLOW_FROM" ]; then
    for cidr in $BOT_ALLOW_FROM; do
      ufw allow from "$cidr" to any port "$RPC_HTTP_PORT" proto tcp comment 'bsc-rpc http'
      ufw allow from "$cidr" to any port "$RPC_WS_PORT"   proto tcp comment 'bsc-rpc ws'
    done
  else
    ufw allow "$RPC_HTTP_PORT/tcp" comment 'bsc-rpc http (api-key gated)'
    ufw allow "$RPC_WS_PORT/tcp"   comment 'bsc-rpc ws (api-key gated)'
  fi

  ufw allow "$P2P_PORT/tcp" comment 'bsc p2p tcp'
  ufw allow "$P2P_PORT/udp" comment 'bsc p2p udp'
  echo "y" | ufw enable
  ufw status verbose
fi

# --- phase 9: disk monitor ---
if run_phase 9; then
  log "phase 9: disk monitor"
  install -m 0755 "$REPO_DIR/scripts/disk-check.sh" /usr/local/bin/bsc-disk-check.sh
  install -m 0644 "$REPO_DIR/config/systemd/bsc-disk-check.service" /etc/systemd/system/bsc-disk-check.service
  install -m 0644 "$REPO_DIR/config/systemd/bsc-disk-check.timer"   /etc/systemd/system/bsc-disk-check.timer
  systemctl daemon-reload
  systemctl enable --now bsc-disk-check.timer
fi

# --- phase 10: SSH hardening ---
if run_phase 10; then
  log "phase 10: SSH hardening (disable password auth)"
  if grep -q "^PermitRootLogin" /etc/ssh/sshd_config && [ -z "$(ls -A /root/.ssh/authorized_keys 2>/dev/null)" ]; then
    log "  WARN: /root/.ssh/authorized_keys empty -- skipping SSH hardening to avoid lockout"
  else
    install -m 0644 "$REPO_DIR/config/ssh/00-bsc-rpc-hardening.conf" /etc/ssh/sshd_config.d/00-bsc-rpc-hardening.conf
    sshd -t
    systemctl reload ssh
  fi
fi

cat <<EOF

==================================================
install.sh complete

Next steps:
  1. Run the snapshot stream (long, ~10h, resumable on R2 disconnect):
       $REPO_DIR/scripts/download-snapshot.sh

  2. When .snapshot-complete file appears under $DATADIR/node/, start the node:
       systemctl enable --now bsc.service
       journalctl -u bsc -f

  3. Test the API gate from a remote host:
       curl -H "X-API-Key: \$(cat $DATADIR/config/api.key)" http://HOST:$RPC_HTTP_PORT/

API key is at: $DATADIR/config/api.key
==================================================
EOF
