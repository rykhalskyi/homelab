---
tags: [talos, node-one, etcd, kubernetes, control-plane, quorum, operations, recovery, instruction]
date: 2026-10-10
source_count: 0
---

# Adding node-one to the Talos cluster (control-plane IP gotcha)

> **Instructional runbook.** How to add `node-one` (`192.168.2.233`) to the
> `talos` cluster as a second **control plane + workload** node, and the etcd
> peer-URL trap that took the whole cluster down on the first attempt — with the
> exact diagnosis and recovery. For the CNI/machine layer see
> [[Cilium on Talos (Helm, kube-proxy-free)]]; for context switching see
> [[kubectl contexts: switching between clusters]]; for `talosctl` basics see
> [[Talos CLI: common commands (dashboard, status, shutdown)]].

## Result / facts

| Item | Value |
| --- | --- |
| Node | `node-one` (repurposed HP ProDesk 400 G3 DM) |
| Address | `192.168.2.233/24`, gateway `192.168.2.1` |
| NIC | **`enp1s0`** (not `eno1`) |
| Install disk | **`/dev/sda`** |
| Role | `control-plane` + workloads (CP taint removed) |
| Cluster endpoint | `https://192.168.2.234:6443` (node-two) |
| Cluster | 2 control planes: `node-two` `.234`, `node-one` `.233` |

`node-one` was the old Ubuntu/k3s host and was **wiped**: the phase-1 Compose
stacks, the k3s (`k8s`) cluster and its data, Forgejo, the AIO Nextcloud, etc. are
gone. It is now a Talos control plane, same shape as `node-two`.

## Preconditions

- `infra/clusters/talos/secrets.yaml` present and matching the **running** cluster
  (stale CA = Talos API lockout).
- The node's **real NIC name** and **install disk** confirmed (boot the ISO into
  maintenance mode, then `talosctl get links` / `talosctl get disks --insecure`).
  On `node-one` these are `enp1s0` and `/dev/sda`.
- The node is on a **free, final** static IP — see the gotcha below. Do **not**
  let it join on DHCP and move later.

## Steps

### 1. `nodes/node-one/patch.yaml`

Same as node-two's patch, with `node-one`'s interface and address:

```yaml
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  node-role.kubernetes.io/control-plane:
    $patch: delete
---
machine:
  network:
    interfaces:
      - interface: enp1s0
        addresses:
          - 192.168.2.233/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.2.1
        dhcp: false
---
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
```

### 2. Generate the config (two steps)

Two steps because the CP-taint `$patch: delete` needs the generated defaults to
already exist (`gen config --config-patch` patches *before* defaults are added,
so the delete fails with "lookup failed").

```bash
cd infra/clusters/talos
talosctl gen config talos https://192.168.2.234:6443 \
  --with-secrets secrets.yaml \
  --install-disk /dev/sda \
  --with-docs=false --with-examples=false \
  -t controlplane -o nodes/node-one/controlplane.yaml

talosctl machineconfig patch nodes/node-one/controlplane.yaml \
  --patch @nodes/node-one/patch.yaml \
  -o nodes/node-one/controlplane.yaml.tmp && \
  mv nodes/node-one/controlplane.yaml.tmp nodes/node-one/controlplane.yaml
```

### 3. Apply from maintenance mode — **no bootstrap**

```bash
talosctl apply-config --insecure -n <maintenance-ip> --file nodes/node-one/controlplane.yaml
```

`bootstrap` is only ever for the *first* etcd member; a joining control plane
adds itself to etcd automatically. The static `machine.network` block makes the
node come up on `192.168.2.233` immediately.

### 4. Verify

```bash
talosctl -n 192.168.2.233 health
talosctl -n 192.168.2.233,192.168.2.234 etcd members
talosctl -n 192.168.2.233,192.168.2.234 etcd status   # LEADER column must be set
kubectl --context talos get nodes -o wide
kubectl --context talos -n kube-system get ds         # cilium only, no flannel/kube-proxy
```

## The gotcha: a joined control plane's IP is baked into etcd

