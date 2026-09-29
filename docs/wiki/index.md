# DevOps Wiki — Index

Home-server DevOps notes and runnable how-tos (server `node-one`).

## Guides

- [[Cloudflare Tunnel → nginx (install + first tunnel)]] — [open](pages/cloudflare-tunnel-nginx.md) — (2026-09-18, 0 sources) — install `cloudflared` on Ubuntu, log in, create a tunnel, route a DNS hostname, configure `~/.cloudflared/config.yml`, run it (foreground + systemd), and troubleshoot 502 Bad Gateway. Working setup: `otakeessen.com` → nginx on port 80.
- [[Reconfiguring a Cloudflare Tunnel (change hostname / port)]] — [open](pages/cloudflared-reconfigure-hostname.md) — (2026-09-18, 0 sources) — change a tunnel's public hostname or local port: add the new DNS route, edit the ingress rule in the **active** config (`/etc/cloudflared/config.yml` for the service, `~/.cloudflared/config.yml` in foreground), restart, drop the old DNS record, verify.

## Orchestration

- [[k3s + GitOps: nginx and cloudflared (phase 2.1)]] — [open](pages/k3s-gitops-nginx-cloudflared.md) — (2026-09-25, 0 sources) — plain-language runbook for moving `infra/nginx` and the Cloudflare tunnel onto k3s, with Flux reconciling GitHub: build the site image in CI, install k3s without bundled Traefik, manage Traefik via Flux, run nginx and cloudflared as Deployments, route `*.otakeessen.com` through Traefik, and cut over from Compose + systemd. Also covers rollback, troubleshooting, and how the same manifests move to Talos (phase 3).
- [[Deploying site changes (GitOps)]] — [open](pages/deploying-site-changes.md) — (2026-09-27, 0 sources) — the day-to-day flow for shipping a change to the landing page or wiki: edit, run `make wiki`, push to `main`, let CI build the image, merge the auto-opened pin PR, and let Flux reconcile `infra/k8s/apps/nginx`. Lists the paths that trigger a rebuild, the verify commands, the manual-pin fallback, and the repo setting the pin bot needs.
- [[Nextcloud on k3s (custom image + Helm chart)]] — [open](pages/nextcloud-on-k3s.md) — (2026-09-27, 0 sources) — move Nextcloud off the AIO Compose stack onto k3s with Flux: bake `byebyemoneylist` into a `nextcloud:apache` image, deploy the official Nextcloud Helm chart (Bitnami Postgres + Redis subcharts) with an `before-starting` hook that overlays the app, reuse `/home/jaro/ncdata` through a static local PV, seed `config.php` so the entrypoint skips `maintenance:install`, and cut the Cloudflare tunnel over. Includes the AIO `pg_dump`/restore runbook, rollback, troubleshooting, and a go-live checklist.
- [[Releasing a new Nextcloud image (byebyemoneylist app)]] — [open](pages/nextcloud-image-release.md) — (2026-09-28, 0 sources) — the day-to-day release/update flow for the app baked into the k3s Nextcloud image: push a `v*` tag in the app repo (`release.yml` publishes the tarball), bump `BYML_VERSION`/`BYML_SHA256` in `infra/nextcloud/versions.env`, let `build-nextcloud-image.yml` build and push `ghcr.io/rykhalskyi/homelab-nextcloud`, merge the pin PR that updates `infra/k8s/apps/nextcloud/helmrelease.yaml`, and let Flux reconcile. Lists which workflow lives in which repo and which three steps are actually manual.
- [[PostgreSQL + pgAdmin on k3s (decoupled from Nextcloud)]] — [open](pages/postgresql-pgadmin.md) — (2026-09-29, 0 sources) — move Nextcloud's database off the chart's bundled subchart into a pinned standalone Bitnami Postgres `HelmRelease` (major 17, reusing the `nextcloud-db` Secret), add a LAN-only pgAdmin (`pgadmin.homelab.local` via a client hosts entry), slim Redis to standalone, and run the one-window `pg_dump`/`pg_restore` migration. Includes verify, rollback, the pinned chart/image versions, and the Pi-hole port-80 caveat. Prerequisite for the Nextcloud 31→33 + Euro-Office work.

## Design

- [[Byebyemoneylist app integration (Nextcloud AIO)]] — [open](pages/nextcloud-aio-custom-app.md) — (2026-09-19, 0 sources) — how the `byebyemoneylist` app is shipped onto Nextcloud AIO: GitHub Actions builds a versioned release tarball, `versions.env` pins it, and `infra/nextcloud/deploy-app.sh` sideloads it into `custom_apps` (AIO's `nextcloud_aio_nextcloud` volume). Why a custom Nextcloud image is not possible with AIO, plus update/rollback and the k3s path.
- [[laya-api container deploy (pinned GHCR image)]] — [open](pages/laya-api-container-deploy.md) — (2026-09-23, 0 sources) — build `laya-api` in GitHub Actions and publish the image to GHCR with a `laya-api-<version>.digest` release asset, pin version + digest in `infra/laya-api/versions.env`, and deploy on `node-one` via Compose on port 8001. Mirrors the byebyemoneylist release/pin pattern, includes the CPU-only torch fix that shrinks the image from ~5.4 GB to ~1.5 GB.

## TODO pages

- Cloudflare Tunnel → multiple services (one tunnel, many subdomains).
- Nextcloud AIO behind a Cloudflare Tunnel (`APACHE_PORT`, skip validation).
