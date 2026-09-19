# Deploying the byebyemoneylist app into Nextcloud AIO

This directory ships the pinned release of the `byebyemoneylist` app into the
running Nextcloud AIO container. It complements the AIO stack in
`docker-compose.yml`; it does not replace it.

## Why sideload instead of a custom image

AIO pins its Nextcloud image to `ghcr.io/nextcloud-releases/aio-nextcloud` (in
the mastercontainer's `containers.json`) and offers no supported override, so a
custom Nextcloud image cannot be used. The supported path is a **custom app**:

- the Nextcloud container mounts the persistent `nextcloud_aio_nextcloud`
  volume at `/var/www/html`;
- `/custom_apps/` is listed in AIO's `upgrade.exclude`, so it survives
  container recreation and Nextcloud updates;
- `nextcloud_aio_nextcloud` is a declared AIO backup volume.

## Pieces

| File | Purpose |
|------|---------|
| `versions.env` | Pinned `BYML_VERSION` (+ optional `BYML_SHA256`). Committed, no secrets. |
| `deploy-app.sh` | Downloads the pinned release tarball and installs it into the container. |
| `../Makefile` | `make nc-app-deploy`, `make nc-app-status` wrappers. |

## Release side (app repo `rykhalskyi/byebyemoneylist-ns`)

`.github/workflows/release.yml` runs on a `v*` tag, builds the frontend
(Node 24, `npm ci && npm run l10n && npm run build`), validates the tag against
`appinfo/info.xml`, packages the runtime tree and uploads two release assets:

```
byebyemoneylist-<version>.tar.gz
byebyemoneylist-<version>.tar.gz.sha256
```

The tarball contains only runtime files: `appinfo lib templates l10n js css img
composer.json CHANGELOG.md LICENSE README.md` (no `src`, `tests`, `wiki`,
`vendor`, `node_modules`).

## Deploy side (node-one)

```bash
cd ~/Source/homelab
git pull
make nc-app-deploy          # or: bash infra/nextcloud/deploy-app.sh
```

`deploy-app.sh`:

1. reads `BYML_VERSION` from `versions.env`;
2. downloads `https://github.com/<repo>/releases/download/v<version>/byebyemoneylist-<version>.tar.gz`;
3. verifies `BYML_SHA256` (when set) and the `info.xml` version;
4. `docker cp`s the app into `nextcloud-aio-nextcloud:/var/www/html/custom_apps/byebyemoneylist`;
5. sets ownership to `33:0` (www-data);
6. disables → swaps → enables the app and runs `occ migrations:migrate`.

Verify:

```bash
make nc-app-status
# or manually:
docker exec -u www-data nextcloud-aio-nextcloud php occ app:list | grep byebyemoneylist
```

## Update / rollback

- **Update:** publish a new `v*` release (and optionally its `sha256` in the
  release assets), set `BYML_VERSION`/`BYML_SHA256` in `versions.env`, commit,
  then `git pull && make nc-app-deploy` on `node-one`.
- **Rollback:** set `BYML_VERSION` back and re-run. App code rolls back cleanly;
  DB migrations do **not** auto-revert, so avoid deploying versions with
  destructive migrations you might need to undo.

## Troubleshooting

- `container 'nextcloud-aio-nextcloud' not found` — start the AIO stack first.
- `download failed` — the release tag does not exist yet, or the repo is
  private (a read token would then be required).
- `tarball app version ... does not match ...` — `BYML_VERSION` and the
  `info.xml` in that release disagree.
- App shows as disabled in the web UI — re-run `deploy-app.sh`; check
  `docker logs nextcloud-aio-nextcloud` for PHP errors.
- Nextcloud version out of range — the app supports Nextcloud `31–35`; check
  with `docker exec -u www-data nextcloud-aio-nextcloud php occ status`.
