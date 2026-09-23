---
tags: [laya-api, docker, ghcr, ci, github-actions, python, deploy]
date: 2026-09-23
source_count: 0
---

# laya-api container deploy (pinned GHCR image)

Design of how the **laya-api** prediction API (`rykhalskyi/laya-api`) is built and
run on `node-one` from a pinned container image. It follows the same
release-and-pin pattern as [[Byebyemoneylist app integration (Nextcloud AIO)]],
with the **image digest** playing the role of `BYML_SHA256`.

- App repo: `rykhalskyi/laya-api` (public)
- Image: `ghcr.io/rykhalskyi/laya-api`
- Homelab stack: `infra/laya-api/` (Compose, `versions.env`, `deploy.sh`)
- Host port: `8001` (container listens on `8000`)

## Order (happy path)

1. **Release the app** (app repo). Bump `version` in `pyproject.toml`, re-lock,
   commit, then tag and push:
   ```bash
   uv lock                                  # syncs the project version in uv.lock
   git add pyproject.toml uv.lock && git commit -m "Release vX.Y.Z" && git push
   git tag -a vX.Y.Z -m "laya-api vX.Y.Z" && git push origin vX.Y.Z
   ```
   CI builds the `Dockerfile`, pushes the image to GHCR, and publishes the
   release asset `laya-api-X.Y.Z.digest`.

2. **Pin it in the homelab repo** (on the workstation), either:
   - **manual:** `make laya-api-pin VERSION=X.Y.Z` writes `LAYA_API_VERSION` +
     `LAYA_API_SHA256` into `infra/laya-api/versions.env`; or
   - **bot:** `update-laya-api-pin.yml` does the same and opens a pull request.

3. **Land it on `main`.** Commit/push the manual change, or review and merge the
   bot's PR.

4. **Deploy on `node-one`.**
   ```bash
   cd ~/Source/homelab && git pull && make laya-api-deploy
   make laya-api-status
   ```

## How it works

### Why a pinned image instead of `build:`

The app is built **once in CI** and published to GHCR as an immutable tag +
digest. `node-one` only pulls it - no source checkout and no Python toolchain on
the server - so deploys are fast and reproducible, and a rollback is a two-line
change. The homelab repo never contains the application source.

### Release (app repo)

`.github/workflows/release.yml`, triggered by a `v*` tag:

1. Build the `Dockerfile` and push to GHCR with tags `X.Y.Z`, `X.Y`, `sha-*`.
2. Publish a GitHub release whose only asset is the image digest:
   ```
   laya-api-<version>.digest     # sha256:<manifest digest>
   ```

The **git tag is the source of truth** for the version - it names both the
image tag and the asset. Keep `pyproject.toml` `version` equal to it. The tag
must be valid semver (`vX.Y.Z`), otherwise `docker/metadata-action` skips the
version tags.

### CPU-only torch (image size)

`laya` pulls in `torch` + `transformers`, which by default resolve to the CUDA
wheels: `torch` (~550 MB), the `nvidia-*` CUDA packages (~3.2 GB) and `triton`
(~900 MB) - a ~5.4 GB image, and enough to exhaust a GitHub runner's disk.

`node-one` has no NVIDIA GPU, so the build pins CPU-only torch in
`pyproject.toml`:

```toml
[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true

[tool.uv.sources]
torch = { index = "pytorch-cpu" }
```

`tool.uv.sources` only applies to **direct** dependencies, so `torch` is also
listed in `[project] dependencies` to force the override through `laya`. This
drops `nvidia-*` and `triton` entirely (`uv.lock` loses ~250 lines) and shrinks
the image to roughly 1.5 GB.

### Pin (homelab repo)

| File | Role |
|------|------|
| `infra/laya-api/versions.env` | Pinned `LAYA_API_VERSION` + `LAYA_API_SHA256` (image digest). Committed, no secrets. |
| `infra/laya-api/docker-compose.yml` | Compose stack; image is `<repo>:<version>@<digest>`. |
| `infra/laya-api/deploy.sh` | Pin from a release, then pull + (re)create the stack. `--pin` writes version + digest. |
| `infra/laya-api/README.md` | Build/deploy/update/rollback runbook beside the stack. |
| `Makefile` (`laya-api-deploy`, `laya-api-pin`, `laya-api-status`) | Convenience wrappers. |

