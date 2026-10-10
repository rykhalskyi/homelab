---
tags: [talos, kubernetes, pgadmin, postgresql, cnpg, cloudnativepg, database, ingress, traefik, sops, lan]
date: 2026-10-10
source_count: 0
---

# pgAdmin for the talos cluster (LAN-only)

A pgAdmin to inspect the CloudNativePG `postgres` cluster on the `talos`
cluster. It is deliberately **LAN-only** (host under `*.homelab.local`, never
`*.otakeessen.com`), mirroring the k8s cluster's pgAdmin. Login credentials are
the **same** as the k8s pgAdmin (`pgadmin-auth`).

## Target picture

```
databases/pgadmin  ──►  postgres-rw.databases.svc:5432   (CNPG primary)
        ▲
Traefik (node-two :80) ◄── http://pgadmin-db.homelab.local/   (LAN only)
```

## The pieces

| File | Role |
|------|------|
| `infra/clusters/talos/apps/pgadmin/{pvc,deployment,service,ingress}.yaml` | the workload |
| `infra/clusters/talos/apps/pgadmin/kustomization.yaml` | bundles it |
| `infra/clusters/talos/apps/secrets/pgadmin-auth.sops.yaml` | **local only**, login creds |

Image `dpage/pgadmin4:9.18.0@sha256:c332c5f6…26de` (same pin as k8s); 2Gi
`local-path` PVC; `Recreate` strategy (single writer).

## Credentials

Same login as the k8s cluster's pgAdmin. The out-of-band Secret
`databases/pgadmin-auth` (`PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD`)
is applied by `apps/secrets/apply.sh` (see
[[Secrets with SOPS + age (local, out-of-band)]]).

## Deploy

```bash
flux --context talos reconcile kustomization apps -n flux-system --with-source
kubectl --context talos -n databases get pods -w      # pgadmin-...
```

## LAN access

The Ingress host is **`pgadmin-db.homelab.local`** — distinct from the k8s
cluster's `pgadmin.homelab.local` (node-one) so the two never collide. Add to
each client's `/etc/hosts`:

```
192.168.2.234 pgadmin-db.homelab.local
```

Then open `http://pgadmin-db.homelab.local/` and log in with the `pgadmin-auth`
email/password.

## Register the database

In pgAdmin, add a new server:

- **Host**: `postgres-rw` (or `postgres-rw.databases.svc.cluster.local`)
- **Port**: `5432`
- **Maintenance database**: `postgres`
- **Username**: `app`
- **Password**: from the operator-generated Secret `postgres-app`:

  ```bash
  kubectl --context talos -n databases get secret postgres-app \
    -o jsonpath='{.data.password}' | base64 -d; echo
  ```

(`postgres-app` is created by the operator with the `app` role/password. Add
`enableSuperuserAccess: true` to the Cluster if you also want a
`postgres-superuser` login.)

## Verify

```bash
kubectl --context talos -n databases get deploy,po,svc,ingress | grep -i pgadmin
curl -s -H 'Host: pgadmin-db.homelab.local' http://192.168.2.234/misc/ping   # pong
```

## Notes

- **LAN-only**: `*.homelab.local` is never routed by the Cloudflare tunnel
  (which only forwards `*.otakeessen.com`), so pgAdmin stays internal.
- The talos `databases` namespace is `baseline` PSA; pgAdmin runs as uid 5050
  with a pod-level `securityContext` (no privileged bits needed).
- The k8s pgAdmin can't see this database (separate cluster, ClusterIP not
  routable); this one connects to the in-cluster `postgres-rw` Service.
