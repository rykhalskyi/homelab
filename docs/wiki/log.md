# DevOps Wiki — Log

## [2026-11-01] change | trim Open WebUI prompt overhead

The first chat sent ~5.5k prompt tokens for a 4-character message. The bulk was
Open WebUI's optional built-ins (code interpreter, memory system context) and
background title/tag/follow-up generations, all of which queue behind the main
request because Ollama runs one slot. The Deployment now sets
`ENABLE_CODE_INTERPRETER`, `ENABLE_MEMORIES`, `ENABLE_MEMORY_SYSTEM_CONTEXT`,
`ENABLE_WEB_SEARCH`, `ENABLE_IMAGE_GENERATION`,
`ENABLE_TITLE_GENERATION`, `ENABLE_TAGS_GENERATION`,
`ENABLE_FOLLOW_UP_GENERATION` and `ENABLE_RETRIEVAL_QUERY_GENERATION` to
`false`. This keeps a simple chat close to the raw message size; the model's
own chat template remains.

## [2026-11-01] fix | Open WebUI routed through LiteLLM

Open WebUI had persisted its first-run Ollama connection in its database, so
`ENABLE_OLLAMA_API=false` and `OPENAI_API_BASE_URL` were ignored: chats still
called `http://ollama.ollama.svc.cluster.local:11434/api/chat`, bypassing
LiteLLM and therefore Langfuse. Added `ENABLE_PERSISTENT_CONFIG=false` so the
Deployment env is authoritative. Verified a chat POST went to
`litellm:4000/v1/chat/completions` and a new `litellm_request` generation for
`llama3.2:3b` appeared in Langfuse. Also recorded the `gemma3:1b does not
support tools` error and why a 5.5k-token prompt takes ~45 s on CPU.
## [2026-11-01] verify | Ollama + LiteLLM + Langfuse end-to-end

After merging #169, verified on the cluster: the Ollama initContainer pulled
all four models onto the 50Gi PVC (`ollama list` shows ~8 GB) in ~11 minutes;
Open WebUI and LiteLLM run with zero restarts; `GET /v1/models` through LiteLLM
lists all four; a `POST /v1/chat/completions` for `llama3.2:3b` returned
`hello from litellm` with 44 tokens; and Langfuse received the trace (two
events, project id `cmvxv…`, `litellm_request`). Langfuse v4 stores ingested
spans in ClickHouse `events_core`/`events_full`, so the legacy `traces` table
can stay empty. Node memory was ~5 GiB of ~12 GiB, Open WebUI 0 restarts.
Marked the page live and verified in the index.

## [2026-11-01] fix | Ollama model store + LiteLLM startup

After the first deploy: (1) the Ollama initContainer pulled the models into its
ephemeral `/root/.ollama` because only the main container set
`OLLAMA_MODELS=/models`, so `ollama list` was empty — both containers now set
it. (2) LiteLLM v1.106.6 refuses to start without a master key, so the
Deployment sets the fixed LAN-only dummy `LITELLM_MASTER_KEY=sk-litellm`
(matching Open WebUI; not a security boundary). (3) Open WebUI and LiteLLM got
startupProbes so slow first boots are not killed by liveness. Updated the wiki
page and index. Also documented the `litellm-langfuse` failure mode where
`stringData` is encrypted as a single string (Kubernetes rejects it) and must
be recreated as a YAML mapping.

## [2026-11-01] change | LiteLLM → Langfuse tracing for Ollama

Added a stateless LiteLLM proxy in namespace `litellm` between Open WebUI/apps
and Ollama. `litellm-config` maps the four Ollama models, and
`success_callback`/`failure_callback: ["langfuse_otel"]` export prompt,
response, tokens and latency to the in-cluster Langfuse at
`http://langfuse-web.langfuse.svc.cluster.local:3000`. The proxy is exposed
in-cluster at `litellm:4000/v1` and LAN-only at `llm.lan.otakeessen.com`.
Open WebUI now disables its direct Ollama connection and chats through LiteLLM,
so UI chats are traced. Langfuse keys are optional env vars read from the
out-of-band `litellm-langfuse` Secret (SOPS, gitignored); the wiki documents the
`apply.sh` flow and the restart. Direct `ollama:11434` calls remain untraced.

## [2026-11-01] ingest | Ollama + Open WebUI on Talos

Added [[Ollama + Open WebUI on Talos (LAN-only, node-three)]]: Ollama pinned to
`node-three` (i5-9500, ~12 GB, no GPU) with a 50Gi `local-path` model store and
an initContainer that pulls `llama3.2:3b`, `qwen2.5-coder:3b`, `gemma3:1b` and
`qwen3.5:4b`. Open WebUI is the LAN chat UI. Both hosts
(`ollama.lan.otakeessen.com`, `chat.lan.otakeessen.com`) use the existing
wildcard certificate and are 404'd at the Cloudflare tunnel. CPU is capped at
4800m (80% of six cores), one model is loaded at a time, and the model
add/update workflow is documented. Also records the planned stateless LiteLLM
proxy that sends Ollama calls to Langfuse. Updated the index under Operations.

## [2026-10-31] update | Adding a node to the Talos cluster

Added a boot/UEFI checklist after the `node-three` rack move: a “Waiting for
DHCP” screen before Talos loads is the BIOS PXE/network boot, not Talos and not
the router. Documents the BIOS checks (UEFI vs Legacy, Secure Boot, AHCI, PXE
order), the bootloader difference (UEFI vs Legacy), verification with
`talosctl get bootedentries` / `get discoveredvolumes`, the
`talos.halt_if_installed` message, and stale etcd member cleanup before
reinstalling a control plane. Added a short version to the talos README and
updated the index description.

## [2026-10-31] ingest | Adding a node to the Talos cluster

Added [[Adding a node to the Talos cluster]], a short end-to-end runbook for
adding a machine: find the NIC/disk in maintenance mode, write the per-node
`patch.yaml`, generate the config with the real `secrets.yaml` (two-step
`gen config` + `machineconfig patch`), validate and apply without `bootstrap`,
then verify etcd/Kubernetes/Cilium. Covers the worker/control-plane differences
and the final-static-IP etcd gotcha, and links to the detailed `node-one`
runbook and the Cilium page. Updated the index under "Cluster access".

## [2026-10-31] change | bake BookTailor into the Nextcloud image

Extended the custom Nextcloud image pipeline to ship both apps: BookTailor v1.7.0
is now pinned next to byebyemoneylist in
`infra/images/nextcloud/versions.env`, downloaded and checksum-verified by
`build-nextcloud-image.yml`, copied to `/opt/booktailor` in the image, and
enabled by the HelmRelease `before-starting` hook. Added
`update-booktailor-pin.yml`, the optional `booktailor` Langfuse Secret wiring
(`BOOKTAILOR_LANGFUSE_*` from the in-cluster Langfuse web service), and a
`booktailor-secret.example.yaml`. On the app side, added the tag-driven
`release.yml`, a `set-version.sh` helper, deterministic packaging with a
`booktailor/` top-level directory, and raised the declared Nextcloud support to
35. Rewrote [[Releasing a new Nextcloud image (BookTailor + byebyemoneylist apps)]]
and updated the index.

## [2026-10-30] change | retire the k3s tree and clean up references

