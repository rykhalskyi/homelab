---
tags: [talos, kubernetes, observability, prometheus, grafana, alertmanager, cilium, hubble, flux, monitoring, node-two]
date: 2026-10-09
source_count: 0
---

# Observability on Talos (Prometheus + Grafana + Alertmanager)

Metrics/alerting stack for the `talos` cluster (`node-two`, `192.168.2.234`),
deployed with **Flux** into namespace `monitoring`. **Grafana is LAN-only**
(`http://grafana.homelab.local`); nothing is exposed publicly. Cilium and Hubble
metrics are scraped too. For the CNI itself see
[[Cilium on Talos (Helm, kube-proxy-free)]]; for secrets see
[[Secrets with SOPS + age (local, out-of-band)]].

## What is deployed (and where)

The `infrastructure` Flux Kustomization (entrypoint
`infra/clusters/talos/infrastructure.yaml` -> path `./infrastructure`) reconciles
three things. Two of them are prerequisites the Talos cluster lacks entirely:

| Component | Namespace | Why |
| --- | --- | --- |
| `local-path-provisioner` | `local-path-storage` | Talos ships **no** storage provisioner; gives a default `local-path` StorageClass so PVCs bind |
| `traefik` | `traefik` | Talos has **no** ingress controller; routes `grafana.homelab.local` on the node's :80 |
| `kube-prometheus-stack` | `monitoring` | Prometheus + Operator, Grafana, Alertmanager, node-exporter, kube-state-metrics |

```
infra/clusters/talos/
├── kustomization.yaml                     # entrypoint; uncommented infrastructure.yaml
├── infrastructure.yaml                    # Flux Kustomization -> ./infrastructure
└── infrastructure/
    ├── kustomization.yaml
    ├── sources/{local-path-provisioner,traefik,kube-prometheus-stack}.yaml
    ├── local-path/    namespace.yaml · helmrelease.yaml
    ├── traefik/       namespace.yaml · helmrelease.yaml
    └── monitoring/    namespace.yaml · helmrelease.yaml · grafana-ingress.yaml
```

## How the pieces work

### Storage — `local-path-provisioner`
The chart is **not** on a Helm index; it lives in the upstream git repo, so a
Flux `GitRepository` pins it to tag `v0.0.37` and the `HelmRelease` references
`./deploy/chart/local-path-provisioner`. Two Talos-specific values:

- `nodePathMap: /var/local-path-provisioner` — the default
  `/opt/local-path-provisioner` is **not writable** on Talos (immutable rootfs);
  `/var` is.
- The `local-path-storage` namespace is labelled
  `pod-security.kubernetes.io/enforce: privileged` — the provisioner's short-lived
  helper pods run privileged and mount the host filesystem.

`storageClass.defaultClass: true` + `reclaimPolicy: Retain` (data survives PVC
deletion).

### Ingress — Traefik on host ports
Cilium runs kube-proxy-free and Cilium LB-IPAM/L2 is **not** enabled, so there is
no `LoadBalancer` implementation. Instead Traefik binds the node's host ports:

```yaml
# infrastructure/traefik/helmrelease.yaml
service:
  spec:
    type: ClusterIP        # chart 41.x nests type under service.spec
ports:
  web:       { hostPort: 80 }
  websecure: { hostPort: 443 }   # reserved; no TLS terminates here yet
```

The chart creates the `traefik` IngressClass, so Ingresses use
`ingressClassName: traefik`.

> **PSA:** the cluster defaults namespaces to the `baseline` PodSecurity level,
> which forbids `hostPort`. The `traefik` namespace must be
> `pod-security.kubernetes.io/enforce: privileged` or the Deployment never
> schedules.

### The stack — `kube-prometheus-stack`
Disabled for Talos (`kubeEtcd`/`kubeControllerManager`/`kubeScheduler` run as
static pods bound to localhost; Cilium replaces `kubeProxy`) — so their
ServiceMonitors would scrape nothing. Kept: apiserver, kubelet/cAdvisor,
node-exporter (host metrics), kube-state-metrics (object state). Grafana reaches
Prometheus in-cluster; Prometheus/Alertmanager UIs have no Ingress.

- Prometheus: `retention: 7d`, `retentionSize: 9GB`, 10Gi `local-path` PVC.
- Alertmanager: config from the out-of-band Secret `alertmanager-config`, 1Gi PVC.
- Grafana: admin from the out-of-band Secret `grafana-admin`, 2Gi PVC.
- Release name `kube-prometheus-stack` => Services
  `kube-prometheus-stack-{grafana,prometheus,alertmanager}`.

Two non-obvious requirements (both bit us on the first rollout):

1. **`monitoring` namespace must be privileged.** node-exporter uses
   `hostNetwork`/`hostPID`/hostPath/`hostPort: 9100`, and the cluster's default
   `baseline` PSA forbids all of those. Without the label the DaemonSet is stuck
   `FailedCreate`, which makes the Helm install time out and uninstall.
