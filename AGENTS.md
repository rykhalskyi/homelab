# AGENTS.md

Guidance for agents working in this repository (the `homelab` project).

## What this repo is

- `infra/` — deployable stacks. `nginx/` is the static homelab landing page;
  `nextcloud/`, `forgejo/`, `pihole/`, and `laya-api/` (a pinned prebuilt image
  deployed via `infra/laya-api/deploy.sh`) are Docker Compose; `infra/k8s/` is
  the k3s cluster (apps + infrastructure) reconciled by Flux.
- `docs/wiki/` — the DevOps wiki, authored in Markdown. It is **served by
  Pullini** at `https://wiki.otakeessen.com`, not built into the nginx site. See
  `docs/wiki/AGENTS.md` for the wiki schema and ingest workflow.
- `infra/nginx/html/` — the static landing page (`index.html` + assets). It has
  no build step.
- `node-one` (Ubuntu, HP ProDesk 400 G3 DM) runs the stacks; it deploys with
  `git pull` against the `main` branch and Flux for the k8s apps.

## Golden rule: the wiki is Markdown only

There is **no HTML wiki generation**. `docs/wiki/` stays as Markdown, and
Pullini (a read-only Git-backed wiki browser) renders it at
`https://wiki.otakeessen.com`. Do not add a generator or commit generated HTML
into `infra/nginx/html/`.

- Edit wiki content in `docs/wiki/` directly; no rebuild step.
- The landing page links out to `https://wiki.otakeessen.com` — keep it that
  way rather than embedding wiki pages.

## Other common commands

```bash
make serve                     # preview the site at http://localhost:8080
cd infra/nginx && docker compose up -d   # run nginx (serves ./html)
cd infra/nextcloud && docker compose up -d
make laya-api-deploy            # deploy/update the pinned laya-api image
make laya-api-pin VERSION=x.y.z  # pin a new laya-api release
```

## Conventions

- The site is plain HTML/CSS/JS with no build step and no runtime deps — keep
  it that way. Do not introduce a framework or external CDN.
- Landing page: `infra/nginx/html/index.html` (services + `#architecture`
  sections). Host facts live in the architecture card. It links to the wiki at
  `https://wiki.otakeessen.com`.
- Styles: `infra/nginx/html/assets/css/style.css` (CSS variables at the top,
  light + dark themes).
- Keep secrets out of the repo — `.env`, `*.pem`, `*.key`, `.cloudflared/` are
  gitignored. Never commit credentials.
