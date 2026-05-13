# Grafana Cloud Demo — Order Service N+1 Bug

A high-impact, fully reproducible demo: a Grafana alert fires on a real latency
spike, **Grafana Assistant** investigates traces and span metrics across three
microservices, identifies an N+1 query bug, and opens a GitHub PR with the
fix. The PR merge triggers an automated deploy, span metrics show the latency
drop grouped by `service.version`, and a single command resets everything for
the next run.

Everything lives inside Grafana Cloud + your own Kubernetes cluster + your own
fork of this repo. Roughly 15 minutes end-to-end.

---

## The Scenario

`order-service` has an N+1 bug: each checkout makes **N individual HTTP calls**
to `inventory-service` (one per item) instead of a single batch call.

| Order | Items | Buggy latency | Fixed latency |
|-------|-------|--------------|---------------|
| order-1 | 3 | ~270ms | ~90ms |
| order-4 | 5 | ~480ms | ~90ms |
| order-6 | 10 | ~1000ms | ~100ms |

A Grafana alert fires when `frontend-api` p99 checkout latency > 300ms.
Grafana Assistant diagnoses the root cause from traces and opens the fix PR.

---

## Architecture

```
load-generator (3 RPS, 50% to order-6)
      │
      ▼
frontend-api ──────────────────────────────┐
      │                                    │
      ▼                                    │
order-service ──(N calls, buggy)──▶ inventory-service
              ──(1 batch, fixed)──▶ inventory-service

Each service exports OTLP traces + metrics → Alloy (k8s-monitoring) → Grafana Cloud
```

The bug is controlled by a single env var (`BUG_ENABLED`) in
[`k8s/order-service.yaml`](k8s/order-service.yaml). Flipping it `true`↔`false`
is the entire fix — no rebuild, no migration.

---

## Prerequisites

**Tools on your machine**

