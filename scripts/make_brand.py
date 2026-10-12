#!/usr/bin/env python3
"""Generates Cover Flow's brand assets: the app icon, the README header and the README badges.

    python3 scripts/make_brand.py [--version 1.0.1]

Outputs
    Resources/AppIcon-1024.png     app icon source (build.command turns it into AppIcon.icns)
    docs/readme-header.png         2560x760 README header
    docs/badge-release.svg         RELEASE  | V1.0.1
    docs/badge-download.svg        DOWNLOAD | MACOS APP
    docs/badge-platform.svg        PLATFORM | MACOS 14+ · APPLE SILICON

Layout and badge format follow the other dustalexw apps (Data Curator, Banana Split Redux, Sipass);
colours are Cover Flow's own: deep navy, ivory and the brass accent used in the app.
Needs Pillow and the Inter / Inter Display fonts.
"""
import argparse
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_DIRS = ["/usr/share/fonts/opentype/inter", os.path.expanduser("~/Library/Fonts"), "/Library/Fonts"]

NAVY_TOP = (22, 38, 74)       # #16264A
NAVY_BOT = (9, 17, 38)        # #091126
IVORY = (236, 231, 220)       # #ECE7DC
CREAM = (250, 244, 228)       # #FAF4E4 (badge label text, shared with the other apps)
BRASS = (242, 196, 125)       # #F2C47D (the app's accent)
SLATE = (150, 166, 196)
SIDE_IN = (58, 84, 132)
SIDE_OUT = (36, 55, 94)
LABEL = "#20222c"             # badge label background, shared with the other apps


def font(name, size):
    for d in FONT_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    raise SystemExit(f"Font not found: {name}")


def vgrad(w, h, top, bot):
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)))
    return g.resize((w, h))


SLEEVE = (92, 52, 140)         # #5C348C record sleeve (purple)
CORAL = (232, 115, 90)
TEAL = (63, 184, 175)
PLUM = (122, 74, 140)


def record(img, cx, cy, r):
    """An ornate vinyl disc: fine grooves with an iridescent sheen, a brass rim, and a
    jewel-toned centre label with a sunburst and a ring of beads. Drawn on layers so the
    translucent parts blend properly."""
    import math
    W, H = img.size
    disc = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(disc)
    box = lambda rr: [cx - rr, cy - rr, cx + rr, cy + rr]

    # vinyl body with a lifted shadow
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).ellipse([cx - r, cy - r + r * 0.05, cx + r, cy + r + r * 0.05], fill=(9, 17, 38, 120))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(max(1, r * 0.04))))
    d.ellipse(box(r), fill=(14, 18, 32, 255))

    # grooves: alternating fine rings, slightly warm so they read against the black
    n = 22
    for i in range(n):
        rr = r * (0.96 - i * (0.50 / n))
        a = 46 if i % 3 == 0 else 22
        d.ellipse(box(rr), outline=(190, 200, 225, a), width=max(1, int(r * 0.006)))

    # iridescent sheen: two opposite soft wedges in teal→plum→coral
    sheen = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    for base, cols in ((-62, (TEAL, PLUM, CORAL)), (118, (CORAL, PLUM, TEAL))):
        for j, col in enumerate(cols):
            sd.pieslice(box(r * 0.97), base + j * 9, base + j * 9 + 11, fill=col + (70,))
    sheen = sheen.filter(ImageFilter.GaussianBlur(max(1, r * 0.035)))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse(box(r * 0.97), fill=255)
    ImageDraw.Draw(mask).ellipse(box(r * 0.44), fill=0)
    disc.alpha_composite(Image.composite(sheen, Image.new("RGBA", (W, H), (0, 0, 0, 0)), mask))
    d = ImageDraw.Draw(disc)

    # brass rim
    d.ellipse(box(r), outline=BRASS + (255,), width=max(2, int(r * 0.03)))

    # label: concentric jewel rings
    L = r * 0.42
    d.ellipse(box(L), fill=CORAL + (255,))
    d.ellipse(box(L * 0.86), fill=BRASS + (255,))
    d.ellipse(box(L * 0.74), fill=PLUM + (255,))
    # sunburst of alternating rays on the plum field
    rays = 16
    for k in range(rays):
        a0 = k * 360 / rays
        col = TEAL if k % 2 == 0 else BRASS
        d.pieslice(box(L * 0.70), a0, a0 + 360 / rays * 0.55, fill=col + (255,))
    d.ellipse(box(L * 0.40), fill=NAVY_TOP + (255,))
    d.ellipse(box(L * 0.34), outline=BRASS + (255,), width=max(1, int(r * 0.012)))
    # bead ring between coral and brass
    beads = 24
    br = L * 0.93
    bead = max(1.0, L * 0.035)
    for k in range(beads):
        a = math.radians(k * 360 / beads)
        bx, by = cx + br * math.cos(a), cy + br * math.sin(a)
        d.ellipse([bx - bead, by - bead, bx + bead, by + bead], fill=CREAM + (255,))
    # spindle hole
    hole = L * 0.11
    d.ellipse(box(hole), fill=SLEEVE + (255,))
    d.ellipse(box(hole), outline=BRASS + (255,), width=max(1, int(r * 0.008)))

    img.alpha_composite(disc)


