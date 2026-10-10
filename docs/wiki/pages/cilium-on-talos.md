---
tags: [talos, cilium, cni, kubernetes, helm, hubble, node-two, operations]
date: 2026-10-08
source_count: 0
---

# Cilium on Talos (Helm, kube-proxy-free)

The `talos` cluster (`node-two` `192.168.2.234` and, since 2026-10-10, `node-one`
`192.168.2.233` — see [[Adding node-one to the Talos cluster (control-plane IP gotcha)]])
runs **Cilium** as its CNI
instead of Talos's default flannel, with **kube-proxy disabled**
(kube-proxy-free / eBPF service load-balancing via KubePrism). Hubble is
enabled. This page records how it is installed, how to add nodes, how to
upgrade it, and the CLI commands. For the machine/OS layer see
[[Talos CLI: common commands (dashboard, status, shutdown)]]; for `kubectl`
contexts see [[kubectl contexts: switching between clusters]].

## Three layers (keep these straight)

| Layer | What | Where | Managed by |
| --- | --- | --- | --- |
| Machine config | flannel removed, kube-proxy disabled, static IP, CP taint removed | `nodes/<node>/patch.yaml` -> generated `controlplane.yaml` (gitignored) | `talosctl` |
| Cilium | the CNI + Hubble | Helm release `cilium` in `kube-system` | **Helm** (`cilium/install.sh`) |
| Everything above | apps/add-ons | `infra/clusters/talos/{apps,infrastructure}` | **Flux** |

Cilium is **not** part of the machine config and **not** Flux-managed — it is a
plain Helm release. That is deliberate: Helm owns the CA/mTLS certificates and
reuses them across upgrades, so a version bump never rotates certs or causes a
partial-rotation outage.

## Repo files

- `infra/clusters/talos/cilium/values.yaml` — Talos-specific values (chart
  pinned), Hubble on, `operator.replicas: 1` for a single node.
- `infra/clusters/talos/cilium/install.sh` — `helm upgrade --install cilium
  cilium/cilium -f values.yaml`. Used for both first install and upgrades.
- `infra/clusters/talos/nodes/<node>/patch.yaml` — the machine patch (see below).
- `infra/clusters/talos/README.md` — the authoritative, short version.

## Machine layer: what `patch.yaml` does

```yaml
# 1. remove the control-plane NoSchedule taint (single-node: allow workloads)
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  node-role.kubernetes.io/control-plane:
    $patch: delete
# 2. static network (the cluster endpoint is 192.168.2.234)
---
machine:
  network:
    interfaces:
      - interface: eno1
        addresses: [192.168.2.234/24]
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.2.1
        dhcp: false
# 3. cluster-wide CNI switch (every node)
---
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
```

### Generate a node config: two steps, not one

```bash
# base config from the REAL secrets.yaml
talosctl gen config talos https://192.168.2.234:6443 \
  --with-secrets secrets.yaml --install-disk /dev/nvme0n1 \
  --with-docs=false --with-examples=false \
  -t controlplane -o nodes/<node>/controlplane.yaml
# then apply the patch with machineconfig patch
talosctl machineconfig patch nodes/<node>/controlplane.yaml \
  --patch @nodes/<node>/patch.yaml -o nodes/<node>/controlplane.yaml.tmp && \
  mv nodes/<node>/controlplane.yaml.tmp nodes/<node>/controlplane.yaml
```

Why not `--config-patch` in one step: `gen config` applies patches **before**
the default documents exist, so the `$patch: delete` against
`KubeNodeConfig.taints` fails ("lookup failed"). `machineconfig patch` operates
on the generated config, so it works. (The flannel/kube-proxy deletes work
either way.)

## Verify

```bash
cilium status --context talos          # all OK; "Helm chart version 1.20.2"
kubectl --context talos get nodes
kubectl --context talos -n kube-system get ds   # cilium + cilium-envoy; NO flannel/kube-proxy
kubectl --context talos get crd | grep cilium   # CRDs created by the operator at runtime
```

