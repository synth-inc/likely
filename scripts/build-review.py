#!/usr/bin/env python3
"""Builds docs/review/index.html: a side-by-side, word-level review of the site copy changes.

Compares each page's data-copy-id elements (plus <title> and the meta description) between a base
git ref and the working tree, groups them by section (the nearest preceding h1/h2), and highlights
word-level changes. Every changed element must have a reason in review_reasons.py, or the build fails.

    python3 scripts/build-review.py [--base origin/site-privacy-terms]
"""
import argparse
import sys as _sys
_sys.dont_write_bytecode = True
import difflib
import html
import json
import re
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from review_reasons import REASONS, PAGE_NOTES  # noqa: E402

PAGES = [("privacy.html", "Privacy Policy"), ("terms.html", "Terms of Service"), ("index.html", "Landing page")]
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}


class Extractor(HTMLParser):
    """Collects every data-copy-id element's text, in document order, with its section and placeholders."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.items = []          # dicts: id, text, section, placeholders
        self.stack = []          # open elements: (tag, item or None, is_heading, is_placeholder)
        self.section = "Header"
        self.in_title = False
        self.title = ""
        self.heading_buf = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "meta" and a.get("name") == "description":
            self.items.append({"id": "meta.description", "text": a.get("content", ""), "section": "Page metadata",
                               "placeholders": []})
        if tag == "title":
            self.in_title = True
        if tag == "footer":
            self.section = "Footer"
        if tag in VOID:
            if tag == "br":
                self._text(" ")
            return
        item = None
        if "data-copy-id" in a:
            item = {"id": a["data-copy-id"], "text": "", "section": None, "placeholders": [], "tag": tag}
        is_heading = tag in ("h1", "h2")
        if is_heading:
            self.heading_buf = ""
        is_ph = "placeholder" in (a.get("class") or "").split()
        self.stack.append((tag, item, is_heading, is_ph))

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False
            self.items.insert(0, {"id": "meta.title", "text": self.title.strip(), "section": "Page metadata",
                                  "placeholders": []})
        if tag in VOID:
            return
        # Pop to the matching tag (tolerates unclosed <p>/<li>).
        while self.stack:
            t, item, is_heading, is_ph = self.stack.pop()
            if is_heading and self.heading_buf is not None:
                self.section = re.sub(r"\s+", " ", self.heading_buf).strip()
                self.heading_buf = None
            if item is not None:
                item["text"] = re.sub(r"\s+", " ", item["text"]).strip()
                item["section"] = self.section
                self.items.append(item)
            if t == tag:
                break

    def _text(self, data):
        if self.in_title:
            self.title += data
        if self.heading_buf is not None:
            self.heading_buf += data
        in_ph = any(p for _, _, _, p in self.stack)
        for _, item, _, _ in self.stack:
            if item is not None:
                item["text"] += data
                if in_ph and data.strip():
                    if item.get("_ph_open"):
                        item["placeholders"][-1] += data
                    else:
                        item["placeholders"].append(data)
                        item["_ph_open"] = True
                elif not in_ph:
                    item.pop("_ph_open", None)

    def handle_data(self, data):
        self._text(data)


def extract(source):
    p = Extractor()
    p.feed(source)
    items = []
    seen = set()
    for it in p.items:
        it.pop("_ph_open", None)
        it.pop("tag", None)
        if it["id"] in seen:
            raise SystemExit(f"duplicate data-copy-id: {it['id']}")
        seen.add(it["id"])
        items.append(it)
    return items


TOKEN = re.compile(r"\s+|[\w’'\-.]+(?<![.])|[^\w\s]")


def tokens(text):
    return TOKEN.findall(text)


def word_diff(a, b):
    """Returns (before_html, after_html) with deletions and insertions marked."""
    ta, tb = tokens(a), tokens(b)
    sm = difflib.SequenceMatcher(None, ta, tb, autojunk=False)
    left, right = [], []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        sa, sb = html.escape("".join(ta[i1:i2])), html.escape("".join(tb[j1:j2]))
        if op == "equal":
            left.append(sa)
            right.append(sb)
        else:
            if sa:
                left.append(f"<del>{sa}</del>")
            if sb:
                right.append(f"<ins>{sb}</ins>")
    return "".join(left), "".join(right)


def align(before, after):
    """Merges both id lists in document order: after's order, with removed ids at their old position."""
    bmap = {it["id"]: it for it in before}
    amap = {it["id"]: it for it in after}
    rows = []
    bi = 0
    bids = [it["id"] for it in before]
    for it in after:
        if it["id"] in bmap:
            # Emit removed ids that came before this one in the old document.
            pos = bids.index(it["id"])
            while bi < pos:
                rid = bids[bi]
                if rid not in amap:
                    rows.append((bmap[rid], None))
                bi += 1
            bi = max(bi, pos + 1)
            rows.append((bmap[it["id"]], it))
        else:
            rows.append((None, it))
    for rid in bids[bi:]:
        if rid not in amap:
            rows.append((bmap[rid], None))
    return rows


