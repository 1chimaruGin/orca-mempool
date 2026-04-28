#!/bin/bash
# Quick post-install sanity checks. Runs locally on the node host.
# Verifies: nginx auth gate, geth RPC reachable, WS subscribe works (briefly).
set -uo pipefail

if [ -f "$(dirname "$0")/../.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$(dirname "$0")/../.env"; set +a
fi

DATADIR="${DATADIR:-/data/bsc-rpc}"
RPC_HTTP_PORT="${RPC_HTTP_PORT:-8645}"
RPC_WS_PORT="${RPC_WS_PORT:-8646}"
HOST="${HOST:-127.0.0.1}"
API_KEY="${API_KEY:-$(cat "$DATADIR/config/api.key" 2>/dev/null)}"

if [ -z "$API_KEY" ]; then
  echo "ERR: API_KEY empty (.env or $DATADIR/config/api.key not readable)"
  exit 2
fi

ok ()  { printf '\033[32m PASS \033[0m %s\n' "$1"; }
fail() { printf '\033[31m FAIL \033[0m %s\n' "$1"; FAIL=1; }

FAIL=0

# 1. Auth gate: 403 without key
code=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$RPC_HTTP_PORT/")
[ "$code" = "403" ] && ok "no-key request returns 403" || fail "no-key request returned $code (expected 403)"

# 2. Auth gate: 403 with wrong key
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: wrong" "http://$HOST:$RPC_HTTP_PORT/")
[ "$code" = "403" ] && ok "wrong-key request returns 403" || fail "wrong-key request returned $code (expected 403)"

# 3. With correct key, expect 200 from a valid eth_blockNumber if geth is up,
#    or 502/504 if geth is still syncing/down.
resp=$(curl -s -w '\n%{http_code}' \
  -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "http://$HOST:$RPC_HTTP_PORT/")
code=$(echo "$resp" | tail -1)
body=$(echo "$resp" | head -n -1)
case "$code" in
  200) ok "valid-key eth_blockNumber: HTTP 200 - $body" ;;
  502|504) fail "valid-key reaches nginx but geth is down/booting (HTTP $code)" ;;
  *) fail "unexpected status $code body=$body" ;;
esac

# 4. txpool_status (BSC-specific helpful endpoint)
resp=$(curl -s -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"txpool_status","params":[],"id":1}' \
  "http://$HOST:$RPC_HTTP_PORT/")
echo "$resp" | grep -q '"result"' && ok "txpool_status: $resp" || fail "txpool_status: $resp"

# 5. Sync status
resp=$(curl -s -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  "http://$HOST:$RPC_HTTP_PORT/")
echo "$resp" | grep -q '"result"' && ok "eth_syncing: $resp" || fail "eth_syncing: $resp"

# 6. Brief WS subscribe (3 sec)
if command -v websocat >/dev/null 2>&1; then
  echo "newPendingTransactions subscribe (3s sample)..."
  timeout 3 websocat \
    --header "X-API-Key: $API_KEY" \
    "ws://$HOST:$RPC_WS_PORT/" <<<'{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["newPendingTransactions"]}' \
    | head -3 \
    && ok "WS subscribe yielded events" \
    || fail "WS subscribe did not yield within 3s (node may not be synced)"
else
  echo "(skipping WS subscribe test - install 'websocat' for full coverage: cargo install websocat)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "All checks passed."
  exit 0
else
  echo
  echo "One or more checks failed."
  exit 1
fi
