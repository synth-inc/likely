#!/usr/bin/env python3
"""Regenerates evals/fixtures/files: small synthetic documents and images for the public eval suite.

Everything here is made up (the "Jordan Rivera" persona, companies, amounts). Pure standard library:
PDFs are written by hand with uncompressed text (so grep and Spotlight can read them), PNGs pixel by
pixel. Run from anywhere:  python3 evals/fixtures/generate.py
"""
import math
import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "files")


def write(rel, data):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    # Fixed dates keep "most recent" questions answerable and the files reproducible.
    return path


def pdf(title, lines):
    """A one-page PDF (Helvetica) with a title and body lines."""
    def esc(s):
        return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    ops = ["BT", "/F2 16 Tf", "72 740 Td", f"({esc(title)}) Tj", "/F1 11 Tf", "0 -28 Td", "14 TL"]
    for line in lines:
        ops.append(f"({esc(line)}) '")
    ops.append("ET")
    stream = "\n".join(ops).encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        ("<< /Title (%s) /Producer (Likely eval fixtures) >>" % esc(title)).encode("latin-1"),
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R /Info 7 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return out


def png(width, height, pixel):
    """pixel(x, y) -> (r, g, b)."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixel(x, y))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * max(0, min(1, t))) for i in range(3))


def portrait(x, y, w=256, h=320):
    """Head-and-shoulders silhouette on a studio backdrop: reads as a headshot."""
    bg = mix((196, 214, 230), (120, 146, 170), y / h)
    cx, head_cy, head_r = w / 2, h * 0.38, w * 0.2
    # shoulders: an ellipse below the head
    if ((x - cx) / (w * 0.42)) ** 2 + ((y - h * 1.02) / (h * 0.36)) ** 2 <= 1:
        return mix((52, 64, 92), (34, 42, 62), (y - h * 0.7) / (h * 0.3))
    # hair (top half of a slightly larger circle)
    d_hair = math.hypot(x - cx, (y - head_cy + 8) * 1.05)
    if d_hair <= head_r * 1.12 and y < head_cy - head_r * 0.25:
        return (62, 44, 32)
    d = math.hypot((x - cx) * 1.08, y - head_cy)
    if d <= head_r:
        if math.hypot(x - (cx - head_r * 0.38), y - (head_cy - 4)) < 5 or math.hypot(x - (cx + head_r * 0.38), y - (head_cy - 4)) < 5:
            return (40, 30, 26)  # eyes
        if abs(y - (head_cy + head_r * 0.45)) < 2 and abs(x - cx) < head_r * 0.3:
            return (150, 80, 76)  # mouth
        return mix((232, 190, 160), (205, 160, 130), d / head_r)
    # neck
    if abs(x - cx) < w * 0.07 and head_cy < y < h * 0.7:
        return (214, 170, 140)
    return bg


def landscape(x, y, w=320, h=200):
    """Sky, sun, mountains, lake: a vacation photo."""
    ridge = h * 0.55 - 30 * math.sin(x / 37.0) - 18 * math.sin(x / 13.0 + 1)
    if y > h * 0.78:
        return mix((60, 110, 150), (30, 70, 110), (y - h * 0.78) / (h * 0.22))
    if y > ridge:
        return mix((70, 100, 70), (40, 70, 45), (y - ridge) / 60)
    if math.hypot(x - w * 0.75, y - h * 0.25) < 18:
        return (255, 226, 140)
    return mix((120, 180, 235), (240, 200, 170), y / (h * 0.6))


def app_icon(x, y, size=256):
    """macOS-style squircle with a gradient and a white document glyph."""
    m, r = size * 0.1, size * 0.18
    inner = size - 2 * m
    px, py = x - m, y - m
    if not (0 <= px < inner and 0 <= py < inner):
        return (255, 255, 255)
    qx, qy = min(px, inner - 1 - px), min(py, inner - 1 - py)
    if qx < r and qy < r and math.hypot(r - qx, r - qy) > r:
        return (255, 255, 255)
    base = mix((255, 149, 0), (255, 59, 92), (px + py) / (2 * inner))
    # document glyph with a folded corner and a magnifier ring
    gx, gy = px / inner, py / inner
    if 0.3 < gx < 0.62 and 0.22 < gy < 0.78 and not (gx > 0.52 and gy < 0.32 and (gx - 0.52) > (gy - 0.22)):
        if 0.36 < gx < 0.56 and any(abs(gy - l) < 0.012 for l in (0.42, 0.5, 0.58)):
            return mix(base, (255, 255, 255), 0.35)
        return (255, 255, 255)
    ring = math.hypot(gx - 0.64, gy - 0.66)
    if 0.1 < ring < 0.14 or (ring >= 0.14 and gx > 0.7 and gy > 0.72 and abs((gx - 0.7) - (gy - 0.72)) < 0.03 and gx < 0.82):
        return (255, 255, 255)
    return base


def main():
    w = write
    w("Documents/Housing/Lease Agreement - 418 Alder St.pdf", pdf("Residential Lease Agreement", [
        "This Lease Agreement is made on August 1, 2026 between Maple Leasing LLC (Landlord)",
        "and Jordan Rivera (Tenant) for the premises at 418 Alder Street, Apt 3B, Portland, OR 97205.",
        "Term: twelve (12) months, beginning September 1, 2026 and ending August 31, 2027.",
        "Monthly rent: $2,150.00, due on the first day of each month. Security deposit: $2,150.00.",
        "Utilities: Tenant pays electricity and internet; Landlord pays water, sewer and trash.",
        "Pets: one cat permitted with a $300 pet deposit.",
        "Signed: Maple Leasing LLC    Jordan Rivera",
    ]))
    w("Documents/Housing/Renters Insurance Declarations.pdf", pdf("Renters Insurance - Declarations Page", [
        "Policyholder: Jordan Rivera    Policy number: HO4-5521-0098",
        "Insured location: 418 Alder Street, Apt 3B, Portland, OR 97205",
        "Policy period: 09/01/2026 to 09/01/2027",
        "Personal property: $30,000    Personal liability: $300,000    Deductible: $500",
        "Insurer: Evergreen Mutual Insurance Co.",
    ]))
    for date, gross, net in (("2026-10-15", "4,375.00", "3,212.48"), ("2026-10-31", "4,375.00", "3,198.12")):
        w(f"Documents/Work/Paystub_{date}.pdf", pdf("Earnings Statement", [
            "Employer: Acme Widgets Inc., 100 Industrial Way, Portland, OR",
            "Employee: Jordan Rivera    Employee ID: 20417",
            f"Pay date: {date}    Pay period: semi-monthly",
            f"Gross pay: ${gross}    Federal withholding: $612.50    State withholding: $301.88",
            f"Net pay: ${net}",
            "Year-to-date gross: $87,500.00",
        ]))
    for year in (2024, 2025):
        for fund, ein in (("Brightwater Partners LP", "84-1234567"), ("Oakridge Growth Fund LLC", "47-7654321")):
            if year == 2024 and fund.startswith("Oakridge"):
                continue
            short = fund.split(" ")[0]
            w(f"Documents/Taxes/{year}/K-1s/{short} - Schedule K-1 {year}.pdf", pdf(f"Schedule K-1 (Form 1065) {year}", [
                f"Partner's Share of Income, Deductions, Credits, etc. - Tax year {year}",
                f"Partnership: {fund}    EIN: {ein}",
                "Partner: Jordan Rivera    Limited partner",
                "Box 1 Ordinary business income (loss): 1,842",
                "Box 5 Interest income: 214    Box 9a Net long-term capital gain: 3,120",
                "This is a synthetic test document for Likely's eval suite.",
            ]))
    w("Documents/Taxes/2025/1099-INT Example Credit Union 2025.pdf", pdf("Form 1099-INT 2025", [
        "Payer: Example Credit Union    Recipient: Jordan Rivera",
        "Box 1 Interest income: $418.22",
    ]))
    w("Documents/Resume/Jordan_Rivera_Resume.pdf", pdf("Jordan Rivera", [
        "Product Designer - Portland, OR - jordan.rivera@example.com",
        "Experience: Senior Product Designer, Acme Widgets (2022-present); Designer, Fernway Studio (2018-2022)",
        "Skills: interaction design, prototyping, design systems, user research",
        "Education: B.F.A. Graphic Design, Oregon College of Art",
    ]))
    w("Documents/Notes/q3-planning-notes.md", """# Q3 planning meeting - July 8, 2026