Deleted the retired k3s tree `infra/clusters/k8s/` (40 files) and removed every
live reference to it. Removed the now-dead `build-nginx-image.yml` /
`update-nginx-image-pin.yml` (nothing consumed `homelab-nginx`; the landing page
is served by the phase-1 Compose bind mount). Repointed the Nextcloud pin
workflow to `infra/clusters/talos/apps/nextcloud/helmrelease.yaml` and renamed
the chain `k3s/nextcloud` -> `talos/nextcloud`. Narrowed Renovate to
`infra/clusters/talos`, dropped the `k8s-nc-reset-bruteforce` Make target and
the k8s secrets `.gitignore` entry, and refreshed `AGENTS.md`, `README.md`, and
the nginx image README. Wiki: rewrote [[Deploying site changes (GitOps)]],
updated [[Releasing a new Nextcloud image (byebyemoneylist app)]],
[[Secrets with SOPS + age (local, out-of-band)]], and
[[Nextcloud + Euro-Office on Talos (LAN-only)]]; marked the k3s pages
superseded/historical ([[Backups: what to save and how to restore]],
[[PostgreSQL + pgAdmin on k3s (decoupled from Nextcloud)]],
[[Euro-Office on k3s]], [[Nextcloud on k3s (custom image + Helm chart)]],
[[Nextcloud major upgrade on k3s (31 → 32 → 33)]],
[[k3s config graph: entrypoint, Kustomizations, and leaves]], and
[[k3s + GitOps: nginx and cloudflared (phase 2.1)]]).

## [2026-10-30] change | cert-manager Grafana dashboard in Git

The imported cert-manager dashboard (grafana.com 11001) pointed its `Datasource`
variable at a non-existent `k8s-qa` (regex `/k8s.*/`), so it showed no data even
after the ServiceMonitor label fix. Committed the dashboard as a
`grafana_dashboard: "1"` ConfigMap (`monitoring/cert-manager-dashboard`), with
the datasource regex relaxed to `/.*/` and no pinned variable defaults; the
Grafana sidecar now provisions it on every sync.

## [2026-10-30] change | pgAdmin 9.19.0

Bumped the pinned pgAdmin image from `dpage/pgadmin4:9.18.0` to `9.19.0` on both
clusters (`infra/clusters/{k8s,talos}/apps/pgadmin/deployment.yaml`), digest
`sha256:3591b3d0…0c83`. Replaced the pods to pick up the new image; no manifest
or PVC changes.

## [2026-10-28] fix | Ragatool HuggingFace model download permissions

The first embedding task failed with `Permission denied (os error 13)` writing
`/.cache/huggingface/xet/logs/...`, leaving a partial fastembed snapshot and an
ONNX `NO_SUCHFILE` error. The backend runs as UID 1000 with no home directory;
pin `HOME=/data` and `HF_HOME=/data/huggingface` in `ragatool-backend-config`,
then recreate the Pod and remove the partial
`/data/fastembed/models--qdrant--bge-small-en-v1.5-onnx-q` directory before the
retry. Documented in [[Ragatool on Talos (LAN-only RAG + MCP)]].

## [2026-10-28] ingest | Ragatool on Talos (LAN-only RAG + MCP)

Prepared the `ragatool` stack on `talos`: FastAPI backend (ports 8000/8001/8002
for REST + MCP SSE + MCP HTTP) and the Angular UI in namespace `ragatool`, with
all state on one 10Gi `local-path` PVC (`/data`: SQLite, Chroma, fastembed
cache). The UI is LAN-only at `ragatool.homelab.home.arpa`; MCP uses
`ragatool-mcp{,-http}.homelab.home.arpa` through the Traefik VIP. Also changed
the app's frontend so the API address is runtime config: `config.js` is written
from `API_URL` at container start, and nginx proxies `/api/` to a deploy-time
`BACKEND_URL` (default same-origin), replacing the build-time `sed` of
`environment.ts`. Added `update-ragatool-image-pin.yml` (pins both images by
digest after the app repo's Create Package workflow dispatches
`ragatool-images`). No Secret is required.

## [2026-10-25] fix | Langfuse DB after Talos upgrade (CNPG SA collision)

After upgrading both Talos nodes to `v1.14.4`, the hibernated CNPG clusters
were rehydrated and all recovered except `langfuse-1`, which crash-looped with
`open /var/run/secrets/kubernetes.io/serviceaccount/token: no such file or
directory`. The Langfuse chart creates the app ServiceAccount `langfuse` with
`automountServiceAccountToken: false`, but CloudNativePG's `Cluster langfuse`
uses the same name for its instance ServiceAccount and needs an API token. The
chart's web/worker pods already opt out at pod level, so the fix is a
`postRenderers` patch on the HelmRelease that forces the ServiceAccount to
automount. Documented the gotcha in [[Langfuse on Talos (LLM observability)]].

## [2026-10-23] ingest | Langfuse on Talos (LLM observability)

Documented the prepared Langfuse v4 deployment on `talos`: LAN-only at
`http://langfuse.homelab.home.arpa`, Helm chart `2.1.6` (app `4.63.0`), a
dedicated CloudNativePG `Cluster langfuse`, a pinned single-node ClickHouse
StatefulSet instead of the chart's operator/cert-manager path, bundled Valkey,
and MinIO for blobs. Recorded the two non-obvious pieces: the ClickHouse
`users.d` initContainer (env-created users live in read-only `users.xml`, so a
SQL `GRANT` fails) and the `wait-for-deps` initContainer for first-boot
migrations. Also documented the SOPS `langfuse-secrets`/`cnpg-minio` shape, the
MinIO `langfuse`/`clickhouse-backups` layout, verify commands, and the non-HA
local-path caveats. The page is marked prepared/pending review; it becomes live
after the PR merges and Flux reconciles.

## [2026-10-21] change | Transcributed web UI on the LAN VIP

Moved the chart to `0.2.5` and made the new web UI the LAN entry at
`http://transcributed.homelab.home.arpa`: Traefik (VIP `192.168.2.240`) ->
`transcributed-ui:80` -> nginx proxy -> `transcributed-api:8000`. The API
Ingress is disabled so the same host/path is not served by two routers; the UI
proxies `/api/`, `/healthz` and `/readyz` for a single origin. Pinned all three
images (UI/API/worker) to the `sha-2f6b6f5...` v0.2.5 digests, taught the image
pin workflow about the UI, and dropped the obsolete `ScaledJob.cooldownPeriod`
postRenderer. Documented the suspend-before-merge upgrade sequence and the
Swagger/OpenAPI port-forward (the UI does not proxy those paths).

## [2026-10-21] fix | Transcributed docs: failure path and upgrade drain

Corrected the architecture page: failed tasks are still dead-lettered to
`transcription.dead` through `transcription.dlx` (only the retry queues and
`max_attempts` are gone), and the 0.2.1 -> 0.2.5 upgrade now drains worker Jobs
and scales the API to zero before the pre-upgrade migration drops
`tasks.attempts`/`tasks.max_attempts`. Also marked the plan page's image-tag
guidance as plan-time, clarified the pin workflow's hard requirement for the
UI image, and normalized the proxied path to `/api/`.

## [2026-10-20] ingest | Transcributed on Talos (architecture) + running a transcription

