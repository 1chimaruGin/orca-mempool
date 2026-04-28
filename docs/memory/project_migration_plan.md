---
name: BSC node migration to Asia DC
description: Plan to migrate from Hetzner HEL1 to Asia (Tokyo/Singapore) at end of May 2026 for MEV/sniping latency
type: project
originSessionId: 824813a1-89e9-4d37-a802-4de6065c5382
---
User bought Hetzner AX41-NVMe HEL1 (135.181.215.53) on 2026-04-28 for ~$100/mo before discussing geography. HEL1 → BSC validators (mostly Asia) is 150-250 ms RTT, which limits competitiveness for latency-critical BSC sniping/MEV.

**Decision (2026-04-28, revised same day):** Do NOT cancel Hetzner. Keep HEL1 as the main node + bot host. Add a small Singapore VPS later as a *relay* (mempool ingest + tx submit) when cost permits. User considered cancelling for a full Asia migration but chose this hybrid approach to control cost.

**Singapore relay design (planned, not built):**
- Cheap VPS (target $5-15/mo) in Singapore.
- Runs a thin geth peer or pure relay daemon that connects to BSC peers locally and forwards pending tx hashes/full bodies to HEL1 via a persistent low-overhead channel (gRPC or raw TCP pipe).
- Receives signed tx blobs from HEL1 and broadcasts to local BSC peers / submits to validator-direct endpoints (e.g., 48Club Puissant in Asia).
- Net win: ~30% latency reduction end-to-end vs HEL1-only, and direct submission to Asian validators improves inclusion reliability.

**Why hybrid not pure-Singapore:** Full BSC nodes need 64 GB RAM and 2+ TB NVMe — Asian bare-metal of that spec runs $200-300/mo. A relay VPS is $10-15/mo. HEL1 stays as the heavy-state node; Singapore is just the latency frontend.

**Migration prep (do during April-May while HEL1 is up):**
- Daily rsync of chaindata + configs to the Hetzner Storage Box (`u584696@u584696.your-storagebox.de`). Migration becomes "rsync from box to new node" instead of re-downloading 1.5 TB snapshot.
- Save all configs to the box: systemd unit, nginx config, /data/bsc-rpc/config, /data/bsc-rpc/scripts.

**Asia provider shortlist to research:**
- Latitude.sh Tokyo (Ryzen 9 / 64 GB / 2× 1.92 TB NVMe ~$199/mo)
- OVH Singapore (SGP1) AdvanceGEN line
- Cherry Servers Singapore
- Constant / Vultr bare metal Tokyo/Singapore

**Why:** User runs a BSC sniping bot. Strategy uses public mempool — see private-mempool note in `feedback_no_tls.md` for that gap. Even with public-only mempool, geography to BSC validators is the main remaining lever for tx-landing speed.

**How to apply:** When the user resumes work in this project after gathering data, ask first whether profits from HEL1 were good enough to consider staying, before assuming the migration must happen. The Storage Box is keeper regardless of compute location.
