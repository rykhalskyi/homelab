---
tags: [kubectl, kubernetes, kubeconfig, contexts, k9s, k8s, talos]
date: 2026-10-08
source_count: 0
---

# kubectl contexts: switching between clusters

How one workstation drives two clusters — the old k3s cluster `k8s`
(`node-one`, `192.168.2.233`) and the new Talos cluster `talos`
(`node-two`, `192.168.2.234`) — with a single kubeconfig. For the
machine-level (OS) view of Talos, see
[[Talos CLI: common commands (dashboard, status, shutdown)]].

> **Update (2026-10-10): the `k8s`/k3s cluster is retired.** Its host, `node-one`,
> was wiped and re-joined the **`talos`** cluster as a second control plane
> (`192.168.2.233`) — see
> [[Adding node-one to the Talos cluster (control-plane IP gotcha)]]. The `k8s`
> context/kubeconfig and the two-cluster comparison below are kept for history;
> `talos` is now the only cluster, with nodes `node-one` and `node-two`.

## What a context is

A kubeconfig file holds `clusters` + `users` + `contexts`. A **context** binds
one cluster to one user (and an optional default namespace); `current-context`
picks the active one. `kubectl` reads `$KUBECONFIG`, else `~/.kube/config`.

## See what you have

```bash
kubectl config get-contexts
kubectl config current-context
```

Our merged setup:
```
CURRENT   NAME    CLUSTER   AUTHINFO
*         k8s     default   default      # k3s  -> node-one (v1.36.4+k3s1)
          talos   talos     admin@talos  # Talos-> node-two (v1.37.1)
```

## Switch

```bash
kubectl config use-context talos     # make Talos the default
kubectl config use-context k8s       # back to k3s
kubectl get nodes                    # now shows the selected cluster
```

Per-command, without switching:
```bash
kubectl --context talos get pods -A
kubectl --context k8s   get nodes -o wide
```

## See the nodes of each cluster

```bash
kubectl --context talos get nodes -o wide
kubectl --context k8s   get nodes -o wide
# or switch first, then: kubectl get nodes
```

## Default namespace per context

```bash
kubectl config set-context --current --namespace=homelab   # for the current context
# or target one explicitly:
kubectl config set-context talos --namespace=default
```

## Rename a context (cosmetic)

```bash
kubectl config rename-context default k8s
kubectl config rename-context admin@talos talos
```

## Merge two kubeconfigs into one

`$KUBECONFIG` accepts a colon-separated list; `view --flatten` embeds the certs
into a single file. **Back up first.**

```bash
cp ~/.kube/config ~/.kube/config.bak.$(date +%Y%m%d-%H%M%S)

KUBECONFIG=~/.kube/config:~/Source/homelab/infra/clusters/talos/talos.kubeconfig \
  kubectl config view --flatten > /tmp/merged.kube && \
  mv /tmp/merged.kube ~/.kube/config && chmod 600 ~/.kube/config

kubectl config get-contexts
```

To use the list **without** merging (read-only, both stay separate files):
```bash
export KUBECONFIG=~/.kube/config:~/Source/homelab/infra/clusters/talos/talos.kubeconfig
kubectl config get-contexts
```

## k9s — same TUI, both clusters

k9s reads the same kubeconfig, so no separate config is needed:

```bash
k9s                          # then type :ctx and pick k8s or talos
k9s --context talos          # launch straight into Talos
```

Inside k9s: `:ctx` opens the context picker, `:ns` the namespace picker.

## Verify you're pointed at the right cluster

```bash
kubectl config current-context      # k8s or talos
kubectl cluster-info                # shows the API server URL
kubectl get nodes                   # node-one (k3s) vs node-two (Talos)
```

Common slip: a command runs against the *wrong* cluster because you didn't
switch context. When in doubt, `kubectl config current-context` first — or use
`--context` per command.
