---
tags: [nextcloud, aio, docker, ci, github-actions, deploy, byebyemoneylist]
date: 2026-09-19
source_count: 0
---

# Byebyemoneylist app integration (Nextcloud AIO)

Design of how the personal Nextcloud app **Bye Bye Money List**
(`rykhalskyi/byebyemoneylist-ns`) is shipped onto the Nextcloud AIO instance on
`node-one`, and why it is done this way.

See [[Cloudflare Tunnel → nginx (install + first tunnel)]] for how Nextcloud is
exposed; this page is only about delivering the app.

## Order (happy path)

1. **Release the app** (app repo). Bump the version to `X.Y.Z` in
   `appinfo/info.xml` (and `package.json`/`package-lock.json`), commit, then tag
   and push:
   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
   CI builds the frontend and publishes `byebyemoneylist-X.Y.Z.tar.gz` plus its
   `.sha256` to the GitHub Release.

2. **Pin it in the homelab repo** (on your workstation) - either:
   - **manual:** `make nc-app-pin VERSION=X.Y.Z` writes both `BYML_VERSION` and
     `BYML_SHA256` into `infra/nextcloud/versions.env`; or
   - **bot:** `update-byebyemoneylist-pin.yml` does the same and opens a pull
     request.

3. **Land it on `main`.** Commit/push the manual change, or review and merge the
   bot's PR.

4. **Deploy on `node-one`.**
   ```bash
   cd ~/Source/homelab && git pull && make nc-app-deploy
   make nc-app-status
   ```

## How it works

### Why sideload instead of a custom image

AIO pins its Nextcloud image to `ghcr.io/nextcloud-releases/aio-nextcloud` and
offers no supported override, so a custom Nextcloud image is not an option. The
app is installed as a **custom app** instead, which is durable because:

- AIO's Nextcloud container mounts the persistent volume
  `nextcloud_aio_nextcloud` at `/var/www/html`;
- `/custom_apps/` is listed in AIO's `upgrade.exclude`, so it survives container
  recreation and Nextcloud updates;
- `nextcloud_aio_nextcloud` is a declared AIO backup volume.

The artifact is built **once on GitHub Actions** from a tagged release; the
server only downloads it. This avoids Node/npm on `node-one`, keeps deploys
reproducible, and leaves the door open to reuse the same artifact on k3s later.

### Release (app repo)

`.github/workflows/release.yml`, triggered by a `v*` tag:

1. `npm ci`, `npm run l10n`, `npm run build` on Node 24.
2. Validate the tag equals `appinfo/info.xml` `<version>`.
3. Package the runtime tree: `appinfo lib templates l10n js css img
   composer.json CHANGELOG.md LICENSE README.md` (no `src tests wiki vendor
   node_modules`).
4. Upload `byebyemoneylist-<version>.tar.gz` and `.sha256` to the GitHub
   Release.

### Pin (homelab repo)

| File | Role |
|------|------|
| `infra/nextcloud/versions.env` | Pinned `BYML_VERSION` + `BYML_SHA256`. Committed, no secrets. |
| `infra/nextcloud/deploy-app.sh` | Download the pinned tarball and install it. `--pin` writes version + checksum. |
| `infra/nextcloud/DEPLOY.md` | Build/deploy/update/rollback runbook beside the script. |
| `Makefile` (`nc-app-deploy`, `nc-app-pin`, `nc-app-status`) | Convenience wrappers. |

The **checksum is filled explicitly**, not automatically: CI publishes a
`<tarball>.sha256` asset, `make nc-app-pin` copies its hash into `versions.env`,
and that commit is the integrity anchor used by `make nc-app-deploy`. An empty
`BYML_SHA256` skips verification with a warning.

`make nc-app-pin` needs no Docker; run it where you author the homelab repo and
commit the result - the server only pulls.

**Bot:** `.github/workflows/update-byebyemoneylist-pin.yml` runs the same pin
logic on a schedule (or a `repository_dispatch` event) and opens a PR updating
`BYML_VERSION` + `BYML_SHA256` together. Merging the PR is what makes it
deployable. (Needs *Settings → Actions → General → Workflow permissions →
"Allow GitHub Actions to create and approve pull requests".*)

### Deploy script (`node-one`)

`deploy-app.sh` downloads the pinned release asset, verifies the checksum and
the `info.xml` version, copies the app into
`nextcloud-aio-nextcloud:/var/www/html/custom_apps/byebyemoneylist`, sets
ownership to `33:0`, then disables, swaps and re-enables the app. It does not
call `occ migrations:migrate` - Nextcloud registers `migrations:*` only when
`debug=true`, which production AIO leaves off; enabling the app already applies
pending migrations.

## Update and rollback

- **Update:** bump the app version and tag `vX.Y.Z` → `make nc-app-pin
  VERSION=X.Y.Z` (or merge the bot PR) → push/merge to `main` → on `node-one`
  `git pull && make nc-app-deploy`.
- **Rollback:** set the pin back and re-run. Code reverts cleanly; DB migrations
  do **not** auto-revert.

## Verify

```bash
make nc-app-status
docker exec -u www-data nextcloud-aio-nextcloud php occ app:list | grep byebyemoneylist
docker exec -u www-data nextcloud-aio-nextcloud php occ config:app:get byebyemoneylist installed_version
```

## Notes and limits

- The app supports Nextcloud `31–35`.
- Custom-image overrides and the AIO mastercontainer's `containers.json` are
  deliberately **not** modified; that path is unsupported and would be undone by
  AIO updates.
- **Future (k3s):** the same release artifact can be consumed by the official
  Nextcloud Helm chart, either baked into a custom image or dropped in via an
  initContainer; the AIO-specific copy step is then replaced, but the build
  stays a GitHub release.
- Optional later: a Renovate `regex` rule on `versions.env` to open
  "bump BYML_VERSION" PRs automatically.
