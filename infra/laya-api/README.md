# Deploying laya-api from a pinned image

This directory deploys the [`laya-api`](https://github.com/rykhalskyi/laya-api)
prediction API on `node-one` from a pinned, prebuilt container image — the same
release-and-pin pattern used for the Nextcloud app in `infra/nextcloud/`, with
the image digest playing the role of `BYML_SHA256`.

## Why an image instead of `build:`

The app is built once in CI and published to GHCR (`ghcr.io/rykhalskyi/laya-api`)
as an immutable tag + digest. This repo only consumes it — no source checkout,
no Python toolchain, and deploys are a fast `docker compose pull`.

## Pieces

| File | Purpose |
|------|---------|
| `versions.env` | Pinned `LAYA_API_VERSION` (+ `LAYA_API_SHA256` image digest). Committed, no secrets. |
| `docker-compose.yml` | Compose stack; references `ghcr.io/rykhalskyi/laya-api:<version>@<digest>`. |
| `deploy.sh` | Pins version + digest from a release, then pulls and (re)creates the stack. |
| `.env` | Git-ignored secrets: `LAYA_ADMIN_KEY` (and optional `LAYA_HOST_PORT`, `GHCR_TOKEN`). |
| `../Makefile` | `make laya-api-deploy`, `make laya-api-pin`, `make laya-api-status` wrappers. |

## Release side (app repo `rykhalskyi/laya-api`)

`.github/workflows/release.yml` runs on a `v*` tag, builds the `Dockerfile`,
pushes it to GHCR (`vX.Y.Z`, `X.Y`, `sha-*` tags) and publishes a GitHub release
with one asset:

```
laya-api-<version>.digest     # sha256:<manifest digest>
```

## Deploy side (`node-one`)

```bash
cd ~/Source/homelab
git pull
make laya-api-pin VERSION=0.1.0   # once per new release: pin version + digest
make laya-api-deploy              # pull + (re)create the stack
```

`deploy.sh`:

1. reads `LAYA_API_VERSION` from `versions.env`;
2. `--pin` downloads the `laya-api-<version>.digest` release asset and writes
   **both** `LAYA_API_VERSION` and `LAYA_API_SHA256` into `versions.env` so they
   never drift;
3. exports the pinned tag/digest and the `.env` secrets, then runs
   `docker compose pull && up -d` for the digest-pinned image.

The API listens on host port `8001` by default (`LAYA_HOST_PORT` overrides it).

## Secrets (`.env`)

`deploy.sh` requires `.env`; create it from the example and set the admin key.
`.env` is git-ignored — never commit it.

```bash
cp infra/laya-api/.env.example infra/laya-api/.env
# then edit LAYA_ADMIN_KEY (generate: python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
```

Read the admin key to mint client keys:

```bash
source infra/laya-api/.env
curl -X POST http://127.0.0.1:8001/admin/keys \
  -H "X-API-Key: $LAYA_ADMIN_KEY" -H 'Content-Type: application/json' \
  -d '{"name":"my-client"}'
```

If the GHCR package is private, set `GHCR_TOKEN` (and `GHCR_USER`) in `.env` so
`deploy.sh` logs in before pulling. A public package needs neither.

## Pin version + digest

```bash
make laya-api-pin                  # re-pin the version already in versions.env
make laya-api-pin VERSION=0.1.0    # pin a specific (new) version
```

`--pin` fetches the release's `.digest` asset and writes **both**
`LAYA_API_VERSION` and `LAYA_API_SHA256` into `versions.env`. Commit the change.
An empty `LAYA_API_SHA256` blocks `make laya-api-deploy`.

## Automated pin updates (bot)

`.github/workflows/update-laya-api-pin.yml` runs the same pin logic and opens a
pull request, so the version/digest pair is updated without manual edits. It
triggers on:

| Trigger | How |
|---------|-----|
| `schedule` | daily poll of the latest laya-api release |
| `workflow_dispatch` | Actions → *Update laya-api pin* → Run workflow (optional `version` input) |
| `repository_dispatch` | event `laya-api-release`, optional `client_payload.version` |

It only opens a PR when the resolved version differs from the pinned one.

**Prerequisite:** enable *Settings → Actions → General → Workflow permissions →
"Allow GitHub Actions to create and approve pull requests"*.

## Update / rollback

- **Update:** publish a new `v*` release in `laya-api`, then
  `make laya-api-pin VERSION=x.y.z && make laya-api-deploy` on `node-one`.
- **Rollback:** set `LAYA_API_VERSION`/`LAYA_API_SHA256` back (or `git revert`
  the pin commit) and re-run `make laya-api-deploy`. The SQLite DB in the
  `laya_api_data` volume is untouched.

## Troubleshooting

- `missing .../.env` — copy `.env.example` to `.env` and set `LAYA_ADMIN_KEY`.
- `LAYA_API_SHA256 is empty` — run `make laya-api-pin VERSION=x.y.z` first.
- `could not fetch ... .digest` — the release tag does not exist yet (or the
  repo is private and needs a read token).
- `error getting credentials` / `denied` on pull — the GHCR package is private;
  set `GHCR_TOKEN` + `GHCR_USER` in `.env`.
