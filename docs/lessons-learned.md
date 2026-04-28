# Lessons learned (read this before deploying again)

These are non-obvious things that bit us during the first bring-up on Hetzner
HEL1 (2026-04-28). Written so the next deployment doesn't repeat the same
mistakes.

---

## 1. Geography matters more than node spec for BSC sniping

We deployed on **Hetzner HEL1 (Helsinki, Finland)** before discussing where the
bot actually trades. BSC validators run **mostly in Asia (Singapore, Tokyo,
Hong Kong)**. Round-trip latency from HEL1 → BSC validator is **150-250 ms**.

Why this matters:
- For most token-launch sniping on 3-second BSC blocks, an EU node still gets
  txs landed (gas-price ordering inside a block beats arrival-order). You
  *won't* be the absolute fastest but you'll fill many opportunities.
- For high-frequency sandwich MEV competing every block, EU is uncompetitive.
  The top sandwich bots colocate in Asia.

**Rule for the next deploy:** pick the DC *before* discussing node specs.
Hetzner has no Asian DCs. Candidates:

| Provider | DCs | Bare-metal? | Approx. price |
|---|---|---|---|
| Latitude.sh | Tokyo, Singapore | yes | ~$199/mo (Ryzen 9, 64 GB, 2× 1.92 TB NVMe) |
| OVH | Singapore (SGP1) | yes | comparable, AdvanceGEN line |
| Cherry Servers | Singapore | yes | varies |
| Vultr Bare Metal | Tokyo, Singapore | yes | varies |

---

## 2. Public mempool is not the whole mempool

A growing share of profitable BSC tx flow is sent through **private mempools /
builder relays**, not the public p2p mempool your `eth_subscribe
newPendingTransactions` will see:

- 48Club Puissant — `puissant-bsc.48.club`
- BlockRazor / Blink / bloXroute — paid feeds
- NodeReal MegaNode

Plan accordingly:
- A public-mempool-only sniper *will* work but won't see private-relay flow.
- For tx submission you can still benefit from a private relay (e.g., 48Club
  Puissant) even from a public-only receive side. Submit-side relays are
  largely free.

---

## 3. The pruned BSC snapshot is too big for a 1.7 TB disk

When this stack was first designed the assumption was a 300-500 GB snapshot.
The current pruned PBSS snapshot is **~1.5 TB compressed in a single
.tar.lz4** (and ~1.5 TB extracted). On a 1.7-1.8 TB disk you cannot keep the
compressed file and its extraction at the same time.

The streaming downloader at `scripts/download-snapshot.sh` solves this with:
- A FIFO between curl (writer) and `lz4 -d - | tar` (reader).
- HTTP `Range:` headers + a resume loop, because R2 closes long single
  transfers (we saw drops every 30-60 GB).
- A persistent FIFO writer FD across curl invocations, so lz4 never sees EOF
  during a connection drop.

When deploying on a new host, the *baseline* disk you want is **2-2.5 TB+** if
you intend to keep one backup snapshot or any meaningful chain growth runway.

---

## 4. `--state.scheme path` is required for PBSS snapshots

The current pruned snapshot uses path-based state DB (PBSS). geth defaults to
hash-based, and silently fails to open the imported chaindata. Pass:

```
--state.scheme path --db.engine pebble
```

Both flags are wired into `config/systemd/bsc.service.template`.

---

## 5. Disk monitor or you will run out of space silently

BSC chaindata grows **5-10 GB/week** post-snapshot. On a 200 GB headroom box
that's <6 months before the disk fills and the node halts mid-sync at 3 a.m.
The disk-check timer in this repo writes a status line every 15 min and
escalates to journalctl + alert log at 80%. Wire it into your existing alerting
on the new host.

---

## 6. UFW lockout safety

Order of operations matters:
1. `ufw allow 22/tcp` (or your specific source CIDR)
2. **Then** `ufw enable`

If you flip the order, you lose your SSH session immediately. The `install.sh`
in this repo does it in the safe order.

---

## 7. SSH hardening is one-way; verify keys first

Before installing `config/ssh/00-bsc-rpc-hardening.conf` (which disables
password auth), confirm `~/.ssh/authorized_keys` has a real key on it AND that
your current session is using key auth (`who am i` and check `last`). The
install script refuses to apply hardening if `authorized_keys` is empty, but
that's not bulletproof — you can still lock yourself out if the only key is
broken.

---

## 8. Storage Box ≠ live storage

A Hetzner Storage Box is great for backups (rsync over SSH on port 23) but is
*not* a viable place to put live geth chaindata. SFTP latency would tank IOPS
and geth would be unhappy. Use it for:

- Periodic chaindata rsync (after stopping geth — see
  `scripts/backup-to-storage-box.sh shutdown`)
- Snapshot staging if you ever switch to download-then-extract instead of
  streaming
- Config backups
- Copy of API key and host SSH keys so a re-deploy is fast

---

## 9. Don't let setup fees be a sunk-cost trap

Hetzner dedicated servers have a non-refundable setup fee (~$42 on AX41-NVMe).
If you realize the location is wrong on day 1, cancelling immediately costs
≈ setup fee + 1-2 days of pro-rata, NOT the full month. Cancel sooner rather
than later if migration is a foregone conclusion.

---

## 10. Stop the snapshot before destroying the host

The snapshot download is a 10-hour streaming job. If you're about to nuke the
host, kill the script, the curl, the lz4, and the tar processes; remove the
partial chaindata; *then* tear down. Otherwise you waste outbound R2 bandwidth
quota for no reason and possibly draw rate-limiting that hurts your next
download attempt.

---

## What this repo does NOT yet provide

- TLS for the RPC endpoint (intentional — see `feedback_no_tls` decision)
- Bot/mempool consumer code (this is just the node + auth gate)
- Validator-direct submit path (no bundle relay integration)
- Chain re-snapshot automation (you re-run download-snapshot.sh by hand)