## Adding a new node

**Cilium is cluster-wide — a new node needs no Cilium work.** The `cilium`
DaemonSet schedules a pod onto it automatically. A new node only needs the
machine-config CNI switch, like node-two.

- **Cluster-wide (every node):** `KubeFlannelCNIConfig $patch: delete` +
  `KubeProxyConfig enabled: false`.
- **Per-node:** its own static `machine.network` block; the CP taint removal
  only if you drop that on a control plane.

Worker node (e.g. `node-three`):

```bash
# boot Talos, note its maintenance (DHCP) IP, then:
talosctl gen config talos https://192.168.2.234:6443 \
  --with-secrets secrets.yaml --install-disk /dev/nvme0n1 \
  -t worker -o nodes/node-three/worker.yaml
talosctl machineconfig patch nodes/node-three/worker.yaml \
  --patch @nodes/node-three/patch.yaml -o nodes/node-three/worker.yaml.tmp && \
  mv nodes/node-three/worker.yaml.tmp nodes/node-three/worker.yaml
talosctl apply-config --insecure -n <dhcp-ip> --file nodes/node-three/worker.yaml
```

No `bootstrap` — that is only ever the first control plane. An additional
control-plane node auto-joins etcd for quorum; use `-t controlplane`.

Caveats:
- **Use the real `secrets.yaml`** — a mismatched one gives the node the wrong
  machine CA and locks you out of its Talos API (see Gotchas).
- **Join on the node's final static IP.** A control-plane node's etcd peer URL is
  fixed when it joins; booting on DHCP and moving the IP afterwards loses etcd
  quorum and downs the API. Full story + recovery in
  [[Adding node-one to the Talos cluster (control-plane IP gotcha)]].
- Today `patch.yaml` mixes node-two's static IP and the shared CNI switch.
  Cleaner: split into a shared `patch-cni.yaml` plus a tiny per-node
  `patch.yaml` (network [+ taint]).
- The cluster `endpoint` is single (`https://192.168.2.234:6443`). For real HA,
  list all control-plane IPs as endpoints when generating configs.

## Upgrading Cilium

```bash
helm repo update cilium
helm search repo cilium/cilium --versions | head        # newest stable
CILIUM_VERSION=1.20.3 bash infra/clusters/talos/cilium/install.sh

# verify
cilium status --wait --context talos
kubectl --context talos -n kube-system rollout status ds/cilium
# inspect / roll back
helm --kube-context talos -n kube-system history cilium
helm --kube-context talos -n kube-system rollback cilium <REVISION>
```

The machine config only changes for **CNI-mode changes** (e.g. re-enabling
kube-proxy), never for a Cilium version bump.

> Do **not** manage Cilium through a Talos inline manifest. Talos inline
> manifests are create-only and re-render a fresh CA each time, which is how a
> partial certificate rotation (and outage) happens. Helm avoids this.

## Metrics (Prometheus / kube-prometheus-stack)

`cilium/values.yaml` enables the agent, operator, Hubble and relay metrics and
their `ServiceMonitor`s, each labelled `release: kube-prometheus-stack` so the
kube-prometheus-stack Prometheus CR scrapes them. Hubble adds flow metrics
(`drop`, `tcp`, `flow`, `http`, `dns`, `icmp`) — see
[[Observability on Talos (Prometheus + Grafana + Alertmanager)]].

```bash
# after kube-prometheus-stack is installed (it provides the ServiceMonitor CRD):
bash infra/clusters/talos/cilium/install.sh
kubectl --context talos -n monitoring get servicemonitors.monitoring.coreos.com | grep -i cilium
```

ServiceMonitors need the `monitoring.coreos.com/v1` CRD. On a **fresh** cluster
Cilium is installed before kube-prometheus-stack, so `install.sh` detects the
missing CRD and installs without ServiceMonitors; re-run it later to enable
them. (Grafana/Prometheus live in `monitoring`, not `kube-system`.)

## Commands

