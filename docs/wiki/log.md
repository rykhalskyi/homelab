# DevOps Wiki — Log

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