2. **Prometheus data volume uses `subPath: prometheus-db`.** The kubelet creates
   that subdirectory as root:root 0755 and does **not** apply `fsGroup` to
   subPath mounts, so Prometheus (uid 1000) crashloops with
   `/prometheus/queries.active: permission denied`. Fixed with an
   `init-chown-data` initContainer (root) that creates/chowns the dir before the
   main container starts.

### Cilium + Hubble metrics
`cilium/values.yaml` enables the agent, operator, Hubble and relay metrics and
their `ServiceMonitor`s, each labelled `release: kube-prometheus-stack` so the
Prometheus CR's `serviceMonitorSelector` picks them up. Hubble exposes flow
metrics (`drop`, `tcp`, `flow`, `http`, `dns`, `icmp`).

> Ordering: ServiceMonitors need the `monitoring.coreos.com/v1` CRD, which comes
> from kube-prometheus-stack. `cilium/install.sh` detects a missing CRD and
> installs Cilium **without** ServiceMonitors for the bootstrap run; re-run it
> after kube-prometheus-stack is up to add them.

## Deploy

```bash
# 1. Flux reconciles the infra manifests from the branch/main
flux reconcile kustomization infrastructure --with-source
kubectl --context talos -n local-path-storage get deploy
kubectl --context talos -n traefik get deploy
kubectl --context talos -n monitoring get pods

# 2. Apply the out-of-band secrets (fills Grafana password + Telegram token)
bash infra/clusters/talos/apps/secrets/apply.sh

# 3. Enable Cilium/Hubble metrics (only after the CRD exists)
bash infra/clusters/talos/cilium/install.sh
```

Client access:

```bash
# /etc/hosts
192.168.2.234 grafana.homelab.local
# then
curl -I http://grafana.homelab.local
```

## Secrets (out of band, never committed)

`infra/clusters/talos/apps/secrets/` is gitignored. `apply.sh` reads each
manifest's own `namespace`, so it handles both `homelab` and `monitoring`.

| Secret | Namespace | Keys | Used by |
| --- | --- | --- | --- |
| `grafana-admin` | `monitoring` | `admin-user`, `admin-password` | Grafana `admin.existingSecret` |
| `alertmanager-config` | `monitoring` | `alertmanager.yaml` | Alertmanager `configSecret` |

Edit the placeholders (`CHANGE_ME`, `CHANGE_ME_BOT_TOKEN`, `chat_id`):

```bash
sops infra/clusters/talos/apps/secrets/grafana-admin.sops.yaml
sops infra/clusters/talos/apps/secrets/alertmanager-config.sops.yaml
bash infra/clusters/talos/apps/secrets/apply.sh
```

The Telegram receiver is in `alertmanager.yaml` (`telegram_configs`:
`bot_token`, `chat_id`). Get a bot token from @BotFather; the chat ID from the
`getUpdates` API.

## Verify

```bash
flux get kustomizations
kubectl --context talos -n monitoring get pods,svc,pvc,ingress
kubectl --context talos get storageclass local-path
# Prometheus sees targets scraped from Cilium/Hubble:
kubectl --context talos -n monitoring get servicemonitors.monitoring.coreos.com
# fire a test alert:
kubectl --context talos -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093
```

## Gotchas

- **Default PSA is `baseline`.** The cluster forbids `hostPort`/`hostNetwork`/
  `hostPID`/hostPath by default, so the `traefik` (hostPort) and `monitoring`
  (node-exporter) namespaces are labelled
  `pod-security.kubernetes.io/enforce: privileged`. `local-path-storage` is too
  (its helper pods mount the host).
- **Prometheus subPath permissions.** See above — the `init-chown-data` init
  container exists solely to chown the kubelet-created `subPath` dir.
- **Alertmanager rejects `chat_id: 0`.** The operator treats the zero value as
  "missing" and refuses to build the StatefulSet; use a real (non-zero) Telegram
  chat id in `alertmanager-config`.
- **Talos + host paths.** Anything using a hostPath must live under a writable
  mount (`/var/...`). `local-path-provisioner` defaults to `/opt`, which fails
  on Talos — hence `nodePathMap`.
- **ServiceMonitor CRD ordering.** Cilium metrics require kube-prometheus-stack's
  CRDs first; `install.sh` auto-downgrades on a fresh bootstrap.
- **No LoadBalancer on Talos.** Cilium is kube-proxy-free with LB-IPAM/L2 off;
  use host ports (Traefik) or NodePort, not `type: LoadBalancer`.
- **LAN-only by hostname.** `grafana.homelab.local` is outside
  `*.otakeessen.com`, so no tunnel route can reach it — same pattern as pgAdmin
  on the k8s cluster.
- **Reclaim `Retain`.** Deleting a PVC leaves the PV + data behind; clean up
  `/var/local-path-provisioner/*` manually when you really want it gone.

## See also

- [[Cilium on Talos (Helm, kube-proxy-free)]]
- [[Talos CLI: common commands (dashboard, status, shutdown)]]
- [[kubectl contexts: switching between clusters]]
- [[Secrets with SOPS + age (local, out-of-band)]]
- [[k3s + GitOps: nginx and cloudflared (phase 2.1)]] — the `k8s` cluster's
  Flux/Traefik patterns this mirrors
