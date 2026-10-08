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
talosctl upgrade --image <installer-image>   # upgrade the Talos OS
```

Both are irreversible/risky — confirm the target node with `--nodes` first.

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