Documented the live Transcributed deployment on `talos` in two pages:
[[Transcributed on Talos (architecture)]] and
[[Running a transcription (Transcributed)]]. The architecture page maps the
Flux-managed pieces (published OCI chart `0.1.0`, KEDA `2.21.0`, RabbitMQ,
CNPG, the API Deployment, KEDA worker Jobs, the read-only NAS PV/PVC, and
MinIO/CNPG backups) with request-flow and namespace/pod Mermaid diagrams. It
also records the deployment-side fixes: pin both images to `v0.1.0`, drop the
unsupported `ScaledJob.cooldownPeriod` with a HelmRelease `postRenderers`
patch, and use client-default NFS mount options because the Synology rejects
`nfsvers=4.1`. The usage page is a copy-paste API runbook (create project, add
NAS-relative items, start, poll, download `txt`/`vtt`/`json`, cancel, clean up)
and documents the `small`-only worker model, retries, and KEDA concurrency.
Also marked the original deployment plan as implemented; its historical
findings and preconditions remain below as plan-time context.

## [2026-10-18] ingest | Transcributed on Talos (deployment plan)

Saved a deployment plan (no cluster changes) for running
[Transcributed](https://github.com/rykhalskyi/transcributed) on `talos`:
[[Transcributed on Talos (deployment plan)]]. Records the current state (chart
`0.1.0` is the only published release; images are tagged `v0.1.0` while the
chart defaults to `0.1.0`; KEDA and RabbitMQ are absent; the NAS does not yet
export `/volume1/video/lectures`) and the chosen shape: KEDA in the
infrastructure layer, a single-node RabbitMQ StatefulSet, a dedicated CNPG
`Cluster transcributed` with MinIO backups, the chart installed by Flux from
the OCI source, LAN-only ingress at `transcributed.homelab.home.arpa`,
read-only NFS input, and up to two KEDA workers with preferred anti-affinity.
The plan is split into two PRs so the database and broker are Ready before the
chart's migration hook runs.

## [2026-10-16] change | Navidrome LAN-only + node-independent ingress VIP

Made Navidrome LAN-only and gave the LAN ingress a floating VIP:

- Navidrome: replaced the public `music.otakeessen.com` Ingress (and its
  `X-Forwarded-Proto` Middleware, now removed) with a **LAN-only**
  `music.homelab.local` Ingress. Hosts entry is now
  `192.168.2.240 music.homelab.local`. It is no longer reachable from the
  internet.
- VIP: Traefik is now a `LoadBalancer` Service on the node-independent VIP
  `192.168.2.240`, assigned by a Flux-managed `CiliumLoadBalancerIPPool` and
  ARP-announced by a `CiliumL2AnnouncementPolicy` (new
  `infrastructure/cilium/`). Removed the `nodeSelector`/`hostPort` pinning and
  the `privileged` PodSecurity label from the Traefik namespace.
  `cilium/values.yaml` enables `l2announcements` (+ raised `k8sClientRateLimit`);
  because Cilium is out of band, re-run `cilium/install.sh` to apply it.
- Repointed every `*.homelab.local` hosts entry/verify snippet at
  `192.168.2.240`: Navidrome, Forgejo, Nextcloud/Euro-Office, pgAdmin, Grafana.

Updated [[Navidrome on Talos (FLAC music server, LAN-only, read-only NAS library)]],
[[Cilium on Talos (Helm, kube-proxy-free)]], the talos `README.md`, and the
hosts entries in the Forgejo / pgAdmin / Nextcloud-Euro-Office / Observability
pages.

## [2026-10-15] ingest | Navidrome on Talos (FLAC music server)

Added Navidrome to the `talos` cluster: new
`infra/clusters/talos/apps/navidrome/` (namespace, 2Gi `local-path` PVC for
`/data`, digest-pinned `navidrome/navidrome:0.64.2` Deployment that mounts the
Synology FLAC library **read-only** over NFS
(`192.168.2.112:/volume1/media/Music` -> `/music`) with a `local-path` PVC at
`/data`, Service `navidrome:80`, a `X-Forwarded-Proto: https` middleware, and a
public Ingress at `music.otakeessen.com`). Wired into `apps/kustomization.yaml`.
No new Secret; the `*.otakeessen.com` wildcard tunnel already routes the host.
Wrote [[Navidrome on Talos (FLAC music server, LAN-only, read-only NAS library)]].

## [2026-10-14] change | Forgejo: public host git.otakeessen.com

Exposed Forgejo publicly at `https://git.otakeessen.com` (the `*.otakeessen.com`
Cloudflare tunnel already reaches Traefik): added a public Ingress + a
`X-Forwarded-Proto: https` middleware, set the Deployment's
`FORGEJO__server__DOMAIN`/`ROOT_URL` to the public host, and listed
`git.otakeessen.com` explicitly in the cloudflared config. The LAN
`git.homelab.local` Ingress stays. **Cloudflare Access must be configured for the
host** or the forge is internet-reachable. Updated
[[Forgejo on Talos (self-hosted git forge)]] (title drops "LAN-only").

## [2026-10-14] change | MinIO cnpg policy: allow forgejo/* (backups)

Added `arn:aws:s3:::cnpg-backups/forgejo/*` to the MinIO `cnpg-rw` policy's
object `Resource` list on the NAS so the new Forgejo CNPG `Cluster` can archive
WAL + base backups (`s3://cnpg-backups/forgejo`). Updated the policy snippet in
[[CloudNativePG on Talos (PostgreSQL + MinIO backups)]]. Motivated by the forgejo
cluster reporting `ContinuousArchiving=False` until the prefix was allowed.

## [2026-10-14] ingest | Forgejo on Talos (LAN-only)

Added the Forgejo app to the `talos` cluster on branch `talos/forgejo`: new
`infra/clusters/talos/apps/forgejo/` (namespace, 20Gi `local-path` PVC, CNPG
`Cluster forgejo` + daily `ScheduledBackup`, digest-pinned
`codeberg.org/forgejo/forgejo:16` Deployment configured via `FORGEJO__*` env,
Service, LAN Ingress at `git.homelab.local`, daily `forgejo-restic` restic
CronJob to `s3://restic-backups/forgejo`, and `create-admin.sh`). Wired into
`apps/kustomization.yaml`. Four out-of-band SOPS Secrets
(`forgejo-db`, `forgejo-minio`, `forgejo-backup`, `forgejo-admin`) — local only.
Wrote [[Forgejo on Talos (self-hosted git forge)]]. **Not yet merged /
deployed.** Requires the MinIO `cnpg` policy to be widened with `forgejo/*`.

## [2026-10-14] change | restic backups: Phase 0 + Phase 1 implemented

Created the MinIO target out of band on the NAS: bucket `restic-backups`, user
`restic` with policy `restic-rw` (ListBucket/GetBucketLocation on the bucket +
object RW/Delete under `restic-backups/*`), and a service account. Verified with
`mc ls`/`mc admin user/policy entities`.

Implemented Phase 1 of [[File-volume backups on Talos (restic → MinIO) — plan]]
on branch `talos/restic-file-backups`:

- `infra/clusters/talos/apps/nextcloud/restic-backup.yaml` — CronJob
  `nextcloud-restic` (daily 02:00, reads `nextcloud-data` read-only, restic
  `0.19.1` pinned by digest, repo `s3://restic-backups/nextcloud`, retention
  7d/4w/6m).
- `apps/nextcloud/kustomization.yaml` — reference it.
- `apps/secrets/nextcloud-backup.sops.yaml` (local-only, gitignored) — the
  `nextcloud-backup` Secret (`RESTIC_PASSWORD`, `ACCESS_KEY_ID`,
  `ACCESS_SECRET_KEY`), added to the local `secrets/kustomization.yaml`.

Validated with `kubectl kustomize` (apps + root build OK). **Not deployed** —
pending merge → Flux reconcile — and **not yet restore-tested**.

## [2026-10-13] ingest | File-volume backups on Talos (restic → MinIO) — plan

Added [[File-volume backups on Talos (restic → MinIO) — plan]] on branch
`talos/restic-file-backups`: the agreed design for backing up app **data
volumes** (which CloudNativePG does not cover), so the TODO in
[[Backups: what to save and how to restore]] can be closed later. Decision:
per-app **restic** CronJobs to a dedicated `restic-backups` MinIO bucket + a
least-privilege `restic` user, one CronJob per data PVC (read-only mount),
daily ~02:00 with 7d/4w/6m retention, credentials in a per-namespace SOPS
`<app>-backup` Secret. First cut = Nextcloud `nextcloud-data`; **Forgejo
deferred** (not deployed to Talos yet) and **off-site copy deferred**. The page
records the MinIO prep, files to add, verification, a restore sketch, and risks.
**No manifests implemented yet** — this is a plan only.

## [2026-10-11] change | MinIO cnpg policy: allow pullini/* (backups)

Widened the MinIO `cnpg-rw` policy's object `Resource` list with
`arn:aws:s3:::cnpg-backups/pullini/*` on the NAS so the talos `pullini` CNPG
Cluster can archive WAL + base backups (`s3://cnpg-backups/pullini`). Verified:
`ContinuousArchiving=True` and objects present under
`pullini/pullini/wals/…`. Updated the policy snippet in
[[CloudNativePG on Talos (PostgreSQL + MinIO backups)]].

## [2026-10-11] change | kustomize prune guard scoped to talos only

Narrowed `.github/workflows/kustomize-prune-guard.yml` to guard
`infra/clusters/talos` only: dropped the `infra/clusters/k8s*` entries from the
trigger `paths` and from both build/reject path arrays, and added
`infra/clusters/talos/apps` so every talos app is covered. The k3s cluster is
being decommissioned, so removing its resources (e.g. the `homelab/pullini-data`
PVC as part of the Pullini move) must not fail the guard. Updated [[Backups:
what to save and how to restore]] to note the talos-only scope.

## [2026-10-11] change + ingest | Pullini moved from k3s to Talos (CloudNativePG)

Moved **Pullini** off the k3s (`node-one`) cluster onto `talos`. New manifests
under `infra/clusters/talos/apps/pullini/` (namespace `pullini`): web +
scheduler `Deployment` (pinned image, `wait-for-db` initContainer on
`pullini-rw`), `ConfigMap`, `Service`, `Ingress` (`wiki.otakeessen.com`),
`forwarded-proto` `Middleware`, a 2Gi `local-path` PVC, a dedicated CloudNativePG
`Cluster pullini` (`bootstrap.initdb` db/owner `pullini`, credentials from the
SOPS `pullini-secrets`), and a daily `ScheduledBackup pullini-daily` to
`s3://cnpg-backups/pullini` on MinIO. Added `- pullini` to
`infra/clusters/talos/apps/kustomization.yaml`. Two new local SOPS Secrets
(`pullini-secrets.sops.yaml`, `pullini-minio.sops.yaml` — the latter the
namespaced `cnpg-minio` copy) and the MinIO `cnpg` policy must be widened to
`pullini/*`. Repointed `.github/workflows/update-pullini-image-pin.yml` to the
talos path and renamed it `talos/pullini`. Removed
`infra/clusters/k8s/apps/pullini/` + its kustomization entry and the k8s README
rows. Added [[Pullini on Talos (CloudNativePG + Flux)]] and marked
[[Pullini on k3s (postgresql + Flux)]] superseded (fresh install; no DB data
migrated).

## [2026-10-10] change | Nextcloud CNPG backups (MinIO)

Enabled backups for the `nextcloud` CloudNativePG `Cluster`: added the
`barmanObjectStore` stanza (destination `s3://cnpg-backups/nextcloud`, same LAN
MinIO) and `ScheduledBackup nextcloud-daily` (03:00, 30d retention) under
`infra/clusters/talos/apps/nextcloud/`. A CNPG backup is physical (base + WAL of
the whole instance), so it covers every Nextcloud table — there is no per-table
option. Two namespacing details: Secrets are per-namespace, so a second
`cnpg-minio` Secret is needed in `nextcloud`
(`apps/secrets/nextcloud-minio.sops.yaml`), and the MinIO `cnpg` policy must be
widened to `s3://cnpg-backups/nextcloud/*`. Updated
[[Nextcloud + Euro-Office on Talos (LAN-only)]] (secrets table, pieces, gotcha)
and [[CloudNativePG on Talos (PostgreSQL + MinIO backups)]] (policy, credentials
note).

## [2026-10-10] change + ingest | node-one added to the Talos cluster (control-plane IP gotcha)

Repurposed the old Ubuntu/k3s host as a second Talos **control-plane + workload**
node: `node-one` (`192.168.2.233`, NIC `enp1s0`, disk `/dev/sda`), using
`nodes/node-one/patch.yaml` (static `.233/24`, CP taint removed, flannel deleted,
kube-proxy off) and the two-step `talosctl gen config` + `machineconfig patch`.
No `bootstrap` (node-two already bootstrapped etcd). Initial mistake: the config
was applied **un-patched**, so the node booted on DHCP `.117` with flannel +
kube-proxy and joined etcd at `.117`; moving it to `.233` left the etcd membership
peer URL pointing at the dead `.117`, so the 2-member cluster lost quorum and the
whole API went down (`etcdserver: no leader`, kube-apiserver `connection refused`,
`rafthttp ... dial tcp 192.168.2.117:2380`). Recovered **without wiping node-two**
(and its `local-path` PVCs): backed up node-two's etcd DB via `talosctl cp`, then
aligned `node-one`'s address with the membership's current value (`.233`) to
restore quorum, deleted the bad-boot flannel/kube-proxy DaemonSets + RBAC/ConfigMap
leftovers, and rebooted `node-one` to clear `flannel.1`. Both nodes now `Ready`;
only `cilium`/`cilium-envoy` run. Also updated `README.md` (node is up + the IP
gotcha), added `.233` to the `talosconfig`/`~/.talos/config` endpoints for
failover, and documented everything in the new instruction page
[[Adding node-one to the Talos cluster (control-plane IP gotcha)]]. Recorded that a
2-member etcd has no HA: powering off either node takes the API down until
`node-three` joins.

## [2026-10-10] change | Nextcloud + Euro-Office on Talos: public via Cloudflare (k8s retired)

The k8s cluster went down (`cloud.otakeessen.com` returned Cloudflare **530**),
so [[Nextcloud + Euro-Office on Talos (LAN-only)]] took over the canonical
hostnames: a `cloudflared` Deployment now runs in the talos `cloudflared`
namespace, reusing the existing tunnel (same `TUNNEL_ID`/`credentials.json`,
copied into local SOPS Secrets), with ingress routing `cloud.`/`office.` and the
`*.otakeessen.com` wildcard to the talos Traefik. Added the
`eurooffice-forwarded-proto` middleware (mixed-content fix) on
`office.otakeessen.com`, kept LAN Ingresses, and set `overwrite.cli.url` /
`DocumentServerUrl` to the public https URLs. Gotcha recorded: the Nextcloud
chart does not update `trusted_domains` on upgrade, so changing `nextcloud.host`
made the readiness probe (Host = the new host) get HTTP 400 and the Helm upgrade
time out — fixed with `occ config:system:set trusted_domains`. Verified
`https://cloud.otakeessen.com/status.php` and
`https://office.otakeessen.com/healthcheck` both `200`.
## [2026-10-10] change | Nextcloud + Euro-Office on Talos: applied and working

Took [[Nextcloud + Euro-Office on Talos (LAN-only)]] live on `node-two` and
resolved three rollout issues: (1) the five out-of-band Secrets were unapplied,
so pods hit `CreateContainerConfigError` — fixed with
`infra/clusters/talos/apps/secrets/apply.sh`; (2) the Synology
`/volume1/nextcloud` NFS export only allowed node-one (`192.168.2.233`), so
node-two failed `mount.nfs: access denied` — the NAS ACL now includes
`192.168.2.234`; (3) the first Helm install timed out mid-mount and, with no
remediation, went `Stalled/RetriesExceeded` (`cannot remediate failed release`)
— added `install/upgrade.remediation.retries: 3` (PR #87). Wired the post-install
DB-stored config: `eurooffice` app 11.0.6 (`DocumentServerUrl`,
`DocumentServerInternalUrl`, `StorageUrl`, JWT, `sameTab`), `overwrite.cli.url`,
extra trusted domains, and the NAS as a Local external storage (`files_external`,
`datadir=/nas`). Working versions: Nextcloud 35.0.1 / byebyemoneylist 1.1.0 /
eurooffice 11.0.6 / DocumentServer 9.3.4.37.

## [2026-10-10] ingest | Nextcloud + Euro-Office on Talos (LAN-only)

Added [[Nextcloud + Euro-Office on Talos (LAN-only)]]: a clean-install Nextcloud
plus the Euro-Office DocumentServer on the `talos` cluster, in a new `nextcloud`
namespace, reconciled by Flux (`infrastructure` gains the `nextcloud`
`HelmRepository`; `apps` gains the `nextcloud` and `eurooffice` bundles). Mirrors
the k8s stack but swaps the parts Talos does differently: a dedicated
CloudNativePG `Cluster nextcloud` (PG 18.4, `local-path`) whose owner/password
come from the shared out-of-band `nextcloud-db` Secret via
`bootstrap.initdb.secret`, dynamic `local-path` PVCs instead of a static PV, the
same NAS-over-NFS share mounted at `/nas` (inline pod volume, supported on
Talos), no DB `dependsOn` (the CR is not a HelmRelease, so the
Pod retries behind the startup probe), `TRUSTED_PROXIES: 10.244.0.0/16`
(Cilium/Talos pod CIDR), and a LAN-only host pair
`cloud-talos.`/`office-talos.homelab.local` on node-two `:80`. Documents the five
SOPS Secrets (four generated, `byebyemoneylist` reused from the k8s bundle), the
`occ` connector wiring, verify commands, the phase-B Cloudflare path, and
gotchas. Also extended `.github/workflows/update-nextcloud-image-pin.yml` to pin
the image digest in **both** clusters' HelmReleases.

## [2026-10-10] ingest | pgAdmin for the talos cluster (LAN-only)

Added [[pgAdmin for the talos cluster (LAN-only)]]: a `dpage/pgadmin4`
(digest-pinned) Deployment + 2Gi `local-path` PVC + Service + a Traefik Ingress
serving `pgadmin-db.homelab.local` on node-two (`192.168.2.234`), so it is
reachable only from the LAN (the Cloudflare tunnel routes only
`*.otakeessen.com`). Reconciled by Flux in the `apps` layer alongside the CNPG
`postgres` Cluster; the login is the same out-of-band SOPS `pgadmin-auth` Secret
as the k8s cluster (`databases` namespace). Documents registering the server
(`postgres-rw:5432`, user `app`), verify commands, and the distinct hostname
that avoids colliding with the k8s `pgadmin.homelab.local`.
## [2026-10-10] fix | CNPG backups: MinIO policy must not prefix-scope ListBucket

First backup of the talos `postgres` Cluster hung in `running` and WAL archiving
failed with `403 ... HeadBucket operation: Forbidden`. Cause: the MinIO policy
granted `s3:ListBucket` only under an `s3:prefix` condition, but barman-cloud's
`HeadBucket` preflight has no prefix, so it was denied. Corrected
[[CloudNativePG on Talos (PostgreSQL + MinIO backups)]]: grant
`s3:ListBucket`/`s3:GetBucketLocation` on the whole bucket, keep only the object
actions scoped to `talos/*`.

## [2026-10-10] fix | CloudNativePG CRD-ordering (split into the apps layer)

The initial [[CloudNativePG on Talos (PostgreSQL + MinIO backups)]] change put
the operator and the `Cluster`/`ScheduledBackup` CRs in the same
`infrastructure` Flux Kustomization. Because kustomize-controller dry-runs the
whole set, a `ScheduledBackup` whose CRD did not exist yet failed with
`no matches for kind "ScheduledBackup" in version "postgresql.cnpg.io/v1"` —
aborting the entire apply and preventing the operator from ever installing (a
chicken-and-egg). Fixed by moving the CRs into a new `apps` Flux Kustomization
(`infra/clusters/talos/apps/`, `wait: true`, `dependsOn: infrastructure`) and
enabling `apps.yaml` in the talos root, leaving only the operator + CRDs in
`infrastructure`. Page updated with the two-layer explanation and gotcha.

## [2026-10-10] ingest | CloudNativePG on Talos (PostgreSQL + MinIO backups)

Added [[CloudNativePG on Talos (PostgreSQL + MinIO backups)]]: runs PostgreSQL
on the `talos` cluster with the CloudNativePG operator (Flux `infrastructure`
layer) and backs it up to the LAN MinIO bucket. The operator (`cloudnative-pg`
chart 0.29.1 → operator 1.30.1) lives in `cnpg-system` and the single-instance
`postgres` `Cluster` (PostgreSQL 18.4, digest-pinned `system` operand,
`local-path` PVC) in `databases`; WAL archiving + a daily `ScheduledBackup` go to
`s3://cnpg-backups/talos` on `192.168.2.112:9000` via the in-tree
`barmanObjectStore` (deprecated since CNPG 1.26). Documents the out-of-band MinIO
bootstrap — including that MinIO removed its Docker Hub images so `mc` must come
from the GitHub release, and that `s3:prefix` is only valid on `s3:ListBucket` —
the prefix-scoped user/policy + service account, the local SOPS `cnpg-minio`
Secret, verify commands, a restore sketch, and gotchas (single-node = no HA,
node-local PVCs, CRD-ordering retry).

## [2026-10-09] change | Observability rollout fixes (PSA, Prometheus subPath, Telegram chat_id)

Rolled [[Observability on Talos (Prometheus + Grafana + Alertmanager)]] out to
the live `talos` cluster and fixed three issues the manifests didn't anticipate:
(1) the cluster defaults namespaces to `baseline` PSA, which forbids `hostPort`
and host namespaces — so the `traefik` (hostPort 80/443) and `monitoring`
(node-exporter) namespaces needed `pod-security.kubernetes.io/enforce:
privileged`; (2) the Prometheus Operator mounts its data volume with
`subPath: prometheus-db` and the kubelet creates that subdir root-owned (fsGroup
is not applied to subPath), so Prometheus crashlooped on
`/prometheus/queries.active: permission denied` — fixed with an `init-chown-data`
initContainer; (3) Alertmanager rejects `chat_id: 0` as missing, so the
out-of-band Secret needs a real non-zero chat id. All pods now Running; docs and
gotchas updated.

## [2026-10-09] ingest | Observability on Talos (Prometheus + Grafana + Alertmanager)

Added [[Observability on Talos (Prometheus + Grafana + Alertmanager)]]: brings
the `talos` cluster a Flux-managed (`infrastructure` layer) metrics/alerting
stack — `kube-prometheus-stack` in namespace `monitoring` — plus the two
prerequisites Talos lacks, `local-path-provisioner` (no storage provisioner;
host path moved to `/var` because the rootfs is read-only) and Traefik bound to
**host ports** (no LoadBalancer on kube-proxy-free Cilium; LB-IPAM/L2 not
enabled). Grafana is **LAN-only** at `grafana.homelab.local` (mirrors the pgAdmin
pattern), Prometheus/Alertmanager stay ClusterIP, and Cilium/Hubble flow metrics
are scraped via labelled ServiceMonitors. Documents the out-of-band SOPS secrets
(`grafana-admin`, `alertmanager-config` with a Telegram receiver), generalizing
`apps/secrets/apply.sh` to read each manifest's namespace, the
ServiceMonitor-CRD ordering handled in `cilium/install.sh`, verify commands, and
the Talos gotchas (`/var` host paths, Retain reclaim, no LB).

## [2026-10-08] ingest | Cilium on Talos (Helm, kube-proxy-free)

Added [[Cilium on Talos (Helm, kube-proxy-free)]] after rebuilding `node-two`
with Cilium instead of flannel: the three layers (machine config vs Helm release
vs Flux), why Cilium is Helm-managed rather than an inline manifest or
Flux-managed (stable CA/certs across upgrades), the `cilium/values.yaml` +
`install.sh` files, the machine patch (delete `KubeFlannelCNIConfig`, disable
`KubeProxyConfig`, static network on `eno1`, remove the single-node CP taint)
and the two-step `gen config` + `machineconfig patch` generation (the taint
`$patch: delete` fails under `--config-patch`), how to add worker/control-plane
nodes (cluster-wide Cilium + per-node network; note that Cilium lands on new
nodes automatically), upgrading/rolling back Cilium via Helm, and the
`cilium` / `cilium-dbg` / `hubble` command set with fallbacks. Also records the
stale-`secrets.yaml` CA-mismatch lockout and its no-reset recovery (mint a
client cert from the embedded CA key), the single-node operator replica and CP
taint issues, and the `forwardKubeDNSToHost` vs `bpf.masquerade` caveat.

## [2026-10-08] ingest | Secrets with SOPS + age

Added [[Secrets with SOPS + age (local, out-of-band)]]: documents that secrets
are SOPS/age-encrypted, stored locally (gitignored, never committed), and
applied out of band for both clusters (`k8s`, `talos`) with one shared age key.
Covers the file/key layout, creating/editing/encrypting a Secret, `apply.sh`
(`CTX`/`NS`), copying files between clusters, key rotation, verification, and
gotchas. Notes Flux does no in-cluster decryption today.

## [2026-10-08] ingest | Talos CLI + kubectl context switching

Added two pages under a new *Cluster access* index section:
[[Talos CLI: common commands (dashboard, status, shutdown)]] (context/config,
`talosctl dashboard`, health/status/logs, reboot/shutdown, etcd/bootstrap,
machine config; notes the gRPC API on port 50000) and
[[kubectl contexts: switching between clusters]] (one kubeconfig for the `k8s`
and `talos` clusters: switch/rename/merge contexts, `--context`, per-context
namespace, k9s `:ctx`). Follows bootstrapping `node-two` as the `talos` cluster
(`192.168.2.234`) and merging its kubeconfig into `~/.kube/config`.

## [2026-10-08] ingest | infra/ restructure (clusters, phase1, images, pi3)

Reorganized `infra/` and updated every wiki page that referenced the old paths:
the k8s cluster moved from `infra/k8s/` to `infra/clusters/k8s/` (self-contained:
Flux entrypoint + `apps/` + `infrastructure/`), phase-1 Compose stacks moved to
`infra/phase1/`, the k8s image build sources split out to
`infra/images/{nginx,nextcloud}/`, and `infra/clusters/talos/` + `infra/pi3/`
added as placeholders. The cluster was cut over in two steps: an additive commit
added the new tree and flipped the root `flux-system` Kustomization `path` in
`gotk-sync.yaml`, then the old `infra/k8s/` tree was removed. `node-one` is a
node of the `k8s` cluster, not the cluster id; node-name references were left
untouched. CI workflows (including the kustomize prune guard), the `Makefile`,
`.sops.yaml`, `.gitignore`, and the repo READMEs were updated to match.

## [2026-10-03] ingest | k3s config graph (entrypoint, Kustomizations, leaves)

Added [[k3s config graph: entrypoint, Kustomizations, and leaves]], a reference
map of the `infra/k8s/` manifests with four Mermaid diagrams: the Flux reconcile
chain from the `flux-system` Kustomization (`gotk-sync.yaml`) through
`clusters/node-one/kustomization.yaml` to the `infrastructure`/`apps`
Kustomizations; the infrastructure root (chart sources, StorageClass, Traefik);
the apps root with every workload→Secret/StorageClass/Ingress edge; and the
runtime Cloudflare→Traefik→Service flow. Includes an edge table and flags two
gotchas already known from prior pages: `flux-system` must stay in the root
`resources:` list (2026-10-02 self-prune), and `apps/secrets/` is gitignored and
applied out of band via `apps/secrets/apply.sh`, so the Secrets are leaves, not
reconciled.

## [2026-10-02] change | Prune guard + backup runbook after Flux self-prune incident

A bad GitOps change (the explicit `infra/k8s/clusters/node-one/kustomization.yaml`
omitted `flux-system`) made Flux prune its own root Kustomization, which then
garbage-collected the `homelab` namespace and destroyed the Nextcloud database.
The files survived (static `Retain` PV) but accounts/shares/calendars/config did
not. Prevention added: `.github/workflows/kustomize-prune-guard.yml` fails a PR
that removes a `Namespace`/`CustomResourceDefinition`/`PersistentVolumeClaim` or
anything in `flux-system` from the kustomize build. Added
[[Backups: what to save and how to restore]] (backup layers + restore sketch;
automation still TODO).

## [2026-10-02] change | Harden cloudflared, pin chart/image versions

Pinned the Traefik `HelmRelease` to `41.6.1` (was the floating `>=30.0.0`
range) and the `cloudflared` `Deployment` to
`cloudflare/cloudflared:2026.9.3@sha256:072c067d25ccbe61d46e18f0d0723255f2bb5304f7317caa95b27031520ff92c`
(was `:latest`, distroless so no exec probes). Added resource requests/limits,
`/ready` readiness + liveness probes backed by a metrics server
(`--metrics 0.0.0.0:2000`), and Cloudflare's upstream `securityContext`
(non-root uid `65532`, read-only rootfs, drop ALL capabilities). Verified by
running the hardened pod next to the live tunnel — all four edge connections
registered and the probe went Ready. Also added `dependsOn: postgresql` to the
Nextcloud `HelmRelease`, an explicit `clusters/node-one/kustomization.yaml`, and
`infra/k8s/README.md` (required out-of-band Secrets index). Updated
[[k3s + GitOps: nginx and cloudflared (phase 2.1)]] so its copied manifests match.

## [2026-10-01] change | Hide the Euro-Office welcome page

`https://office.otakeessen.com/` 302s to a public `/welcome/` landing page.
Added a Traefik `Middleware` (`eurooffice-hide-welcome`) that redirects that
path to Nextcloud, and listed it alongside `eurooffice-forwarded-proto` on the
Ingress. The editor endpoints (`/web-apps`, `/coauthoring`, `/healthcheck`) are
untouched, so embedding keeps working (`eurooffice:documentserver --check`
passes). Updated [[Euro-Office on k3s]].

## [2026-10-01] change | Wiki un-hosted from nginx; served by Pullini

Removed the HTML wiki generation: deleted `tools/build_wiki.py`, the generated
`infra/nginx/html/wiki/`, the `make wiki` target, and the CI "wiki up to date"
check. The landing page lost its "From the wiki" tiles and now links to
`https://wiki.otakeessen.com` (Pullini), and its service list is now just the
public apps: Homelab site, Wiki, Nextcloud.
`docs/wiki/` stays Markdown only — edit and commit, no build. Updated
`AGENTS.md`, `docs/wiki/AGENTS.md`, the nginx README, and
[[Deploying site changes (GitOps)]].

## [2026-10-01] ingest | Pullini on k3s

Added [[Pullini on k3s (postgresql + Flux)]]. Moved the `pullini` app onto
`node-one`'s k3s cluster: image built **on demand** by the `rykhalskyi/pullini`
repo's `Build image` workflow (`ghcr.io/rykhalskyi/pullini:sha-<sha>`, commit
stamped in as `PULLINI_GIT_SHA`), pinned by the new
`.github/workflows/update-pullini-image-pin.yml`, deployed as a web + scheduler
sidecar `Deployment` in namespace `homelab`, exposed at `wiki.otakeessen.com`
via Traefik with an `X-Forwarded-Proto` middleware. It uses a dedicated `pullini`
role/database on the standalone PostgreSQL, provisioned idempotently by
`infra/k8s/apps/pullini/provision-db.sh` from the out-of-band `pullini-secrets`
Secret (which also carries the admin login). The single admin user is seeded on
first boot (Option A entrypoint bootstrap) instead of an interactive
`createsuperuser`. Documents the build/pin chain, secret layout, verify/rollback,
and node-migration (pg_dump/restore) notes.

## [2026-09-29] ingest | Nextcloud 33 + Euro-Office

Upgraded the k3s Nextcloud one major at a time, **31.0.14 → 32.0.15 → 33.0.9**,
using the image entrypoint's built-in rsync + `occ upgrade` (each bump via a
`NEXTCLOUD_VERSION` PR and image-pin PR). `byebyemoneylist` stayed enabled and
the users survived. Then added [[Euro-Office on k3s]]: the document server
(`ghcr.io/euro-office/documentserver`, digest-pinned, JWT from `eurooffice-jwt`)
behind `office.otakeessen.com`, plus the `eurooffice` Nextcloud app configured
with `occ` and verified with `eurooffice:documentserver --check` (DS 9.3.4.37).
Also documented [[Nextcloud major upgrade on k3s (31 → 32 → 33)]]. Fixed
`overwrite.cli.url` (`https://localhost` → `https://cloud.otakeessen.com`),
which was breaking the connector's connection check.

