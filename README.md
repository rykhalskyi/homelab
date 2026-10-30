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

- `infra/clusters/` — k8s clusters: `talos/` (the live cluster, reconciled by
  Flux). The retired k3s tree (`k8s/`) was removed.
- `infra/phase1/` — phase-1 Docker Compose stacks: `nginx/`, `nextcloud/`,
  `forgejo/`, `pihole/`, `laya-api/`.
- `infra/images/` — build sources for the cluster images: `nginx/` (site content +
  Dockerfile) and `nextcloud/` (Dockerfile + pinned versions).
- `infra/pi3/` — Raspberry Pi 3 config (VPN + dashboard), not in the cluster.
- `docs/wiki/` — the DevOps wiki, written in Markdown and served by Pullini at
  `https://wiki.otakeessen.com`.
- `infra/images/nginx/html/` — the static homelab landing page.

## Site & wiki

The landing page is plain HTML/CSS/JS served as-is by the phase-1 nginx Compose
stack (`infra/images/nginx/` bind-mounted; no image build). The
wiki Markdown in `docs/wiki/` is served directly by Pullini at
`https://wiki.otakeessen.com` — no HTML build step.

```bash
make serve    # preview the landing page at http://localhost:8080
```

See `infra/images/nginx/README.md` for details.

