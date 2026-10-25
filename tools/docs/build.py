#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
# ///
"""Build the documentation site from docs/*.md, and check it.

    uv run tools/docs/build.py            # build into tmp/site/, fail on any finding
    uv run tools/docs/build.py --serve    # the same, then serve it on http://127.0.0.1:8000/

The markdown files stay where they are (README, the launchers and `para` point at
docs/*.md), and the site is generated from them, so nothing is written twice.
The one-line installers (tools/launcher/install.sh and install.ps1) are copied
to the site's root with the commit being built written into them, so the
published script always clones the code it was published with.
Every URL in the output is relative, so the site works from any base path (a
GitHub project page under /parastudio/) and from a plain static server.

The build fails (exit 1, one line per finding) on: a docs page missing from NAV
or a NAV entry with no page, a broken relative link or #anchor (README.md's
included), a missing image, an image without alt text, headings out of order,
and anything that looks like a local path, a tailnet address or an email
address. docs/site.md has why it is built this way.
"""

from __future__ import annotations

import argparse
import functools
import html
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote

from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
IMG = DOCS / "img"
THEME = Path(__file__).resolve().parent / "theme"
FONTS = ROOT / "tools" / "para" / "studio" / "fonts"
REPO_URL = "https://github.com/PDepaula/parastudio"
# The one-line installers, published at the site's root: (source, the empty commit line in it, the
# stamped line). The build writes the commit it is built from into that one line and changes
# nothing else; .github/scripts/installer-copy-check.sh checks the published copies against this.
INSTALLERS = [
    (ROOT / "tools" / "launcher" / "install.sh", 'PARASTUDIO_COMMIT=""', 'PARASTUDIO_COMMIT="{sha}"'),
    (ROOT / "tools" / "launcher" / "install.ps1", "  $PARASTUDIO_COMMIT = ''", "  $PARASTUDIO_COMMIT = '{sha}'"),
]
SITE_URL = "https://pdepaula.github.io/parastudio/"

# The left navigation: (group, [(file in docs/, label)]). Every docs/*.md must
# be here exactly once; the build fails otherwise. Order is reading order (the
# previous/next links at the foot of each page follow it).
NAV: list[tuple[str, list[tuple[str, str]]]] = [
    ("Start here", [
        ("index.md", "Welcome"),
        ("install.md", "Install with one line"),
        ("start.md", "Set up from a terminal"),
    ]),
    ("Using Studio", [
        ("studio.md", "The Studio page"),
    ]),
    ("Platforms", [
        ("mac.md", "Mac"),
        ("windows.md", "Windows"),
        ("windows-first-game.md", "Windows, step by step"),
        ("linux.md", "Linux"),
        ("platforms.md", "What was checked where"),
    ]),
    ("Make a game", [
        ("para.md", "The para CLI"),
        ("engine.md", "The engine"),
        ("art.md", "Art"),
        ("testing.md", "Testing"),
        ("web.md", "Publish to the web"),
    ]),
    ("Roadmap", [
        ("roadmap.md", "Roadmap"),
    ]),
    ("For maintainers", [
        ("studio-maintainers.md", "Studio internals"),
        ("site.md", "This site"),
    ]),
]

