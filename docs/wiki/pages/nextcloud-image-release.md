---
tags: [nextcloud, talos, byebyemoneylist, booktailor, ci, github-actions, ghcr, flux, gitops, release, runbook]
date: 2026-10-31
source_count: 0
---

# Releasing a new Nextcloud image (BookTailor + byebyemoneylist apps)

How to ship new versions of **BookTailor** (`rykhalskyi/booktailor`) and
**Bye Bye Money List** (`rykhalskyi/byebyemoneylist-ns`) into the Nextcloud
image that `talos` runs. Both apps follow the same release/pin pattern: the app
repos publish release tarballs, the homelab repo pins them, CI builds one custom
image containing both, and Flux rolls it out.

See [[Nextcloud + Euro-Office on Talos (LAN-only)]] for the cluster setup.

## The chain

```text
booktailor           change the app, bump <version>, push tag vX.Y.Z
                     release.yml builds the frontend and publishes
                     booktailor-X.Y.Z.tar.gz + .sha256
byebyemoneylist-ns   same: release.yml publishes byebyemoneylist-X.Y.Z.tar.gz
        |            + .sha256
        v
homelab              bump BOOKTAILOR_VERSION / BOOKTAILOR_SHA256 and/or
                     BYML_VERSION / BYML_SHA256 in
                     infra/images/nextcloud/versions.env, push to main
        |
        v
CI (homelab)         build-nextcloud-image.yml downloads + verifies both
                     tarballs, builds FROM nextcloud:35-apache + both apps,
                     pushes ghcr.io/rykhalskyi/homelab-nextcloud:sha-<commit>
        |
        v
CI (homelab)         update-nextcloud-image-pin.yml opens a PR pinning the
                     digest in infra/clusters/talos/apps/nextcloud/helmrelease.yaml
        |
        v
you                  merge the pin PR -> Flux reconciles -> new Pod; the
                     before-starting hook copies both apps into custom_apps
                     and re-enables whichever app version changed
```

The key idea: **the image is built from release tarballs, not from branches.**
Nothing happens until a release exists and its pin lands in `versions.env`.

## Which workflow runs where

| Workflow | Repo | Trigger |
|---|---|---|
| `release.yml` | booktailor | push a `v*` tag (or manual dispatch) |
| `release.yml` | byebyemoneylist-ns | push a `v*` tag (or manual dispatch) |
| `update-booktailor-pin.yml` | homelab | daily poll, manual dispatch, or `booktailor-release` dispatch |
| `update-byebyemoneylist-pin.yml` | homelab | daily poll, manual dispatch, or `byebyemoneylist-release` dispatch |
| `build-nextcloud-image.yml` | homelab | push to `main` touching `infra/images/nextcloud/versions.env` (or the Dockerfile) |
| `update-nextcloud-image-pin.yml` | homelab | after `talos/nextcloud 2/3 Build Nextcloud image` succeeds |

You do **not** run these by hand, except the release tags and merging the PRs.

## Steps

### 1. Change the app and bump its version

BookTailor has a helper that keeps all three version files in sync:

```bash
cd ~/Source/booktailor
./scripts/set-version.sh 1.7.1
git add appinfo/info.xml package.json package-lock.json
git commit -m "Release 1.7.1"
```

For byebyemoneylist, raise `<version>` in `appinfo/info.xml` (and keep
`package.json` in sync), then commit.

The tag you push must equal the app's `appinfo/info.xml` version, or CI fails.

### 2. Tag and push - this starts the release

```bash
# booktailor
git tag v1.7.1 && git push origin main && git push origin v1.7.1

# or byebyemoneylist-ns
git tag v1.1.1 && git push origin main && git push origin v1.1.1
```

The app repo's `release.yml` builds the frontend and publishes
`<app>-<version>.tar.gz` plus `.sha256` to the GitHub Release. Wait for the run
to be green under **Actions**.

