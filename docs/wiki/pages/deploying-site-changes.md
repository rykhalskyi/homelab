---
tags: [nginx, k3s, flux, gitops, ghcr, ci, deploy]
date: 2026-10-01
source_count: 0
---

# Deploying site changes (GitOps)

How to publish a change to the homelab landing page now that the site runs as an
image on k3s and Flux reconciles this repo. This is the day-to-day flow; see
[[k3s + GitOps: nginx and cloudflared (phase 2.1)]] for the one-time setup.

The chain: **edit `infra/nginx/html/**` → push to `main` → CI builds an image →
a bot opens a pin PR → merge → Flux rolls out the new Pod.**

The wiki is **not** part of this. It is Markdown under `docs/wiki/` served by
Pullini at `https://wiki.otakeessen.com` — editing a page needs no build and no
image ([[Pullini on k3s (postgresql + Flux)]]).

## What triggers an nginx rebuild

The `k3s/nginx 1/2 Build nginx site image` workflow runs on a push to `main` that
changes either of these paths:

| Path | What it is |
|------|------------|
| `infra/nginx/**` | the site itself (`html/`, `conf.d/`, `Dockerfile`) |
| `.github/workflows/build-nginx-image.yml` | the workflow itself |

Wiki-only changes under `docs/wiki/**` no longer rebuild the image.

## Publish a landing-page change

1. **Edit the content** in `infra/nginx/html/**` (e.g. `index.html`, assets).

2. **Commit and push to `main`**
   ```bash
   git add infra/nginx
   git commit -m "Update site: <what changed>"
   git push origin main
   ```

3. **Let CI build the image.** Watch the `k3s/nginx 1/2 Build nginx site image`
   run under **Actions**. It pushes
   `ghcr.io/rykhalskyi/homelab-nginx:sha-<commit>`.

4. **Merge the pin PR.** On build success, `k3s/nginx 2/2 Pin nginx site image`
   opens a PR (`bot/nginx-image-<short>`) that rewrites the `image:` line in
   `infra/k8s/apps/nginx/deployment.yaml` to the new tag + digest. Review and
   merge it — this is the step that actually makes the change live.

5. **Flux rolls it out** (within its 10m interval), or force it:
   ```bash
   flux reconcile kustomization apps -n flux-system
   kubectl -n homelab rollout status deploy/nginx
   ```

## Publish a wiki change

Edit Markdown in `docs/wiki/` (and keep `index.md` + `log.md` current), then
commit and push. Nothing is generated; Pullini reads the repository.

## Verify

```bash
kubectl -n homelab get deploy nginx \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
kubectl -n homelab logs deploy/nginx --tail=10
curl -sI https://homelab.otakeessen.com
```

## Notes

- The image is built from the **CI commit**, so the pin PR is what moves the
  cluster; pushing content alone does nothing until the pin lands.
- Non-site changes (for example `infra/k8s/**` or `docs/wiki/**`) do not rebuild
  the image.
- **Manual fallback** (no bot): read the digest from the build log ("Show the
  digest to pin"), then edit `deployment.yaml` yourself:
  `image: ghcr.io/rykhalskyi/homelab-nginx:sha-<commit>@sha256:<digest>`.
- The pin workflow needs **Settings → Actions → General → Workflow permissions →
  "Allow GitHub Actions to create and approve pull requests"**. Without it the
  run fails at "create pull request" (the branch is still pushed).