def mark(img, cx, cy, s):
    """The Cover Flow mark: a purple record sleeve, its ornate record, and two receding
    covers on each side."""
    draw = ImageDraw.Draw(img)
    h = s / 2
    for side in (-1, 1):
        for k, col in ((2, SIDE_OUT), (1, SIDE_IN)):
            inner_x = cx + side * (h + s * 0.06 + (k - 1) * s * 0.20)
            outer_x = inner_x + side * s * 0.16
            inner_h = h * (0.80 - (k - 1) * 0.04)
            outer_h = h * (0.94 - (k - 1) * 0.04)
            draw.polygon([(inner_x, cy - inner_h), (outer_x, cy - outer_h),
                          (outer_x, cy + outer_h), (inner_x, cy + inner_h)], fill=col)
    draw.rounded_rectangle([cx - h, cy - h, cx + h, cy + h], radius=s * 0.035, fill=SLEEVE)
    record(img, cx, cy, s * 0.40)


def icon_tile(size, ss=4):
    """The app icon artwork without the macOS margin, for placing on banners."""
    W = size * ss
    tile = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, W - 1], radius=int(W * 0.225), fill=255)
    tile.paste(vgrad(W, W, NAVY_TOP, NAVY_BOT).convert("RGBA"), (0, 0), mask)
    mark(tile, W / 2, W / 2 + W * 0.007, W * 0.437)
    d = ImageDraw.Draw(tile)
    # hairline edge so the tile reads on a navy banner
    d.rounded_rectangle([0, 0, W - 1, W - 1], radius=int(W * 0.225), outline=(255, 255, 255, 34), width=ss * 2)
    return tile.resize((size, size), Image.LANCZOS)


def app_icon(path, S=1024, ss=4):
    W = S * ss
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    m = 100 * ss
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, W - m, W - m], radius=185 * ss, fill=255)
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([m, m + 14 * ss, W - m, W - m + 14 * ss], radius=185 * ss, fill=(0, 0, 0, 110))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(18 * ss)))
    img.paste(vgrad(W, W, NAVY_TOP, NAVY_BOT).convert("RGBA"), (0, 0), mask)
    mark(img, W / 2, W / 2 + 6 * ss, 360 * ss)
    img.resize((S, S), Image.LANCZOS).save(path)


def pill(draw, x, y, text, fnt, h, fill, outline, color, dot=None, pad=None):
    pad = pad or h * 0.55
    tw = draw.textlength(text, font=fnt)
    dot_w = h * 0.55 if dot else 0
    w = pad * 2 + tw + dot_w
    draw.rounded_rectangle([x, y, x + w, y + h], radius=h / 2, fill=fill, outline=outline, width=2)
    tx = x + pad
    if dot:
        r = h * 0.14
        cy = y + h / 2
        draw.ellipse([tx, cy - r, tx + 2 * r, cy + r], fill=dot)
        tx += dot_w
    asc, desc = fnt.getmetrics()
    draw.text((tx, y + (h - asc - desc) / 2 + desc * 0.15), text, font=fnt, fill=color)
    return w