Mapping to the Nextcloud app flow:

| Nextcloud | laya-api |
|---|---|
| `make nc-app-pin` | `make laya-api-pin` |
| writes `BYML_VERSION` + `BYML_SHA256` | writes `LAYA_API_VERSION` + `LAYA_API_SHA256` |
| `make nc-app-deploy` | `make laya-api-deploy` |
| `make nc-app-status` | `make laya-api-status` |

The digest is filled explicitly, not automatically: CI publishes
`laya-api-<version>.digest`, `make laya-api-pin` copies its hash into
`versions.env`, and that commit is the integrity anchor. An empty
`LAYA_API_SHA256` **blocks** `make laya-api-deploy`.

**Bot:** `.github/workflows/update-laya-api-pin.yml` runs the same `--pin` logic
on a schedule (daily), on `workflow_dispatch`, or on a `repository_dispatch`
event `laya-api-release`, and opens a PR updating both values together. Merging
the PR is what makes the release deployable. Needs *Settings → Actions → General
→ Workflow permissions → "Allow GitHub Actions to create and approve pull
requests"*. The doorbell (`repository_dispatch` from the app repo) is optional
and requires a PAT there; the daily poll works without it.

### Deploy (node-one)

`infra/laya-api/deploy.sh`:

1. reads `LAYA_API_VERSION` from `versions.env`;
2. `--pin` downloads `laya-api-<version>.digest` and writes **both**
   `LAYA_API_VERSION` and `LAYA_API_SHA256` into `versions.env`;
3. requires `.env` to exist, exports the pinned tag/digest and the `.env`
   secrets, then runs `docker compose pull && up -d`.

The stack (`docker-compose.yml`):

```yaml
image: "ghcr.io/rykhalskyi/laya-api:${LAYA_API_VERSION}@${LAYA_API_SHA256}"
container_name: laya-api
environment:
  LAYA_ADMIN_KEY: ${LAYA_ADMIN_KEY}
  LAYA_API_KEY_DATABASE: /app/data/api_keys.db
ports:
  - "${LAYA_HOST_PORT:-8001}:8000"
volumes:
  - laya_api_data:/app/data
```

### Secrets (`.env`)

`infra/laya-api/.env` is **git-ignored** and required. Create it from the
example and set the admin key:

```bash
cp infra/laya-api/.env.example infra/laya-api/.env
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'   # paste as LAYA_ADMIN_KEY
chmod 600 infra/laya-api/.env
```

The API-key store is SQLite in the persistent `laya_api_data` volume (no DB
server). Keys are shown only at creation; only SHA-256 hashes are stored.

If the GHCR package is **private**, set `GHCR_TOKEN` (+ `GHCR_USER`) in `.env`
so `deploy.sh` logs in before pulling; a public package needs neither. Make it
public once at *Packages → laya-api → Package settings → Change visibility*.

## Update and rollback

- **Update:** release `vX.Y.Z` in the app repo → `make laya-api-pin
  VERSION=X.Y.Z` (or merge the bot PR) → push/merge to `main` → on `node-one`
  `git pull && make laya-api-deploy`.
- **Rollback:** set `LAYA_API_VERSION`/`LAYA_API_SHA256` back (or `git revert`
  the pin commit) and re-run `make laya-api-deploy`. The SQLite DB in the
  `laya_api_data` volume is untouched.

## Verify

```bash
make laya-api-status
curl -s http://127.0.0.1:8001/health          # {"status":"ok"}
source infra/laya-api/.env
curl -s -X POST http://127.0.0.1:8001/admin/keys \
  -H "X-API-Key: $LAYA_ADMIN_KEY" -H 'Content-Type: application/json' \
  -d '{"name":"my-client"}'                    # returns a client key once
```

## Notes and limits

- Host port `8001` avoids the ports already taken on `node-one` (80, 443, 222,
  3000, 8080, 11000, 3478). Override with `LAYA_HOST_PORT`.
- The image is CPU-only by design; if a GPU is ever added, the `pytorch-cpu`
  index pin must be reconsidered.
- `deploy.sh` requires `.env`; a missing file aborts with a pointer to the
  example rather than starting a container that cannot mint keys.
- See [[Cloudflare Tunnel → nginx (install + first tunnel)]] if the API should
  later be exposed publicly.
