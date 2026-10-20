#!/usr/bin/env python3
"""Documentation checks (stdlib only).

1. Every relative Markdown link in README.md and docs/*.md points at a file that exists.
2. Every #anchor in such a link matches a heading of the target file (GitHub slug rules).
3. docs/README.md links to every page in docs/ (the two archived WSL2-era notes are exempt).

Exit status 1 and one line per problem when anything is wrong. Run: python3 -I tests/check_docs.py
"""
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE = ("Pterodactyl-Docker-WSL2-Deployment-Guide.md", "Analisis Dokumentasi")   # legacy notes: not checked, not indexed

LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")


def is_archive(path):
    return path.name.startswith(ARCHIVE)


def doc_files():
    files = [ROOT / "README.md"] + sorted((ROOT / "docs").rglob("*.md"))
    return [f for f in files if not is_archive(f)]


def prose_lines(path):
    """(number, text) for every line outside fenced code blocks, with inline code spans blanked."""
    fenced = False
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if not fenced:
            yield n, re.sub(r"`[^`]*`", "``", line)


def slug(text):
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)      # [label](url) -> label
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("`", "").replace("*", "").replace("~", "")
    return re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")


_anchor_cache = {}


def anchors(path):
    if path not in _anchor_cache:
        seen, found = {}, set()
        fenced = False
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            m = None if fenced else HEADING.match(line)
            if m:
                s = slug(m.group(2))
                n = seen.get(s, 0)
                seen[s] = n + 1
                found.add(s if n == 0 else f"{s}-{n}")
        _anchor_cache[path] = found
    return _anchor_cache[path]


def check_links(problems):
    for doc in doc_files():
        rel = doc.relative_to(ROOT)
        for n, line in prose_lines(doc):
            for target in LINK.findall(line):
                if re.match(r"[a-z][a-z0-9+.-]*:", target, re.I):   # http:, https:, mailto:
                    continue
                path_part, _, frag = target.partition("#")
                dest = doc if not path_part else (doc.parent / unquote(path_part)).resolve()
                if not dest.exists():
                    problems.append(f"{rel}:{n}: broken link, no such file: {target}")
                elif frag and dest.suffix == ".md" and not is_archive(dest) and unquote(frag) not in anchors(dest):
                    problems.append(f"{rel}:{n}: broken anchor #{frag} in {dest.relative_to(ROOT)}")


def check_index(problems):
    index = (ROOT / "docs" / "README.md").read_text(encoding="utf-8")
    for page in sorted((ROOT / "docs").glob("*.md")):
        if page.name == "README.md" or is_archive(page):
            continue
        if not re.search(r"\]\(" + re.escape(page.name) + r"(#[^)]*)?\)", index):
            problems.append(f"docs/README.md: does not link to docs/{page.name}")
    # every sub-folder (docs/extensions/, ...) has a README that the top-level index must link to
    for folder in sorted(p for p in (ROOT / "docs").iterdir() if p.is_dir()):
        if (folder / "README.md").exists() and not re.search(r"\]\(" + re.escape(folder.name) + r"/README\.md(#[^)]*)?\)", index):
            problems.append(f"docs/README.md: does not link to docs/{folder.name}/README.md")


def main():
    problems = []
    check_links(problems)
    check_index(problems)
    for p in problems:
        print(p)
    print(f"checked {len(doc_files())} files, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
