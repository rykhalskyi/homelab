# Nextcloud AIO

Self-contained Nextcloud (All-in-One) stack, exposed publicly through the
Cloudflare tunnel on `cloud.otakeessen.com`.

## How it fits

```
Cloudflare edge (TLS)
  └── cloud.otakeessen.com → tunnel → http://localhost:11000 → AIO Apache
```

Only the admin UI is published on the host (`8080`). Nextcloud's Apache is
bound to `127.0.0.1:11000` (via `APACHE_PORT` / `APACHE_IP_BINDING`), so it is
not directly exposed - only the tunnel can reach it.

## Run

```bash
mkdir -p /home/jaro/ncdata
cd infra/nextcloud
docker compose up -d
```

Then open `https://<server-ip>:8080` (accept the self-signed certificate),
enter `cloud.otakeessen.com` as the domain, and click **Start containers**.

## Custom apps

The `byebyemoneylist` app is sideloaded into the running AIO container from a
pinned GitHub release (AIO does not allow a custom Nextcloud image):

```bash
make nc-app-deploy    # install/update the pinned version
make nc-app-status    # show app + migration status
```

Version pin: `versions.env`. Full notes: [`DEPLOY.md`](DEPLOY.md) and the
[wiki design page](../../docs/wiki/pages/nextcloud-aio-custom-app.md).

## Notes

- `NEXTCLOUD_DATADIR` must be set **before** the first install and not changed
  afterwards.
- `SKIP_DOMAIN_VALIDATION: true` is required because TLS is terminated at the
  Cloudflare edge (no public HTTP challenge).
- The named volume `nextcloud_aio_mastercontainer` must keep its exact name -
  AIO's built-in backups depend on it.
- Disable Cloudflare **Rocket Loader** for the domain, or the login page may
  not render.
- Tunnel ingress rule lives in `/etc/cloudflared/config.yml` on the host
  (see `docs/wiki/pages/cloudflare-tunnel-nginx.md`).
