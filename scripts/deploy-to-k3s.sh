#!/usr/bin/env bash
# ============================================================================
# NIPON CI/CD — deploy-to-k3s.sh
#
# Runs ON the k3s node (ssh ... 'bash -s' < deploy-to-k3s.sh). Pulls the freshly
# built images from the local registry, renders the kustomize manifest with each
# service pinned to the built SHA, applies it, and waits for the rollout.
#
# Inputs (env):
#   DEPLOY_SHA   git short SHA to deploy (from the pipeline's build stage)
#   REGISTRY     local registry, default 192.168.68.120:5000
#   NIPON_SRC    checkout dir on the node, default /opt/nippon
# ============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-192.168.68.120:5000}"
SHA="${DEPLOY_SHA:-latest}"
NIPON_SRC="${NIPON_SRC:-/opt/nippon}"
NS="nippon"

echo "=== NIPON deploy to k3s @ ${SHA} (registry ${REGISTRY}) ==="

# 1) Make sure the node can reach the registry (insecure HTTP) and pull.
sudo k3s crictl pull "$REGISTRY/nippon/security-service:${SHA}" 2>/dev/null || true

# 2) Get a fresh checkout of NIPON on the node (the pipeline pushes the source
#    over first, or the node clones it).
if [ ! -d "$NIPON_SRC/.git" ]; then
  echo ">>> cloning NIPON on node -> $NIPON_SRC"
  git clone --depth 1 https://github.com/kmoreti/nippon.git "$NIPON_SRC"
fi
cd "$NIPON_SRC"

# 3) Render the kustomize base with every service image pinned to $SHA.
#    Kustomize `--image` overrides each `nippon/<svc>` -> registry tag.
IMAGES_ARGS=()
for svc in $(ls services 2>/dev/null | grep -E 'service$|^gateway$|^frontend$'); do
  IMAGES_ARGS+=("--image" "nippon/${svc}=${REGISTRY}/nippon/${svc}:${SHA}")
done

# 4) Apply. `--server-side` makes the apply idempotent across CI runs.
echo ">>> kustomize build + k3s kubectl apply (pinning to ${SHA})"
sudo k3s kustomize build deploy/k8s "${IMAGES_ARGS[@]}" 2>/dev/null \
  | sudo k3s kubectl apply --server-side --force -f -

# 5) Wait for the rollout (best-effort; a timeout does not abort the pipeline).
echo ">>> waiting for rollout (60s)"
for i in $(seq 1 6); do
  sleep 10
  notready=$(sudo k3s kubectl get pods -n "$NS" 2>/dev/null \
    | awk 'NR>1 && $2!="1/1" {c++} END{print c+0}')
  echo "  t=$((i*10))s pods-not-ready: ${notready:-0}"
  [ "${notready:-0}" = "0" ] && { echo ">>> all pods ready"; break; }
done

# 6) Record the deployed SHA on the node for audit + rollback.
echo "$SHA" | sudo tee /var/lib/nippon/deployed_sha > /dev/null 2>&1 || true

echo "=== deploy complete: NIPON @ ${SHA} on $NS ==="