## [2026-09-29] edit | Migrated Nextcloud onto the standalone PostgreSQL

Executed the [[PostgreSQL + pgAdmin on k3s (decoupled from Nextcloud)]] runbook.
Dumped the chart subchart DB (`nextcloud-postgresql-0`) with `pg_dump -Fc` and
restored it into the standalone `postgresql-0` (137 tables, 3 users, 163
`oc_appconfig` rows — verified equal). Repointed Nextcloud with
`occ config:system:set dbhost --value=postgresql`, restarted the pod, and turned
maintenance mode off. Updated `infra/k8s/apps/nextcloud/helmrelease.yaml` to
disable the `postgresql` subchart and point `externalDatabase` at the standalone
service (`host: postgresql`, `type: postgresql`). Old PVC and the dump are kept
for rollback. Also fixed the Bitnami chart source (OCI → `OCIRepository`).

## [2026-09-29] ingest | PostgreSQL + pgAdmin on k3s (decoupled from Nextcloud)

Added [[PostgreSQL + pgAdmin on k3s (decoupled from Nextcloud)]], the first step
of the Nextcloud 31→33 follow-up: move Nextcloud's database off the Nextcloud
Helm chart's bundled `postgresql` subchart into a pinned standalone Bitnami
`HelmRelease` (`postgresql` chart 16.7.27 / Postgres 17.6.0, images under
`bitnamilegacy`, `global.security.allowInsecureImages`), reusing the existing
`nextcloud-db` Secret so only `dbhost` changes. Adds a LAN-only pgAdmin
(`dpage/pgadmin4`, Ingress host `pgadmin.homelab.local`, resolved by a client
`/etc/hosts` entry so the Cloudflare wildcard never exposes it), slims the Redis
subchart to standalone, and documents the one-window `pg_dump`/`pg_restore`
migration, verification, rollback, and the Pi-hole port-80 caveat. Nextcloud
version and Euro-Office are explicitly deferred to the next step.

