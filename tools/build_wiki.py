#!/usr/bin/env python3
"""Build the DevOps wiki into static HTML for the nginx homelab site.

Reads Markdown from docs/wiki/ (index.md, log.md, pages/*.md), converts it to
HTML using only the standard library, and writes the result to
infra/nginx/html/wiki/. The generated files are committed so `git pull` on the
server is enough to publish updates.

Usage:
    python3 tools/build_wiki.py
"""

from __future__ import annotations

import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
WIKI_DIR = ROOT / "docs" / "wiki"
PAGES_DIR = WIKI_DIR / "pages"
OUT_DIR = ROOT / "infra" / "nginx" / "html" / "wiki"

SITE_NAME = "Homelab Otakeessen"


# --------------------------------------------------------------------------- #
# Markdown parsing helpers
# --------------------------------------------------------------------------- #

LIST_RE = re.compile(r"^(\s*)([-*+]|\d+\.)\s+(.*)$")
WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
CODE_RE = re.compile(r"`([^`]+)`")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
HR_RE = re.compile(r"^(-{3,}|\*{3,}|_{3,})\s*$")


def esc(text: str) -> str:
    return html.escape(text, quote=True)


def split_frontmatter(text: str) -> tuple[dict[str, str], str]:
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            fm: dict[str, str] = {}
            for line in lines[1:i]:
                if ":" in line:
                    key, value = line.split(":", 1)
                    fm[key.strip()] = value.strip()
            return fm, "\n".join(lines[i + 1:]).lstrip("\n")
    return {}, text


def first_heading(body: str) -> str:
    for line in body.split("\n"):
        m = HEADING_RE.match(line)
        if m and len(m.group(1)) == 1:
            return m.group(2).strip()
    return "Untitled"


def rewrite_link(url: str) -> str:
    if re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I) or url.startswith("#"):
        return url
    if url.endswith(".md"):
        url = url[:-3] + ".html"
    url = re.sub(r"^(\./)?pages/", "", url)
    return url


def render_inline(text: str, linkmap: dict[str, str]) -> str:
    codes: list[str] = []

    def stash(m: re.Match[str]) -> str:
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"

    text = CODE_RE.sub(stash, text)
    text = esc(text)

    text = LINK_RE.sub(
        lambda m: f'<a href="{rewrite_link(m.group(2))}">{m.group(1)}</a>',
        text,
    )

    def wikilink(m: re.Match[str]) -> str:
        name = m.group(1).strip()
        slug = linkmap.get(name)
        if slug:
            return f'<a href="{slug}.html">{name}</a>'
        return f'<span class="wl-missing" title="page not written yet">{name}</span>'

    text = WIKILINK_RE.sub(wikilink, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)

    def restore(m: re.Match[str]) -> str:
        return f"<code>{esc(codes[int(m.group(1))])}</code>"

    return re.sub(r"\x00(\d+)\x00", restore, text)


def is_block_start(line: str) -> bool:
    if not line.strip():
        return True
    if line.startswith("```") or line.startswith(">"):
        return True
    if HEADING_RE.match(line) or HR_RE.match(line):
        return True
    if LIST_RE.match(line):
        return True
    return False


def split_row(line: str) -> list[str]:
    row = line.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|"):
        row = row[:-1]
    return [cell.strip() for cell in row.split("|")]


def parse_table(lines: list[str], i: int, linkmap: dict[str, str]) -> tuple[str, int]:
    header = split_row(lines[i])
    i += 2  # skip header + separator
    rows = []
    while i < len(lines) and "|" in lines[i] and lines[i].strip():
        rows.append(split_row(lines[i]))
        i += 1

    head = "".join(f"<th>{render_inline(c, linkmap)}</th>" for c in header)
    body = ""
    for row in rows:
        cells = "".join(f"<td>{render_inline(c, linkmap)}</td>" for c in row)
        body += f"<tr>{cells}</tr>"

    table = f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"
    return table, i


