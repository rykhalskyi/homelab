---
tags: [cloudflare, cloudflared, tunnel, dns, systemd, reconfigure]
date: 2026-09-18
source_count: 0
---

# Reconfiguring a Cloudflare Tunnel (change hostname / port)

How to change which public hostname (or local port) a running tunnel points at.
See [[Cloudflare Tunnel → nginx (install + first tunnel)]] for the initial setup.

Worked example: switch `cloud.otakeessen.com` → `homelab.otakeessen.com`
for the existing `nginxtest` tunnel.

The tunnel itself does not care about the name; only two things change:

1. **DNS** - which hostname resolves to the tunnel.
2. **Ingress rule** - which local port that hostname forwards to.

## Step 0 - know which mode is running

The config file you must edit depends on how cloudflared runs:

| Mode | Command | Config file it reads |
|------|---------|----------------------|
| Foreground | `cloudflared tunnel run nginxtest` | `~/.cloudflared/config.yml` |
| systemd service | `systemctl status cloudflared` | `/etc/cloudflared/config.yml` |

```bash
pgrep -a cloudflared          # shows foreground process + args
systemctl status cloudflared  # active(running) => service mode
```

> Editing the wrong file has no effect. In service mode, always edit
> `/etc/cloudflared/config.yml`.

## Step 1 - add the new DNS route

```bash
cloudflared tunnel route dns nginxtest homelab.otakeessen.com
```

Creates `homelab.otakeessen.com → <UUID>.cfargotunnel.com` (proxied).
The tunnel name (`nginxtest`) is unchanged.

## Step 2 - update the ingress rule

Edit the config file for the running mode:

- **Service:** `/etc/cloudflared/config.yml`
- **Foreground:** `~/.cloudflared/config.yml`

```yaml
tunnel: nginxtest
credentials-file: /etc/cloudflared/<UUID>.json   # ~/.cloudflared/<UUID>.json in foreground
ingress:
  - hostname: homelab.otakeessen.com             # <-- the new name
    service: http://localhost:80                 # <-- the port the app is published on
  - service: http_status:404                     # catch-all, must stay last
```

If you also changed the app's port (e.g. nginx moved to `8081`), update
`service:` to match and recreate the container:
`cd ~/Source/nginx && docker compose up -d`.

## Step 3 - apply / restart

```bash
# systemd service
sudo systemctl restart cloudflared
systemctl status cloudflared
journalctl -u cloudflared -n 30 --no-pager

# foreground: Ctrl+C, then
cloudflared tunnel run nginxtest
```

If you edited `~/.cloudflared/config.yml` but run as a service, copy it over
first:
```bash
sudo cp ~/.cloudflared/config.yml /etc/cloudflared/config.yml
sudo systemctl restart cloudflared
```

## Step 4 - (optional) remove the old hostname

`cloudflared` cannot delete DNS records. Remove the old CNAME in the
Cloudflare dashboard: **DNS → Records → delete the old record**.

If you leave it, the old hostname still resolves to the tunnel but is not in
the ingress list, so it hits the `http_status:404` catch-all.

## Step 5 - verify

```bash
curl -I https://homelab.otakeessen.com   # expect 200
```
Cloudflare's universal SSL covers any `*.otakeessen.com` subdomain, so no
certificate work is needed when changing the name.

## General reconfiguration checklist

- [ ] `cloudflared tunnel route dns <tunnel> <new-hostname>` (if the name changed)
- [ ] Edit the ingress `hostname:` / `service:` in the **active** config file
- [ ] Restart the running mode (`systemctl restart` or re-run foreground)
- [ ] Delete the old DNS record in the dashboard
- [ ] `curl -I https://<new-hostname>`
- [ ] Renaming the tunnel itself is optional - it is only a label
