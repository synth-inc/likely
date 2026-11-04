#!/usr/bin/env python3
"""Adds a release to Likely's Sparkle appcast (creating the file if needed). Used by scripts/release.sh.

The newest item goes first. An existing item with the same build number is replaced, so a re-run of a
release that never shipped doesn't leave duplicates.
"""
import argparse
import html
import os
import re
from email.utils import formatdate

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Likely</title>
        <link>https://github.com/synth-inc/likely</link>
        <description>Likely updates</description>
        <language>en</language>
"""
FOOTER = """    </channel>
</rss>
"""

p = argparse.ArgumentParser()
p.add_argument("appcast")
p.add_argument("--version", required=True)
p.add_argument("--build", required=True)
p.add_argument("--url", required=True)
p.add_argument("--enclosure", required=True, help='sign_update output: sparkle:edSignature="..." length="..."')
p.add_argument("--min-system", required=True)
p.add_argument("--release-page", required=True)
p.add_argument("--notes", default="")
a = p.parse_args()

if not re.fullmatch(r'sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"', a.enclosure.strip()):
    raise SystemExit(f"unexpected sign_update output: {a.enclosure!r}")

notes = ""
if a.notes:
    paragraphs = "".join(f"<p>{html.escape(line)}</p>" for line in a.notes.splitlines() if line.strip())
    notes = f"            <description><![CDATA[{paragraphs}]]></description>\n"

item = f"""        <item>
            <title>Version {html.escape(a.version)}</title>
            <pubDate>{formatdate(usegmt=True)}</pubDate>
            <sparkle:version>{html.escape(a.build)}</sparkle:version>
            <sparkle:shortVersionString>{html.escape(a.version)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{html.escape(a.min_system)}</sparkle:minimumSystemVersion>
            <link>{html.escape(a.release_page)}</link>
{notes}            <enclosure url="{html.escape(a.url)}" type="application/octet-stream" {a.enclosure.strip()}/>
        </item>
"""

text = open(a.appcast).read() if os.path.exists(a.appcast) else HEADER + FOOTER
# Drop an earlier item for the same build.
text = re.sub(
    r"[ \t]*<item>(?:(?!</item>).)*?<sparkle:version>" + re.escape(a.build) + r"</sparkle:version>.*?</item>\n?",
    "", text, flags=re.S)
first_item = text.find("<item>")
if first_item != -1:
    line_start = text.rfind("\n", 0, first_item) + 1
    text = text[:line_start] + item + text[line_start:]
else:
    text = text.replace("    </channel>", item + "    </channel>", 1)

with open(a.appcast, "w") as f:
    f.write(text)
print(f"appcast: added {a.version} ({a.build}) -> {a.appcast}")
