# orca-mempool

Reusable bring-up for a **dedicated BSC RPC + mempool node** optimized for
sniping bots: low-latency `newPendingTransactions` over a WebSocket gated by
an `X-API-Key` header.

This repo packages everything we discovered the hard way during the first
deployment on Hetzner — including the lessons that mattered more than the
node spec itself. **Read [`docs/lessons-learned.md`](docs/lessons-learned.md)
before deploying again.**

---

## What you get

- BSC `geth` (built from the upstream `bnb-chain/bsc` source, pinned by tag).
- Tuned `config.toml` for sniping (txpool 100 k slots / 50 k queue, 48 GiB
  cache, RPC bound to `127.0.0.1`, public RPC fronted by nginx).
- nginx reverse proxy with `X-API-Key` allowlist (HTTP only, no TLS — by
  design; bot connects directly via IP + key).
- systemd unit (`bsc.service`) with sane restart + file-descriptor limits.
- UFW firewall config that locks everything but SSH + RPC ports + BSC P2P.
- 15-minute disk-usage timer that escalates at 80 %.
- A streaming snapshot downloader that solves "1.5 TB compressed snapshot
  doesn't fit on a 1.7 TB disk" via FIFO + HTTP `Range:` resume.
- `rsync`-to-Storage-Box backup script.

## What you do NOT get

- TLS (intentional — single-bot HTTP+APIkey was the chosen tradeoff).
- A bot. This repo is just the node side; you bring your own consumer that
  subscribes to `eth_subscribe` and sends `eth_sendRawTransaction`.
- A validator-direct submit path (no bundle relay integration).

## Hardware baseline

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 8 cores | 16+ cores |
| RAM | 32 GB | 64 GB (drives `--cache 49152`) |
| Disk | 2 TB NVMe | 2.5+ TB NVMe (chain growth headroom) |
| Network | 1 Gbps | 1-2.5 Gbps |
| **Location** | **Tokyo / Singapore / HK** for competitive MEV | same |

> If you skip "Location" you will be slower than the bots colocated near BSC
> validators. We learned this the painful way — see
> [`docs/lessons-learned.md`](docs/lessons-learned.md) §1.

---

## Quick start (fresh Ubuntu 24.04 host)

```bash
git clone git@github.com:1chimaruGin/orca-mempool.git /opt/orca-mempool
cd /opt/orca-mempool
cp .env.example .env
$EDITOR .env                    # set DATADIR, BOT_ALLOW_FROM, etc.

sudo ./install.sh               # phases 1-10, idempotent

# the snapshot is its own step (long; ~10 h on a 1 Gbps link)
sudo ./scripts/download-snapshot.sh

# when /data/bsc-rpc/node/.snapshot-complete appears:
sudo systemctl enable --now bsc.service
sudo journalctl -u bsc -f       # watch sync
```

The bot then connects to:

```
http://<host>:8645   # JSON-RPC
ws://<host>:8646     # WebSocket subscriptions
```

with header `X-API-Key: <contents of $DATADIR/config/api.key>`.

---

## Layout

```
.
├── install.sh                   # idempotent host bring-up (phases 1-10)
├── .env.example                 # all knobs (ports, cache, txpool, etc.)
├── scripts/
│   ├── download-snapshot.sh     # streaming snapshot import (FIFO + Range)
│   ├── disk-check.sh            # /data usage check (driven by timer)
│   └── backup-to-storage-box.sh # rsync chaindata + configs to a Hetzner box
├── config/
│   ├── geth/config.toml         # tuned txpool / RPC / P2P
│   ├── systemd/
│   │   ├── bsc.service.template # placeholders: __BIN_PATH__ etc.
│   │   ├── bsc-disk-check.service
│   │   └── bsc-disk-check.timer
│   ├── nginx/
│   │   └── bsc-rpc.conf.template # placeholders: __API_KEY__ etc.
│   └── ssh/
│       └── 00-bsc-rpc-hardening.conf
└── docs/
    ├── lessons-learned.md       # READ THIS BEFORE NEXT DEPLOY
    ├── phase2-sg-relay.md       # Singapore relay + multi-path submit (next phase)
    └── architecture.svg         # Phase-by-phase flow diagram
```

---

## Phase 2 — Singapore relay + multi-path submit