def header(path, version, W=2560, H=760):
    img = vgrad(W, H, NAVY_TOP, NAVY_BOT).convert("RGBA")

    # quiet brass glow behind the title, like the soft lighting on the other headers
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([W * 0.18, -H * 0.5, W * 0.78, H * 0.9], fill=BRASS + (16,))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(160)))

    # right edge: a shelf of covers receding into the distance (Cover Flow's signature),
    # playing the role the peppermint stripes play on Data Curator's header
    ss = 2
    shelf = Image.new("RGBA", (W * ss, H * ss), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shelf)
    base_x, cy = 2440 * ss, (H / 2 + 40) * ss
    for i in range(4, -1, -1):
        x_in = base_x - i * 92 * ss
        hh_in = (170 - i * 10) * ss
        hh_out = (215 - i * 9) * ss
        x_out = x_in + 72 * ss
        shade = 0.6 + 0.08 * (4 - i)
        col = tuple(int(c * shade) for c in SIDE_IN) + (int(110 + 30 * (4 - i)),)
        sd.polygon([(x_in, cy - hh_in), (x_out, cy - hh_out), (x_out, cy + hh_out), (x_in, cy + hh_in)], fill=col)
    # fade the shelf in from the left so it never competes with the text
    fade = Image.new("L", (W * ss, 1))
    for x in range(W * ss):
        fade.putpixel((x, 0), int(255 * min(1, max(0, (x - 2020 * ss) / (300 * ss)))))
    shelf.putalpha(Image.composite(shelf.getchannel("A"), Image.new("L", shelf.size, 0), fade.resize(shelf.size)))
    img = Image.alpha_composite(img, shelf.resize((W, H), Image.LANCZOS))

    # app icon tile
    tile = icon_tile(400)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([110, 200, 510, 600], radius=90, fill=(0, 0, 0, 150))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(28)))
    img.alpha_composite(tile, (110, 180))
    d = ImageDraw.Draw(img)

    x = 620
    d.text((x, 196), "RECORD-COLLECTION PLAYER", font=font("Inter-Bold.otf", 30), fill=BRASS)
    title = font("InterDisplay-Bold.otf", 168)
    d.text((x - 6, 236), "Cover ", font=title, fill=CREAM)
    d.text((x - 6 + d.textlength("Cover ", font=title), 236), "Flow", font=title, fill=BRASS)
    d.text((x, 432), "Browse your music by its covers.", font=font("Inter-Medium.otf", 46), fill=IVORY)
    d.text((x, 496), "Cover Flow, a grid, and Album View — from mini-player to full screen.", font=font("Inter-Regular.otf", 34), fill=SLATE)

    # translucent pills go on their own layer so they blend instead of punching holes
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    chip = font("Inter-Medium.otf", 30)
    cx = x
    for label, dot in (("3D Cover Flow", BRASS), ("Album View", IVORY), ("Editable queue", (120, 200, 160)), ("FLAC · ALAC · MP3", SLATE)):
        cx += pill(ld, cx, 578, label, chip, 62, (255, 255, 255, 10), (255, 255, 255, 38), IVORY, dot=dot) + 22

    small = font("Inter-SemiBold.otf", 28)
    vx = W - 120 - (d.textlength(f"v{version}", font=small) + 56)
    pill(ld, vx, 70, f"v{version}", small, 58, BRASS + (40,), BRASS + (110,), BRASS)
    mw = d.textlength("Only on macOS", font=small) + 56 + 32
    pill(ld, vx - 24 - mw, 70, "Only on macOS", small, 58, (9, 17, 38, 200), (255, 255, 255, 40), CREAM, dot=IVORY)

    img = Image.alpha_composite(img, layer)
    img.convert("RGB").save(path, optimize=True)


def badge(path, label, value, fill, text):
    """Same construction as the other apps' badges: 34px, Arial bold 11, tracked uppercase."""
    label, value = label.upper(), value.upper()
    lw = round(len(label) * 8.2 + 24)
    vw = round(len(value) * 8.2 + 26)
    w = lw + vw
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="34" viewBox="0 0 {w} 34" role="img" aria-label="{label}: {value}">
  <title>{label}: {value}</title>
  <rect width="{lw}" height="34" fill="{LABEL}"/>
  <rect x="{lw}" width="{vw}" height="34" fill="{fill}"/>
  <g font-family="Arial" font-size="11" font-weight="bold" letter-spacing="1.2" text-anchor="middle">
    <text x="{lw / 2:.1f}" y="21" fill="#faf4e4">{label}</text>
    <text x="{lw + vw / 2:.1f}" y="21" fill="{text}">{value}</text>
  </g>
</svg>
'''
    with open(path, "w") as f:
        f.write(svg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="1.2.2")
    v = ap.parse_args().version
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    app_icon(os.path.join(ROOT, "Resources/AppIcon-1024.png"))
    header(os.path.join(ROOT, "docs/readme-header.png"), v)
    badge(os.path.join(ROOT, "docs/badge-release.svg"), "Release", f"v{v}", "#f2c47d", "#20222c")
    badge(os.path.join(ROOT, "docs/badge-download.svg"), "Download", "macOS app", "#ece7dc", "#16264a")
    badge(os.path.join(ROOT, "docs/badge-platform.svg"), "Platform", "macOS 14+ · Apple silicon + Intel", "#16264a", "#faf4e4")
    print("Wrote icon, header and badges for", v)


if __name__ == "__main__":
    main()
