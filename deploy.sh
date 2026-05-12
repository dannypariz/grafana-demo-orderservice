#!/usr/bin/env bash
# deploy.sh — Grafana Cloud demo deployment helper
#
# Usage:
#   ./deploy.sh             Deploy everything (BUG_ENABLED comes from k8s/order-service.yaml)
#   ./deploy.sh --reset     Restore main to BUG_ENABLED=true via PR, then sync cluster.
#                           Idempotent — if main is already in that state, only syncs.
#   ./deploy.sh --teardown  Delete the grafana-demo namespace

set -euo pipefail

NAMESPACE="grafana-demo"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="$REPO_ROOT/k8s"
GRAFANA_DIR="$REPO_ROOT/grafana"
DASHBOARD_UID="order-service-n-plus-one-demo"

# Post a Grafana annotation to the demo dashboard (requires gcx; silent on failure)
post_annotation() {
  local text="$1" tags="$2"
  command -v gcx &>/dev/null || return 0
  local f
  f=$(mktemp /tmp/gcx-anno-XXXXXX.yaml)
  cat > "$f" <<YAML
apiVersion: annotations.grafana.app/v1
kind: Annotation
metadata:
  name: "demo-$(date +%s)"
spec:
  dashboardUID: ${DASHBOARD_UID}
  tags: [${tags}]
  text: "${text}"
  time: $(date +%s)000
YAML
  gcx annotations create -f "$f" 2>/dev/null && echo "Grafana annotation posted." || true
  rm -f "$f"
}

# Returns 0 if k8s/order-service.yaml in current working tree has BUG_ENABLED=true
manifest_has_bug_true() {
  grep -A1 'name: BUG_ENABLED' "$K8S_DIR/order-service.yaml" | grep -q 'value: "true"'
}

# Open a PR that flips BUG_ENABLED back to true, auto-merge it with admin rights.
# No-op if main already has BUG_ENABLED=true.
restore_bug_in_repo_via_pr() {
  cd "$REPO_ROOT"

  if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree has uncommitted changes — commit or stash before --reset" >&2
    git status --short >&2
    exit 1
  fi

  git fetch origin main --quiet
  git checkout main --quiet
  git pull --ff-only origin main --quiet

  if manifest_has_bug_true; then
    echo "main already has BUG_ENABLED=true — no restore PR needed."
    return 0
  fi

  local branch="restore/re-enable-bug-$(date +%s)"
  echo "main has BUG_ENABLED=false — opening restore PR on branch $branch..."
  git checkout -b "$branch" --quiet

  python3 - <<'PY'
import re, pathlib
p = pathlib.Path("k8s/order-service.yaml")
content = p.read_text()
new = re.sub(
    r'(name: BUG_ENABLED\s*\n\s+value: ")false(")',
    r'\1true\2',
    content,
)
if new == content:
    raise SystemExit("No BUG_ENABLED=false block found to flip")
p.write_text(new)
PY

  git add k8s/order-service.yaml
  git commit -m "restore: re-enable BUG_ENABLED=true for next demo run" --quiet
  git push -u origin "$branch" --quiet

  local pr_url
  pr_url=$(gh pr create \
    --title "restore: re-enable BUG_ENABLED=true for next demo run" \
    --body "Automated reset between demos. Restores the initial state so the AI Assistant has something to fix on the next run." \
    --head "$branch" \
    --base main)
  echo "Opened $pr_url"

  local pr_num
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')

  echo "Auto-merging PR #$pr_num with admin..."
  gh pr merge "$pr_num" --admin --squash --delete-branch

  git checkout main --quiet
  git pull --ff-only origin main --quiet
  echo "main restored: $(git rev-parse --short HEAD)"
}

sync_cluster_to_manifest() {
  cd "$REPO_ROOT"
  echo "Syncing cluster with k8s/order-service.yaml..."
  kubectl apply -f "$K8S_DIR/order-service.yaml"
  kubectl set env deployment/order-service -n "$NAMESPACE" SERVICE_VERSION="$(git rev-parse --short HEAD)"
  kubectl rollout restart deployment/order-service -n "$NAMESPACE"
  kubectl rollout status deployment/order-service -n "$NAMESPACE" --timeout=180s
}

case "${1:-}" in
  --reset)
    echo "Resetting demo — restoring BUG_ENABLED=true in repo if needed, then syncing cluster..."
    restore_bug_in_repo_via_pr
    sync_cluster_to_manifest
    SHORT_SHA=$(git rev-parse --short HEAD)
    echo "Done. service.version=$SHORT_SHA"
    post_annotation "Demo reset — BUG_ENABLED=true, version=${SHORT_SHA}" "demo, reset"
    ;;

  --teardown)
    echo "Deleting namespace $NAMESPACE..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    echo "Teardown complete."
    ;;

  "")
    echo "Deploying Grafana demo to namespace: $NAMESPACE"
    kubectl apply -f "$K8S_DIR/namespace.yaml"
    kubectl apply -f "$K8S_DIR/inventory-service.yaml"
    kubectl apply -f "$K8S_DIR/order-service.yaml"
    kubectl apply -f "$K8S_DIR/frontend-api.yaml"
    kubectl apply -f "$K8S_DIR/load-generator.yaml"

    echo ""
    echo "Waiting for deployments to be ready..."
    for svc in inventory-service order-service frontend-api load-generator; do
      kubectl rollout status deployment/"$svc" -n "$NAMESPACE"
    done

    echo ""
    echo "Provisioning Grafana dashboard..."
    if command -v gcx &>/dev/null; then
      gcx dashboards create -f "$GRAFANA_DIR/dashboard-order-service.json" \
        --folder-name "Order Service Demo" --upsert 2>/dev/null && \
        echo "Dashboard provisioned in folder 'Order Service Demo'." || \
        echo "Warning: dashboard provisioning failed (gcx not configured?) — skipping."
    else
      echo "Warning: gcx not found — skipping dashboard provisioning."
    fi

    echo ""
    echo "All services running. BUG_ENABLED matches k8s/order-service.yaml in main."
    echo "Run './deploy.sh --reset' between demos to restore the bug state."
    ;;

  *)
    echo "Unknown argument: ${1}"
    echo "Usage: $0 [--reset|--teardown]"
    exit 1
    ;;
esac