After Phase 1 (this README) is deployed and the bot is verified, the next
step is to add Asian-DC tx-submission paths. With BSC block time at 0.45 s
(Fermi hard fork, 2026-01-14), Hetzner-to-validator RTT of 150 ms is 33 %
of a single block — Asian relays are effectively required to compete.
See [`docs/phase2-sg-relay.md`](docs/phase2-sg-relay.md) for the full
design, plus:

- [`scripts/phase2-setup-aws-relay.sh`](scripts/phase2-setup-aws-relay.sh)
  — runs on a fresh AWS Singapore box, brings up WireGuard + nginx relay
- [`scripts/phase2-setup-hetzner-wg.sh`](scripts/phase2-setup-hetzner-wg.sh)
  — runs on the Hetzner box, adds the WireGuard peer
- [`config/wireguard/`](config/wireguard/) — WG config templates for both ends
- [`config/nginx/aws-relay.conf.template`](config/nginx/aws-relay.conf.template)
  — AWS-side reverse proxy that forwards JSON-RPC to BSC over the tunnel

The bot becomes a **parallel-submit fan-out**:

```
signed snipe tx ──┬─► Hetzner local geth          (slow, fallback)
                  ├─► Puissant rpc                 (Asia, free, validator-direct)
                  ├─► BlockRazor bundle endpoint   (Asia, free tier)
                  └─► AWS SG over WireGuard        (Asia, free tier 12 mo)
```

Same nonce, only one lands; duplicates dropped at validators.

---

## Per-phase what `install.sh` does

| # | Phase | Action |
|---|---|---|
| 1 | Deps | apt: golang, build-essential, aria2, lz4, nginx, ufw, fail2ban, sshpass, pv |
| 2 | Build | `git clone bnb-chain/bsc`, `git checkout $GETH_VERSION`, `make geth`, install to `/usr/local/bin/geth-bsc` |
| 3 | Genesis | Download `mainnet.zip` from BSC release for `$GETH_VERSION`, extract `genesis.json` |
| 4 | Init | `geth-bsc --datadir $DATADIR/node init genesis.json` (cheap; snapshot will overwrite) |
| 5 | Config | Drop tuned `config.toml` into `$DATADIR/config/` |
| 6 | systemd | Render `bsc.service` from template, `daemon-reload`, validate (do *not* start) |
| 7 | nginx | Generate API key if not in `.env`, render reverse proxy config, restart nginx |
| 8 | UFW | `default deny`, allow SSH + `$RPC_HTTP_PORT` + `$RPC_WS_PORT` + BSC P2P; optional source-IP allowlist |
| 9 | Disk monitor | Install `bsc-disk-check.sh` + 15-min timer (escalates at 80 %) |
| 10 | SSH hardening | Drop-in disabling password auth, but **only if `authorized_keys` is non-empty** |

You can run a subset with `PHASES=5,7 ./install.sh`.

---

## Snapshot script highlights

[`scripts/download-snapshot.sh`](scripts/download-snapshot.sh) is the most
non-obvious piece in this repo and worth understanding before tweaking:

1. Spawn `lz4 -d - | tar --strip-components=2 -xf -` reading from a FIFO.
2. Open the FIFO **as a write FD in the parent shell** (`exec 3>$FIFO`). This
   FD stays open across curl invocations, so the extraction pipeline never
   sees EOF mid-transfer.
3. Loop: `curl --header "Range: bytes=$OFFSET-" $URL -o /dev/fd/3
   -w '%{size_download}'`. After each curl exit, advance `$OFFSET` by the
   bytes actually received.
4. Continue until `$OFFSET >= Content-Length`. Close FD 3, wait extractor.

This pattern means R2 closing the connection (which it does every 30-60 GB on
the 1.5 TB blob) is a one-second blip rather than a full restart.

To use a fresher snapshot:
1. Read the latest CSV under
   <https://github.com/bnb-chain/bsc-snapshots/tree/main/dist>.
2. Update `BASE_URL` and `BLOCKS_URL` in `.env` (or pass as env vars).

---

## Cancelling / migrating

If you decide the host or DC was wrong (we did — see lessons §1, §9):

```bash
# 1. backup configs + chaindata to your Storage Box
sudo systemctl stop bsc.service
./scripts/backup-to-storage-box.sh shutdown

# 2. on the new host, clone, .env, install.sh
# 3. seed chaindata from the box instead of re-downloading the 1.5 TB snapshot
```

---

## License

MIT.