def git_show(ref, path):
    return subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT, check=True, capture_output=True,
                          text=True).stdout


def build(base):
    pages = []
    placeholders = []
    missing = []
    stale = []
    for fname, label in PAGES:
        before = extract(git_show(base, f"docs/{fname}"))
        after = extract((ROOT / "docs" / fname).read_text())
        rows = []
        counts = {"changed": 0, "added": 0, "removed": 0, "unchanged": 0}
        for b, a in align(before, after):
            cid = (a or b)["id"]
            section = (a or b)["section"]
            if a and b and a["text"] == b["text"]:
                kind = "unchanged"
            elif a and b:
                kind = "changed"
            elif a:
                kind = "added"
            else:
                kind = "removed"
            counts[kind] += 1
            reason = REASONS.get(fname, {}).get(cid)
            if kind != "unchanged" and not reason:
                missing.append(f"{fname} {cid}")
            if kind == "unchanged" and reason:
                stale.append(f"{fname} {cid}")
            bh, ah = word_diff(b["text"] if b else "", a["text"] if a else "")
            anchor = f"{fname.split('.')[0]}--{cid}"
            if a:
                for ph in a["placeholders"]:
                    placeholders.append({"text": ph.strip(), "page": label, "id": cid, "anchor": anchor,
                                         "section": section, "kind": kind})
            rows.append({"id": cid, "section": section, "kind": kind, "before": bh, "after": ah,
                         "reason": reason or "", "anchor": anchor})
        removed_ids = [r["id"] for r in rows if r["kind"] == "removed"]
        pages.append({"file": fname, "label": label, "rows": rows, "counts": counts, "removed": removed_ids,
                      "note": PAGE_NOTES.get(fname, "")})
    if missing:
        raise SystemExit("No reason for these changes (add them to scripts/review_reasons.py):\n  " +
                         "\n  ".join(missing))
    if stale:
        print("warning: reasons for unchanged ids:", ", ".join(stale), file=sys.stderr)
    return pages, placeholders


