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

Files under `infra/k8s/apps/eurooffice/`:

| File | Role |
|------|------|
| `deployment.yaml` | the DocumentServer (all-in-one community image) |
| `pvc.yaml` | 10Gi `local-path` PVC mounted at `/var/www/onlyoffice/Data` |
| `service.yaml` | ClusterIP `eurooffice:80` |
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

Secret (not in Git):

```bash
kubectl -n homelab create secret generic eurooffice-jwt \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)"
```

## Nextcloud app (connector)

```bash
NC="kubectl -n homelab exec deploy/nextcloud -c nextcloud -- php /var/www/html/occ"
$NC app:install eurooffice && $NC app:enable eurooffice
$NC config:app:set eurooffice DocumentServerUrl --value="https://office.otakeessen.com/"
$NC config:app:set eurooffice jwt_secret  --value="$(kubectl -n homelab get secret eurooffice-jwt -o jsonpath='{.data.JWT_SECRET}' | base64 -d)"
$NC config:app:set eurooffice jwt_header  --value="Authorization"
$NC config:app:set eurooffice sameTab     --value=true     # click-to-open default
```

`DocumentServerUrl` must end with `/`. These app settings live in the database
(not Git), so re-run them after a rebuild from scratch.

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

- The DocumentServer is a single pod on `node-one`; documents themselves stay in
  Nextcloud, so the DS PVC is not user data.
- Public URLs are used in both directions (browser and server) — fine for a
  homelab; the DS's internal-URL/`StorageUrl` options exist if you later want to
  keep server-to-server traffic in-cluster.
- Only Office file types get the Euro-Office handler; plain text/markdown keep
  the normal editor.
- To remove it: `occ app:disable eurooffice`, drop `- eurooffice` from
  `infra/k8s/apps/kustomization.yaml`, and delete the Secret/PVC.