def parse_list(lines: list[str], i: int, linkmap: dict[str, str]) -> tuple[str, int]:
    base_indent = len(LIST_RE.match(lines[i]).group(1))  # type: ignore[union-attr]
    ordered = bool(re.match(r"^\s*\d+\.", lines[i]))
    tag = "ol" if ordered else "ul"
    items: list[str] = []

    while i < len(lines):
        m = LIST_RE.match(lines[i])
        if not m:
            if items and lines[i].strip() and not is_block_start(lines[i]):
                items[-1] += " " + render_inline(lines[i].strip(), linkmap)
                i += 1
                continue
            break
        indent = len(m.group(1))
        if indent < base_indent:
            break
        if indent > base_indent:
            nested, i = parse_list(lines, i, linkmap)
            if items:
                items[-1] += nested
            continue

        content = m.group(3)
        checkbox = re.match(r"^\[( |x|X)\]\s+(.*)$", content)
        if checkbox:
            checked = " checked" if checkbox.group(1).lower() == "x" else ""
            inner = f'<input type="checkbox" disabled{checked}> ' + render_inline(
                checkbox.group(2), linkmap
            )
        else:
            inner = render_inline(content, linkmap)
        items.append(inner)
        i += 1

    body = "".join(f"<li>{item}</li>" for item in items)
    return f"<{tag}>{body}</{tag}>", i


def render_blocks(body: str, linkmap: dict[str, str]) -> str:
    lines = body.split("\n")
    out: list[str] = []
    i, total = 0, len(lines)

    while i < total:
        line = lines[i]

        if not line.strip():
            i += 1
            continue

        fence = re.match(r"^```(\w*)", line)
        if fence:
            lang = fence.group(1)
            i += 1
            buf = []
            while i < total and not lines[i].startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            cls = f' class="language-{lang}"' if lang else ""
            out.append(f"<pre><code{cls}>{esc(chr(10).join(buf))}</code></pre>")
            continue

        heading = HEADING_RE.match(line)
        if heading:
            level = len(heading.group(1))
            out.append(
                f"<h{level}>{render_inline(heading.group(2), linkmap)}</h{level}>"
            )
            i += 1
            continue

        if HR_RE.match(line):
            out.append("<hr>")
            i += 1
            continue

        if line.startswith(">"):
            buf = []
            while i < total and lines[i].startswith(">"):
                buf.append(re.sub(r"^>\s?", "", lines[i]))
                i += 1
            out.append(
                "<blockquote>"
                + render_blocks("\n".join(buf), linkmap)
                + "</blockquote>"
            )
            continue

        if (
            "|" in line
            and i + 1 < total
            and "|" in lines[i + 1]
            and re.match(r"^\s*\|?[\s:|-]+\|[\s:|-]*$", lines[i + 1])
        ):
            table, i = parse_table(lines, i, linkmap)
            out.append(table)
            continue

        if LIST_RE.match(line):
            rendered, i = parse_list(lines, i, linkmap)
            out.append(rendered)
            continue

        buf = [line]
        i += 1
        while i < total and not is_block_start(lines[i]):
            buf.append(lines[i])
            i += 1
        out.append("<p>" + render_inline(" ".join(buf), linkmap) + "</p>")

    return "\n".join(out)


# --------------------------------------------------------------------------- #
# Page assembly
# --------------------------------------------------------------------------- #

HEADER = """<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title} · {site}</title>
  <meta name="description" content="Homelab DevOps wiki and runnable how-tos.">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/assets/css/style.css">
  <meta name="color-scheme" content="light dark">
</head>
<body>
  <header class="site-header">
    <div class="container header-inner">
      <a class="brand" href="/">
        <img class="brand-mark" src="/assets/img/logo.svg" alt="" width="32" height="32">
        <span class="brand-name">Homelab Otakeessen</span>
      </a>
      <nav class="site-nav" aria-label="Main">
        <a href="/#services">Services</a>
        <a href="/#architecture">Architecture</a>
        <a href="/wiki/" class="is-active">Wiki</a>
      </nav>
      <button id="theme-toggle" class="theme-toggle" type="button" aria-label="Toggle color theme">
        <svg class="icon-sun" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">
          <circle cx="12" cy="12" r="4"></circle>
          <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"></path>
        </svg>
        <svg class="icon-moon" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">
          <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"></path>
        </svg>
      </button>
    </div>
  </header>
  <main>
"""

