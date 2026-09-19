# Homelab

## About

**Homelab** is my personal infrastructure project — a real, running home lab I
use to learn and practice modern operations end to end.

It covers a range of topics:

- **Servers** — physical and virtual hosts, their setup, hardening, and upkeep.
- **Hosting** — self-hosted services, networking, DNS, and exposing services
  safely (reverse proxies, Cloudflare tunnels).
- **Containers & orchestrators** — Docker and Compose today, moving toward
  Kubernetes as the lab grows.
- **GitOps** — infrastructure as code: Git is the single source of truth, and
  every machine is configured by pulling from it.

Everything here is developed in the form of my home lab: servers that manage
my internal network and expose a small number of resources publicly.

## Repository layout

- `infra/` — deployable service stacks (Docker Compose): `nginx/`, `nextcloud/`.
- `docs/wiki/` — the DevOps wiki, written in Markdown.
- `infra/nginx/html/` — the static homelab site (landing page + generated wiki).

## Site & wiki

The site is plain HTML/CSS/JS served by nginx (`infra/nginx/`). The wiki
Markdown in `docs/wiki/` is converted to static pages under
`infra/nginx/html/wiki/`:

```bash
make wiki     # build the wiki into the site
make serve    # preview at http://localhost:8080
```

Generated wiki HTML is committed, so `git pull` on `node-one` is enough to
publish. See `infra/nginx/README.md` for details.

