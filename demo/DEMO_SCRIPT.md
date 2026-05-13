# Demo Script — Grafana Cloud N+1 Bug

**Duration:** ~15 min | **Audience:** Technical / DevOps / SRE

> URLs below reference variables from your `.env`. With `GRAFANA_HOST=acme.grafana.net`
> and `GITHUB_OWNER=acme` your firing alert URL becomes
> `https://acme.grafana.net/alerting/grafana/order-svc-checkout-latency/view`, etc.

## Quick-access URLs (open these before starting)

| What | URL |
|------|-----|
| Firing alert | `https://${GRAFANA_HOST}/alerting/grafana/${ALERT_RULE_UID}/view` |
| Demo dashboard | `https://${GRAFANA_HOST}/d/${DASHBOARD_UID}` |
| App Observability | `https://${GRAFANA_HOST}/a/grafana-app-observability-app/services` |
| Grafana Assistant | Open from the sparkle icon (top-right of any Grafana page) |
| GitHub PRs (after Prompt 4) | `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/pulls` |

Running `./demo-check.sh` prints these fully resolved URLs.

---

## Before You Start

```bash
./demo-check.sh
```

All 4 checks must pass (pods running, bug enabled via /health, order-6 >800ms, alert Firing).
If the alert is Pending, wait 1–2 minutes — it fires quickly once latency crosses 300ms.

---

## Act 1 — The Alert (2 min)

- Open the **firing alert URL** above. Show the
  **"frontend-api checkout latency high"** alert in **Firing** state.
- *"This alert fired on its own — p99 checkout latency crossed 300ms.
  Let's hand this to Grafana Assistant."*
- Open Grafana Assistant (sparkle icon, top-right).

---

## Act 2 — Root cause with Assistant (8 min)

Use the prompts in `GRAFANA_ASSISTANT_PROMPTS.md` in order.

**Prompt 1** — Assistant reads the firing alert, queries
`traces_spanmetrics_latency_bucket` for `frontend-api`, and confirms p99 ~1s.

**Prompt 2** — Assistant opens the App Observability service map, identifies
`frontend-api → order-service → inventory-service`, and flags that
`inventory-service` has ~10× more spans than traffic volume — the N+1 signature.

**Prompt 3** — Assistant queries Tempo, surfaces order-6 (10 items, ~1s) and
shows the sequential waterfall: each `GET /items/{id}` blocks the next.

---

## Act 3 — Fix via GitHub MCP (3 min)

**Prompt 4** — Assistant creates a PR via GitHub MCP.

- Branch `fix/order-service-n-plus-one`, changes `BUG_ENABLED` to `"false"`
  in `k8s/order-service.yaml` only.
- Open the **GitHub PRs URL** above and show the open PR.
- **While waiting for approval:** explain the deployment pipeline — the
  `deploy-on-merge.yml` workflow applies the manifest and restarts the pod in
  ~30s, no image rebuild needed.
- **Merge the PR** — workflow triggers automatically. The PR comment confirms
  deploy when done (`SERVICE_VERSION=<sha>-fix` stamped).

---

## Act 4 — Confirm the improvement (2 min)

**Prompt 5** — Assistant queries span metrics grouped by `service_version`:

- `<sha>` (buggy): p99 ~950ms
- `<sha>-fix` (fixed): p99 ~90ms

Open the **demo dashboard** URL above — the `Fix deployed` annotation marks
the exact moment of the drop. The N+1 panel also shows inventory-service spans
collapsing from ~30/s to ~3/s.

> **Heads-up:** span metrics have a 1–3 min pipeline delay (Alloy → Prometheus).
> Right after the deploy you'll see a brief gap in the chart before the new
> `<sha>-fix` series appears. The annotation is instant; the chart catches up.

---

## Reset for Next Run

```bash
./deploy.sh --reset   # auto-opens restore PR (admin-merged) + re-enables bug in cluster + posts "Demo reset" annotation
./demo-check.sh       # verify ready
```
