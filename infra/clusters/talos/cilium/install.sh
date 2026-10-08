#!/usr/bin/env bash
# Install (or upgrade) Cilium on the Talos cluster.
#
# Run once after `talosctl bootstrap` -- before Flux exists -- to bring up pod
# networking, and again to upgrade. Helm generates the CA + mTLS certificates
# once and reuses them on every `helm upgrade`, so this is safe to run while
# apps are live (no cert rotation, no partial-rotation outage).
#
#   ./install.sh
#   CILIUM_VERSION=1.20.3 ./install.sh
#   CTX=talos ./install.sh
#
# Adding nodes needs none of this: Cilium is cluster-wide, so the cilium
# DaemonSet schedules onto any new node automatically.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
CTX="${CTX:-talos}"

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --kube-context "$CTX" \
  -f "$DIR/values.yaml"

echo
echo "Cilium $CILIUM_VERSION applied. Verify with:"
echo "  kubectl --context $CTX -n kube-system rollout status ds/cilium"
echo "  cilium status --wait"