## [2026-09-28] edit | Rename CI workflows with chain step prefixes

Prefixed the GitHub Actions workflow display names with their chain and step
position so the deploy chains are readable in the Actions list. Nextcloud k3s
chain: `k3s/nextcloud 1/3 Update byebyemoneylist pin` ->
`k3s/nextcloud 2/3 Build Nextcloud image` -> `k3s/nextcloud 3/3 Pin Nextcloud
image`. nginx k3s chain: `k3s/nginx 1/2 Build nginx site image` ->
`k3s/nginx 2/2 Pin nginx site image`. Compose chain: `compose/laya-api 1/1
Update laya-api pin`. Updated
the `workflow_run.workflows` references, workflow comments/PR bodies, and the
[[Deploying site changes (GitOps)]], [[Releasing a new Nextcloud image
(byebyemoneylist app)]], and [[k3s + GitOps: nginx and cloudflared (phase 2.1)]]
pages plus `infra/laya-api/README.md` and `infra/nextcloud/DEPLOY.md`.

## [2026-09-28] ingest | Releasing a new Nextcloud image (byebyemoneylist app)

Added [[Releasing a new Nextcloud image (byebyemoneylist app)]], the day-to-day
runbook for shipping a new `byebyemoneylist` version into the k3s Nextcloud
image. Spells out the cross-repo chain: tag a release in `byebyemoneylist-ns`
(`release.yml` publishes the tarball) -> bump `BYML_VERSION`/`BYML_SHA256` in
`infra/nextcloud/versions.env` -> `build-nextcloud-image.yml` builds and pushes
`ghcr.io/rykhalskyi/homelab-nextcloud:sha-<commit>` -> `update-nextcloud-image-pin.yml`
opens a digest-pin PR on `infra/k8s/apps/nextcloud/helmrelease.yaml` -> Flux
reconciles and the `before-starting` hook applies the new app. Includes the
"which workflow, which repo" table, the three manual steps, verification, and a
note that deployment stays dark until the HelmRelease is wired into Flux at
cutover. Also corrected the [[Nextcloud on k3s (custom image + Helm chart)]]
Part A: the image is now built in the homelab repo from the pinned release
tarball, not in the app repo.

