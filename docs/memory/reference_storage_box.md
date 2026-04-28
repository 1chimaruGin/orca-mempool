---
name: Hetzner Storage Box for BSC node backups
description: SSH-key-authenticated rsync target for chaindata backups + snapshot staging
type: reference
originSessionId: 824813a1-89e9-4d37-a802-4de6065c5382
---
5 TB Hetzner Storage Box at HEL1 (same DC as the BSC node), purchased 2026-04-28 specifically as a backup/staging target for the BSC RPC node.

**Connection (passwordless via key):**
- Host: `u584696.your-storagebox.de`
- User: `u584696`
- Port: `23`
- Identity file: `/root/.ssh/id_ed25519` on the BSC node (ed25519, fingerprint `SHA256:TfcVO9LmQsrbpzGDPu4t/DBAQnL2lrXqOayXO/1slcA`)
- Restricted shell — only SFTP / rsync / scp work, no arbitrary commands.

**Working commands:**
```
sftp -P 23 -i /root/.ssh/id_ed25519 u584696@u584696.your-storagebox.de
rsync -av -e 'ssh -p 23 -i /root/.ssh/id_ed25519' SRC u584696@u584696.your-storagebox.de:./PATH/
```

**Intended uses:**
1. Periodic chaindata backups (rsync after stopping geth — chaindata is open files; can also use BSC's `geth db inspect` while running with care)
2. Staging area for future BSC snapshot downloads (compressed file lands here, then extract to local /data, avoids the "compressed + extracted both on local 1.7 TB" problem)
3. Disaster recovery copy of `/data/bsc-rpc/config/`, `/etc/systemd/system/bsc.service`, `/etc/nginx/sites-available/bsc-rpc`, `/data/bsc-rpc/scripts/`

**Cost:** ~€13/mo (5 TB).

**Note:** Storage Box password was shared in the bootstrap transcript on 2026-04-28 and should be rotated; key access has been working since then so the password is no longer needed.
