---
name: HTTP-only RPC, no TLS
description: This BSC node is bot-only; user wants HTTP + API key, NOT certbot/Let's Encrypt TLS
type: feedback
originSessionId: 824813a1-89e9-4d37-a802-4de6065c5382
---
Do not configure certbot, Let's Encrypt, or any TLS for the public RPC endpoint on the BSC node. Use HTTP only with `X-API-Key` header check via nginx.

**Why:** The user's bot is the only client; it connects directly via IP + API key. No domain. TLS adds handshake overhead on every RPC call, which conflicts with the latency-critical sniping use case. The API key over HTTP is acceptable here because the bot's source IP is also restricted via UFW.

**How to apply:** Skip the certbot step in any setup script. Bind nginx to a non-standard HTTP port (8645 for RPC, 8646 for WS). Pair the API key with a UFW source-IP allowlist for defense-in-depth. If the user later asks to expose the RPC publicly, push back and recommend re-introducing TLS.
