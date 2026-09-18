# DevOps Wiki — Log

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