# What must never be published. Home folders are allowed only with a
# placeholder name (docs say /Users/you/...).
PLACEHOLDER_USERS = {"you", "YOU", "<you>", "user", "USER", "<user>", "<name>", "name", "runner", "$USER", "%USERNAME%"}
PRIVATE_PATTERNS = [
    ("local path", re.compile(r"/(?:home|Users)/([^/\s`'\")\]]+)")),
    ("local path", re.compile(r"[A-Za-z]:\\+Users\\+([^\\\s`'\")\]]+)")),
    ("tailnet address", re.compile(r"\b[\w-]+(?:\.[\w-]+)*\.ts\.net\b", re.I)),
    ("tailnet address", re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b")),
    ("email address", re.compile(r"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[a-z]{2,}\b", re.I)),
]
ALLOWED_EMAIL_DOMAINS = ("example.com", "example.org", "users.noreply.github.com")


@dataclass
class Page:
    file: str               # e.g. "studio.md"
    label: str              # the NAV label
    group: str
    src: Path
    text: str = ""
    title: str = ""
    slugs: set[str] = field(default_factory=set)
    headings: list[tuple[int, str, str]] = field(default_factory=list)  # (level, text, id)
    body: str = ""
    sections: list[dict] = field(default_factory=list)                # the search index's rows

    @property
    def out(self) -> str:
        return self.file[:-3] + ".html"

    @property
    def title_plain(self) -> str:
        return self.title.replace("`", "")


class Findings(list):
    def add(self, where: str, msg: str) -> None:
        self.append(f"{where}: {msg}")


def markdown() -> MarkdownIt:
    return MarkdownIt("commonmark", {"html": True}).enable(["table", "strikethrough"])


def inline_text(tok) -> str:
    """The plain text of an inline token (what GitHub slugs a heading from)."""
    out = []
    for c in tok.children or []:
        if c.type in ("text", "code_inline"):
            out.append(c.content)
        elif c.type in ("softbreak", "hardbreak"):
            out.append(" ")
        elif c.type == "image":
            out.append(c.content)
    return "".join(out)


def github_slug(text: str, seen: dict[str, int]) -> str:
    """GitHub's heading anchor: lowercase, punctuation dropped, spaces to dashes, -1/-2 for repeats."""
    s = unicodedata.normalize("NFKC", text).strip().lower()
    s = "".join(ch for ch in s if ch in " -_" or unicodedata.category(ch)[0] in "LN")
    s = s.replace(" ", "-")
    n = seen.get(s, 0)
    seen[s] = n + 1
    return s if n == 0 else f"{s}-{n}"


def private_hits(text: str) -> list[str]:
    hits = []
    for kind, pat in PRIVATE_PATTERNS:
        for m in pat.finditer(text):
            if kind == "local path" and m.group(1) in PLACEHOLDER_USERS:
                continue
            if kind == "email address" and m.group(0).lower().endswith(ALLOWED_EMAIL_DOMAINS):
                continue
            line = text.count("\n", 0, m.start()) + 1
            # Only the first characters: a CI log is public, so it must not repeat what it found.
            hits.append(f"line {line}: {kind} ({m.group(0)[:3]}…)")
    return hits


def png_size(path: Path) -> tuple[int, int] | None:
    """A PNG's width and height from its header, so the page keeps its layout while images load."""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
    except OSError:
        return None
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def is_external(href: str) -> bool:
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", href)) or href.startswith("//")


def tracked(path: Path) -> bool:
    """A repo path a GitHub link can show: it exists and git does not ignore it."""
    if not path.exists():
        return False
    try:
        r = subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(path)], capture_output=True)
        return r.returncode != 0
    except OSError:
        return True