CSS = """
:root { color-scheme: light dark; --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --card:#f7f7f9;
  --del-bg:#ffe5e5; --del-fg:#a30000; --ins-bg:#dcf5e0; --ins-fg:#0b6b25; --ph:#fff1d6; --accent:#0a66d8; }
@media (prefers-color-scheme: dark) { :root { --bg:#16171a; --fg:#f2f2f4; --muted:#a1a1a8; --line:#2c2d33;
  --card:#1e1f24; --del-bg:#4a1d1f; --del-fg:#ffb3b3; --ins-bg:#173d22; --ins-fg:#a6f0b6; --ph:#4a3a14; --accent:#6fb1ff; } }
* { box-sizing: border-box; }
body { margin: 0; font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: var(--bg); color: var(--fg); }
header.top { padding: 28px 32px 8px; max-width: 1500px; margin: 0 auto; }
h1 { font-size: 26px; margin: 0 0 4px; }
.sub { color: var(--muted); margin: 0 0 18px; }
.summary { display: flex; gap: 14px; flex-wrap: wrap; margin: 12px 0 18px; }
.summary a { text-decoration: none; color: inherit; }
.stat { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 12px 16px; min-width: 210px; }
.stat b { display: block; font-size: 16px; margin-bottom: 4px; }
.stat .n { font-size: 13px; color: var(--muted); }
.pill { display: inline-block; font-size: 12px; padding: 1px 8px; border-radius: 99px; margin-right: 4px; font-weight: 600; }
.pill.changed { background: #e8f0ff; color: #0a4fb0; } .pill.added { background: var(--ins-bg); color: var(--ins-fg); }
.pill.removed { background: var(--del-bg); color: var(--del-fg); }
@media (prefers-color-scheme: dark) { .pill.changed { background:#1c2c48; color:#9cc4ff; } }
.box { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px 18px; margin: 0 0 16px; }
.box h2 { font-size: 17px; margin: 0 0 8px; }
.box ol, .box ul { margin: 6px 0 0; padding-left: 22px; }
.box li { margin: 3px 0; }
.ph { background: var(--ph); border-radius: 5px; padding: 0 5px; }
.controls { position: sticky; top: 0; z-index: 5; background: var(--bg); border-bottom: 1px solid var(--line);
  padding: 10px 32px; display: flex; gap: 18px; align-items: center; flex-wrap: wrap; }
.controls nav a { margin-right: 14px; color: var(--accent); text-decoration: none; font-weight: 600; }
.controls label { color: var(--muted); font-size: 14px; }
main { max-width: 1500px; margin: 0 auto; padding: 8px 32px 80px; }
section.page { margin-top: 34px; }
section.page > h2 { font-size: 22px; border-bottom: 2px solid var(--line); padding-bottom: 6px; }
.note { color: var(--muted); margin: 6px 0 12px; }
h3.sec { font-size: 15px; margin: 26px 0 8px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 0; border: 1px solid var(--line); border-radius: 10px;
  margin: 0 0 10px; overflow: hidden; scroll-margin-top: 60px; }
.row:target { outline: 3px solid var(--accent); }
.row .meta { grid-column: 1 / -1; display: flex; gap: 10px; align-items: baseline; padding: 7px 12px;
  background: var(--card); border-bottom: 1px solid var(--line); font-size: 13px; flex-wrap: wrap; }
.row .meta code { font-size: 12px; color: var(--muted); }
.row .meta .why { flex: 1 1 400px; }
.row .col { padding: 10px 12px; white-space: pre-wrap; word-wrap: break-word; }
.row .col + .col { border-left: 1px solid var(--line); }
.row .col.empty { color: var(--muted); font-style: italic; }
.colhead { display: grid; grid-template-columns: 1fr 1fr; font-size: 12px; font-weight: 700; color: var(--muted);
  text-transform: uppercase; letter-spacing: .05em; padding: 0 12px 4px; }
del { background: var(--del-bg); color: var(--del-fg); text-decoration: line-through; border-radius: 3px; }
ins { background: var(--ins-bg); color: var(--ins-fg); text-decoration: none; border-radius: 3px; }
.row.unchanged { display: none; opacity: .75; }
body.show-unchanged .row.unchanged { display: grid; }
body.only-changed h3.sec.quiet { display: none; }
h3.sec.quiet { display: none; }
body.show-unchanged h3.sec.quiet { display: block; }
@media (max-width: 800px) { .row, .colhead { grid-template-columns: 1fr; } .row .col + .col { border-left: 0; border-top: 1px solid var(--line); } }
"""

JS = """
document.getElementById('unch').addEventListener('change', e => document.body.classList.toggle('show-unchanged', e.target.checked));
// Opening a link to an unchanged row shows unchanged rows.
function reveal() { const t = location.hash && document.getElementById(location.hash.slice(1));
  if (t && t.classList.contains('unchanged')) { document.getElementById('unch').checked = true; document.body.classList.add('show-unchanged'); t.scrollIntoView(); } }
window.addEventListener('hashchange', reveal); reveal();
"""


