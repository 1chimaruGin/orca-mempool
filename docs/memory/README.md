# Agent memory snapshot

These are the memory entries the AI agent built up during the Hetzner HEL1
deployment on 2026-04-28. They're snapshotted into the repo so when you
re-deploy on a Singapore box, you (or a future agent) can re-load them as
context.

The schema is loose: each file has YAML frontmatter (`name`, `description`,
`type`) followed by markdown body. Types in use:

- **project** — initiatives, decisions, deadlines for this work
- **feedback** — corrections / preferences that should shape future work
- **reference** — pointers to external systems / immutable facts

`MEMORY.md` is the index. Entries for the most-relevant ones in order of
likely usefulness on the next deploy:

1. [reference_bsc_chain_facts.md](reference_bsc_chain_facts.md)
   — current BSC block time (0.45 s post-Fermi 2026-01-14), finality, hard-fork
     history. Don't quote stale Maxwell-era numbers.
2. [project_bsc_rpc.md](project_bsc_rpc.md)
   — what this whole project is for and the original brief
3. [feedback_no_tls.md](feedback_no_tls.md)
   — single bot, HTTP+API-key only, no certbot. Persists across redeploys.
4. [project_migration_plan.md](project_migration_plan.md)
   — the Asia-DC migration plan and the cancellation decision
5. [reference_storage_box.md](reference_storage_box.md)
   — Hetzner Storage Box for backups (separate from server, NOT cancelled
     when the server is)
6. [reference_server_layout.md](reference_server_layout.md)
   — the OLD Hetzner box's paths/ports. Will need to be replaced when you
     move to Singapore.

## Reloading these into a future agent

When you start a fresh Claude session on the Singapore box:

```bash
mkdir -p /root/.claude/projects/$(pwd | sed 's,/,-,g')/memory
cp /opt/orca-mempool/docs/memory/*.md /root/.claude/projects/$(pwd | sed 's,/,-,g')/memory/
```

The agent will pick them up automatically on next conversation.

## What you should update when you migrate

- `reference_server_layout.md` — change IP, hostname, paths, the storage
  partition layout for the new box.
- `project_migration_plan.md` — flip status to "migrated", note the date.
- Add a new reference file describing the Singapore provider, plan, and
  any quirks of that environment.
