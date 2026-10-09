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

# values.yaml enables ServiceMonitors for the kube-prometheus-stack Prometheus.
# On a brand-new cluster Cilium is installed *before* Flux/kube-prometheus-stack,
# so the ServiceMonitor CRD does not exist yet and Helm would fail. Detect that
# and fall back to installing without ServiceMonitors; re-run this script after
# kube-prometheus-stack is up to add them.
SM_ARGS=()
if ! kubectl --context "$CTX" get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "note: ServiceMonitor CRD not present -> installing Cilium without ServiceMonitors."
  echo "      Re-run this script after kube-prometheus-stack to enable Cilium/Hubble metrics."
  SM_ARGS=(
    --set prometheus.serviceMonitor.enabled=false
    --set operator.prometheus.serviceMonitor.enabled=false
    --set hubble.metrics.serviceMonitor.enabled=false
    --set hubble.relay.prometheus.serviceMonitor.enabled=false
  )
fi

helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --kube-context "$CTX" \
  -f "$DIR/values.yaml" \
  "${SM_ARGS[@]}"

echo
echo "Cilium $CILIUM_VERSION applied. Verify with:"
echo "  kubectl --context $CTX -n kube-system rollout status ds/cilium"
echo "  cilium status --wait"
