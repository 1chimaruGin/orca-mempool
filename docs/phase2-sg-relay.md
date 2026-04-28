# Phase 2 — Singapore relay + multi-path submit

This is the post-Hetzner-bring-up plan. Execute it **after** the BSC node is
fully synced and the bot has been verified working against `localhost:8545`.

## Goal

Add an **Asian-DC tx-submission path** so snipe txs land at BSC validators
~150 ms faster than from Hetzner alone, without paying for a full Asian BSC
node. Pair it with **public free Asian relay endpoints (Puissant +
BlockRazor)** so the bot has **multiple parallel submit paths** for
reliability.

End state:

```
            mempool ingest (parallel subscribe)
            ├─ Hetzner local geth ws://127.0.0.1:8546   (public mempool)
            ├─ Puissant pending feed                     (private mempool)
            └─ BlockRazor mempool feed                   (private mempool)
                    │
                    ▼
            bot decision + signing on Hetzner
                    │
                    ├──── tx submit (parallel broadcast)
                    │     ├─ Hetzner local geth           eth_sendRawTransaction
                    │     ├─ Puissant rpc                 https://puissant-bsc.48.club/
                    │     ├─ BlockRazor bundle endpoint   (private bundle API)
                    │     └─ AWS SG relay (WG tunnel)     https://10.0.0.2:8545
                    │           └─ AWS forwards to BSC validators directly
```

The same signed tx is fired to all submit paths simultaneously. Whichever
reaches a validator first wins; duplicate same-nonce txs are dropped. Cost
on chain is the gas of the tx that landed, no penalty for the others.

## Why this layout

- **Public mempool only sees ~50% of profitable BSC tx flow**; private feeds
  (Puissant, BlockRazor) see the rest. Subscribing to all three closes that
  blind spot.
- **Tx submission from Hetzner HEL1 to BSC validators is ~150 ms**. From a
  Singapore-hosted relay (AWS, Puissant, BlockRazor) it's ~5-10 ms. With BSC
  block time at **0.45 s** (Fermi hard fork, 2026-01-14), 150 ms is **33 %
  of a single block** — the difference between landing in block N (Asian
  submit) and block N+2 (Hetzner-only). At ~1 s finality, the practical
  competitive window for a snipe is only ~2-3 blocks; an EU-only path
  loses most of those races.
- **Multiple parallel submit paths** = resilience. If one relay is down, the
  others still land your tx.
- **AWS free tier (12 months)** covers the WireGuard relay box. After that,
  you can drop AWS and rely on Puissant + BlockRazor (still free) — same
  result.

## Components

### A. AWS Lightsail Singapore (or EC2 t3.micro free tier)

- **Region:** ap-southeast-1 (Singapore)
- **Spec:** Lightsail $3.50/mo plan (512 MB RAM, 20 GB SSD) is enough; free
  for 3 months. Or EC2 t3.micro (1 GB RAM, 8 GB) — free for 12 months.