### 3. Point the homelab repo at the release

Either let the matching pin workflow open a PR, or edit
`infra/images/nextcloud/versions.env` directly:

```env
BYML_VERSION=1.1.0
BYML_SHA256=...
BOOKTAILOR_VERSION=1.7.1
BOOKTAILOR_SHA256=...
```

Merge that change to `main`. The pin workflows fetch the checksum from the
release `.sha256` asset, so the version and checksum never drift.

### 4. CI builds the image

Pushing `versions.env` to `main` starts `build-nextcloud-image.yml`. It
downloads both tarballs, verifies both checksums and `info.xml` versions, builds
the image, and pushes
`ghcr.io/rykhalskyi/homelab-nextcloud:sha-<homelab commit>`. Watch **Actions**.

### 5. Merge the pin PR

When the build succeeds, `update-nextcloud-image-pin.yml` opens a PR
(`bot/nextcloud-image-<short>`) that rewrites the image pin in
`infra/clusters/talos/apps/nextcloud/helmrelease.yaml` to
`sha-<commit>@sha256:<digest>`. Review and merge it - that is the step that makes
the new image deployable.

### 6. Flux rolls it out

Within its interval Flux applies the new `HelmRelease`; force it if you like:

```bash
flux reconcile kustomization apps -n flux-system --with-source
kubectl -n nextcloud rollout status deploy/nextcloud
```

On start the `before-starting` hook copies `/opt/booktailor` and
`/opt/byebyemoneylist` into `custom_apps/`. For each app whose `info.xml`
version differs from `installed_version`, it runs `occ app:enable`, which
applies that app's DB migrations.

## Your only manual steps

1. Push the app's `vX.Y.Z` tag (step 2).
2. Land the `versions.env` change on `main` (step 3).
3. Merge the image-pin PR (step 5).

Everything else runs itself.

## Verify

```bash
kubectl -n nextcloud exec -u www-data deploy/nextcloud -- \
  php /var/www/html/occ config:app:get byebyemoneylist installed_version
kubectl -n nextcloud exec -u www-data deploy/nextcloud -- \
  php /var/www/html/occ config:app:get booktailor installed_version
kubectl -n nextcloud get deploy nextcloud \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

## Optional: BookTailor Langfuse tracing

BookTailor reads `BOOKTAILOR_LANGFUSE_*` from the container environment. The
HelmRelease wires the in-cluster Langfuse web service and reads the public and
secret keys from an **optional** `booktailor` Secret in the `nextcloud`
namespace. Create it from the Langfuse project UI (see
`infra/clusters/talos/apps/nextcloud/booktailor-secret.example.yaml`):

```bash
kubectl -n nextcloud create secret generic booktailor \
  --from-literal=langfuse-public-key=pk-lf-... \
  --from-literal=langfuse-secret-key=sk-lf-...
```

Without the Secret the pod still starts and BookTailor simply runs with
Langfuse tracing and prompt fetching disabled.

## Notes

- The image tag is the **homelab** commit that bumped `versions.env`, not either
  app version. That commit is the immutable thing Flux pins.
- Changing an app repo alone does **nothing** until you release and re-pin; the
  tarballs are the artifacts, not the branches.
- Both release tarballs contain a top-level app directory (`booktailor/`,
  `byebyemoneylist/`) so the image build can extract them straight into the
  build context.
- `NEXTCLOUD_VERSION` in `versions.env` sets the base image for **both** apps.
  Bump it one major at a time; both apps support 31-35.
- The GHCR package `homelab-nextcloud` must be **public**, or the Pod needs an
  image pull secret.
- **Manual fallback** (no bot): read the digest from the build log ("Show the
  digest to pin"), then set the tag in `helmrelease.yaml` yourself.
- The pin workflows need **Settings -> Actions -> General -> Workflow
  permissions -> "Allow GitHub Actions to create and approve pull requests"**.
