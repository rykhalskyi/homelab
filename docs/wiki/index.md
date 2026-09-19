# DevOps Wiki — Index

Home-server DevOps notes and runnable how-tos (server `node-one`).

## Guides

- [[Cloudflare Tunnel → nginx (install + first tunnel)]] — [open](pages/cloudflare-tunnel-nginx.md) — (2026-09-18, 0 sources) — install `cloudflared` on Ubuntu, log in, create a tunnel, route a DNS hostname, configure `~/.cloudflared/config.yml`, run it (foreground + systemd), and troubleshoot 502 Bad Gateway. Working setup: `otakeessen.com` → nginx on port 80.
- [[Reconfiguring a Cloudflare Tunnel (change hostname / port)]] — [open](pages/cloudflared-reconfigure-hostname.md) — (2026-09-18, 0 sources) — change a tunnel's public hostname or local port: add the new DNS route, edit the ingress rule in the **active** config (`/etc/cloudflared/config.yml` for the service, `~/.cloudflared/config.yml` in foreground), restart, drop the old DNS record, verify.

## Design

- [[Byebyemoneylist app integration (Nextcloud AIO)]] — [open](pages/nextcloud-aio-custom-app.md) — (2026-09-19, 0 sources) — how the `byebyemoneylist` app is shipped onto Nextcloud AIO: GitHub Actions builds a versioned release tarball, `versions.env` pins it, and `infra/nextcloud/deploy-app.sh` sideloads it into `custom_apps` (AIO's `nextcloud_aio_nextcloud` volume). Why a custom Nextcloud image is not possible with AIO, plus update/rollback and the k3s path.

## TODO pages

- Cloudflare Tunnel → multiple services (one tunnel, many subdomains).
- Nextcloud AIO behind a Cloudflare Tunnel (`APACHE_PORT`, skip validation).
