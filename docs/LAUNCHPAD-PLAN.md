# Launchpad Node — Architecture & Rollout Plan

**Scope:** stand up this Base node as production RPC infrastructure for a token launchpad.
**Decisions locked:** hybrid RPC (managed primary + self-host), **Base mainnet**, **bare-metal / dedicated host**.

> Honest framing first: you do **not** need to self-host to launch. A managed provider
> alone can carry a launchpad to meaningful scale. We self-host for (a) cost control once
> RPC volume is high, (b) no third-party rate limits on the indexer's backfills, (c) an
> independent fallback if the provider degrades, and (d) data privacy. The plan treats the
> self-hosted node as the **backend's** workhorse and keeps the provider as the public face.

---

## 1. Target architecture

```
                         ┌──────────────────────────┐
   Wallets / Frontend ──▶│  Managed RPC (Alchemy/QN) │  public, DDoS-protected, rate-limited
                         └──────────────────────────┘
                                     ▲  (failover)
                                     │
┌────────────────────┐      ┌────────────────────┐      ┌──────────────────────────────┐
│  Launchpad backend │─────▶│  Private RPC LB     │─────▶│  Self-hosted Base nodes (≥2)  │
│  - indexer         │      │  (firewall'd, TLS)  │      │  reth + op-node, mainnet,     │
│  - event listeners │      └────────────────────┘      │  ARCHIVE, on NVMe RAID        │
│  - tx submission   │                                   └──────────────────────────────┘
└────────────────────┘                                              │
                                                                     ▼
                                                        forwards txs to Base sequencer
```

- **Public traffic never touches our node.** The frontend uses the managed provider.
- **Backend talks to our nodes privately** (firewall + private network), with the managed
  provider as automatic failover at the backend's RPC client layer.
- **≥2 self-hosted nodes** behind a simple private load balancer / client-side round-robin.
  Mainnet money flows must survive one node dying or being upgraded.

---

## 2. Division view (who cares about what)

| Division | Top priorities for this node |
| --- | --- |
| **Engineering** | Reproducible builds (pinned `versions.env`), idempotent deploys, one-node-at-a-time upgrades, no edits to upstream entrypoints. |
| **Security** | RPC never public, JWT rotated, `debug`/`txpool` reachable only by backend, firewall as the gate, secrets in a manager, key custody for any tx-signing kept **out** of the node. |
| **Infrastructure** | NVMe RAID0 + ext4, archive sizing + 20% buffer, snapshot restore for fast bring-up, healthchecks, log rotation, fd limits. |
| **Reliability** | ≥2 nodes + managed failover, alerting on sync stall / scrape down / disk, runbook for restore, defined RTO/RPO. |
| **Performance** | Flashblocks for sub-200ms pending state (snappy mint/buy), WS subscriptions for the indexer, local reads = no provider latency. |
| **Product / UX** | Fast confirmation feedback, reliable event delivery (no missed mints), accurate balances. |
| **Growth / Business** | Cost per RPC call trending down as we shift volume from provider → self-host; provider as the launch accelerant. |
| **Sustainability** | Documented upgrades tracking upstream `base/base`, on-call runbook, monitoring you can hand to an ops person. |

---

## 3. Phased rollout

### Phase 0 — Decide & size (before touching the server)
- Confirm **archive vs full/pruned**. Default **archive** (indexer backfills historical logs).
  This choice is permanent after first sync.
- Size storage: `2 × current chain size + snapshot size + 20%`. Check
  https://base.org/stats and https://basechaindata.vercel.app. Provision NVMe RAID0 / ext4.
- Pick the managed provider (Alchemy or QuickNode) and create the launchpad's API keys.

### Phase 1 — Single node, bring-up (validate the box)
1. `cp .env.production.example .env.production` and fill real values.
2. **Rotate the JWT:** `openssl rand -hex 32` → `BASE_NODE_L2_ENGINE_AUTH_RAW`.
3. Point `HOST_DATA_DIR` at the NVMe mount.
4. **Apply the firewall first:** `sudo BACKEND_CIDRS="<backend-cidr>" SSH_CIDR="<admin-cidr>" bash ops/firewall/ufw.sh`.
5. (Optional, strongly recommended) restore from a snapshot to skip days of sync —
   see https://docs.base.org/chain/run-a-base-node#snapshots.