def render(pages, placeholders, base, head):
    e = html.escape
    out = ["<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'>",
           "<meta name='viewport' content='width=device-width, initial-scale=1'><meta name='robots' content='noindex'>",
           "<title>Likely site copy: review of legal fixes</title><style>", CSS, "</style></head><body>"]
    out.append("<header class='top'><h1>Likely site copy: before and after</h1>")
    out.append(f"<p class='sub'>Base: <code>{e(base)}</code> · After: working tree of <code>{e(head)}</code>. "
               "Generated by <code>scripts/build-review.py</code> from the text of every <code>data-copy-id</code> "
               "element, plus the page title and meta description. Deletions are <del>red and struck</del>, "
               "additions <ins>green</ins>.</p>")
    out.append("<div class='summary'>")
    total = 0
    for p in pages:
        c = p["counts"]
        n = c["changed"] + c["added"] + c["removed"]
        total += n
        out.append(f"<a class='stat' href='#page-{p['file'].split('.')[0]}'><b>{e(p['label'])}: {n} changes</b>"
                   f"<span class='n'><span class='pill changed'>{c['changed']} changed</span>"
                   f"<span class='pill added'>{c['added']} added</span>"
                   f"<span class='pill removed'>{c['removed']} removed</span> · {c['unchanged']} unchanged</span></a>")
    out.append(f"<div class='stat'><b>Total: {total} changes</b><span class='n'>"
               f"{len(placeholders)} placeholders to fill</span></div></div>")

    out.append("<div class='box'><h2>Placeholders the owner must fill</h2><ol>")
    for ph in placeholders:
        out.append(f"<li><span class='ph'>{e(ph['text'])}</span> · {e(ph['page'])}, {e(ph['section'])} "
                   f"(<a href='#{e(ph['anchor'])}'><code>{e(ph['id'])}</code></a>)</li>")
    out.append("</ol></div>")
    removed_all = [(p["label"], r) for p in pages for r in p["removed"]]
    out.append("<div class='box'><h2>data-copy-id check</h2><p>")
    if removed_all:
        out.append("Removed ids: " + ", ".join(f"{e(l)} <code>{e(r)}</code>" for l, r in removed_all))
    else:
        out.append("Every <code>data-copy-id</code> from the base is still present. New text has new ids "
                   "(the rows marked <span class='pill added'>added</span>).")
    out.append("</p></div></header>")

    out.append("<div class='controls'><nav>")
    for p in pages:
        out.append(f"<a href='#page-{p['file'].split('.')[0]}'>{e(p['label'])}</a>")
    out.append("</nav><label><input type='checkbox' id='unch'> Show unchanged text too</label></div><main>")

    for p in pages:
        out.append(f"<section class='page' id='page-{p['file'].split('.')[0]}'><h2>{e(p['label'])} "
                   f"<code style='font-size:14px;color:var(--muted)'>docs/{e(p['file'])}</code></h2>")
        if p["note"]:
            out.append(f"<p class='note'>{e(p['note'])}</p>")
        out.append("<div class='colhead'><span>Before</span><span>After</span></div>")
        current = None
        # Sections with no changes get a 'quiet' heading, shown only with unchanged rows.
        changed_sections = {r["section"] for r in p["rows"] if r["kind"] != "unchanged"}
        for r in p["rows"]:
            if r["section"] != current:
                current = r["section"]
                quiet = "" if current in changed_sections else " quiet"
                out.append(f"<h3 class='sec{quiet}'>{e(current)}</h3>")
            pill = "" if r["kind"] == "unchanged" else f"<span class='pill {r['kind']}'>{r['kind']}</span>"
            why = f"<span class='why'>{e(r['reason'])}</span>" if r["reason"] else "<span class='why'></span>"
            before = r["before"] or "(none)"
            after = r["after"] or "(removed)"
            bcls = " empty" if not r["before"] else ""
            acls = " empty" if not r["after"] else ""
            out.append(f"<div class='row {r['kind']}' id='{e(r['anchor'])}'><div class='meta'>{pill}"
                       f"<code>{e(r['id'])}</code>{why}</div>"
                       f"<div class='col{bcls}'>{before}</div><div class='col{acls}'>{after}</div></div>")
        out.append("</section>")
    out.append("</main><script>" + JS + "</script></body></html>")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/site-privacy-terms")
    ap.add_argument("--out", default=str(ROOT / "docs" / "review" / "index.html"))
    args = ap.parse_args()
    head = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=ROOT, capture_output=True,
                          text=True).stdout.strip()
    pages, placeholders = build(args.base)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(render(pages, placeholders, args.base, head))
    for p in pages:
        print(p["file"], json.dumps(p["counts"]))
    print(len(placeholders), "placeholders ->", args.out)


if __name__ == "__main__":
    main()
