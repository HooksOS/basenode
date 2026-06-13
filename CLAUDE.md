# CLAUDE.md

Guidance for working in this repository. Read this before making changes.

## What this is

This repo runs a **Base L2 node** (Coinbase's OP-Stack chain) via Docker Compose.
It is **infrastructure**, not the launchpad application. It provides on-chain data
and transaction submission to the launchpad's backend.

Two processes run per node (see `supervisord.conf`):

- **execution** — `base-reth-node` (Reth). Serves JSON-RPC (`8545` HTTP, `8546` WS),
  the engine API (`8551`, internal only), and P2P.
- **consensus** — `base-consensus` (OP-Stack derivation). Drives the execution
  client and forwards transactions to the Base sequencer.

The binaries are **not** in this repo. They are built from `base/base` pinned in
`versions.env` (currently `v1.1.0`, commit-verified in the `Dockerfile`). Treat the
node software as an upstream dependency — we configure and operate it, we don't fork it.

## How it's used by the launchpad

We run a **hybrid RPC** topology:

- **Public / frontend traffic** → a managed provider (Alchemy / QuickNode / Base public RPC).
  The provider absorbs DDoS, rate limits, and global latency. The frontend wallet never
  talks to our node directly.
- **Launchpad backend** (indexer, event listeners, tx submission) → **this self-hosted node**,
  reachable **only over a private network / firewall** to backend IPs. This is where we get
  no rate limits, full history, and cost control at scale.

The node is **mainnet** (`base`). Real funds depend on it — see the rules below.

## Non-negotiable operating rules

1. **Never expose `8545` / `8546` / `8551` / metrics ports to the public internet.**
   The RPC binds to `0.0.0.0` inside the container with `--http.corsdomain="*"`,
   `--ws.origins="*"`, and the `debug` / `txpool` / `miner` namespaces enabled
   (see `execution-entrypoint`). That is acceptable **only** behind the host firewall.
   The host firewall (`ops/firewall/ufw.sh`) is the authoritative network gate — apply it
   before the node ever syncs on a public IP. Publicly reachable ports are P2P only
   (`9222`, `30303` TCP+UDP).
2. **`8551` (engine authrpc) must never leave the host.** It is not published in
   `docker-compose.yml`; keep it that way.
3. **Rotate the engine JWT before production.** `.env.mainnet` ships a well-known
   default (`BASE_NODE_L2_ENGINE_AUTH_RAW=688f5d…`). Generate a fresh one
   (`openssl rand -hex 32`) and keep it in `.env.production` (gitignored), not in a
   committed file. Both processes must use the same value.
4. **Do not run a single node behind real money.** Run ≥2 nodes; the managed provider
   is the third leg. A single node is a single point of failure for mints/buys.
5. **Secrets never get committed.** Real L1 endpoints, JWTs, and provider keys live in
   `.env.production` / secret manager. `.gitignore` excludes them — keep it that way.
6. **Pruning/archive mode is permanent.** The node type chosen at first sync cannot be
   changed later (see note in `.env.mainnet`). For a launchpad we default to **archive**
   so the indexer can backfill historical logs.

## Key files

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Base service definitions (execution + consensus). |
| `docker-compose.prod.yml` | Production hardening overlay (logging, healthchecks, limits). |
| `.env.mainnet` / `.env.sepolia` | Network config. **Contains placeholder secrets — do not put real ones here.** |
| `.env.production.example` | Template for real secrets; copy to `.env.production` (gitignored). |
| `execution-entrypoint` | Reth launch flags. Upstream-shaped; avoid editing — override via env/compose. |
| `consensus-entrypoint` | op-node launch logic (incl. follow mode). |
| `versions.env` | Pinned upstream commit/tag for the node binaries. |
| `ops/firewall/ufw.sh` | Host firewall rules — the public-exposure gate. |
| `ops/monitoring/` | Prometheus + Grafana stack scraping node metrics. |
| `docs/LAUNCHPAD-PLAN.md` | Full architecture, rollout, security, and cost plan. |

## Common commands

```bash
# Start (mainnet, hardened) — set real secrets in .env.production first
docker compose --env-file .env.production -f docker-compose.yml -f docker-compose.prod.yml up -d --build

# Tail logs (structured JSON)
docker compose logs -f execution
docker compose logs -f node

# Health: latest block (run on the host; do NOT open this port publicly)
curl -s -X POST localhost:8545 -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Sync progress vs head — compare to https://base.org/stats
# Generate a fresh engine JWT
openssl rand -hex 32
```

## When changing things

- **Config changes** go in env files / compose overrides, **not** in the entrypoints
  (they track upstream).
- **Upgrading the node**: bump `versions.env` to a new tag + commit, rebuild, verify sync
  on **sepolia first**, then roll mainnet one node at a time (the other serves traffic).
- **Before exposing anything**: re-check rule #1. When in doubt, keep it private and route
  public traffic through the managed provider.
- Run `/security-review` on any change that touches port bindings, the firewall, secrets,
  or the entrypoints.
