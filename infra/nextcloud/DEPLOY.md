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
| `.env` | Optional, git-ignored app secrets (e.g. `SILICONFLOW_API_KEY`). Copied to `<app>/` on deploy. |
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
6. disables the app and swaps the new release into place;
7. if a git-ignored `.env` sits next to the script, copies it into the app dir
   as `<app>/.env` (owned `33:0`, mode `640`). The swap wipes it otherwise, so
   this runs on every deploy;
8. re-enables the app. Re-enabling applies any pending DB migrations
   (Nextcloud's installer runs them), and sets `installed_version`.

## App secrets (`.env`)

The app reads an app-local, git-ignored `.env` at
`custom_apps/byebyemoneylist/.env` (see the app's
`OCA\ByeByeMoneyList\Config\EnvLoader`). Because `deploy-app.sh` replaces the
whole app directory, keep the persistent copy on the host next to the script:

```bash
# infra/nextcloud/.env  (git-ignored by the repo root .gitignore)
SILICONFLOW_API_KEY=sk-...
```

`make nc-app-deploy` re-installs it automatically. Missing file is not an error
(a warning is logged and the step is skipped).

Verify:

```bash
make nc-app-status
# or manually:
docker exec -u www-data nextcloud-aio-nextcloud php occ app:list | grep byebyemoneylist
```

## Pin version + checksum

The version and its checksum are recorded together so they can never drift:

```bash
make nc-app-pin                    # re-pin the version already in versions.env
make nc-app-pin VERSION=1.0.3      # pin a specific (new) version
```

`--pin` fetches the release's `.sha256` asset and writes **both**
`BYML_VERSION` and `BYML_SHA256` into `versions.env`. Commit the change.
The checksum anchors the deploy: `make nc-app-deploy` re-verifies the download
against it. An empty `BYML_SHA256` skips verification with a warning.

## Automated pin updates (bot)

`.github/workflows/update-byebyemoneylist-pin.yml` runs the same pin logic and
opens a pull request, so the version/checksum pair is updated without manual
edits. It triggers on:

| Trigger | How |
|---------|-----|
| `schedule` | daily poll of the latest app release |
| `workflow_dispatch` | Actions → *Update byebyemoneylist pin* → Run workflow (optional `version` input) |
| `repository_dispatch` | event `byebyemoneylist-release`, optional `client_payload.version` |

It only opens a PR when the resolved version differs from the pinned one, then
updates `version + checksum` on a `bot/byebyemoneylist-<version>` branch.

**Prerequisite:** enable *Settings → Actions → General → Workflow permissions →
"Allow GitHub Actions to create and approve pull requests"* (or supply a PAT),
otherwise PR creation fails.

**Instant updates (optional):** instead of waiting for the daily poll, make the
app repo's release workflow dispatch the event — this needs a PAT with `repo`
access stored as `HOMELAB_DISPATCH_TOKEN` in the app repo:

```bash
curl -fsSL -X POST \
  -H "Authorization: Bearer $HOMELAB_DISPATCH_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/rykhalskyi/homelab/dispatches \
  -d '{"event_type":"byebyemoneylist-release","client_payload":{"version":"'"$version"'"}}'
```

Automating the actual deploy on `node-one` is separate: the server has no
inbound access, so it either pulls on a timer/systemd unit or you run
`make nc-app-deploy` after merging.

## Update / rollback

- **Update:** publish a new `v*` release (and optionally its `sha256` in the
  release assets), set `BYML_VERSION`/`BYML_SHA256` in `versions.env`, commit,
  then `git pull && make nc-app-deploy` on `node-one`.
- **Rollback:** set `BYML_VERSION` back and re-run. App code rolls back cleanly;
  DB migrations do **not** auto-revert, so avoid deploying versions with
  destructive migrations you might need to undo.

## Troubleshooting

- `Command "migrations:migrate" is not defined` — expected, and not used by the
  script. Nextcloud only registers `migrations:*` when the `debug` system value
  is `true`; production AIO has it off. Migrations run automatically when the
  app is enabled (`occ app:enable`), so the script relies on that.
- `container 'nextcloud-aio-nextcloud' not found` — start the AIO stack first.
- `download failed` — the release tag does not exist yet, or the repo is
  private (a read token would then be required).
- `tarball app version ... does not match ...` — `BYML_VERSION` and the
  `info.xml` in that release disagree.
- App shows as disabled in the web UI — re-run `deploy-app.sh`; check
  `docker logs nextcloud-aio-nextcloud` for PHP errors.
- Nextcloud version out of range — the app supports Nextcloud `31–35`; check
  with `docker exec -u www-data nextcloud-aio-nextcloud php occ status`.
