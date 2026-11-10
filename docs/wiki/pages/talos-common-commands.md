---
tags: [talos, talosctl, kubernetes, cli, operations, dashboard, node-two]
date: 2026-10-08
source_count: 0
---

# Talos CLI: common commands (dashboard, status, shutdown)

Everyday `talosctl` commands for the Talos cluster (`node-two`,
`192.168.2.234`). `talosctl` talks to the **Talos gRPC API over mTLS on port
`50000`** — there is no REST API and no SSH; `talosctl` is the client. These
commands act on the **machine/OS**, not on Kubernetes objects (for those see
[[kubectl contexts: switching between clusters]]).

## Config & context (which cluster `talosctl` talks to)

`talosctl` resolves its config from `$TALOSCONFIG`, else `~/.talos/config`.

```bash
talosctl config info                 # current context, nodes, endpoints, expiry
talosctl config merge ./talosconfig  # add a context from a file
talosctl config context talos        # switch context (like kubectl use-context)
talosctl config endpoint 192.168.2.234
talosctl config node 192.168.2.234
```

One-off overrides (no config change):
```bash
talosctl version --talosconfig ./talosconfig --endpoints 192.168.2.234 --nodes 192.168.2.234
```

## Dashboard

Live TUI with CPU/mem graphs, services, and logs:

```bash
talosctl dashboard
```

Navigate with the arrow/Tab keys, `F1` for help, `q` to quit. Run it in a real
terminal. (The Kubernetes equivalent is k9s — see
[[kubectl contexts: switching between clusters]].)

## Status & inspection

```bash
talosctl version                 # client + server (OS) version, RBAC status
talosctl health                  # etcd, kubelet, kube-proxy, CoreDNS, schedulability
talosctl get members             # this node's machine-type / OS / addresses
talosctl get addresses           # IPs per interface
talosctl get links               # NIC link state / MAC
talosctl get routes             # routing table
talosctl get disks               # block devices (install target, USB, ...)
talosctl get volumes
talosctl service                 # state of system services (etcd, kubelet, ...)
talosctl stats                   # CPU / memory
```

Logs:
```bash
talosctl dmesg                             # kernel ring buffer
talosctl logs kubelet                      # a system service's logs
talosctl logs controller-runtime
talosctl logs -k -n kube-system <pod>      # a Kubernetes pod's logs
```

## Power control

```bash
talosctl reboot  --nodes 192.168.2.234      # graceful reboot
talosctl shutdown --nodes 192.168.2.234     # graceful power-off
```

> `shutdown` powers the machine **off** — bring it back with physical/WoL/IPMI.
> `reboot` comes back on its own. The node re-applies its machine config and
> rejoins the cluster after boot.

Restart just one service instead of the whole node:
```bash
talosctl service kubelet restart
# or: talosctl restart kubelet
```

## etcd & Kubernetes bootstrap

```bash
talosctl etcd members            # member list (empty until bootstrapped)
talosctl etcd status
talosctl bootstrap               # one-time: initialise the first etcd member
talosctl kubeconfig --nodes 192.168.2.234 --merge=false ./talos.kubeconfig
```

## Machine configuration

The node's config is managed by Talos (no SSH). Preview / change it:

```bash
talosctl get machineconfig -o yaml          # effective config
talosctl apply-config --file controlplane.yaml   # apply a config (from maintenance: add --insecure)
talosctl edit mc                            # edit the running config in $EDITOR
talosctl patch mc --patch @some-patch.yaml  # apply a patch
```

## Destructive (be careful)

```bash
talosctl reset                   # WIPE the node (disks/OS) -> reinstall needed
```

`talosctl reset` is irreversible; confirm the target node with `--nodes` first.

## Upgrading Talos OS (rolling, one node at a time)

A Talos OS upgrade does **not** upgrade Kubernetes. Check the target release's
default Kubernetes version first; if it matches the running cluster, there is
nothing to do. Kubernetes is bumped separately with
`talosctl upgrade-k8s --to <version>`.

Install a `talosctl` matching the target version, then pass the release's
installer image explicitly. These nodes have **no system extensions**, so they
use the empty Image Factory schematic:

```bash
IMG=factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.5
talosctl upgrade -n <node-ip> --image "$IMG" --drain=false --wait
```

> **Use `--drain=false` here.** The six CloudNativePG clusters are
> single-instance with `minAvailable: 1` PDBs (`ALLOWED DISRUPTIONS 0`), so the
> default drain waits out `--drain-timeout` (5m) and aborts before rebooting.
> Pods restart when the node returns; the kubelet may leave old pods in
> `Failed` state — clean them with
> `kubectl delete pods -A --field-selector status.phase=Failed`.

Upgrade one control plane at a time (2/3 etcd quorum) and verify between
nodes: `talosctl -n <node-ip> version`, `talosctl etcd status`,
`talosctl health`, `kubectl get nodes`, and the CNPG clusters. Order used for
these three control planes: `node-three`, `node-one`, then `node-two` last (the
API endpoint, most workloads, and the SSD-backed `local-path` volumes).

The upgrade does **not** persist the new installer image, so bump
`UnattendedInstallConfig.installer.image` afterwards (and the committed pin in
`infra/clusters/talos/nodes/node-three/patch.yaml` for future installs).

## Handy one-liners

```bash
# Is the cluster healthy end to end?
talosctl health

# What install disk / where did it install?
talosctl get disks

# Follow kubelet as it starts
talosctl logs kubelet -f
```

## See also

- [[kubectl contexts: switching between clusters]] — `kubectl`/k9s side of the
  same two clusters (`k8s` and `talos`).
