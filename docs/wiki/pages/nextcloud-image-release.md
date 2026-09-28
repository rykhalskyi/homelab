---
tags: [nextcloud, k3s, byebyemoneylist, ci, github-actions, ghcr, flux, gitops, release, runbook]
date: 2026-09-28
source_count: 0
---

# Releasing a new Nextcloud image (byebyemoneylist app)

How to ship a new version of **Bye Bye Money List** into the Nextcloud image that
k3s runs. It is the same idea as [[Deploying site changes (GitOps)]], with one
extra step: the app source lives in a **different repo**
(`rykhalskyi/byebyemoneylist-ns`), so you publish a release there first, then
point the homelab repo at it.

See [[Nextcloud on k3s (custom image + Helm chart)]] for the one-time migration,
and [[Byebyemoneylist app integration (Nextcloud AIO)]] for the old AIO path.

## The chain

```text
byebyemoneylist-ns   change the app, bump <version>, push tag vX.Y.Z
                     release.yml builds the frontend and publishes
                     byebyemoneylist-X.Y.Z.tar.gz + .sha256
        |
        v
homelab              bump BYML_VERSION + BYML_SHA256 in
                     infra/nextcloud/versions.env, push to main
        |
        v
CI (homelab)         build-nextcloud-image.yml downloads + verifies the
                     tarball, builds FROM nextcloud:31-apache + app,
                     pushes ghcr.io/rykhalskyi/homelab-nextcloud:sha-<commit>
        |
        v
CI (homelab)         update-nextcloud-image-pin.yml opens a PR pinning the
                     digest in infra/k8s/apps/nextcloud/helmrelease.yaml
        |
        v
you                  merge the pin PR -> Flux reconciles -> new Pod; the
                     before-starting hook copies the app into custom_apps
```

The key idea: **the image is built from the release tarball, not from a branch.**
Nothing happens until you cut a release and bump the pin.

## Which workflow runs where

| Workflow | Repo | Starts itself? | Trigger |
|---|---|---|---|
| `release.yml` | byebyemoneylist-ns | yes | push a `v*` tag (or manual dispatch) |
| `update-byebyemoneylist-pin.yml` | homelab | yes (cron) | daily poll, or you run `make nc-app-pin` |
| `build-nextcloud-image.yml` | homelab | yes | push to `main` touching `infra/nextcloud/versions.env` (or the Dockerfile) |
| `update-nextcloud-image-pin.yml` | homelab | yes | after `Build Nextcloud image` succeeds |

You do **not** run any of these by hand. Your only manual actions are the three
marked below.

## Steps

### 1. Change the app and bump the version (app repo)

Edit the app, then raise `<version>` in `appinfo/info.xml` (for example to
`1.0.6`). The tag you push must equal that version, or CI fails.

```bash
cd ~/Source/byebyemoneylist-ns
# edit the app + appinfo/info.xml -> 1.0.6
git commit -am "Release 1.0.6"
```

### 2. Tag and push - this starts the release (app repo)

```bash
git tag v1.0.6
git push origin main
git push origin v1.0.6
```

`release.yml` starts automatically, builds the frontend, and publishes
`byebyemoneylist-1.0.6.tar.gz` + `.sha256` to the GitHub Release. Wait until the
run is green under **Actions**.

### 3. Point the homelab repo at the release

```bash
cd ~/Source/homelab
make nc-app-pin VERSION=1.0.6        # writes BYML_VERSION + BYML_SHA256
git add infra/nextcloud/versions.env
git commit -m "Pin byebyemoneylist v1.0.6"
git push origin main
```

`make nc-app-pin` needs no Docker and no server; it just copies the release's
`.sha256` hash into `versions.env`. (Or skip this and merge the bot's PR from
`update-byebyemoneylist-pin.yml`.)

### 4. CI builds the image

Pushing `versions.env` to `main` starts `build-nextcloud-image.yml`. It
downloads the tarball, verifies `BYML_SHA256`, builds the image, and pushes
`ghcr.io/rykhalskyi/homelab-nextcloud:sha-<homelab commit>`. Watch **Actions**.

### 5. Merge the pin PR

When the build succeeds, `update-nextcloud-image-pin.yml` opens a PR
(`bot/nextcloud-image-<short>`) that rewrites the image pin in
`infra/k8s/apps/nextcloud/helmrelease.yaml` to `sha-<commit>@sha256:<digest>`.
Review and merge it - that is the step that makes the new version deployable.

### 6. Flux rolls it out

Within its interval Flux applies the new `HelmRelease`; force it if you like:

```bash
flux reconcile kustomization apps -n flux-system --with-source
kubectl -n homelab rollout status deploy/nextcloud
```

On start the `before-starting` hook copies `/opt/byebyemoneylist` over
`custom_apps/byebyemoneylist`; because `installed_version` differs it runs
`occ app:enable`, which applies any DB migrations.

## Your only manual steps

1. Push the `vX.Y.Z` tag (step 2).
2. Land the `versions.env` change on `main` (step 3).
3. Merge the pin PR (step 5).

Everything else runs itself.

## Verify

```bash
kubectl -n homelab exec -u www-data deploy/nextcloud -- \
  php /var/www/html/occ config:app:get byebyemoneylist installed_version
kubectl -n homelab get deploy nextcloud \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

## Notes

- The image tag is the **homelab** commit that bumped `versions.env`, not the app
  version. That commit is the immutable thing Flux pins.
- Changing the app code alone does **nothing** until you release and re-pin; the
  tarball is the artifact, not the branch.
- `NEXTCLOUD_VERSION` in `versions.env` sets the base image. Bump it to move the
  Nextcloud major (must be >= what AIO ran; the app supports 31-35).
- The GHCR package `homelab-nextcloud` must be **public**, or the Pod needs an
  image pull secret.
- **Manual fallback** (no bot): read the digest from the build log ("Show the
  digest to pin"), then set the tag in `helmrelease.yaml` yourself.
- The pin workflow needs **Settings -> Actions -> General -> Workflow permissions
  -> "Allow GitHub Actions to create and approve pull requests"**.

## Status

The image pipeline (steps 1-5) is in place. Step 6 does not happen yet: the
Nextcloud `HelmRelease` is not wired into Flux (`infra/k8s/apps/kustomization.yaml`
does not list `nextcloud`) until the migration cutover in
[[Nextcloud on k3s (custom image + Helm chart)]].
