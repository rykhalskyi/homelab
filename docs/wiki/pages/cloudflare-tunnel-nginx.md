---
tags: [cloudflare, cloudflared, tunnel, nginx, docker, ubuntu, reverse-proxy]
date: 2026-09-18
source_count: 0
---

# Cloudflare Tunnel → nginx (install + first tunnel)

Expose a local nginx (in Docker) to the internet through a **Cloudflare
Tunnel** - no open router ports, valid HTTPS at Cloudflare's edge.

Working setup used here:

| Thing | Value |
|-------|-------|
| Server | `node-one` (Ubuntu), user `jaro` |
| Domain | `otakeessen.com` (added to Cloudflare) |
| Public hostname | `cloud.otakeessen.com` |
| Local service | nginx container, published on host port `80` |
| Tunnel name | `nginxtest` |

## How it works (mental model)

```
browser → https://cloud.otakeessen.com
        → Cloudflare edge (TLS)
        → Tunnel (outbound-only from the server)
        → cloudflared reads ~/.cloudflared/config.yml
        → http://localhost:80  → nginx container
```

Cloudflare does **not** know what "nginx" is. The routing is only:
1. **DNS** decides which hostname enters the tunnel
   (`cloud.otakeessen.com → <tunnel-id>.cfargotunnel.com`).
2. **`config.yml`** decides which local port it exits to
   (`hostname: cloud.otakeessen.com → http://localhost:80`).

## Prerequisites

- Domain added in Cloudflare and the zone is **Active** (nameservers at the
  registrar point to Cloudflare). This is the only dashboard step.
- nginx running and reachable locally.

## 1. Install cloudflared

```bash
curl -L -o cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb
cloudflared --version
```

## 2. Log in (headless)

```bash
cloudflared tunnel login
```

It prints a URL. Open it **in a browser on any machine**, log in to Cloudflare,
and pick `otakeessen.com`. This writes `~/.cloudflared/cert.pem`.

## 3. Create the tunnel

```bash
cloudflared tunnel create nginxtest
```

`nginxtest` is just a **label**; Cloudflare also assigns a UUID and creates
`~/.cloudflared/<UUID>.json` (the tunnel credentials). Note the UUID.

## 4. Create the DNS route

```bash
cloudflared tunnel route dns nginxtest cloud.otakeessen.com
```

This calls the Cloudflare API and creates the CNAME
`cloud.otakeessen.com → <UUID>.cfargotunnel.com` (proxied). No manual DNS
entry needed. If a record for that host already exists, delete it or append
`--overwrite-dns`.

## 5. Configure `~/.cloudflared/config.yml`

```yaml
tunnel: nginxtest
credentials-file: /home/jaro/.cloudflared/<UUID>.json
ingress:
  - hostname: cloud.otakeessen.com
    service: http://localhost:80        # the port nginx is published on
  - service: http_status:404            # required catch-all, must be last
```

**`service` must match the port nginx is published on.** Check with
`docker ps` - this setup used `0.0.0.0:80->80/tcp`, so the target is `:80`.

## 6. Run and test (foreground)

```bash
# nginx reachable locally?
curl -I http://localhost:80        # expect HTTP/1.1 200 OK

cloudflared tunnel run nginxtest   # Ctrl+C to stop
```

Then open `https://cloud.otakeessen.com` - the nginx page with a valid
Cloudflare certificate.

## 7. Run as a systemd service (always on)

```bash
sudo mkdir -p /etc/cloudflared
sudo cp ~/.cloudflared/config.yml /etc/cloudflared/config.yml
sudo cp ~/.cloudflared/<UUID>.json /etc/cloudflared/
sudo chmod 600 /etc/cloudflared/<UUID>.json
```

Edit `/etc/cloudflared/config.yml` so the credentials path is absolute:

```yaml
credentials-file: /etc/cloudflared/<UUID>.json
```

Then install and start:

```bash
sudo cloudflared service install
sudo systemctl enable --now cloudflared
systemctl status cloudflared
journalctl -u cloudflared -f        # live logs
```

> Note: the service reads **`/etc/cloudflared/config.yml`**, not
> `~/.cloudflared/config.yml`. After editing the home copy, re-copy it and
> `sudo systemctl restart cloudflared`.

## Reference: nginx compose file

`~/Source/nginx/docker-compose.yml`:

```yaml
services:
  nginx:
    image: nginx:stable
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./html:/usr/share/nginx/html:ro
      - ./conf.d:/etc/nginx/conf.d:ro
```

Remember: bind-mounting an **empty** `conf.d/` hides the image's default
config, and nginx then listens on nothing (the page won't load). Keep a
`default.conf` with a `server { listen 80; ... }` block in there.

## Troubleshooting

### 502 Bad Gateway from Cloudflare

The tunnel connected but `cloudflared` could not reach the local service -
almost always a **port mismatch**.

```bash
docker ps                                  # what port is nginx published on?
curl -I http://localhost:<port>            # does it answer locally?
cat /etc/cloudflared/config.yml            # (service) target port
cat ~/.cloudflared/config.yml              # (foreground) target port
journalctl -u cloudflared -n 50 --no-pager # "Unable to reach the origin service"
```

Fix: make `service:` match the published port, then restart cloudflared.

### Other gotchas

- Foreground `cloudflared` and the systemd service read **different config
  files** - editing one does not affect the other.
- Changing the port in `docker-compose.yml` requires
  `docker compose up -d` to recreate the container; otherwise nothing listens
  on the new port.
- Chain errors (`1033`, `530`) usually mean the tunnel/service is not running.

## Security notes

- The tunnel is **publicly reachable** once live (traffic passes through and
  is decrypted by Cloudflare's edge). Add **Cloudflare Access** on the hostname
  to restrict it to specific emails if needed.
- Keep `~/.cloudflared/<UUID>.json` secret - it is the tunnel credential.
- Disable Cloudflare **Rocket Loader** for Nextcloud later, or its login page
  may not render.

## Next steps (planned)

- Run **Nextcloud (AIO)** behind the same tunnel: set `APACHE_PORT: 11000`,
  `APACHE_IP_BINDING: 127.0.0.1`, `SKIP_DOMAIN_VALIDATION: true`, then add an
  ingress rule `cloud2.otakeessen.com → http://localhost:11000`.
- One tunnel can route **many hostnames** (one subdomain per service) - see
  [[Cloudflare Tunnel → multiple services (planned)]].