## [2026-09-27] ingest | Nextcloud on k3s (custom image + Helm chart)

Added [[Nextcloud on k3s (custom image + Helm chart)]], a design plus migration
runbook for moving Nextcloud off the AIO Compose stack onto k3s. The target: the
app repo publishes `ghcr.io/rykhalskyi/byebyemoneylist-nextcloud` (`FROM
nextcloud:<ver>-apache`, app at `/opt/byebyemoneylist`), Flux deploys the
official Nextcloud Helm chart, a `before-starting` hook overlays the baked app
onto the PVC and writes `.env` from a Secret, `/home/jaro/ncdata` is reused via a
static `local` PV, and `cloud.otakeessen.com` routes through Traefik as usual.
Documents why AIO cannot be used in k8s, the exact values (Bitnami Postgres +
Redis subcharts, external DB Secret wiring, seed init container, ingress, cron),
the out-of-band Secrets, and a step-by-step in-place migration: dump the AIO
Postgres, adapt and seed `config.php` (keeping `instanceid`/`secret`/
`passwordsalt`), restore the schema, stop AIO, start the Pod, verify, cut over
the tunnel, and retire Compose. Also covers rollback, a troubleshooting table,
and a go-live checklist.

## [2026-09-27] ingest | Deploying site changes (GitOps)

