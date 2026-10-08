---
tags: [nextcloud, k3s, eurooffice, onlyoffice, documentserver, office, gitops, flux, oci]
date: 2026-09-29
source_count: 0
---

# Euro-Office on k3s

Euro-Office is the European fork of the ONLYOFFICE DocumentServer (backed by
Nextcloud, IONOS, Proton, …). This page wires it up as the default office editor
for the k3s Nextcloud, replacing the ONLYOFFICE integration that AIO used to
ship automatically.

Two parts, like ONLYOFFICE:

1. a **DocumentServer** workload (the editor backend), and
2. the **`eurooffice` Nextcloud app** (the connector), configured with `occ`.

## Prerequisite

The `eurooffice` app requires **Nextcloud 33–35**, so the instance was upgraded
first: see [[Nextcloud major upgrade on k3s (31 → 32 → 33)]].

## DocumentServer workload

Files under `infra/clusters/k8s/apps/eurooffice/`:

| File | Role |
|------|------|
| `deployment.yaml` | the DocumentServer (all-in-one community image) |
| `pvc.yaml` | 10Gi `local-path` PVC mounted at `/var/www/onlyoffice/Data` |
| `service.yaml` | ClusterIP `eurooffice:80` |
| `middleware.yaml` | Traefik `Middleware`s: force `X-Forwarded-Proto: https`; hide the `/welcome/` landing page |
| `ingress.yaml` | host `office.otakeessen.com` (wildcard tunnel → Traefik) |

Details that matter:

- Image **`ghcr.io/euro-office/documentserver`** — upstream publishes only
  `latest`/`main` (no semver tags), so it is **pinned by digest**:
  `latest@sha256:889e681923d2dcc8bdfb92fe128d10e185fcff880d302b6a0c0c7bf339499290`.
  Bump the digest deliberately.
- The all-in-one image embeds its own Postgres/RabbitMQ/Redis; it needs **~2–4 GB
  RAM**.
- JWT is mandatory and must match the app: `JWT_ENABLED=true`,
  `JWT_HEADER=Authorization`, `JWT_SECRET` from the out-of-band Secret.
- `ALLOW_PRIVATE_IP_ADDRESS=true` so the DS may talk to in-cluster addresses.
- A `Memory` emptyDir at `/dev/shm` (embedded services).
- Readiness on `/healthcheck`.
- The `X-Forwarded-Proto: https` middleware is **required** (see the mixed-content
  gotcha below).

Secret (not in Git):

```bash
kubectl -n homelab create secret generic eurooffice-jwt \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)"
```

## Nextcloud app (connector)

```bash
NC="kubectl -n homelab exec deploy/nextcloud -c nextcloud -- php /var/www/html/occ"
$NC app:install eurooffice && $NC app:enable eurooffice
$NC config:app:set eurooffice DocumentServerUrl         --value="https://office.otakeessen.com/"
$NC config:app:set eurooffice DocumentServerInternalUrl --value="http://eurooffice.homelab.svc.cluster.local/"
$NC config:app:set eurooffice StorageUrl                --value="http://nextcloud.homelab.svc.cluster.local:8080/"
$NC config:app:set eurooffice jwt_secret  --value="$(kubectl -n homelab get secret eurooffice-jwt -o jsonpath='{.data.JWT_SECRET}' | base64 -d)"
$NC config:app:set eurooffice jwt_header  --value="Authorization"
$NC config:app:set eurooffice sameTab     --value=true     # click-to-open default
```

Why these three URLs:

- `DocumentServerUrl` — what the **browser** loads; the public URL, must end
  with `/`.
- `DocumentServerInternalUrl` — Nextcloud → DocumentServer calls (health check,
  conversions), kept in-cluster.
- `StorageUrl` — the Nextcloud address the **DocumentServer** uses to fetch
  files; the in-cluster Service on its real port (`8080`).

Do **not** let these go through Cloudflare: NC → DS over the public hostname
timed out (`cURL error 28: timed out after 120s`).

The internal hostname must also be trusted, or Nextcloud answers the DS with
`400` (untrusted domain) and downloads fail:

```bash
$NC config:system:set trusted_domains 2 --value=nextcloud.homelab.svc.cluster.local
$NC config:system:set trusted_domains 3 --value=nextcloud
```

These app/system settings live in the database / `config.php` (not Git), so
re-run them after a rebuild from scratch.

### Gotcha: `overwrite.cli.url`

If `overwrite.cli.url` is wrong (it was `https://localhost` inherited from the
AIO migration), the connection check fails with:

```
Error while downloading the document file to be converted.
```

Because CLI-generated document URLs then point at `https://localhost`, which the
DocumentServer cannot reach. Fix:

```bash
$NC config:system:set overwrite.cli.url --value=https://cloud.otakeessen.com
```

### Gotcha: Mixed Content (`X-Forwarded-Proto`)

TLS terminates at Cloudflare and Traefik's entrypoint is plain HTTP, so the
DocumentServer sees `X-Forwarded-Proto: http` and builds its own asset URLs
(e.g. `/cache/files/data/.../Editor.bin`) as `http://office.otakeessen.com/...`.
The HTTPS page then blocks them — the browser console shows:

```
Mixed Content: The page at 'https://cloud.otakeessen.com/...' was loaded over
HTTPS, but requested an insecure XMLHttpRequest endpoint
'http://office.otakeessen.com/cache/files/data/.../Editor.bin...'
```

Fix: force the header at Traefik with a `Middleware` referenced from the Ingress.

```yaml
# infra/clusters/k8s/apps/eurooffice/middleware.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: eurooffice-forwarded-proto
  namespace: homelab
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: https
```

```yaml
# infra/clusters/k8s/apps/eurooffice/ingress.yaml  (metadata)
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: homelab-eurooffice-forwarded-proto@kubernetescrd
```

After changing this, hard-reload (the old `http://` editor config may be cached;
a private window works too).

### Hiding the welcome page

The DocumentServer is public because the browser loads the editor from it, but
its landing page (`/` 302s to `/welcome/`) is not meant for visitors. A second
`Middleware`, `eurooffice-hide-welcome`, redirects just that path to Nextcloud:

```yaml
# infra/clusters/k8s/apps/eurooffice/middleware.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: eurooffice-hide-welcome
  namespace: homelab
spec:
  redirectRegex:
    regex: '^https?://office\.otakeessen\.com/welcome/?$'
    replacement: 'https://cloud.otakeessen.com/'
    permanent: false
```

The Ingress lists both middlewares:

```yaml
    traefik.ingress.kubernetes.io/router.middlewares: homelab-eurooffice-forwarded-proto@kubernetescrd,homelab-eurooffice-hide-welcome@kubernetescrd
```

Only `/welcome/` is redirected; `/web-apps/...`, `/coauthoring/...`, and
`/healthcheck` still serve directly, so embedding is unaffected
(`occ eurooffice:documentserver --check` stays green).

## Verify

```bash
$NC eurooffice:documentserver --check
# Document server https://office.otakeessen.com/ version 9.3.4.37 is successfully connected

curl -s https://office.otakeessen.com/healthcheck     # true
```

Then open `https://cloud.otakeessen.com`, create or open a `.docx`/`.xlsx`/
`.pptx`, and edit it. `sameTab=true` makes Euro-Office the default handler for
those types; per-type/per-user defaults are in **Settings → Administration →
Euro-Office** (`/settings/admin/eurooffice`).

Working versions: Nextcloud **33.0.9**, `eurooffice` app **11.0.5**,
DocumentServer **9.3.4.37**.

## Notes and limits

- Server-to-server traffic stays in-cluster (`DocumentServerInternalUrl` /
  `StorageUrl`); only the browser uses the public `office.otakeessen.com`.
- The DocumentServer is a single pod on `node-one`; documents themselves stay in
  Nextcloud, so the DS PVC is not user data.
- Only Office file types get the Euro-Office handler; plain text/markdown keep
  the normal editor.
- To remove it: `occ app:disable eurooffice`, drop `- eurooffice` from
  `infra/clusters/k8s/apps/kustomization.yaml`, and delete the Secret/PVC.
