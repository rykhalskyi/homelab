# DevOps Wiki — Schema

This wiki documents DevOps how-tos and infrastructure for my home server
(`node-one`): Docker, networking, reverse proxies/tunnels, and services.

## Roles

- **User** curates what to document, directs analysis, asks questions.
- **Agent** owns the wiki: writes/updates pages, keeps index & log current,
  never edits raw sources.

## Location

Lives inside the homelab project at `~/Source/homelab/docs/wiki/`.

## Layout

```
~/Source/homelab/docs/wiki/
├── AGENTS.md          # this schema
├── index.md           # content-oriented catalog of every page
├── log.md             # chronological, append-only record
└── pages/
    ├── cloudflare-tunnel-nginx.md          # first guide
    ├── cloudflared-reconfigure-hostname.md
    └── ...                                 # more guides/notes as the wiki grows
```

## Conventions

- Every page gets YAML frontmatter: `tags`, `date`, `source_count`.
- Use wikilinks (`[[Page Name]]`) or relative links for cross-references.
- Guides should be **copy-paste runnable**: full commands, real file paths,
  and a "verify" step for each stage.
- Record the working setup (host, paths, ports, domain) so it can be rebuilt.
- When new info contradicts an existing page, update the page and note the
  supersession — never leave stale claims next to newer ones.

## Workflows

- **Ingest:** write/update `pages/*.md` → update `index.md` → append to `log.md`.
- **Query:** read `index.md` first, drill into pages, cite them in the answer.
- **Lint:** check contradictions, stale claims, orphans, missing cross-refs, gaps.

## Operations log

Record every ingest/query/lint in `log.md` with entries starting
`## [YYYY-MM-DD] <action> | <title>`.
