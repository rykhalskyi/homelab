---
tags: [talos, kubernetes, etcd, control-plane, worker, operations, instruction]
date: 2026-10-31
source_count: 0
---

# Adding a node to the Talos cluster

Short end-to-end runbook for adding a machine to the `talos` cluster. For the
detailed `node-one` story (and the etcd IP trap) see
[[Adding node-one to the Talos cluster (control-plane IP gotcha)]]; for the CNI
layer see [[Cilium on Talos (Helm, kube-proxy-free)]].

## Before you start

- The machine is booted from the Talos USB in maintenance mode; note its
  temporary DHCP IP.
- `infra/clusters/talos/secrets.yaml` matches the **running** cluster (a stale
  CA locks you out of the node's Talos API).
- A free static IP on `192.168.2.0/24` that the node will keep.
- Cluster endpoint: `https://192.168.2.234:6443`.
- Choose the role: `controlplane` (joins etcd; use for HA) or `worker`.

## 1. Find the NIC and install disk

```bash
talosctl get links --insecure -n <dhcp-ip>
talosctl get disks --insecure -n <dhcp-ip>
```

Use the internal disk (e.g. `/dev/sda` or `/dev/nvme0n1`), **not** the USB
installer (`/dev/sdb` on the machines so far).

## 2. Add `nodes/<node>/patch.yaml`

Only this file is committed; the generated machine config stays local because it
contains cluster secrets.

```yaml
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/<schematic>:v1.14.4
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/<disk>"
  wipe: false
---
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: <node>
---
# control planes only: allow workloads on this node
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  node-role.kubernetes.io/control-plane:
    $patch: delete
---
machine:
  network:
    interfaces:
      - interface: <nic>
        addresses:
          - <static-ip>/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.2.1
        dhcp: false
---
# cluster-wide CNI switch: every node
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
```

Notes:

- Pin the installer tag to the running Talos version when the local `talosctl`
  differs (check with `talosctl version -n 192.168.2.234`).
- For a worker, drop the `KubeNodeConfig` taint-removal document.
- Keep the CNI documents on every node; Cilium schedules itself automatically.

## 3. Generate the config (two steps)

```bash
cd infra/clusters/talos

talosctl gen config talos https://192.168.2.234:6443 \
  --with-secrets secrets.yaml \
  --install-disk /dev/<disk> \
  --with-docs=false --with-examples=false \
  -t controlplane \
  -o nodes/<node>/controlplane.yaml

talosctl machineconfig patch nodes/<node>/controlplane.yaml \
  --patch @nodes/<node>/patch.yaml \
  -o nodes/<node>/controlplane.yaml.tmp &&
  mv nodes/<node>/controlplane.yaml.tmp nodes/<node>/controlplane.yaml
```

Two steps are required: `gen config` applies patches before the default
documents exist, so deletes such as the control-plane taint fail there. Use
`-t worker -o nodes/<node>/worker.yaml` for a worker.

## 4. Validate and apply

```bash
talosctl validate --config nodes/<node>/controlplane.yaml --mode metal
talosctl apply-config --insecure -n <dhcp-ip> --file nodes/<node>/controlplane.yaml
```

No `bootstrap` — that is only for the first control plane. The node installs
Talos to the disk, reboots, and comes up on its static IP.

## 5. Verify

```bash
talosctl version --talosconfig ./talosconfig -n <static-ip>
talosctl etcd members --talosconfig ./talosconfig -n 192.168.2.234
talosctl etcd status  --talosconfig ./talosconfig -n 192.168.2.233,192.168.2.234,<static-ip>
kubectl --context talos get nodes -o wide
kubectl --context talos -n kube-system get pods -o wide \
  --field-selector spec.nodeName=<node>
```

For a worker, skip the etcd checks. Expect `cilium` and `cilium-envoy` pods, and
on a control plane the static `kube-apiserver-<node>` and friends.

## Gotchas

- **Join on the final static IP.** A control plane's etcd peer URL is fixed at
  join time; moving the IP later can lose quorum and down the API. See
  [[Adding node-one to the Talos cluster (control-plane IP gotcha)]].
- **Use the real `secrets.yaml`** so the node trusts the existing cluster.
- **Don't install to the USB stick** — confirm the internal disk first.
- **Commit only `patch.yaml`.** `controlplane.yaml` / `worker.yaml` are
  gitignored.
- The cluster endpoint is currently single (`192.168.2.234`). For full API HA,
  list all control-plane IPs as endpoints when generating configs.
