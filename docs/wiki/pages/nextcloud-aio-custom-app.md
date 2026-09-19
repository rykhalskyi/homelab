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

## Context

- Server runs **Nextcloud All-in-One** (`infra/nextcloud/docker-compose.yml`),
  published through the Cloudflare tunnel on `cloud.otakeessen.com`.
- The app is developed separately against `nextcloud-docker-dev`; the frontend
  is a Vite build and **the built `js/` and `css/` are gitignored** in the app
  repo (no Java/PHP toolchain needed at runtime, no composer runtime deps).
- AIO has no supported way to use a custom Nextcloud image, so "build a new
  Nextcloud image with the app baked in" is **not** an option here.

## Design decision

Ship the app as a **custom app** and install it into the running AIO container:

- AIO's Nextcloud container mounts the persistent volume
  `nextcloud_aio_nextcloud` at `/var/www/html`.
- `/custom_apps/` is listed in AIO's `upgrade.exclude`, so it survives container
  recreation and Nextcloud updates.
- `nextcloud_aio_nextcloud` is a declared AIO backup volume, so the app is
  included in AIO backups.

The artifact is built **once on GitHub Actions** from a tagged release; the
server only downloads it. This avoids needing Node/npm on `node-one`, keeps
deploys reproducible, and leaves the door open to reuse the same artifact on a
future k3s cluster.

## Release flow (app repo)

`.github/workflows/release.yml`, triggered by a `v*` tag:

1. `npm ci`, `npm run l10n`, `npm run build` on Node 24.
2. Validate the tag equals `appinfo/info.xml` `<version>`.
3. Package the runtime tree: `appinfo lib templates l10n js css img
   composer.json CHANGELOG.md LICENSE README.md` (no `src tests wiki vendor
   node_modules`).
4. Upload `byebyemoneylist-<version>.tar.gz` and `.sha256` to the GitHub
   Release.

## Deploy flow (homelab repo)

| File | Role |
|------|------|
| `infra/nextcloud/versions.env` | Pinned `BYML_VERSION` (+ optional `BYML_SHA256`). Committed, no secrets. |
| `infra/nextcloud/deploy-app.sh` | Download the pinned tarball and install it into the container. `--pin` writes the release checksum into `versions.env`. |
| `infra/nextcloud/DEPLOY.md` | Build/deploy/update/rollback runbook beside the script. |
| `Makefile` (`nc-app-deploy`, `nc-app-pin`, `nc-app-status`) | Convenience wrappers. |

On `node-one`:

```bash
cd ~/Source/homelab && git pull && make nc-app-deploy
```

The script downloads the release asset, verifies the checksum and the
`info.xml` version, copies the app into
`nextcloud-aio-nextcloud:/var/www/html/custom_apps/byebyemoneylist`, sets
ownership to `33:0`, then disables, swaps and re-enables the app (which applies
pending migrations). It does not call `occ migrations:migrate` — Nextcloud
registers `migrations:*` only when `debug=true`, which production AIO leaves
off; enabling the app already runs its migrations.

The **checksum is filled explicitly**, not automatically: CI publishes a
`<tarball>.sha256` asset, `make nc-app-pin` copies its hash into
`versions.env`, and that commit is the integrity anchor used by
`make nc-app-deploy`. An empty `BYML_SHA256` skips verification with a warning.

A **bot** can do the pin step for you: `.github/workflows/update-byebyemoneylist-pin.yml`
polls (or is dispatched by) the app releases, runs the same pin logic, and opens
a pull request updating `BYML_VERSION` + `BYML_SHA256` together. Merging the PR
is what makes it deployable; deploying on `node-one` stays a pull (see
`infra/nextcloud/DEPLOY.md`).

## Update and rollback

- **Update:** publish a new `v*` release, run `make nc-app-pin`, set
  `BYML_VERSION` in `versions.env`, commit, then `git pull && make
  nc-app-deploy` on `node-one`.
- **Rollback:** set the pin back and re-run. Code reverts cleanly; DB migrations
  do **not** auto-revert.

## Verify

```bash
make nc-app-status
docker exec -u www-data nextcloud-aio-nextcloud php occ app:list | grep byebyemoneylist
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