Attendees: Jordan, Priya, Sam, Lee

- Ship the onboarding redesign by end of August
- Hire a second front-end engineer (Priya to open the req)
- Pricing experiment: test annual plan discount at 20%
- Next sync: July 22
""")
    w("Documents/Notes/grocery list.txt", "oat milk\ncoffee beans\nspinach\nlemons\npasta\n")
    w("Downloads/invoice-2026-0412-NimbusHost.pdf", pdf("Invoice #2026-0412", [
        "NimbusHost Cloud Services - web hosting and domains",
        "Bill to: Jordan Rivera",
        "Business VPS (2 vCPU, 4 GB) - October 2026: $24.00",
        "Domain renewal jordanrivera.design (1 year): $14.00",
        "Total due: $38.00    Paid by card ending 4242",
    ]))
    w("Downloads/invoice-1187-PaperAndInk.pdf", pdf("Invoice 1187", [
        "Paper & Ink Co. - stationery and printing",
        "Bill to: Jordan Rivera",
        "Business cards (250): $45.00    Letterpress notecards: $28.00",
        "Total: $73.00",
    ]))
    w("Pictures/IMG_2041.png", png(256, 320, portrait))
    w("Pictures/IMG_2042.png", png(320, 200, landscape))
    w("Design/AppIcon.png", png(256, 256, app_icon))
    # Fixed modification dates (Oct 2026), newest pay stub last.
    for dirpath, _, names in os.walk(ROOT):
        for name in names:
            path = os.path.join(dirpath, name)
            stamp = 1790000000 + (100000 if "10-31" in name else 0)
            os.utime(path, (stamp, stamp))
    print("wrote", ROOT)


if __name__ == "__main__":
    main()
