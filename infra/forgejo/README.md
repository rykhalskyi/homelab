# Forgejo

Self-hosted Git forge (community fork of Gitea). Runs local-first on the LAN
and is ready to be published through the Cloudflare tunnel later.

## How it fits

```
LAN:   browser → http://192.168.2.233:3000      → Forgejo
       git     → ssh://git@192.168.2.233:222/...

Later: Cloudflare edge (TLS)
         └── git.otakeessen.com → tunnel → http://localhost:3000 → Forgejo
```

Forgejo's own SSH server is published on host port `222` (not `22`, to avoid
clashing with the host). The tunnel only carries HTTP; git-over-SSH stays a
LAN/port-forward concern.

## Run

Create `.env` next to `docker-compose.yml` (it is gitignored):

```dotenv
DB_PASSWORD=<set-a-strong-password>
```

Then:

```bash
cd infra/forgejo
docker compose up -d
```

Open `http://192.168.2.233:3000` and complete the onboarding wizard. Data
persists in the named volumes `forgejo_data` and `forgejo_postgres`.

`.env` holds `DB_PASSWORD` and is **gitignored** - create it on `node-one`
too; it is not shipped by `git pull`.

## Environment variables

Forgejo writes `app.ini`; every setting can be set with
`FORGEJO__<section>__<KEY>` (the `DEFAULT` section uses an empty
double-underscore, e.g. `FORGEJO____APP_NAME`). `SECRET_KEY` is generated and
persisted on first start, so it is not set in the compose file.

| Variable | Local default | Public |
|----------|---------------|--------|
| `FORGEJO_DOMAIN` | `192.168.2.233` | `git.otakeessen.com` |
| `FORGEJO_ROOT_URL` | `http://192.168.2.233:3000/` | `https://git.otakeessen.com/` |
| `FORGEJO_SSH_DOMAIN` | `192.168.2.233` | `git.otakeessen.com` |

## Publishing through the tunnel

1. Set the three variables above in `.env` (keep `DB_PASSWORD` unchanged),
   then `docker compose up -d`.
2. Add an ingress rule to `/etc/cloudflared/config.yml` on `node-one`:

   ```yaml
   - hostname: git.otakeessen.com
     service: http://localhost:3000
   ```

   and restart the service (`sudo systemctl restart cloudflared`). See
   `docs/wiki/pages/cloudflare-tunnel-nginx.md`.
3. Before going public: set
   `FORGEJO__service__DISABLE_REGISTRATION=true` and put `git.otakeessen.com`
   behind **Cloudflare Access**.

## Notes

- PostgreSQL 14 backend; drop the `db` service and the `FORGEJO__database__*`
  values to fall back to SQLite.
- Upgrading across major image tags (`16` → `17`, ...) needs a manual step -
  read the Forgejo upgrade guide first.
- Cloudflare's Free plan caps proxied uploads at 100 MB, so very large pushes
  over HTTPS can fail; SSH on the LAN is unaffected.