- `kubectl` against a cluster where you have permissions to create namespaces
- `gh` (GitHub CLI), logged in to a user with admin rights on your fork
- `gcx` ([Grafana Cloud CLI](https://github.com/grafana/gcx)), authenticated against your stack
- `envsubst` (ships with `gettext`; macOS: `brew install gettext`)
- `python3` (used by helper scripts)

**Grafana Cloud**

- A Grafana Cloud stack
- Grafana Cloud k8s Monitoring (Alloy + spanmetrics processor) installed in
  your cluster — `order-service`, `frontend-api`, etc. must produce
  `traces_spanmetrics_latency_bucket` metrics
- A Service Account with **Editor** scope, token saved into your `gcx` config
  (`gcx auth …` or hand-rolled `~/.config/gcx/config.yaml`)

**GitHub**

- A fork of this repo under your user/org
- Branch protection on `main` (so PRs are the only path) — this is what
  makes the demo realistic. The `--reset` flow uses `gh pr merge --admin`
  to bypass it, so your user needs admin on the repo.

---

## Setup

### 1. Fork and clone

```bash
gh repo fork grafana-demo-orderservice --clone --remote
cd grafana-demo-orderservice
```

### 2. Configure `.env`

```bash
cp .env.example .env
$EDITOR .env
```

Fill in:

| Variable | What |
|---|---|
| `GITHUB_OWNER` | Your fork's owner |
| `GITHUB_REPO` | `grafana-demo-orderservice` (unless you renamed it) |
| `GHCR_IMAGE_PREFIX` | `ghcr.io/${GITHUB_OWNER}/${GITHUB_REPO}` (default works) |
| `GRAFANA_HOST` | e.g. `acme.grafana.net` (no protocol) |
| `GCX_CONTEXT` | Your `gcx` context name (`gcx config get-contexts`) |
| `ALERT_RULE_UID` | Any stable string you want for the alert UID. Default `order-svc-checkout-latency`. Whatever you put here ends up as the rule's `uid` in Grafana and in the URLs printed by `demo-check.sh` |
| `DASHBOARD_UID` | Same, for the dashboard. Default `order-service-n-plus-one-demo` |

`.env` is git-ignored — your values stay local.

### 3. Configure GitHub repo (Settings → Secrets and variables → Actions)

**Repository variables**

| Name | Example value |
|---|---|
| `GRAFANA_HOST` | `acme.grafana.net` |
| `DASHBOARD_UID` | `order-service-n-plus-one-demo` |

**Repository secrets**

| Name | What |
|---|---|
| `KUBECONFIG` | Base64-encoded kubeconfig (`base64 -i ~/.kube/config \| pbcopy`). Used by `deploy-on-merge.yml` |
| `GRAFANA_SA_TOKEN` | Grafana Cloud SA token with Editor scope. Used to post "Fix deployed" annotations |

> The `build-push.yml` workflow uses the built-in `GITHUB_TOKEN` to push images to your fork's GHCR — no extra setup.

### 4. Deploy

```bash
./deploy.sh
```

This:
- Creates the `grafana-demo` namespace
- Renders k8s manifests with envsubst (substituting `${GHCR_IMAGE_PREFIX}`) and applies them
- Waits for all 4 deployments to roll out
- Provisions the dashboard via `gcx` (folder `Order Service Demo`)

> **First-time deploy:** images are pulled from your GHCR. The first push of
> `main` triggers `build-push.yml` which publishes `:latest` for each service.
> If you've just forked and pushed for the first time, wait for that workflow
> to complete before running `./deploy.sh`, or you'll get `ImagePullBackOff`.

### 5. Import the alert rule

The dashboard is provisioned automatically by `./deploy.sh` (rendered with
your `DASHBOARD_UID`). The alert rule is exported in
[`grafana/alert-checkout-latency.json`](grafana/alert-checkout-latency.json)
and needs to be imported once. Its `uid`, `runbook_url`, etc. are templated
on your `.env`:

```bash
set -a; . ./.env; set +a
envsubst < grafana/alert-checkout-latency.json | gcx alert-rules create -f -
```

The UID created in Grafana is exactly what you set in `ALERT_RULE_UID` —
change it to whatever you want, the scripts will follow. Same for
`DASHBOARD_UID`.

---

## Running the demo

```bash
./demo-check.sh
```

Four checks must pass: pods Running, `BUG_ENABLED=true` confirmed via `/health`,
order-6 latency > 800ms, alert Firing. The script prints fully-resolved
quick-access URLs (alert, dashboard, App Observability).

> Only deploy/reset events post dashboard annotations — `demo-check.sh` is
> read-only. Look for `Demo reset` (orange) and `Fix deployed` (green) markers
> on the timeline.

Then follow [`demo/DEMO_SCRIPT.md`](demo/DEMO_SCRIPT.md) — 4 acts, ~15 min:

1. **The alert** — show the firing alert in Grafana
2. **Root cause with Assistant** — Prompts 1–3 from `demo/GRAFANA_ASSISTANT_PROMPTS.md`
3. **Fix via GitHub MCP** — Prompt 4: Assistant opens a PR flipping `BUG_ENABLED` to `false`. **Merge it.** The `deploy-on-merge.yml` workflow auto-applies the manifest and posts a "Fix deployed" annotation.
4. **Confirm improvement** — Prompt 5: span metrics grouped by `service.version` show the 10× drop

---

## Reset between runs

```bash
./deploy.sh --reset
```

What happens:

1. If `main` has `BUG_ENABLED=false` (because the Assistant's fix PR just
   landed), the script opens an automated `restore/re-enable-bug-<ts>` PR
   and merges it with `gh pr merge --admin --squash`. Idempotent — no-op
   if `main` is already in the reset state.
2. Re-renders and applies `k8s/order-service.yaml` against the cluster
3. Stamps a new `SERVICE_VERSION` (the new short SHA) and forces a rollout restart
4. Posts a `Demo reset` annotation to the dashboard

Repo and cluster are kept in lockstep — no out-of-band patching.

---

## How the deploy loop works

```
main (BUG_ENABLED=true) ────────────────────────────────────┐
                                                            │
  ./demo-check.sh   (read-only: validates state, prints URLs) │
  AI Assistant creates fix PR (BUG_ENABLED=true → false)     │
       │                                                    │
       merge                                                 │
       ▼                                                    │
  .github/workflows/deploy-on-merge.yml                      │
       ├─ guard: only deploy if BUG_ENABLED is false/absent  │
       ├─ kubectl apply k8s/order-service.yaml               │
       ├─ kubectl set env SERVICE_VERSION=<sha>-fix          │
       ├─ kubectl rollout restart                            │
       └─ POST "Fix deployed" annotation                     │
                                                            │
  ./deploy.sh --reset ──▶ auto-PR restore (admin merge) ─────┘
                          + kubectl apply + new SERVICE_VERSION
                          + "Demo reset" annotation
```

---

## Telemetry

| Signal | What it shows |
|--------|---------------|
| Prometheus | p99 latency spike on `frontend-api`; alert fires after 1 min |
| Tempo | Waterfall of N sequential `GET /items/{id}` spans per request |
| App Observability | Service map: frontend-api → order-service → inventory-service |
| `service.version` label | Short git SHA before fix; `<sha>-fix` after |
| Dashboard annotations | `Fix deployed` and `Demo reset` mark each deploy event on the timeline |

---

## Files of interest

- [`services/order-service/main.py`](services/order-service/main.py) — the N+1 toggle
- [`k8s/order-service.yaml`](k8s/order-service.yaml) — the `BUG_ENABLED` env var
- [`.github/workflows/build-push.yml`](.github/workflows/build-push.yml) — builds images to your GHCR
- [`.github/workflows/deploy-on-merge.yml`](.github/workflows/deploy-on-merge.yml) — auto-deploys fix PRs
- [`deploy.sh`](deploy.sh) — single entry point (deploy / reset / teardown)
- [`demo-check.sh`](demo-check.sh) — pre-demo readiness checks
- [`grafana/dashboard-order-service.json`](grafana/dashboard-order-service.json) — demo dashboard (auto-provisioned)
- [`grafana/alert-checkout-latency.json`](grafana/alert-checkout-latency.json) — alert rule (manual import once)

---

## Teardown

```bash
./deploy.sh --teardown   # deletes the grafana-demo namespace
```

The dashboard and alert rule in Grafana Cloud stay — delete them via UI or
`gcx` if you want a fully clean state.