6. Start: `docker compose --env-file .env.production -f docker-compose.yml -f docker-compose.prod.yml up -d --build`.
7. Wait for sync; verify against chain head (see §6).

### Phase 2 — Observability
- `docker compose -f ops/monitoring/docker-compose.monitoring.yml up -d`.
- Confirm Prometheus scrapes reth (`:7301`) and op-node (`:7300`); import a reth/op-node Grafana dashboard.
- Wire alert delivery (Alertmanager → PagerDuty/Slack). Add `node_exporter` for disk/CPU.

### Phase 3 — Integrate the launchpad backend
- Backend RPC client: **primary = self-hosted private endpoint, fallback = managed provider**,
  with health-based switchover and retries.
- Indexer uses WS subscriptions (`8546`) for new heads / logs; tx submission via HTTP (`8545`).
- Enable Flashblocks (`RETH_FB_WEBSOCKET_URL`) if you want sub-block pending UX for mints.

### Phase 4 — HA & production cutover
- Stand up the **second node** (repeat Phase 1 on a second host, ideally different
  rack/provider). Put both behind the private LB / client round-robin.
- Load-test the backend against the nodes; confirm failover by killing one node.
- Define RTO/RPO and rehearse the snapshot-restore runbook.

### Phase 5 — Optimize cost & scale
- Shift read volume from provider → self-host as confidence grows; keep provider for spikes
  and failover. Track cost-per-call and tune the split.

---

## 4. Security checklist (gate to production)

- [ ] Engine JWT rotated; default `688f5d…` not in use.
- [ ] Real secrets only in `.env.production` / secret manager; nothing sensitive committed.
- [ ] Firewall applied: `8545/8546/7300/7301` reachable **only** from backend CIDRs; `8551` unpublished; P2P public.
- [ ] RPC confirmed unreachable from the public internet (test from an outside host).
- [ ] `debug`/`txpool`/`miner` namespaces never exposed beyond the backend.
- [ ] Tx-signing keys (deployer / treasury) live in a signer/KMS/hardware wallet — **never** on the node host.
- [ ] Monitoring + alerting live; on-call rota set.
- [ ] Snapshot-restore runbook rehearsed; second node ready before real money flows.
- [ ] Upgrade procedure tested on sepolia.
- [ ] Run `/security-review` on the deploy config.

---

## 5. Cost & sustainability (rough, validate locally)

- **Self-host:** dedicated host with multi-TB NVMe (e.g. Hetzner/Latitude) is typically a few
  hundred USD/mo per node; ×2 for HA. Largely fixed regardless of RPC volume.
- **Managed provider:** usage-based; cheap at low volume, grows with traffic. Keep as primary
  at launch, shrink its share as self-host proves out.
- **Break-even:** self-hosting wins once sustained RPC volume exceeds the provider's
  mid-tier plan — re-evaluate the split quarterly. Until then the provider buys you speed and
  reliability for little money.

---

## 6. Runbook (operational quick reference)

```bash
# Start / stop
docker compose --env-file .env.production -f docker-compose.yml -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.prod.yml down

# Health: latest block (host-only; never open this port publicly)
curl -s -X POST localhost:8545 -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Compare to chain head: https://base.org/stats   (synced when within a few blocks)

# Logs
docker compose logs -f execution    # reth
docker compose logs -f node         # op-node

# Verify RPC is NOT public (run from a machine outside the backend network):
#   curl --max-time 5 http://<node-public-ip>:8545   -> must time out / refuse
```

**Upgrade the node** (tracks upstream `base/base`):
1. Bump tag + commit in `versions.env`.
2. Rebuild + verify on a **sepolia** node first.
3. Roll mainnet **one node at a time** — the other serves the backend throughout.

**Incident: node down / stalled**
1. Backend should already be failing over to the managed provider (verify).
2. Check `docker compose logs`, disk space, L1 endpoint health.
3. If data corrupt: restore from snapshot, re-sync, rejoin the LB.

---

## 7. What this node is *not*

It is RPC + tx-submission infrastructure. It does **not** hold the launchpad's funds, sign
transactions, or run business logic. Smart-contract security (audits, the bonding-curve /
sale contracts, treasury custody) is a separate, higher-stakes workstream — track it in the
launchpad application repo, not here.
