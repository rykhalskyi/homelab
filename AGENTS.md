# AGENTS.md

Guidance for agents working in this repository (the `homelab` project).

## What this repo is

- `infra/` — deployable stacks, grouped by kind:
  - `infra/clusters/k8s/` — the k8s cluster: the Flux entrypoint (`flux-system/`)
    plus `apps/` and `infrastructure/`, reconciled by Flux. `infra/clusters/talos/`
    is a placeholder for the next cluster.
  - `infra/phase1/` — phase-1 Docker Compose stacks: `nginx/`, `nextcloud/`,
    `forgejo/`, `pihole/`, and `laya-api/` (a pinned prebuilt image deployed via
    `infra/phase1/laya-api/deploy.sh`).
  - `infra/images/` — build sources for the k8s images: `nginx/` (site content +
    Dockerfile) and `nextcloud/` (Dockerfile + `versions.env`).
  - `infra/pi3/` — Raspberry Pi 3 config (VPN + dashboard); not part of the
    cluster.
- `docs/wiki/` — the DevOps wiki, authored in Markdown. It is **served by
  Pullini** at `https://wiki.otakeessen.com`, not built into the nginx site. See
  `docs/wiki/AGENTS.md` for the wiki schema and ingest workflow.
- `infra/images/nginx/html/` — the static landing page (`index.html` + assets).
  It has no build step.
- `node-one` (Ubuntu, HP ProDesk 400 G3 DM) is a node of the `k8s` cluster and
  runs the phase-1 Compose stacks; it deploys with `git pull` against the `main`
  branch, and Flux reconciles the k8s apps.

## Golden rule: the wiki is Markdown only

There is **no HTML wiki generation**. `docs/wiki/` stays as Markdown, and
Pullini (a read-only Git-backed wiki browser) renders it at
`https://wiki.otakeessen.com`. Do not add a generator or commit generated HTML
into `infra/images/nginx/html/`.

- Edit wiki content in `docs/wiki/` directly; no rebuild step.
- The landing page links out to `https://wiki.otakeessen.com` — keep it that
  way rather than embedding wiki pages.

## Other common commands

```bash
make serve                     # preview the site at http://localhost:8080
cd infra/phase1/nginx && docker compose up -d   # run nginx (serves ../../images/nginx/html)
cd infra/phase1/nextcloud && docker compose up -d
make laya-api-deploy            # deploy/update the pinned laya-api image
make laya-api-pin VERSION=x.y.z  # pin a new laya-api release
```

## Git & pull requests

- **Never merge a PR to `main`, and never push directly to `main`, on the user's
  behalf.** Open the pull request and stop; the user reviews and merges it
  themselves. (This includes not using `gh pr merge`, even with `--admin`.)
- Committing to a feature branch and pushing that branch (to open a PR) is fine.

## Conventions

- The site is plain HTML/CSS/JS with no build step and no runtime deps — keep
  it that way. Do not introduce a framework or external CDN.
- Landing page: `infra/images/nginx/html/index.html` (services + `#architecture`
  sections). Host facts live in the architecture card. It links to the wiki at
  `https://wiki.otakeessen.com`.
- Styles: `infra/images/nginx/html/assets/css/style.css` (CSS variables at the
  top, light + dark themes).
- Keep secrets out of the repo — `.env`, `*.pem`, `*.key`, `.cloudflared/` are
  gitignored. Never commit credentials.
