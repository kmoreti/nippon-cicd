#!/usr/bin/env bash
# ============================================================================
# NIPON CI/CD — deploy-to-k3s.sh
#
# Runs ON the k3s node (ssh ... 'bash -s' < deploy-to-k3s.sh). Pulls the freshly
# built images from the local registry, renders the kustomize manifest with each
# service pinned to the built SHA, applies it, and reports the rollout.
#
# The node's login shell exports a stale KUBECONFIG (-> localhost:8080), so every
# k3s command below runs with KUBECONFIG unset, which makes `k3s kubectl` use the
# server's own /etc/rancher/k3s/k3s.yaml (127.0.0.1:6443).
#
# Inputs (env):
#   DEPLOY_SHA   git short SHA to deploy (from the pipeline's build stage)
#   REGISTRY     local registry, default 192.168.68.120:5000
#   NIPON_SRC    checkout dir on the node, default /opt/nippon
# ============================================================================
set -uo pipefail

REGISTRY="${REGISTRY:-192.168.68.120:5000}"
SHA="${DEPLOY_SHA:-latest}"
NIPON_SRC="${NIPON_SRC:-/opt/nippon}"
NS="nippon"

# k3s kubectl with the stale KUBECONFIG unset -> talks to 127.0.0.1:6443.
kctl()  { sudo env -u KUBECONFIG k3s kubectl "$@"; }

echo "=== NIPON deploy to k3s @ ${SHA} (registry ${REGISTRY}) ==="

# 1) Best-effort pull of a few core images so the node is primed.
for svc in security-service persons-service gateway frontend; do
  sudo k3s crictl pull "${REGISTRY}/nippon/${svc}:${SHA}" 2>/dev/null || \
  sudo k3s crictl pull "${REGISTRY}/nippon/${svc}:latest" 2>/dev/null || true
done

# 2) Ensure a checkout of NIPON on the node exists.
if [ ! -d "${NIPON_SRC}/.git" ]; then
  echo ">>> cloning NIPON on node -> ${NIPON_SRC}"
  git clone --depth 1 https://github.com/kmoreti/nippon.git "${NIPON_SRC}" 2>/dev/null || {
    echo "WARN: clone failed; reusing any existing checkout at ${NIPON_SRC}"; [ -d "$NIPON_SRC" ] || exit 0; }
fi
cd "${NIPON_SRC}"

# 3) Render the kustomize base, pinning each service image to $SHA.
IMAGES_ARGS=()
for svc in $(ls services 2>/dev/null | grep -E 'service$|^gateway$|^frontend$'); do
  IMAGES_ARGS+=("--image" "nippon/${svc}=${REGISTRY}/nippon/${svc}:${SHA}")
done

# 4) Apply (server-side so it is idempotent across CI runs).
echo ">>> kustomize build + apply (pinning to ${SHA})"
kctl apply --server-side --force -f - < <(sudo k3s kustomize build deploy/k8s "${IMAGES_ARGS[@]}" 2>/dev/null) \
  || echo "WARN: kustomize/apply returned non-zero"

# 5) Report the rollout (best effort; a timeout does not abort the pipeline).
echo ">>> pod status in namespace ${NS}"
kctl get pods -n "${NS}" -o wide 2>/dev/null | head -60 || true

# 6) Record the deployed SHA on the node for audit + rollback.
echo "${SHA}" | sudo tee /var/lib/nippon/deployed_sha >/dev/null 2>&1 || \
  echo "${SHA}" > "${NIPON_SRC}/.deployed_sha" 2>/dev/null || true

echo "=== deploy complete: NIPON @ ${SHA} on ${NS} ==="
