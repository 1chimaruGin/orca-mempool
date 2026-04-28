#!/bin/bash
# Probe TCP/HTTPS/JSON-RPC/WebSocket latency to a curated list of BSC
# endpoints from the host you run this on.
#
# Use case:
#   - Run BEFORE you buy a long-term server in a region.
#   - Spin up a free-tier / hourly VM in each candidate region (AWS EC2
#     t3.micro, Lightsail, Vultr, DO, Latitude.sh hourly), run this script,
#     terminate. ~$1 of testing saves you from paying for a wrong-region box.
#
# Output: a table per target endpoint with median ping, TCP-connect, TLS
# handshake, JSON-RPC round-trip, and (optional) WebSocket subscribe latency.
#
# Requires: bash, curl (with --connect-time), jq, awk, ping, getent.
# Optional: websocat for WS subscribe timing (cargo install websocat).
#
# Usage:
#   ./latency-probe.sh [iterations]    # default 50
#   ./latency-probe.sh 100             # more samples per target
#   ./latency-probe.sh 50 nows         # skip WS subscribe test (faster)

set -uo pipefail

ITER="${1:-50}"
SKIP_WS="${2:-}"

TARGETS=(
  "bsc-dataseed.bnbchain.org           https://bsc-dataseed.bnbchain.org           wss://bsc-rpc.publicnode.com"
  "bsc.publicnode.com                  https://bsc.publicnode.com                  wss://bsc-rpc.publicnode.com"
  "rpc.ankr.com_bsc                    https://rpc.ankr.com/bsc                    "
  "puissant-bsc.48.club                https://puissant-bsc.48.club                "
  "binance.llamarpc.com                https://binance.llamarpc.com                "
)

# pretty-print a percentile from a sample list
stat_p () {
  local p="$1"; shift
  printf '%s\n' "$@" | awk -v p="$p" '
    { a[NR]=$1 }
    END {
      if (NR == 0) { print "n/a"; exit }
      n = asort(a)
      i = int(p/100*n + 0.5); if (i<1) i=1; if (i>n) i=n
      printf("%.1f", a[i])
    }'
}

probe_ping () {
  local host="$1"
  ping -c "$ITER" -i 0.2 -W 2 -q "$host" 2>/dev/null \
    | awk -F'/' '/min\/avg\/max/{print $5; exit}' || echo "n/a"
}

probe_tcp_connect () {
  local url="$1" samples=()
  for ((i=0; i<ITER; i++)); do
    t=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 5 "$url" 2>/dev/null)
    [ -n "$t" ] && samples+=("$(awk -v x="$t" 'BEGIN{print x*1000}')")
  done
  printf '%s\n' "${samples[@]}"
}

probe_tls () {
  local url="$1" samples=()
  for ((i=0; i<ITER; i++)); do
    t=$(curl -o /dev/null -s -w '%{time_appconnect}\n' --connect-timeout 5 "$url" 2>/dev/null)
    [ -n "$t" ] && samples+=("$(awk -v x="$t" 'BEGIN{print x*1000}')")
  done
  printf '%s\n' "${samples[@]}"
}

probe_jsonrpc () {
  local url="$1" samples=()
  for ((i=0; i<ITER; i++)); do
    t=$(curl -o /dev/null -s -w '%{time_total}\n' --connect-timeout 5 \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$url" 2>/dev/null)
    [ -n "$t" ] && samples+=("$(awk -v x="$t" 'BEGIN{print x*1000}')")
  done
  printf '%s\n' "${samples[@]}"
}

probe_ws_subscribe () {
  local ws_url="$1"
  if [ -z "$ws_url" ] || [ "$SKIP_WS" = "nows" ]; then echo "skipped"; return; fi
  if ! command -v websocat >/dev/null 2>&1; then echo "no-websocat"; return; fi
  # 60-second sample of pending tx events; print median inter-event ms
  local tmp; tmp=$(mktemp)
  ( timeout 60 websocat "$ws_url" \
      <<<'{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["newPendingTransactions"]}' \
      | python3 -c '
import sys, time
last = None
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{") or "params" not in line:  # skip subscribe-ok
        continue
    now = time.time()*1000
    if last is not None:
        print(f"{now-last:.0f}")
    last = now
' > "$tmp"
  )
  if [ ! -s "$tmp" ]; then echo "no-events"; rm -f "$tmp"; return; fi
  awk '{a[NR]=$1} END {n=asort(a); print a[int(n/2)]}' "$tmp"
  rm -f "$tmp"
}

# Header
LOC=$(curl -s --max-time 3 https://ipinfo.io 2>/dev/null \
        | awk -F'"' '/"region"|"country"|"city"|"ip"/{print $2": "$4}' | tr '\n' ' ' \
        || echo unknown)
echo "===================================================================="
echo "BSC latency probe — $(date -u +%FT%TZ)"
echo "host:    $(hostname)"
echo "location: $LOC"
echo "iterations per metric: $ITER"
echo "===================================================================="
printf '%-32s | %7s | %7s | %7s | %7s | %7s | %7s\n' \
       'TARGET' 'ping' 'p99' 'tcp50' 'tls50' 'rpc50' 'wsmedian'
echo "--------------------------------------------------------------------"

for row in "${TARGETS[@]}"; do
  read -r name url ws_url <<<"$row"
  host=$(echo "$url" | awk -F/ '{print $3}')

  ping_med=$(probe_ping "$host")
  ping_p99=$(ping -c "$ITER" -i 0.2 -W 2 -q "$host" 2>/dev/null \
              | awk -F'/' '/min\/avg\/max/{print $7; exit}' || echo n/a)

  mapfile -t tcp_samples < <(probe_tcp_connect "$url")
  tcp_med=$(stat_p 50 "${tcp_samples[@]}")

  mapfile -t tls_samples < <(probe_tls "$url")
  tls_med=$(stat_p 50 "${tls_samples[@]}")

  mapfile -t rpc_samples < <(probe_jsonrpc "$url")
  rpc_med=$(stat_p 50 "${rpc_samples[@]}")

  ws_med=$(probe_ws_subscribe "${ws_url:-}")

  printf '%-32s | %7s | %7s | %7s | %7s | %7s | %7s\n' \
    "$name" "${ping_med:-n/a}" "${ping_p99:-n/a}" "$tcp_med" "$tls_med" "$rpc_med" "$ws_med"
done

echo "--------------------------------------------------------------------"
echo "All values in milliseconds."
echo "  ping = ICMP RTT median"
echo "  p99  = ICMP RTT p99"
echo "  tcp50= TCP connect time, median"
echo "  tls50= TLS handshake time, median"
echo "  rpc50= JSON-RPC eth_blockNumber round-trip, median"
echo "  wsmedian= median inter-event delay on a 60s newPendingTransactions"
echo "         subscribe (lower is better; high = sparse mempool view)"
echo "===================================================================="
