# DevOps Wiki — Log

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
