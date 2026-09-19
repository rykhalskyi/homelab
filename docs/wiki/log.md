# DevOps Wiki — Log

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
