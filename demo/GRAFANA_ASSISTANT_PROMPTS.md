# Grafana Assistant Demo Prompts

5 prompts, one sentence each. Use them in order after running
`./demo-check.sh` and confirming the alert is Firing.

> Replace `<your-org>/<your-repo>` in Prompt 4 with your own GitHub fork
> (e.g. the `GITHUB_OWNER` and `GITHUB_REPO` from your `.env`).

---

## Prompt 1

There's a critical alert firing in Grafana, analyze what's happening.

> **What happens:** Assistant reads the firing alert context, queries
> `traces_spanmetrics_latency_bucket` for `frontend-api`, and confirms p99
> checkout latency is ~1s — well above the 300ms threshold.

---

## Prompt 2

Show me the service map for the last 10 minutes and tell me which service generates the most spans.

> **What happens:** Assistant opens the Tempo service map, identifies the chain
> `frontend-api → order-service → inventory-service`, and flags that
> `inventory-service` has ~10× more spans than expected for the traffic volume —
> the N+1 signature.

---

## Prompt 3

Find traces from order-service where there are more than 5 calls to inventory-service in a single request.

> **What happens:** Assistant queries Tempo for traces where `order-service`
> fans out into many child spans. It surfaces order-6 (10 items, ~1s total) and
> shows the sequential waterfall — each `GET /items/{id}` blocks the next.
> Points out `/items/batch` as the fix.

---

## Prompt 4

Use the GitHub MCP to create a PR in `<your-org>/<your-repo>` that fixes the N+1 bug in order-service. The fix must only modify the file `k8s/order-service.yaml`. Do not touch the Python code.

> **What happens:** Assistant uses GitHub MCP to create a branch
> `fix/order-service-n-plus-one`, commits **only** `k8s/order-service.yaml`
> changing `BUG_ENABLED` from `"true"` to `"false"`, and opens a PR linking
> the traces to the fix. **Merge the PR** — `deploy-on-merge.yml` auto-deploys
> in ~30s and stamps `SERVICE_VERSION=<sha>-fix`.

---

## Prompt 5

Using Prometheus span metrics, show me p99 latency for order-service grouped by service_version to compare before and after the fix.

> **What happens:** Assistant queries:
> ```promql
> histogram_quantile(0.99, sum by (le, service_version) (
>   rate(traces_spanmetrics_latency_bucket{
>     service="order-service",
>     span_name="GET /orders/{order_id}"
>   }[5m])
> )) * 1000
> ```
> `service_version` is a confirmed label on these metrics. Two series appear:
> - `<sha>` (buggy): p99 ~950ms
> - `<sha>-fix` (fixed): p99 ~90ms
>
> 10x improvement as a visible step-change. Also open the
> **Order Service Demo** dashboard in Grafana for the full visual.

---

## After the Demo

```bash
./deploy.sh --reset   # auto-opens restore PR (admin merge) + re-enables bug in cluster
./demo-check.sh       # verify ready
```
