---
tags: [nginx, site, deploy, compose, phase1, github]
date: 2026-10-01
source_count: 0
---

# Deploying site changes (GitOps)

How to publish a change to the homelab landing page. The page is plain
HTML/CSS/JS under `infra/images/nginx/html/`; the phase-1 nginx Compose stack
bind-mounts it, so publishing is just **edit → commit → `git pull`**.

> **The old k3s image flow is retired.** The landing page used to be built into
> `ghcr.io/rykhalskyi/homelab-nginx` and rolled out by Flux on the k3s cluster.
> That cluster and `infra/clusters/k8s/` were removed on 2026-10-30, along with
> `build-nginx-image.yml` and `update-nginx-image-pin.yml`. There is no image
> build or pin PR anymore.

The wiki is **not** part of this. It is Markdown under `docs/wiki/` served by
Pullini at `https://wiki.otakeessen.com` — editing a page needs no build.

## Publish a landing-page change

1. **Edit the content** in `infra/images/nginx/html/**` (e.g. `index.html`).

2. **Commit and push to `main`**
   ```bash
   git add infra/images/nginx
   git commit -m "Update site: <what changed>"
   git push origin main
   ```

3. **Pull on the host.** The phase-1 Compose stack bind-mounts the content, so a
   `git pull` is all that is needed:
   ```bash
   git pull
   # only if the stack is not already running:
   cd infra/phase1/nginx && docker compose up -d
   ```

4. **Verify**
   ```bash
   curl -sI http://localhost/
   ```

## Preview locally

```bash
make serve    # http://localhost:8080
```

## Notes

- **Service cards:** edit the `<a class="card">` blocks in `html/index.html`.
- **Architecture facts:** the `#architecture` section of `html/index.html`.
- **Styles:** the CSS variables at the top of `html/assets/css/style.css`
  (light + dark themes).
- The wiki is **not** built into the site; it links out to Pullini.
