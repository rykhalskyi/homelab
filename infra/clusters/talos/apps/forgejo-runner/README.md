# Forgejo Actions runner (talos)

A single [Forgejo Runner](https://forgejo.org/docs/latest/admin/actions/) so the
self-hosted forge can run CI (`.forgejo/workflows/*.yml`). It is a separate
program from Forgejo: Forgejo serves the pipelines, the runner executes them.

```
browser / git ──► git.otakeessen.com ──► Cloudflare ──► Traefik ──► forgejo:3000
                                                                        ▲
   forgejo-runner ──(in-cluster Service, no Cloudflare)────────────────┘
        │
        └── docker:dind (privileged sidecar) ──► job/step containers
```

## Why a `dind` sidecar

The runner launches every job as a container, so it needs a Docker daemon.
Talos has no host Docker and the runner cannot use containerd, so the pod runs a
`docker:dind` sidecar as its engine. `dockerd` needs its own storage/networking
(overlayfs, iptables, cgroups), which is why the sidecar is `privileged` — that
is effectively **node root**. Both cluster nodes are control planes with a
2-of-2 etcd quorum; treat this pod (and anyone who can push workflows) as
trusted.

The runner talks to Forgejo over the **in-cluster Service**
(`forgejo.forgejo.svc.cluster.local:3000`), never the public host, so CI is not
affected by Cloudflare Access or the ~100 MB tunnel upload cap.

## One-time setup

1. **Register the runner** (writes the UUID + a secret; nothing secret is
   committed):

   ```bash
   bash infra/clusters/talos/apps/forgejo-runner/register-runner.sh
   ```

2. **Put the UUID** into `configmap.yaml`
   (`server.connections.otakeessen.uuid`).

3. **Store the token Secret** out of band (never in Git):

   ```bash
   cp infra/clusters/talos/apps/forgejo-runner/secret.example.yaml \
      infra/clusters/talos/apps/secrets/forgejo-runner-token.sops.yaml
   # namespace it to `forgejo-runner`, set `token:` to the SECRET from step 1
   sops infra/clusters/talos/apps/secrets/forgejo-runner-token.sops.yaml
   bash infra/clusters/talos/apps/secrets/apply.sh
   ```

## Deploy

Merge to `main` and let Flux reconcile, or force it:

```bash
flux reconcile kustomization apps -n flux-system --with-source
kubectl --context talos -n forgejo-runner get pods,pvc
```

## Use it

Add a workflow to a repo — `.forgejo/workflows/ci.yml`:

```yaml
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest        # matches a label in configmap.yaml
    steps:
      - uses: actions/checkout@v6
      - run: make test
```

The runner shows up under `/admin/actions/runners` (and each repo's
`settings/actions/runners`).

## Notes / gotchas

- **One pod == one runner == one job** (`capacity: 1`). To run jobs in parallel,
  add another Deployment with its **own** registration/token and its **own**
  `dind` — do **not** use `replicas:` (they would share one token) and do not
  share a `dind` across runners.
- **Pod Security**: the namespace opts in to `privileged` PSA (the cluster
  default is `baseline`, which forbids the `dind` sidecar). Keep this namespace
  small and trusted — `privileged` is effectively node root.
- **Images are pinned by digest**; bump the tag + digest by hand.
- **Ephemeral storage**: `/data` (`.runner` + cache) and `/var/lib/docker` use
  `emptyDir`; both are lost on restart. Swap for a PVC if you want the cache to
  survive.
- **`token_url`** in `configmap.yaml` reads the token from
  `$CREDENTIALS_DIRECTORY/token`. If a runner version rejects it, fall back to an
  inline `token:` in the connection block (and then the whole config must be a
  Secret).
- **Pushing images built in CI** should target the in-cluster registry
  (`forgejo.forgejo.svc.cluster.local:3000/<owner>/<image>`) to skip Cloudflare;
  pulls for deployments use `git.otakeessen.com/...` with `/v2/*` bypassed in
  Cloudflare Access. See the Pullini artifact
  "Forgejo Runners & Container Image Storage — Decisions".