class Site:
    def __init__(self) -> None:
        self.md = markdown()
        self.findings = Findings()
        self.pages: dict[str, Page] = {}
        for group, items in NAV:
            for file, label in items:
                self.pages[file] = Page(file, label, group, DOCS / file)
        self.order = [p for p in self.pages.values()]
        self.readme_slugs: set[str] = set()

    # --- pass 1: titles and anchors ---------------------------------------
    def scan(self) -> None:
        on_disk = {p.name for p in DOCS.glob("*.md")}
        for f in sorted(on_disk - set(self.pages)):
            self.findings.add(f"docs/{f}", "not in the site's navigation (add it to NAV in tools/docs/build.py)")
        for f in sorted(set(self.pages) - on_disk):
            self.findings.add("tools/docs/build.py", f"NAV lists docs/{f}, which does not exist")
            del self.pages[f]
        self.order = [p for p in self.order if p.file in self.pages]
        for p in self.order:
            p.text = p.src.read_text(encoding="utf-8")
            p.headings = self.headings_of(p.text)
            p.slugs = {h[2] for h in p.headings}
            p.title = next((h[1] for h in p.headings if h[0] == 1), p.label)
        self.readme_slugs = {h[2] for h in self.headings_of((ROOT / "README.md").read_text(encoding="utf-8"))}

    def headings_of(self, text: str) -> list[tuple[int, str, str]]:
        seen: dict[str, int] = {}
        toks = self.md.parse(text)
        out = []
        for i, t in enumerate(toks):
            if t.type == "heading_open":
                txt = inline_text(toks[i + 1])
                out.append((int(t.tag[1]), txt, github_slug(txt, seen)))
        return out

    # --- links ---------------------------------------------------------------
    def resolve(self, href: str, src: Path, where: str, *, image: bool = False) -> str:
        """Check one relative link or image and return its URL in the site."""
        if not href or is_external(href):
            return href
        if href.startswith("#"):
            if unquote(href[1:]) not in (self.slugs_for(src) or set()):
                self.findings.add(where, f"broken anchor {href}")
            return href
        if href.startswith("/"):
            self.findings.add(where, f"absolute link {href} (breaks under the site's base path; make it relative)")
            return href
        path, _, frag = href.partition("#")
        target = (src.parent / unquote(path)).resolve()
        try:
            rel_repo = target.relative_to(ROOT)
        except ValueError:
            self.findings.add(where, f"link {href} leaves the repository")
            return href
        if not tracked(target):
            kind = "image" if image else "link"
            self.findings.add(where, f"broken {kind} {href} (no {rel_repo.as_posix()} in the repository)")
            return href
        if frag:
            slugs = self.slugs_for(target)
            if slugs is not None and unquote(frag) not in slugs:
                self.findings.add(where, f"broken anchor {href} (no heading #{frag} in {rel_repo.as_posix()})")
        if target.parent == DOCS and target.name in self.pages:
            return self.pages[target.name].out + (f"#{frag}" if frag else "")
        if IMG in target.parents:  # the one folder the site copies
            return target.relative_to(DOCS).as_posix() + (f"#{frag}" if frag else "")
        if image:
            self.findings.add(where, f"image {href} is outside docs/img/ (the site only has docs/img/)")
            return href
        kind = "tree" if target.is_dir() else "blob"
        return f"{REPO_URL}/{kind}/main/{rel_repo.as_posix()}" + (f"#{frag}" if frag else "")

    def slugs_for(self, path: Path) -> set[str] | None:
        if path.parent == DOCS and path.name in self.pages:
            return self.pages[path.name].slugs
        if path == ROOT / "README.md":
            return self.readme_slugs
        return None

    # --- pass 2: render ---------------------------------------------------------
    def render(self, p: Page) -> None:
        where = f"docs/{p.file}"
        for hit in private_hits(p.text):
            self.findings.add(where, hit)
        toks = self.md.parse(p.text)
        seen: dict[str, int] = {}
        last_level = 0
        h1s = 0
        for i, t in enumerate(toks):
            line = f"{where}:{t.map[0] + 1}" if t.map else where
            if t.type == "heading_open":
                level = int(t.tag[1])
                txt = inline_text(toks[i + 1])
                t.attrSet("id", github_slug(txt, seen))
                if level == 1:
                    h1s += 1
                if last_level == 0 and level != 1:
                    self.findings.add(line, f"the first heading is h{level}, not h1")
                elif last_level and level > last_level + 1:
                    self.findings.add(line, f"heading jumps from h{last_level} to h{level}")
                last_level = level
            elif t.type == "inline":
                self.fix_inline(t, p.src, line)
            elif t.type == "html_block":
                t.content = self.fix_html(t.content, p.src, line)
        if h1s != 1:
            self.findings.add(where, f"{h1s} h1 headings (a page has exactly one)")
        if p.file == "index.md":
            toks = self.drop_h1(toks)
        body = self.md.renderer.render(toks, self.md.options, {})
        body = body.replace("<table>", '<div class="table-wrap" tabindex="0" role="region" aria-label="Table"><table>')
        body = body.replace("</table>", "</table></div>")
        if p.file == "index.md":
            body = self.cards(body)
        p.body = body
        p.sections = self.sections(p, body)

    def fix_inline(self, t, src: Path, line: str) -> None:
        for c in t.children or []:
            if c.type == "link_open":
                c.attrSet("href", self.resolve(c.attrGet("href") or "", src, line))
            elif c.type == "image":
                if not (c.content or "").strip():
                    self.findings.add(line, f"image {c.attrGet('src')} has no alt text")
                orig = c.attrGet("src") or ""
                c.attrSet("src", self.resolve(orig, src, line, image=True))
                size = png_size(src.parent / unquote(orig))
                if size:
                    c.attrSet("width", str(size[0]))
                    c.attrSet("height", str(size[1]))
                    c.attrSet("style", f"aspect-ratio: {size[0]} / {size[1]}")
                c.attrSet("loading", "lazy")
            elif c.type == "html_inline":
                c.content = self.fix_html(c.content, src, line)

    def fix_html(self, frag: str, src: Path, line: str) -> str:
        for m in re.finditer(r"<img\b[^>]*>", frag, re.I):
            alt = re.search(r'\balt\s*=\s*("([^"]*)"|\'([^\']*)\')', m.group(0))
            if not alt or not (alt.group(2) or alt.group(3) or "").strip():
                self.findings.add(line, "an <img> has no alt text")

        def sub(m: re.Match) -> str:
            return f'{m.group(1)}="{html.escape(self.resolve(html.unescape(m.group(2)), src, line, image=m.group(1).lower() == "src"))}"'
        return re.sub(r'\b(href|src)="([^"]*)"', sub, frag)

    @staticmethod
    def drop_h1(toks):
        for i, t in enumerate(toks):
            if t.type == "heading_open" and t.tag == "h1":
                return toks[:i] + toks[i + 3:]
        return toks

    @staticmethod
    def cards(body: str) -> str:
        """The home page: every h2 section becomes a card."""
        parts = re.split(r"(?=<h2[ >])", body)
        lead, rest = parts[0], parts[1:]
        return lead + "".join(f'<section class="card">{s}</section>' for s in rest)

    @staticmethod
    def sections(p: Page, body: str) -> list[dict]:
        rows = []
        chunks = re.split(r'(<h[1-3] id="[^"]*">.*?</h[1-3]>)', body, flags=re.S)
        heading, anchor = p.title, ""
        for chunk in chunks:
            m = re.match(r'<h[1-3] id="([^"]*)">(.*?)</h[1-3]>', chunk, re.S)
            if m:
                anchor, heading = m.group(1), html.unescape(re.sub(r"<[^>]+>", "", m.group(2)))
                continue
            text = html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", chunk))).strip()
            if text or anchor:
                rows.append({"p": p.title_plain if p.file != "index.md" else "Welcome", "h": heading,
                             "u": p.out + (f"#{anchor}" if anchor else ""), "t": text[:4000]})
        return rows

    def check_readme(self) -> None:
        src = ROOT / "README.md"
        text = src.read_text(encoding="utf-8")
        for hit in private_hits(text):
            self.findings.add("README.md", hit)
        toks = self.md.parse(text)
        for t in toks:
            line = f"README.md:{t.map[0] + 1}" if t.map else "README.md"
            if t.type == "inline":
                self.fix_inline(t, src, line)
            elif t.type == "html_block":
                self.fix_html(t.content, src, line)

    # --- write ---------------------------------------------------------------------
    def nav_html(self, cur: Page) -> str:
        out = []
        for group, items in NAV:
            links = []
            for file, label in items:
                if file not in self.pages:
                    continue
                p = self.pages[file]
                current = ' aria-current="page"' if p is cur else ""
                links.append(f'<li><a class="row" href="{p.out}"{current}>{html.escape(label)}</a></li>')
            gid = "nav-" + re.sub(r"[^a-z]+", "-", group.lower()).strip("-")
            out.append(f'<p class="label" id="{gid}">{html.escape(group)}</p>'
                       f'<ul aria-labelledby="{gid}">{"".join(links)}</ul>')
        return "\n".join(out)

    def toc_html(self, p: Page) -> str:
        items = [(lvl, txt, sid) for lvl, txt, sid in p.headings if lvl in (2, 3)]
        if len(items) < 2 or p.file == "index.md":
            return ""
        lis = "".join(f'<li class="l{lvl}"><a href="#{sid}">{html.escape(txt)}</a></li>' for lvl, txt, sid in items)
        return f'<nav class="toc" aria-labelledby="toc-h"><h2 class="label" id="toc-h">On this page</h2><ul>{lis}</ul></nav>'

    def pager_html(self, p: Page) -> str:
        i = self.order.index(p)
        prev = self.order[i - 1] if i > 0 else None
        nxt = self.order[i + 1] if i + 1 < len(self.order) else None
        out = []
        if prev:
            out.append(f'<a class="prev" href="{prev.out}"><small>Previous</small><span>{html.escape(prev.label)}</span></a>')
        if nxt:
            out.append(f'<a class="next" href="{nxt.out}"><small>Next</small><span>{html.escape(nxt.label)}</span></a>')
        return f'<nav class="pager" aria-label="Previous and next page">{"".join(out)}</nav>' if out else ""

    def write(self, out: Path) -> None:
        if out.exists():
            shutil.rmtree(out)
        (out / "assets" / "fonts").mkdir(parents=True)
        template = (THEME / "page.html").read_text(encoding="utf-8")
        pip = (THEME / "pip.svg").read_text(encoding="utf-8")
        for p in self.order:
            home = p.file == "index.md"
            hero = ""
            body = p.body
            if home:
                # The hero: Pip, the page's h1 and its first paragraph, which leave the article.
                lead = re.search(r"<p>.*?</p>", body, re.S)
                if lead:
                    body = body[:lead.start()] + body[lead.end():]
                hero = (THEME / "hero.html").read_text(encoding="utf-8")
                for k, v in {"{{pip}}": pip, "{{h1}}": html.escape(p.title_plain),
                             "{{lead}}": lead.group(0) if lead else ""}.items():
                    hero = hero.replace(k, v)
            toc = self.toc_html(p)
            page = template
            for k, v in {
                "{{title}}": "Para Studio docs" if home else f"{html.escape(p.title_plain)} · Para Studio docs",
                "{{description}}": html.escape(self.description(p)),
                "{{pip}}": pip,
                "{{nav}}": self.nav_html(p),
                "{{hero}}": hero,
                "{{body}}": body,
                "{{toc}}": toc,
                "{{pager}}": self.pager_html(p),
                "{{edit}}": f"{REPO_URL}/blob/main/docs/{p.file}",
                "{{repo}}": REPO_URL,
                "{{kind}}": ("page-home" if home else "page-doc") + ("" if toc else " no-toc"),
            }.items():
                page = page.replace(k, v)
            (out / p.out).write_text(page, encoding="utf-8")
        rows = [r for p in self.order for r in p.sections]
        (out / "search-index.js").write_text(
            "window.PARA_SEARCH = " + json.dumps(rows, ensure_ascii=False, separators=(",", ":")) + ";\n", encoding="utf-8")
        for f in ("site.css", "site.js"):
            shutil.copy2(THEME / f, out / "assets" / f)
        for f in FONTS.iterdir():
            if f.suffix in (".woff2", ".txt"):
                shutil.copy2(f, out / "assets" / "fonts" / f.name)
        if IMG.is_dir():
            shutil.copytree(IMG, out / "img")
        self.write_installers(out)
        for f in sorted(out.rglob("*")):
            if f.suffix in (".html", ".js", ".css", ".txt", ".sh", ".ps1"):
                for hit in private_hits(f.read_text(encoding="utf-8")):
                    self.findings.add(f"built {f.relative_to(out).as_posix()}", hit)

    def write_installers(self, out: Path) -> None:
        """Copy each installer to the site's root with the commit being built written into it."""
        r = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True)
        sha = r.stdout.strip()
        if r.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
            self.findings.add("tools/docs/build.py", "git rev-parse HEAD gave no commit to write into the installers")
            return
        for src, empty, stamped in INSTALLERS:
            where = src.relative_to(ROOT).as_posix()
            lines = src.read_bytes().decode("utf-8").split("\n")
            hits = [i for i, line in enumerate(lines) if line == empty]
            if len(hits) != 1:
                self.findings.add(where, f"needs exactly one line {empty!r} for the build to write the commit into; found {len(hits)}")
                continue
            lines[hits[0]] = stamped.format(sha=sha)
            (out / src.name).write_bytes("\n".join(lines).encode("utf-8"))

    @staticmethod
    def description(p: Page) -> str:
        """The page's first paragraph as plain text, for search engines and link previews."""
        m = re.search(r"<p>(.*?)</p>", p.body, re.S)
        text = html.unescape(re.sub(r"<[^>]+>", "", m.group(1))) if m else p.title_plain
        return re.sub(r"\s+", " ", text).strip()[:200]


def serve(out: Path, port: int) -> None:
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(out))
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        print(f"serving http://127.0.0.1:{port}/  (Ctrl+C stops)")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


def main() -> int:
    ap = argparse.ArgumentParser(description="Build and check the documentation site.")
    ap.add_argument("--out", default=str(ROOT / "tmp" / "site"), help="output directory (default: tmp/site)")
    ap.add_argument("--serve", action="store_true", help="serve the site after a clean build")
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()
    out = Path(args.out).resolve()

    site = Site()
    site.scan()
    for p in site.order:
        site.render(p)
    site.check_readme()
    site.write(out)
    if site.findings:
        for f in site.findings:
            print(f"docs: {f}")
        print(f"docs: {len(site.findings)} finding(s); the site was written to {os.path.relpath(out, ROOT)} anyway")
        return 1
    print(f"docs: {len(site.order)} pages, no findings; the site is in {os.path.relpath(out, ROOT)}/ "
          f"(published at {SITE_URL})")
    if args.serve:
        serve(out, args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
