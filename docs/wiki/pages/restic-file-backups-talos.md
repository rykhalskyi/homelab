---
tags: [backup, restic, minio, talos, kubernetes, flux, nextcloud, forgejo, sops, plan]
date: 2026-10-13
source_count: 0
---

# File-volume backups on Talos (restic → MinIO) — plan

> **Status: Phase 0 + Phase 1 implemented on this branch (not yet deployed).**
> The MinIO bucket/user/policy are created (out of band), and the Nextcloud
> restic CronJob + its SOPS Secret are added here. Still pending: commit/PR →
> Flux reconcile, a smoke-test run, and a test restore. Forgejo and the off-site
> copy remain deferred. This will supersede the manual items in
> [[Backups: what to save and how to restore]].

## Why

CloudNativePG already mirrors the **databases** (see
[[CloudNativePG on Talos (PostgreSQL + MinIO backups)]]), but the file data in
the apps' PVCs is unprotected:

- **Nextcloud user files** live in the `nextcloud-data` PVC
  (`/var/www/html/data`: uploads, appdata, previews, versions).
- **Forgejo git repositories + LFS** would live in a `forgejo-data` PVC at
  `/data` (not yet deployed to Talos — see *Phase 2*).

`local-path` is node-local with no snapshots, so a lost node means lost volumes.
[[Backups: what to save and how to restore]] already lists a `restic`/`rsync`
job for this as a TODO; this page is the plan to close it.

## Decisions (agreed 2026-10-13)

| Question | Decision |
|----------|----------|
| Mechanism | Per-app **restic** CronJob (not Velero) |
| Target | **New** MinIO bucket `restic-backups` + least-privilege `restic` user |
| Off-site copy | **Deferred** — LAN MinIO (single NAS) only for the first cut |
| Forgejo | **Deferred** — reusable pattern now, Forgejo CronJob added when it is deployed |

## Design

- **restic** — deduplicates, encrypts and uploads only changed blocks, so the
  NAS does not balloon across runs.
- **One CronJob per data PVC**, in the app's namespace, mounting the PVC
  **read-only**.
- Daily at **~02:00** (CNPG base backups run at 03:00); retention
  `restic forget --prune`: **7 daily / 4 weekly / 6 monthly**.
- **Repo per app:** `s3:http://192.168.2.112:9000/restic-backups/<app>`
  (`AWS_DEFAULT_REGION=us-east-1`), same LAN MinIO as CNPG.
- **Credentials:** per-namespace SOPS Secret `<app>-backup` holding
  `RESTIC_PASSWORD`, `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` — mirrors the
  per-namespace `cnpg-minio` pattern (Kubernetes Secrets are namespace-scoped).

## Phase 0 — MinIO prep (NAS, out of band)

Follow the `mc` setup in
[[CloudNativePG on Talos (PostgreSQL + MinIO backups)]], then create a dedicated
bucket and a least-privilege user (kept separate from the CNPG `cnpg`
bucket/user):

```bash
./mc mb local/restic-backups
./mc admin user add local restic '<strong-password>'

# /volume1/docker/restic-policy.json
#   ListBucket / GetBucketLocation on arn:aws:s3:::restic-backups, plus
#   GetObject/PutObject/DeleteObject on arn:aws:s3:::restic-backups/*
./mc admin policy create local restic-rw /volume1/docker/restic-policy.json
./mc admin policy attach local restic-rw --user restic
./mc admin user svcacct add local restic        # Access Key / Secret Key
```

Generate a `RESTIC_PASSWORD` and store it with the svcacct keys in SOPS (below).

## Phase 1 — Nextcloud (the buildable first cut)

> **Implemented on `talos/restic-file-backups`.** The four files below exist; the
> CronJob was validated with `kubectl kustomize` (client-side). Not yet deployed
> (pending merge → Flux) and not yet restore-tested.