- **OS:** Ubuntu 24.04 LTS
- **Public IP:** elastic / static (you'll point WireGuard at it)
- **Open ports:** 22 (SSH from your IPs only), 51820/UDP (WireGuard from
  Hetzner only)

### B. WireGuard tunnel

- Two endpoints: AWS (10.0.0.2) and Hetzner (10.0.0.1) on a /24 subnet
- AWS dials Hetzner (Hetzner has the stable public IP); set
  `PersistentKeepalive = 25` on the AWS side to defeat AWS's NAT idle-timer
- Listen port 51820/udp on Hetzner (open this on UFW)
- Both peers configured with each other's public keys

### C. Tx-submit relay on AWS

Two viable approaches:

1. **Plain nginx reverse proxy** to `https://bsc-dataseed.bnbchain.org` (public
   BSC RPC), gated by API key. Bot hits AWS-IP:8545; AWS forwards to BSC
   public RPC which is in Asia. Latency: ~10-30 ms. Simple but you depend
   on a public RPC.

2. **socat / haproxy** TCP tunnel to a curated list of validator-direct
   submit endpoints (Puissant, BlockRazor). Same effect; better latency to
   the actual block builder. Requires per-target config.

We'll start with (1) since it's drop-in, and add (2) later if the bot is
profitable enough to justify.

### D. Bot config

Bot reads RPC endpoints from a config file. It should:

- **Subscribe to mempool from all three sources in parallel**:
  - `ws://127.0.0.1:8546/` (Hetzner local) with `X-API-Key`
  - `wss://puissant-bsc.48.club/ws` (Puissant)
  - BlockRazor's WS endpoint (after registering for free tier API key)

- **Send signed tx to all four submit paths in parallel** (using
  `Promise.allSettled` / `tokio::join!`/whatever your runtime offers):
  - `http://127.0.0.1:8545/` (Hetzner local) with API key
  - `https://puissant-bsc.48.club/` (Puissant)
  - BlockRazor's bundle API
  - `http://10.0.0.2:8545/` (AWS over WG tunnel)

- **Deduplicate by tx hash** when reading mempool from multiple sources to
  avoid double-processing.

- **Track which path landed the tx** (`eth_getTransactionReceipt` →
  block number, then check who proposed that block) to learn which paths
  are actually winning.

## Step-by-step execution plan

1. **AWS Lightsail SG instance** — provision via console, create static IP,
   note the IPv4.
2. **Install WireGuard** on AWS (`apt install wireguard wireguard-tools`).
3. **Generate keypairs** on both ends (`wg genkey | tee priv | wg pubkey`).
4. **Write `/etc/wireguard/wg0.conf`** on each end (templates below).
5. **Open UFW**: 51820/udp inbound on Hetzner (already firewalled-tight by
   our installer; just add a rule).
6. **Bring up tunnel**: `systemctl enable --now wg-quick@wg0` on both.
7. **Test**: `ping 10.0.0.1` from AWS, `ping 10.0.0.2` from Hetzner.
8. **Install nginx tx-submit proxy on AWS** (config in `config/nginx/aws-relay.conf.template`).
9. **Bot config update**: add the four submit endpoints to `.env` /
   bot config; subscribe to multiple WS feeds.
10. **Smoke test**: send a 0.0001 BNB self-transfer through each submit path
    individually, confirm each lands. Then a parallel-submit test, confirm
    only one lands and the others get "nonce already used" errors (that's
    correct).
11. **Latency measurement**: log timestamp at signing, log timestamp at
    receipt-mined. Compute end-to-end latency per submit path. Use this to
    tune which paths the bot fires to.

## WireGuard config templates

`config/wireguard/hetzner-wg0.conf.template`:

```ini
[Interface]
Address    = 10.0.0.1/24
ListenPort = 51820
PrivateKey = __HETZNER_PRIVATE_KEY__

[Peer]
PublicKey  = __AWS_PUBLIC_KEY__
AllowedIPs = 10.0.0.2/32
```

`config/wireguard/aws-wg0.conf.template`:

```ini
[Interface]
Address    = 10.0.0.2/24
PrivateKey = __AWS_PRIVATE_KEY__

[Peer]
PublicKey            = __HETZNER_PUBLIC_KEY__
Endpoint             = __HETZNER_PUBLIC_IP__:51820
AllowedIPs           = 10.0.0.1/32
PersistentKeepalive  = 25
```

## Reliability checklist

Before declaring this phase done, confirm:

- [ ] WireGuard tunnel survives a Hetzner reboot (re-establishes on its own)
- [ ] AWS instance reboot also re-establishes
- [ ] `ping 10.0.0.x` works in both directions
- [ ] AWS nginx proxy 200s on a `eth_blockNumber` JSON-RPC call from Hetzner
- [ ] Bot can subscribe to Puissant WS feed
- [ ] Bot can subscribe to BlockRazor mempool feed (after API key issued)
- [ ] Self-transfer goes through and lands via each submit path individually
- [ ] Parallel-submit smoke test: 3 of 4 paths return "nonce too low" (correct)
- [ ] Latency measurement for each path is captured to a per-path histogram

## What this phase does NOT solve

- **AWS instance does not run a BSC node** — it cannot see the mempool
  faster than Hetzner. You see the public mempool at Hetzner's speed, the
  private mempool at Puissant's / BlockRazor's speed.
- **6-month free-tier expiry**: after free tier ends, AWS Lightsail $3.50
  /mo plan is the cheapest continuation, or drop AWS and stay on Puissant
  + BlockRazor.
- **Anti-sniper contract logic** (revert on first-buy, blacklist) is a
  bot-side problem. Add `eth_call` simulation before any snipe.
