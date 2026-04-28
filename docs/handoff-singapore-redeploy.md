# Handoff — redeploying on Singapore

Hetzner HEL1 was cancelled on 2026-04-28 because BSC block time at 0.45 s
makes EU-located nodes uncompetitive for KOL front-running. This doc is
the quickstart for resuming on a Singapore box.

## Order of operations

### 1. Pick a Singapore provider

Run [`scripts/latency-probe.sh`](../scripts/latency-probe.sh) from a
short-rented VM in each candidate region first. You're looking for:

- `bsc-dataseed.bnbchain.org` JSON-RPC RTT **< 30 ms**
- `puissant-bsc.48.club` JSON-RPC RTT **< 20 ms**

If a provider/DC delivers these, it's competitive. If a provider's
"Singapore" still measures 80+ ms to Puissant, that's a different DC than
where BSC infra sits — skip it.

Candidates that historically meet the bar:

| Provider | DC | Spec | Approx price | Bare metal? |
|---|---|---|---|---|
| Latitude.sh | Singapore | Ryzen 9 5950X / 64 GB / 2× 1.92 TB NVMe | ~$199/mo | ✅ yes (hourly available) |
| OVH | SGP1 | EPYC / 64-128 GB / 2× 2 TB | ~$200-300/mo | ✅ |
| Cherry Servers | Singapore | varies | ~$150-300/mo | ✅ |
| Equinix Metal | sg.metal | varies, premium | $300+/mo | ✅ (best peering, expensive) |

Front-running needs **bare metal** for deterministic latency, not VPS.

### 2. Provision + initial setup

On the new Singapore box (Ubuntu 24.04 fresh):

```bash
git clone git@github.com:1chimaruGin/orca-mempool.git /opt/orca-mempool
cd /opt/orca-mempool
cp .env.example .env
$EDITOR .env                    # set DATADIR, BOT_ALLOW_FROM, etc.
sudo ./install.sh               # phases 1-10, idempotent
```

### 3. Get the chaindata

You have **two options** depending on the cancellation timeline:

**Option A — re-stream from R2 (easy, slow):**
```bash
sudo ./scripts/download-snapshot.sh   # ~6-12 h, fully resumable
```

**Option B — restore from Hetzner Storage Box (fast, requires Hetzner
node was still alive when you backed up):**
```bash
# you should have run this BEFORE cancelling the Hetzner server:
#   ./scripts/backup-to-storage-box.sh shutdown
# now on Singapore box:
mkdir -p /data/bsc-rpc/node/geth
rsync -av --partial --info=progress2 \
  -e "ssh -p 23 -i /root/.ssh/id_ed25519" \
  u584696@u584696.your-storagebox.de:./bsc-backup/geth/ \
  /data/bsc-rpc/node/geth/
```

(Storage Box is a separate Hetzner product; cancelling the server doesn't
touch it. SSH key auth is set up; reuse `/root/.ssh/id_ed25519` if you
keep that key. Otherwise generate a new one and re-add to the box.)

### 4. Bring up the node

```bash
sudo systemctl enable --now bsc.service
sudo journalctl -u bsc -f       # wait for "Imported new chain segment"
                                  # at head block; 2-30 min for snap sync
                                  # to catch up after snapshot import
sudo ./scripts/smoke-test.sh    # verify RPC + WS gates
```

### 5. Wire up the bot for parallel mempool ingest + submit

This is the part that turns "BSC node in SG" into "front-running setup".

**Mempool ingest** — bot subscribes to all three in parallel and dedupes
by tx hash:

```python
# pseudo-code
sources = [
    "ws://127.0.0.1:8546/",                          # local geth, X-API-Key
    "wss://puissant-bsc.48.club/ws",                 # Puissant pending feed (free)
    "wss://...blockrazor mempool endpoint...",       # BlockRazor (free tier, signup required)
]
for src in sources:
    asyncio.create_task(subscribe_pending(src, queue, dedupe_set))
```

Puissant docs: <https://docs.48.club/services/puissant>
BlockRazor docs: <https://blockrazor.gitbook.io/blockrazor>

**Tx submit** — fan-out to multiple paths; whichever lands first wins:

```python
async def fan_submit(signed_tx_hex: str):
    return await asyncio.gather(
        submit_local(signed_tx_hex),       # http://127.0.0.1:8545/
        submit_puissant(signed_tx_hex),    # https://puissant-bsc.48.club/
        submit_blockrazor(signed_tx_hex),  # BlockRazor bundle endpoint
        return_exceptions=True,
    )
```

Same tx → multiple paths → only one mines (same nonce). No double-spend
risk; duplicate-nonce txs are dropped at the validator.

### 6. Skip Phase 2 (AWS WireGuard relay) — not needed in Singapore

The Phase 2 setup in
[`docs/phase2-sg-relay.md`](phase2-sg-relay.md) was designed to bolt an
Asian relay onto a Hetzner-EU node. Now that you ARE in Singapore, you
don't need an AWS hop. Save the WireGuard scripts as a reference for if
you later add geographic redundancy.

## What you keep from the Hetzner work

- ✅ Entire orca-mempool repo (install.sh, snapshot streamer, configs)
- ✅ Storage Box (separate product, not cancelled with server)
- ✅ The geometry / lessons-learned docs (apply to any future BSC node)
- ✅ Memory snapshots in [`docs/memory/`](memory/)
- ✅ The `35d518d7b1afe8...d647` API key — rotate for safety, but the
     mechanism is the same on the new box

## What you need to redo

- ❌ The chaindata download (unless you backed up to Storage Box first)
- ❌ Firewall config (UFW gets re-applied by `install.sh` on the new box)
- ❌ SSH host keys (new box, new keys; re-paste your client pubkey)
- ❌ Hetzner-specific paths in `reference_server_layout.md` (memory file)

## Realistic expectations after migration

From a Singapore bare-metal box with mempool fan-in (Puissant + BlockRazor)
and submit fan-out (Puissant + BlockRazor + own peer), you can:

- **See most KOL public-mempool txs in 5-15 ms** of broadcast (vs ~150 ms
  from HEL1).
- **See KOL private-mempool txs** that go through Puissant or BlockRazor
  (you couldn't see these from HEL1 at all without paid feeds).
- **Front-run uncontested KOLs** with reasonable win rate.
- **Back-run any KOL** consistently (block N+1).
- **Front-run heavily-watched top-tier KOLs** — still hard, you're now in
  the same DC tier as pros but they have $2k/mo paid feeds (bloXroute).
  Pick less-watched targets.
