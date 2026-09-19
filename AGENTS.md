# AGENTS.md

Guidance for agents working in this repository (the `homelab` project).

## What this repo is

- `infra/` — deployable Docker Compose stacks: `nginx/` (the static homelab
  site) and `nextcloud/`.
- `docs/wiki/` — the DevOps wiki, authored in Markdown. See
  `docs/wiki/AGENTS.md` for the wiki schema and ingest workflow.
- `infra/nginx/html/` — the served site. `wiki/` inside it is **generated**.
- `tools/build_wiki.py` — stdlib-only Markdown → HTML generator.
- `node-one` (Ubuntu, HP ProDesk 400 G3 DM) runs the stacks; it deploys with
  `git pull` against the `main` branch.

## Golden rule: rebuild the site after touching the wiki

After **any** change under `docs/wiki/` (adding or editing pages, `index.md`,
or `log.md`), regenerate the published site and commit the output:

```bash
make wiki          # == python3 tools/build_wiki.py
```

Then commit both the Markdown sources and the regenerated
`infra/nginx/html/wiki/*.html`. Both are versioned; the site deploys by
`git pull`.

- **Never edit `infra/nginx/html/wiki/*.html` by hand** — the next build
  overwrites it. Edit Markdown in `docs/wiki/` instead.
- If `index.md` gains a new page link, the generator rewrites `.md` links and
  resolves `[[wikilinks]]` automatically; just rerun `make wiki`.
- Run `make wiki` before finishing a task that changed wiki content, and verify
  it wrote the expected files (the script prints each path).

## Other common commands

```bash
make serve                     # preview the site at http://localhost:8080
cd infra/nginx && docker compose up -d   # run nginx (serves ./html)
cd infra/nextcloud && docker compose up -d
```

## Conventions

- The site is plain HTML/CSS/JS with no build step and no runtime deps — keep
  it that way. Do not introduce a framework or external CDN.
- Landing page: `infra/nginx/html/index.html` (services + `#architecture`
  sections). Host facts live in the architecture card.
- Styles: `infra/nginx/html/assets/css/style.css` (CSS variables at the top,
  light + dark themes).
- Wiki generators only support the Markdown subset in `docs/wiki/` (headings,
  lists/checkboxes, tables, fenced code, blockquotes, bold, inline code,
  links, `[[wikilinks]]`). Extend `tools/build_wiki.py` if you need more.
- Keep secrets out of the repo — `.env`, `*.pem`, `*.key`, `.cloudflared/` are
  gitignored. Never commit credentials.
