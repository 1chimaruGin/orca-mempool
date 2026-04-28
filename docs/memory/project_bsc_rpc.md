---
name: BSC RPC node project
description: Bot-only BSC mainnet RPC + mempool node on Hetzner AX41-NVMe, optimized for sniping (low-latency newPendingTransactions)
type: project
originSessionId: 824813a1-89e9-4d37-a802-4de6065c5382
---
Setting up a dedicated BSC mainnet (chainId 56) full node on Hetzner AX41-NVMe at 135.181.215.53 (HEL1).

**Why:** The user runs a sniping bot that needs sub-100ms visibility into the BSC mempool (`newPendingTransactions` WebSocket subscribe). Public RPCs are too slow / rate-limited. Node is for the bot only — not a public RPC service.

**How to apply:** When making config tradeoffs on this project, prioritize: (1) mempool latency, (2) txpool capacity (high GlobalSlots/GlobalQueue), (3) peer count. De-prioritize: archive/historical state, public-facing API hardening beyond a single API key, TLS.

Hardware: Ryzen 7 3700X (16 threads), 62 GB RAM, 2× 1 TB NVMe in RAID0 (1.7 TB on `/data`). Ubuntu 24.04.3 LTS.

Phases (per system flow diagram in `/data/bsc-rpc/bsc_rpc_mempool_system_flow.svg`):
1. Storage RAID0 — done before agent arrived.
2. Deps + build BSC geth → `/usr/local/bin/geth-bsc`.
3. Genesis init + snapshot download from `bnb-chain/bsc-snapshots`.
4. Geth config: snap sync, txpool 100k slots / 50k queue, --cache 49152, --maxpeers 200, RPC bound to 127.0.0.1.
5. systemd `bsc.service`.
6. nginx reverse proxy with X-API-Key check + UFW.
7. Verify mempool latency < 100 ms.