Install the `cilium` CLI (not in the repo):

```bash
curl -L https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz \
  | sudo tar xz -C /usr/local/bin
```

### `cilium` CLI (talks to the cluster; add `--context talos`)

- `cilium status` — health summary.
- `cilium status --verbose` — controllers, health checks, config.
- `cilium connectivity test` — full end-to-end test (creates a test namespace;
  it needs the `pod-security.kubernetes.io/enforce=privileged` label).
- `cilium features status` — which features are on.
- `cilium config view` — dump agent config.
- `cilium encryption status`.
- `cilium hubble port-forward` / `cilium hubble ui` — reach Hubble.
- `cilium sysdump` — diagnostic bundle.
- `cilium install` / `upgrade` / `uninstall` — Helm-driven lifecycle.
- `cilium clustermesh` / `cilium bgp` / `cilium multicast`.

### `cilium-dbg` inside the agent (deep, per-node)

```bash
K="kubectl --context talos -n kube-system exec ds/cilium --"
$K cilium-dbg endpoint list        # pods as Cilium endpoints
$K cilium-dbg service list         # eBPF LB (this is what kube-proxy would do)
$K cilium-dbg bpf lb list          # raw BPF LB maps
$K cilium-dbg identity list
$K cilium-dbg monitor              # live events/traces
$K cilium-dbg status --verbose
```

`cilium-dbg service list` on this cluster shows e.g. `10.96.0.10:53` backed by
the two CoreDNS pod IPs — service routing handled in eBPF, not iptables.

### Hubble (flow observability)

```bash
cilium hubble port-forward --context talos   # localhost:4245
hubble observe --follow                      # live pod-to-pod flows
hubble observe --verdict DROPPED             # only drops
cilium hubble ui --context talos
```

`hubble` is a separate binary from the `cilium` CLI releases.

### kubectl fallbacks

`kubectl -n kube-system get pods -l k8s-app=cilium`,
`kubectl get ciliumnodes`, `kubectl get crd | grep cilium`.

## Gotchas

- **`cilium` follows the current kube-context.** The `cilium` CLI uses whatever
  `kubectl` context is current. On this box the default is `k8s` (node-one), so
  a bare `cilium status` reports `daemonsets.apps "cilium" not found`,
  `configmaps "cilium-config" not found`, and `Cluster Pods: 0/N managed` —
  because Cilium only runs on `talos`. Always pass `--context talos` (or run
  `kubectl config use-context talos` first).
- **Stale `secrets.yaml` locks you out.** Applying a config whose machine CA
  differs from the running cluster gives the node the wrong identity and
  `talosctl` fails with `x509: certificate signed by unknown authority`.
  Recovery is possible without a reset: the applied config embeds the CA **key**,
  so mint a client cert signed by it (`openssl`), connect, and re-apply a config
  generated from the correct `secrets.yaml`. Always keep `secrets.yaml` backed up.
- **Single-node operator replica.** The Cilium operator defaults to 2 replicas;
  on one node the second can't get its host ports, so `operator.replicas: 1`.
- **Single-node scheduling.** Control planes carry the
  `node-role.kubernetes.io/control-plane:NoSchedule` taint; the patch removes it
  via `KubeNodeConfig` (persists across reboots). Drop that when you add workers.
- **`connectivity test` and PodSecurity.** The test namespace needs the
  `privileged` enforce label, or pods are rejected (`NET_RAW`).
- **CoreDNS + BPF masquerade.** Talos defaults `forwardKubeDNSToHost: true`; if
  you ever enable Cilium `bpf.masquerade`, set `forwardKubeDNSToHost=false`.

## See also

- [[Talos CLI: common commands (dashboard, status, shutdown)]]
- [[kubectl contexts: switching between clusters]]
- [[Secrets with SOPS + age (local, out-of-band)]]
- [[k3s + GitOps: nginx and cloudflared (phase 2.1)]] — the `k8s` cluster's Flux
  layout the `talos` cluster mirrors
