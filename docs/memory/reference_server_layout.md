---
name: Server layout for BSC node
description: File paths, ports, service names, and storage layout for the BSC RPC node at /data/bsc-rpc
type: reference
originSessionId: 824813a1-89e9-4d37-a802-4de6065c5382
---
**Server:** Hetzner AX41-NVMe, IP 135.181.215.53, HEL1 Finland, Ubuntu 24.04.3 LTS.

**Storage:**
- `/dev/md0` RAID1 — `/boot`
- `/dev/md1` RAID0 — `/` (98 GB)
- `/dev/md2` RAID0 — `/data` (1.7 TB usable)

**Project paths under `/data/bsc-rpc/`:**
- `node/` — geth datadir (chaindata)
- `config/` — `genesis.json`, `config.toml`, `api.key`
- `logs/` — bsc.log
- `scripts/` — install / start / stop / status helpers

**Binaries:**
- `/usr/local/bin/geth-bsc` — built from `github.com/bnb-chain/bsc`

**Ports (chosen by agent on 2026-04-28):**
- 30303 TCP/UDP — BSC P2P (public)
- 8545 — geth HTTP RPC (bound to 127.0.0.1)
- 8546 — geth WebSocket (bound to 127.0.0.1)
- 8645 — nginx public HTTP RPC (X-API-Key required)
- 8646 — nginx public WebSocket (X-API-Key required)
- 22 — SSH

**systemd units:**
- `bsc.service` — geth-bsc full node

**API key:** stored at `/data/bsc-rpc/config/api.key` (chmod 600).