Added [[Deploying site changes (GitOps)]], a short runbook for the now-automated
update flow: edit content (wiki Markdown or `infra/nginx/html/**`), run `make
wiki`, push to `main`, let the `Build nginx site image` workflow produce a new
`sha-<commit>` image, merge the `Update nginx image pin` PR that bumps the digest
in `infra/k8s/apps/nginx/deployment.yaml`, then let Flux roll out the new Pod.
Documents the trigger paths, verify commands, the manual-pin fallback, and the
"Allow GitHub Actions to create and approve pull requests" repo setting the pin
bot requires.

## [2026-09-25] update | k3s + GitOps: nginx and cloudflared (phase 2.1)

Corrected the site's public hostname from `cloud.otakeessen.com` to
`homelab.otakeessen.com` (the live tunnel maps `cloud.` to Nextcloud on `:11000`,
`laya.` to laya-api on `:8001`). Rewrote Part G into a real cutover order for the
already-running server: do the non-disruptive parts first (image, k3s, Flux),
then the single disruptive swap of host port 80 from the nginx container to
Traefik, plus LAN access via Traefik's `LoadBalancer` and local DNS. Documented
two ways to move cloudflared into the cluster - Option A, a `hostNetwork` bridge
that preserves the current `localhost` config while Nextcloud/laya stay on the
host; and Option B, the end-state where all traffic goes through Traefik (needs
Nextcloud's `APACHE_IP_BINDING` changed off loopback).

## [2026-09-25] ingest | k3s + GitOps: nginx and cloudflared (phase 2.1)

Added [[k3s + GitOps: nginx and cloudflared (phase 2.1)]], a novice-friendly
runbook for phase 2.1: moving the homelab site and the Cloudflare tunnel from
Docker Compose + host systemd onto k3s with Flux. Covers the rationale (no bind
mounts in k8s, Pods are ephemeral, Git as the single source of truth), a
glossary, and nine parts: build the site into a GHCR image in CI (with a
wiki-freshness check), install k3s without bundled Traefik, `flux bootstrap`,
manage Traefik via a Flux HelmRelease, run nginx as a Deployment + Service +
Ingress, run cloudflared as a Deployment with its ingress config in a ConfigMap
and credentials in an out-of-band Secret, wildcard `*.otakeessen.com` routing
through Traefik, zero-downtime cutover from the host tunnel, and the new update
flow. Also documents rollback, a troubleshooting table, the phase 3 (Talos)
reuse story, and a go-live checklist.

## [2026-09-23] ingest | laya-api container deploy (pinned GHCR image)

Added [[laya-api container deploy (pinned GHCR image)]], a design page for
building and running `laya-api` on `node-one` from a pinned GHCR image. It
mirrors the [[Byebyemoneylist app integration (Nextcloud AIO)]] release/pin
pattern: the app repo's release workflow (`.github/workflows/release.yml`) builds
the `Dockerfile` on a `v*` tag, pushes `ghcr.io/rykhalskyi/laya-api` and publishes
a `laya-api-<version>.digest` release asset; `infra/laya-api/versions.env` pins
`LAYA_API_VERSION` + `LAYA_API_SHA256`; and `infra/laya-api/deploy.sh` (wrapped by
`make laya-api-deploy` / `laya-api-pin` / `laya-api-status`) pulls and recreates
the Compose stack on port 8001. Also documented the CPU-only torch pin
(`tool.uv.index` + `tool.uv.sources`, plus `torch` as a direct dep) that drops
the NVIDIA/CUDA wheels and shrinks the image from ~5.4 GB to ~1.5 GB, the required
git-ignored `.env` with `LAYA_ADMIN_KEY`, GHCR visibility/`GHCR_TOKEN`, the
optional pin-bot, and update/rollback/verify steps.

## [2026-09-19] update | Byebyemoneylist app integration (Nextcloud AIO)

Restructured [[Byebyemoneylist app integration (Nextcloud AIO)]] to present the
deploy order explicitly (release → pin manually or via bot → land on `main` →
`node-one` deploy). Moved the mechanics into a "How it works" section, corrected
the `--pin` description (writes version + checksum), refreshed the update/rollback
steps, and added the `installed_version` check. Also documented that the deploy
script does not call `occ migrations:migrate` because `migrations:*` only exists
when `debug=true`.

## [2026-09-19] ingest | Byebyemoneylist app integration (Nextcloud AIO)

Added [[Byebyemoneylist app integration (Nextcloud AIO)]], a design page for
shipping the `byebyemoneylist` Nextcloud app to the AIO instance on `node-one`.
Documents why a custom Nextcloud image is impossible with AIO (image hardcoded
in `containers.json`) and the chosen approach: GitHub Actions builds a versioned
release tarball on a `v*` tag, `infra/nextcloud/versions.env` pins the version,
and `infra/nextcloud/deploy-app.sh` sideloads it into
`nextcloud-aio-nextcloud:/var/www/html/custom_apps` before enabling and running
migrations. Added `infra/nextcloud/DEPLOY.md`, Makefile targets
`nc-app-deploy`/`nc-app-status`, and the app-repo release workflow plus
version/`.nvmrc` drift fixes.

## [2026-09-18] move | Wiki relocated into the homelab project

Moved the wiki from `~/Wiki/DevOps/` to `~/Source/homelab/docs/wiki/`.
Updated the location section in `AGENTS.md`.

## [2026-09-18] ingest | Reconfiguring a Cloudflare Tunnel

Added [[Reconfiguring a Cloudflare Tunnel (change hostname / port)]]. Covers
the two things that actually change (DNS route + ingress rule), how to tell
foreground from systemd mode, which config file is authoritative
(`/etc/cloudflared/config.yml` for the service vs `~/.cloudflared/config.yml`
in foreground), the restart/apply steps, deleting the old DNS record in the
dashboard, verification, and a general reconfiguration checklist.

## [2026-09-18] ingest | Cloudflare Tunnel → nginx quick guide

Created the DevOps wiki and its first page
[[Cloudflare Tunnel → nginx (install + first tunnel)]].

Documented the end-to-end working setup validated on `node-one`
(domain `otakeessen.com`, hostname `cloud.otakeessen.com`, nginx container on
port 80): installing `cloudflared` via the `.deb`, `cloudflared tunnel login`
(headless), `tunnel create nginxtest`, `tunnel route dns`, the
`~/.cloudflared/config.yml` ingress format, running in foreground vs as a
systemd service (`/etc/cloudflared/config.yml`), and the 502 troubleshooting
steps (port mismatch between the tunnel `service:` target and the container's
published port). Added [[Cloudflare Tunnel → multiple services (planned)]] and
Nextcloud-AIO-behind-a-tunnel as TODO pages. Created `AGENTS.md` schema,
`index.md`, and `log.md`.