FOOTER = """  </main>
  <footer class="site-footer">
    <div class="container footer-inner">
      <span>&copy; <span id="year">2026</span> Homelab Otakeessen</span>
      <span class="muted">Built with plain HTML &amp; CSS</span>
    </div>
  </footer>
  <script src="/assets/js/main.js" defer></script>
</body>
</html>
"""


def page_shell(title: str, content: str, breadcrumb: str) -> str:
    meta = ""
    if breadcrumb:
        meta = f'        <p class="wiki-crumb">{breadcrumb}</p>\n'
    article = (
        '    <div class="container section">\n'
        f'{meta}'
        '      <article class="panel wiki-article">\n'
        f"{content}\n"
        "      </article>\n"
        "    </div>\n"
    )
    return (
        HEADER.format(title=esc(title), site=esc(SITE_NAME))
        + article
        + FOOTER
    )


def load_pages() -> list[dict[str, str]]:
    pages = []
    for path in sorted(PAGES_DIR.glob("*.md")):
        raw = path.read_text(encoding="utf-8")
        fm, body = split_frontmatter(raw)
        pages.append(
            {
                "slug": path.stem,
                "title": first_heading(body),
                "body": body,
                "fm": fm,
            }
        )
    return pages


def build() -> list[pathlib.Path]:
    if not WIKI_DIR.is_dir():
        sys.exit(f"wiki directory not found: {WIKI_DIR}")

    pages = load_pages()
    linkmap = {p["title"]: p["slug"] for p in pages}

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    written: list[pathlib.Path] = []

    for page in pages:
        tags = page["fm"].get("tags", "").strip("[]")
        date = page["fm"].get("date", "")
        chips = "".join(
            f'<span class="tag">{esc(t.strip())}</span>'
            for t in tags.split(",")
            if t.strip()
        )
        crumb = (
            '<a href="index.html">&larr; Wiki index</a>'
            + (f'<span class="wiki-date">{esc(date)}</span>' if date else "")
            + (f'<span class="tag-list">{chips}</span>' if chips else "")
        )
        content = render_blocks(page["body"], linkmap)
        html_out = page_shell(page["title"], content, crumb)
        target = OUT_DIR / f"{page['slug']}.html"
        target.write_text(html_out, encoding="utf-8")
        written.append(target)

    index_raw = (WIKI_DIR / "index.md").read_text(encoding="utf-8")
    _, index_body = split_frontmatter(index_raw)
    index_title = first_heading(index_body)
    index_content = render_blocks(index_body, linkmap)
    index_content += (
        '\n<p class="wiki-history">'
        '<a href="log.html">Wiki history &rarr;</a></p>'
    )
    index_html = page_shell(index_title, index_content, "")
    (OUT_DIR / "index.html").write_text(index_html, encoding="utf-8")
    written.append(OUT_DIR / "index.html")

    log_path = WIKI_DIR / "log.md"
    if log_path.is_file():
        _, log_body = split_frontmatter(log_path.read_text(encoding="utf-8"))
        log_title = first_heading(log_body)
        log_content = render_blocks(log_body, linkmap)
        log_html = page_shell(
            log_title,
            log_content,
            '<a href="index.html">&larr; Wiki index</a>',
        )
        (OUT_DIR / "log.html").write_text(log_html, encoding="utf-8")
        written.append(OUT_DIR / "log.html")

    return written


def main() -> None:
    written = build()
    for path in written:
        print(f"wrote {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
