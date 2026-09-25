# DevOps Wiki — Index

Home-server DevOps notes and runnable how-tos (server `node-one`).

## Guides

- [[Cloudflare Tunnel → nginx (install + first tunnel)]] — [open](pages/cloudflare-tunnel-nginx.md) — (2026-09-18, 0 sources) — install `cloudflared` on Ubuntu, log in, create a tunnel, route a DNS hostname, configure `~/.cloudflared/config.yml`, run it (foreground + systemd), and troubleshoot 502 Bad Gateway. Working setup: `otakeessen.com` → nginx on port 80.
- [[Reconfiguring a Cloudflare Tunnel (change hostname / port)]] — [open](pages/cloudflared-reconfigure-hostname.md) — (2026-09-18, 0 sources) — change a tunnel's public hostname or local port: add the new DNS route, edit the ingress rule in the **active** config (`/etc/cloudflared/config.yml` for the service, `~/.cloudflared/config.yml` in foreground), restart, drop the old DNS record, verify.

## Orchestration

- [[k3s + GitOps: nginx and cloudflared (phase 2.1)]] — [open](pages/k3s-gitops-nginx-cloudflared.md) — (2026-09-25, 0 sources) — plain-language runbook for moving `infra/nginx` and the Cloudflare tunnel onto k3s, with Flux reconciling GitHub: build the site image in CI, install k3s without bundled Traefik, manage Traefik via Flux, run nginx and cloudflared as Deployments, route `*.otakeessen.com` through Traefik, and cut over from Compose + systemd. Also covers rollback, troubleshooting, and how the same manifests move to Talos (phase 3).

## Design

- [[Byebyemoneylist app integration (Nextcloud AIO)]] — [open](pages/nextcloud-aio-custom-app.md) — (2026-09-19, 0 sources) — how the `byebyemoneylist` app is shipped onto Nextcloud AIO: GitHub Actions builds a versioned release tarball, `versions.env` pins it, and `infra/nextcloud/deploy-app.sh` sideloads it into `custom_apps` (AIO's `nextcloud_aio_nextcloud` volume). Why a custom Nextcloud image is not possible with AIO, plus update/rollback and the k3s path.
- [[laya-api container deploy (pinned GHCR image)]] — [open](pages/laya-api-container-deploy.md) — (2026-09-23, 0 sources) — build `laya-api` in GitHub Actions and publish the image to GHCR with a `laya-api-<version>.digest` release asset, pin version + digest in `infra/laya-api/versions.env`, and deploy on `node-one` via Compose on port 8001. Mirrors the byebyemoneylist release/pin pattern, includes the CPU-only torch fix that shrinks the image from ~5.4 GB to ~1.5 GB.

## TODO pages

- Cloudflare Tunnel → multiple services (one tunnel, many subdomains).
- Nextcloud AIO behind a Cloudflare Tunnel (`APACHE_PORT`, skip validation).
