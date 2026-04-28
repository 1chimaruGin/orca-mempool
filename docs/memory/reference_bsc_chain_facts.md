---
name: BSC chain timing facts (2026)
description: Authoritative current BSC block time, hardfork history, finality - to avoid stale Lorentz/Maxwell-era figures
type: reference
originSessionId: 824813a1-89e9-4d37-a802-4de6065c5382
---
**Current BSC mainnet block time: 0.45 seconds** (as of Fermi hard fork, activated 2026-01-14).

**Finality:** approximately 1 second.

**Hard-fork timeline of block-time reductions:**
- 3.0s → 1.5s — Lorentz hard fork
- 1.5s → 0.75s — Maxwell hard fork (June 2025)
- 0.75s → 0.45s — Fermi hard fork (2026-01-14, completed the short-block roadmap)

**Latency implications for sniping/MEV at 0.45s blocks:**
- 150 ms RTT from HEL1 to BSC validators ≈ 33% of one block window
- Anything ≥ ~200 ms latency means consistently missing block N+1 / fighting for block N+2
- Asian relays (Puissant, BlockRazor at ~5-15 ms validator-RTT) become decisive, not just an optimization

**Why this matters:** my training data leans on Maxwell-era 0.75s and earlier 3s figures. Always defer to user-supplied current figures or check on-chain (`eth_getBlockByNumber latest` followed by previous; subtract timestamps) before quoting block time.