The first attempt applied the **un-patched** config, so `node-one` booted on DHCP
(`192.168.2.117`) with flannel + kube-proxy and **joined etcd at `.117`**. It was
then moved to the intended `.233`, but etcd's membership still had the peer URL
`https://192.168.2.117:2380`. The two peers could no longer reach each other, so
a 2-member cluster (quorum = 2) lost its leader and **the entire API went down**.

Symptoms:

```bash
talosctl -n <ip> etcd status      # ERROR: etcdserver: no leader
kubectl --context talos get nodes # dial tcp 192.168.2.234:6443: connection refused
talosctl -n <ip> logs etcd | grep rafthttp
#   probe ... remote-peer-id ... error: dial tcp 192.168.2.117:2380: no route to host
```

The rafts kept "starting a new election" on both members but never exchanged
votes. Rule: **an etcd member's peer URL is fixed at join time and does not follow
the node's IP.** Make the node's actual static address match the etcd membership
peer URL — not the other way around.

## Recovery (preserving node-two's data)

The etcd DB on node-two holds the cluster's real data; `talosctl reset` on
node-two would wipe `EPHEMERAL` (and the `local-path` PVCs under `/var`), so we
**do not** touch node-two — instead we restore quorum by aligning `node-one`'s
address with the membership, then clean up.

1. **Safety net** — copy node-two's etcd DB (works even with no quorum):

   ```bash
   talosctl -n 192.168.2.234 cp /var/lib/etcd/member/snap/db ./etcd-node-two-db/
   ```

2. **Align the address.** Check what peer URL the membership points at (the
   `rafthttp` dial target in the log, or `talosctl get members`), then apply a
   config whose static address matches it. In this incident Talos had already
   updated the member to `.233`, so re-applying the `.233` config restored peers:

   ```bash
   talosctl --endpoints <current-ip> --nodes <current-ip> \
     apply-config --file nodes/node-one/controlplane.yaml
   ```

3. **Confirm quorum** — both members show a `LEADER`, matching `RAFT INDEX`:

   ```bash
   talosctl -n 192.168.2.233,192.168.2.234 etcd status
   ```

4. **Remove leftovers of the bad first boot** — the un-patched config had
   re-deployed flannel/kube-proxy cluster-wide; deleting the DaemonSets sticks
   once every control-plane config disables them:

   ```bash
   kubectl --context talos -n kube-system delete ds kube-flannel kube-proxy
   kubectl --context talos -n kube-system delete sa flannel kube-proxy
   kubectl --context talos -n kube-system delete cm kube-flannel-cfg kube-proxy-config-*
   kubectl --context talos delete clusterrole flannel
   kubectl --context talos delete clusterrolebinding flannel kube-proxy
   ```

5. **Reboot node-one** to clear the lingering `flannel.1` vxlan interface, then
   re-verify:

   ```bash
   talosctl -n 192.168.2.233 reboot
   talosctl -n 192.168.2.233 get links | grep flannel   # expect no match
   ```

If a clean removal is needed instead (e.g. the membership is genuinely stuck at a
dead IP): bring the node back to its join-time IP so quorum returns, then
`talosctl -n <ip> etcd leave`, change the IP, and re-join — see the Talos
[Disaster Recovery](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery)
guide.

## Quorum

`talosctl etcd status` has no "quorum" field — infer it from the `LEADER` column
(all-zero / `etcdserver: no leader` = quorum lost). With **2 members, both must be
up**. `node-three` is planned; 2-of-3 then tolerates one node down. Until then,
powering off either node takes the API down (see below). `cilium/values.yaml`
sets `operator.replicas: 1` for the single-node case — raise it once the cluster
is bigger.

## Powering node-one off (rack work)

Shutting `node-one` down is **safe for data** (the config is persisted and it
rejoins on boot) but **takes the cluster API down** while it is off, because 2 of
2 etcd members are required:

```bash
talosctl -n 192.168.2.233 shutdown
# ... on return it boots, re-applies its config, and rejoins etcd automatically
```

For planned downtime that must keep the API up, add `node-three` first.

## See also

- [[Cilium on Talos (Helm, kube-proxy-free)]] — machine patch / CNI switch / adding nodes
- [[Talos CLI: common commands (dashboard, status, shutdown)]] — `talosctl` verbs, dashboard, etcd
- [[kubectl contexts: switching between clusters]] — the `talos` context