| File | Change |
|------|--------|
| `infra/clusters/talos/apps/nextcloud/restic-backup.yaml` | **new** CronJob `nextcloud-restic` |
| `infra/clusters/talos/apps/nextcloud/kustomization.yaml` | add `restic-backup.yaml` |
| `infra/clusters/talos/apps/secrets/nextcloud-backup.sops.yaml` | **new** Secret (local-only, gitignored) |
| `infra/clusters/talos/apps/secrets/kustomization.yaml` | add the new sops file |

CronJob shape (`nextcloud-restic`, namespace `nextcloud`):

- **Image** `restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510`
  (the multi-arch index digest) — digest-pinned per repo convention. Unlike the
  app images there is no pin-updater workflow, so the digest is bumped by hand.
- **Volume** `persistentVolumeClaim: nextcloud-data`, mounted at `/data`
  **read-only**. (The PVC root *is* the Nextcloud data dir; local-path RWO plus
  PV node-affinity lets the job co-mount it on the same node as the app.)
- **Cache** `emptyDir` at `/tmp/restic-cache` with `RESTIC_CACHE_DIR` set.
- **Run** init-if-missing → `restic backup --host nextcloud /data` →
  `restic forget --prune …`.
- **No excludes** in v1 (a faithful copy of the volume); excludes such as
  `nextcloud.log`, `updater-*`, `appdata_*/preview/*` can be added later to trim
  size.
- `concurrencyPolicy: Forbidden`, `restartPolicy: OnFailure`, history limits,
  `securityContext.runAsUser: 0` (simplest read access to uid-33 files; a
  non-root + `fsGroup` alternative is possible).
- **Env** `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` — all except the last from the
  `nextcloud-backup` Secret.

Secret (`nextcloud-backup`, out of band):

```bash
sops infra/clusters/talos/apps/secrets/nextcloud-backup.sops.yaml
bash infra/clusters/talos/apps/secrets/apply.sh         # CTX=talos
```

## Phase 2 — Forgejo (deferred)

Forgejo is **not on Talos yet** — it currently exists only as the phase-1
Compose stack under `infra/phase1/forgejo/` (and per
[[Adding node-one to the Talos cluster (control-plane IP gotcha)]] its old host
was wiped). A backup CronJob has nothing to mount until Forgejo is deployed.

Plan: reuse this pattern verbatim in the same change that deploys Forgejo to
Talos — add `apps/forgejo/restic-backup.yaml` (mounting a `forgejo-data` PVC at
`/data`, which holds `/data/git/repositories` and `/data/git/lfs`) plus its own
SOPS `forgejo-backup` Secret and a `restic-backups/forgejo` prefix in the MinIO
policy.

## Off-site copy (deferred)

MinIO is a single NAS. A second restic target (e.g. Backblaze B2) would move
backups off-site; out of scope for the first cut.

## Out of scope

- The NAS share mounted at `/nas` (`/volume1/nextcloud`, a Nextcloud **external
  storage**) — covered by the NAS's own backup tooling, not by restic.
- Database backups — already handled by CloudNativePG.

## Verification

```bash
kubectl --context talos -n nextcloud get cronjob nextcloud-restic
kubectl --context talos -n nextcloud create job --from=cronjob/nextcloud-restic nextcloud-restic-manual
kubectl --context talos -n nextcloud logs job/nextcloud-restic-manual
# on the NAS: ./mc ls -r local/restic-backups/nextcloud
```

Then run **one full test restore** into a scratch directory — an untested backup
is not a backup.

## Restore sketch

```bash
# inside a pod/container with the repo env + the volume mounted read-write:
restic restore latest --target /restore/nextcloud
# then copy the files back onto the data volume and rescan:
#   occ files:scan --all
```

## Risks

- **Live-filesystem consistency.** restic reading while Nextcloud writes can
  capture a file mid-write; restic warns and retries. Acceptable for a homelab,
  and metadata is already covered by the CNPG base+WAL backup. A stricter option
  is a brief maintenance mode around the run.
- **Third-party pin drift.** The restic image digest is manual.
- **Single target.** No off-site copy until the deferred phase.
