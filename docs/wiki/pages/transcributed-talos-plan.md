---
tags: [transcributed, talos, kubernetes, flux, keda, rabbitmq, cloudnativepg, whisper, transcription, nfs, nas, plan, deployment]
date: 2026-10-18
source_count: 0
---

# Transcributed on Talos (deployment plan)

> **Status: implemented 2026-10-20.** Phase 1 (KEDA, RabbitMQ, CNPG) and
> Phase 2 (the Transcributed HelmRelease) are live on `talos`. This page is kept
> as the original plan; the current state is documented in
> [[Transcributed on Talos (architecture)]] and the usage runbook in
> [[Running a transcription (Transcributed)]].
>
> The NAS export and MinIO prefix were added. Two deployment-side changes were
> needed after the plan: remove the unsupported `ScaledJob.cooldownPeriod` with
> a HelmRelease `postRenderers` patch, and use client-default NFS mount options
> (`nfsvers=4.1` is rejected by the Synology). The findings and preconditions
> below describe the state at plan time.

Deployment plan for [Transcributed](https://github.com/rykhalskyi/transcributed),
the self-hosted lecture transcription control plane. The app ships a Helm chart
(at `charts/transcributed/` in the app repo); this homelab repo owns the cluster
deployment, secrets, and supporting infrastructure (D-16 in the app repo).

## Findings (at plan time)

- The chart is published at
  `oci://ghcr.io/rykhalskyi/charts/transcributed:0.1.0`.
- Images are public: `ghcr.io/rykhalskyi/transcributed-api:v0.1.0` and
  `ghcr.io/rykhalskyi/transcributed-worker:v0.1.0`.
- The app repo has a `v0.2.0` tag, but both release workflows failed — only
  `0.1.0` is actually published. Do not pin `0.2.0`.
- The chart defaults image tags to `appVersion` (`0.1.0`), while the published
  image tags are `v0.1.0`. The HelmRelease **must** set
  `api.image.tag` and `worker.image.tag` explicitly, or the pods fail with
  `ImagePullBackOff`.
- The `talos` cluster already has CloudNativePG, Traefik, `local-path`,
  metrics-server, and the `*.otakeessen.com` Cloudflare tunnel. It has **no
  KEDA** and **no RabbitMQ**; the chart requires both.
- NAS `192.168.2.112` currently exports only `/volume1/media` and
  `/volume1/nextcloud` to the node IPs. `/volume1/video/lectures` is not
  exported yet.

## Decisions

- **NAS input:** `/volume1/video/lectures`, mounted read-only at
  `/nas/lectures`.
- **Ingress:** LAN-only at `transcributed.homelab.home.arpa`. The API has no
  authentication in this slice, so it must stay off the internet.
- **RabbitMQ:** one-node StatefulSet in its own `rabbitmq` namespace, using the
  official `rabbitmq:4.3-management` image and an 8Gi `local-path` PVC. No
  RabbitMQ operator and no `cert-manager` dependency.
- **Workers:** no node pinning. Start with `maxReplicaCount: 2` and preferred
  pod anti-affinity so KEDA jobs tend to land on different nodes. The scheduler
  remains free to place them wherever resources fit.

## Blocking preconditions (completed 2026-10-20)

1. **Export the NAS path.** On the Synology, enable NFS for `/volume1/video`
   (or export `/volume1/video/lectures` directly) to `192.168.2.233` and
   `192.168.2.234`. Verify:
   ```bash
   showmount -e 192.168.2.112
   ```
   The chart's PV path must be an NFS-accessible path. If Synology only exports
   the shared-folder root, test mounting `/volume1/video/lectures` as a
   subdirectory; if that fails, export `/volume1/video` and either export the
   subfolder or mount it at `/nas/video` and submit paths as `lectures/...`.
2. **Allow backup writes.** Add `arn:aws:s3:::cnpg-backups/transcributed/*` to
   the MinIO `cnpg-rw` policy (see
   [[CloudNativePG on Talos (PostgreSQL + MinIO backups)]]).
3. **Create the SOPS secrets locally** (never committed; see
   [[Secrets with SOPS + age (local, out-of-band)]]):
   - `apps/secrets/rabbitmq.sops.yaml` -> Secret `rabbitmq-secrets` in
     namespace `rabbitmq`, keys `username` and `password`.
   - `apps/secrets/transcributed.sops.yaml` -> Secret `transcributed-secrets`
     in namespace `transcributed`:
     - `username`: `transcributed`
     - `password`: the CNPG bootstrap password (must match `DATABASE_URL`)
     - `DATABASE_URL`:
       `postgresql+psycopg://transcributed:<pass>@transcributed-rw.transcributed.svc.cluster.local:5432/transcributed`
     - `RABBITMQ_URL`:
       `amqp://transcributed:<pass>@rabbitmq.rabbitmq.svc.cluster.local:5672/`
   - `apps/secrets/transcributed-minio.sops.yaml` -> Secret `cnpg-minio` in
     namespace `transcributed` (`ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`).
   - Add all three to `apps/secrets/kustomization.yaml` and apply:
     ```bash
     bash infra/clusters/talos/apps/secrets/apply.sh
     ```
   The RabbitMQ password must match the one in `transcributed-secrets`; the
   CNPG bootstrap password must match the one in `DATABASE_URL`.

## Phase 1 — platform prerequisites (PR 1)

Add the KEDA operator, RabbitMQ, and the Transcributed database. This PR does
**not** install the app chart, so the database and broker are Ready before the
migration hook runs.

### KEDA (infrastructure layer)

- `infra/clusters/talos/infrastructure/sources/keda.yaml` — HelmRepository
  `https://kedacore.github.io/charts`.
- `infra/clusters/talos/infrastructure/keda/namespace.yaml` — namespace `keda`.
- `infra/clusters/talos/infrastructure/keda/helmrelease.yaml` — chart `keda`
  version `2.21.0` (current release), with `install.crds: Create` and
  `upgrade.crds: CreateReplace`, plus modest CPU/memory requests and limits.
- `infra/clusters/talos/infrastructure/keda/kustomization.yaml`.
- Add the source and `keda` entry to
  `infra/clusters/talos/infrastructure/kustomization.yaml`.
- Add the chart source for Flux:
  `infra/clusters/talos/infrastructure/sources/transcributed.yaml` — an
  `OCIRepository` in `flux-system` pointing at
  `oci://ghcr.io/rykhalskyi/charts/transcributed`, tag `0.1.0`.

KEDA is infrastructure because the `ScaledJob` CRD must exist before the
`apps` Kustomization applies the worker. The `apps` Kustomization already
`dependsOn` `infrastructure`.

### RabbitMQ (apps layer)

- `infra/clusters/talos/apps/rabbitmq/namespace.yaml`.
- `infra/clusters/talos/apps/rabbitmq/headless-service.yaml` — `clusterIP: None`
  for the StatefulSet identity.
- `infra/clusters/talos/apps/rabbitmq/service.yaml` — ClusterIP on `5672`
  (AMQP) and optionally `15672` (management).
- `infra/clusters/talos/apps/rabbitmq/statefulset.yaml`:
  - image `docker.io/library/rabbitmq:4.3.4-management`, pinned by digest
    (repo convention);
  - `RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS` from
    `rabbitmq-secrets`;
  - `volumeClaimTemplates` with an 8Gi `local-path` volume at
    `/var/lib/rabbitmq`;
  - readiness/liveness probes with `rabbitmq-diagnostics -q ping`;
  - requests `100m`/`256Mi`, limits `1 CPU`/`1Gi`.
- `infra/clusters/talos/apps/rabbitmq/kustomization.yaml`.

A StatefulSet is used instead of a Deployment because RabbitMQ stores its node
name in the data directory; a stable `rabbitmq-0` hostname avoids a
node-name mismatch after a restart.

### Transcributed database (apps layer)

- `infra/clusters/talos/apps/transcributed/namespace.yaml`.
- `infra/clusters/talos/apps/transcributed/db-cluster.yaml` — CloudNativePG
  `Cluster transcributed`:
  - 1 instance, PostgreSQL 18.4 operand pinned by digest, 10Gi `local-path`;
  - `bootstrap.initdb` with database/owner `transcributed` and secret
    `transcributed-secrets`;
  - `barmanObjectStore` to `s3://cnpg-backups/transcributed` on
    `http://192.168.2.112:9000`, credentials from `cnpg-minio`;
  - `retentionPolicy: "30d"`.
- `infra/clusters/talos/apps/transcributed/scheduled-backup.yaml` — daily
  `ScheduledBackup` at 03:30 (six-field cron).
- `infra/clusters/talos/apps/transcributed/kustomization.yaml` (no HelmRelease
  yet).
- Add `rabbitmq` and `transcributed` to
  `infra/clusters/talos/apps/kustomization.yaml`.

## Phase 2 — deploy the chart (PR 2)

Add `infra/clusters/talos/apps/transcributed/helmrelease.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: transcributed
  namespace: transcributed
spec:
  interval: 10m
  chartRef:
    kind: OCIRepository
    name: transcributed
    namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    api:
      image:
        tag: v0.1.0
      ingress:
        enabled: true
        className: traefik
        hosts:
          - host: transcributed.homelab.home.arpa
            paths:
              - path: /
                pathType: Prefix
    worker:
      image:
        tag: v0.1.0
      keda:
        maxReplicaCount: 2
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/component: worker
    migrations:
      backoffLimit: 6
      activeDeadlineSeconds: 900
    nas:
      enabled: true
      create: true
      server: 192.168.2.112
      share: /volume1/video/lectures
      mountPath: /nas/lectures
      capacity: 10Ti
      accessMode: ReadOnlyMany
```

Then add the HelmRelease to
`infra/clusters/talos/apps/transcributed/kustomization.yaml`.

Optional in this PR:

- Add a `Transcributed` tile to the homepage dashboard.
- Add this page to the index and log (done here).

## Rollout and verification

After PR 1:

```bash
flux reconcile kustomization infrastructure -n flux-system --with-source
kubectl -n keda get pods
kubectl get crd | grep keda

flux reconcile kustomization apps -n flux-system --with-source
kubectl -n rabbitmq get sts,pods,pvc
kubectl -n transcributed get cluster,pods
```

After PR 2:

```bash
kubectl -n transcributed get deploy,svc,scaledjob,jobs,pods -o wide
kubectl -n transcributed logs deploy/transcributed-api
kubectl -n transcributed port-forward svc/transcributed-api 8000:8000
curl -fsS http://localhost:8000/healthz
curl -fsS http://localhost:8000/readyz
```

Then:

1. Point `transcributed.homelab.home.arpa` at `192.168.2.240` in Pi-hole
   local DNS or `/etc/hosts`.
2. Put a test lecture under the exported NAS share (for example
   `lectures/sample1.mp4`).
3. Create a project through the API with the NAS-relative path, start a run,
   and verify:
   - KEDA creates up to two worker Jobs;
   - Jobs land on different nodes when both have room;
   - the transcript artifact is downloadable.

## Risks and notes

- **NFS path shape:** the chart mounts the NFS path at `/nas/lectures`, and the
  API treats that as `NAS_INPUT_ROOT`. If the export is `/volume1/video` and a
  subdirectory mount is rejected, mount the share at `/nas/video` and submit
  paths as `lectures/...`.
- **Migration race:** avoided by the two-PR order. The higher `backoffLimit`
  and deadline are a safety net if the CNPG database is still starting.
- **Password coupling:** the CNPG bootstrap password, the password inside
  `DATABASE_URL`, and the RabbitMQ password (also inside `RABBITMQ_URL`) must
  match their respective SOPS Secrets.
- **Image tags:** always pin both image tags to `v0.1.0`; the chart's default
  `0.1.0` tag does not exist in the registry.
- **Multiple workers:** `maxReplicaCount: 2` with preferred anti-affinity
  spreads jobs but does not block scheduling if one node is down. Each worker
  requests `1 CPU`/`2Gi` and may burst to `4 CPU`/`4Gi`.
- **No authentication:** keep the API LAN-only until auth and multi-user
  authorization are implemented. Do not advertise the public Cloudflare
  hostname yet.
- **Follow-up in the app repo:** fix the chart's default image-tag helper
  (`appVersion` vs `vX.Y.Z` tags) and republish as `0.2.0` when convenient.
  Not a blocker for this deployment.

## References

- Chart and app docs: `~/Source/transcributed/charts/transcributed/README.md`,
  `~/Source/transcributed/wiki/pages/build-deploy.md`.
- Cluster patterns:
  [[CloudNativePG on Talos (PostgreSQL + MinIO backups)]],
  [[Pullini on Talos (CloudNativePG + Flux)]],
  [[Navidrome on Talos (FLAC music server, LAN-only, read-only NAS library)]],
  [[Secrets with SOPS + age (local, out-of-band)]].
