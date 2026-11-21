#!/usr/bin/env bash
# ============================================================================
# NIPPON CI/CD — fetch-kubeconfig.sh (optional helper)
#
# Pulls the k3s admin kubeconfig from the node so you can drive the cluster
# from your laptop:  `ssh ... 'cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config`
# ============================================================================
set -euo pipefail
K3S_NODE="${K3S_NODE:-kmoreti@192.168.68.129}"
K3S_SSH_KEY="${K3S_SSH_KEY:-~/.ssh/id_rsa}"

OUT="${1:-$HOME/.kube/config}"
echo ">>> fetching kubeconfig from ${K3S_NODE} -> ${OUT}"
mkdir -p "$(dirname "$OUT")"
# Rewrite the server URL so the laptop talks to the node's 6443 directly.
ssh -i "$K3S_SSH_KEY" -o StrictHostKeyChecking=no "$K3S_NODE" \
  'cat /etc/rancher/k3s/k3s.yaml' \
  | sed -E "s#server:.*#server: https://$(hostname -I | awk '{print $1}'):6443#" \
  > "$OUT"
chmod 600 "$OUT"
echo ">>> wrote ${OUT}"
kubectl get nodes || true
