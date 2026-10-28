"""Poster / icon for Tripping Zombies MP Fix, in the style of the ZombieSync / SmoothRide art
(dark grid, Bahnschrift, white + teal title, MP / B42 badges, flat zombie, teal glow line).

  python -I make_art.py      writes mod/.../42/poster.png, 42/icon.png and docs/preview.png
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
FONT = r"C:\Windows\Fonts\bahnschrift.ttf"
TEAL = (34, 211, 197)
WHITE = (240, 244, 246)
GREY = (150, 164, 176)
BG0, BG1 = (13, 18, 22), (22, 30, 36)
SKIN = (196, 204, 178)
SHIRT = (74, 86, 98)
PANTS = (52, 61, 70)
EYE = (230, 40, 40)


def font(size, style="Bold"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(style)
    except Exception:
        pass
    return f


def background(w, h):
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        k = y / (h - 1)
        c = tuple(int(BG0[i] + (BG1[i] - BG0[i]) * k) for i in range(3))
        for x in range(w):
            px[x, y] = c
    d = ImageDraw.Draw(im)
    for x in range(0, w, 32):
        d.line([(x, 0), (x, h)], fill=(26, 35, 42))
    for y in range(0, h, 32):
        d.line([(0, y), (w, y)], fill=(26, 35, 42))
    return im


def spaced(d, xy, text, f, fill, spacing):
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=f, fill=fill)
        x += d.textlength(ch, font=f) + spacing
    return x


def text_width(d, text, f, spacing):
    return sum(d.textlength(ch, font=f) for ch in text) + spacing * (len(text) - 1)


def limb(d, a, b, width, fill):
    d.line([a, b], fill=fill, width=width)
    r = width // 2
    for p in (a, b):
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=fill)


def rot(p, origin, ang):
    ox, oy = origin
    x, y = p[0] - ox, p[1] - oy
    c, s = math.cos(ang), math.sin(ang)
    return (ox + x * c - y * s, oy + x * s + y * c)


def zombie(layer, foot, scale, tilt, colors=None, alpha=255):
    """A tripping zombie: pivots forward around its front foot by `tilt` radians, arms thrown forward."""
    d = ImageDraw.Draw(layer)
    sk, sh, pa, ey = colors or (SKIN, SHIRT, PANTS, EYE)
    fx, fy = foot
    s = scale
    o = (fx, fy)
    hip = rot((fx - 6 * s, fy - 52 * s), o, tilt)
    neck = rot((fx - 4 * s, fy - 100 * s), o, tilt)
    head = rot((fx - 2 * s, fy - 116 * s), o, tilt)
    back_foot = rot((fx - 40 * s, fy - 22 * s), o, tilt * 0.4)
    knee_b = rot((fx - 30 * s, fy - 40 * s), o, tilt * 0.8)
    knee_f = rot((fx + 4 * s, fy - 26 * s), o, tilt * 0.6)
    sh_pt = rot((fx - 2 * s, fy - 92 * s), o, tilt)
    hand1 = rot((fx + 40 * s, fy - 102 * s), o, tilt * 1.15)
    hand2 = rot((fx + 36 * s, fy - 90 * s), o, tilt * 1.15)
    elbow1 = rot((fx + 18 * s, fy - 98 * s), o, tilt * 1.1)
    elbow2 = rot((fx + 14 * s, fy - 88 * s), o, tilt * 1.1)
    w_leg, w_arm = int(13 * s), int(9 * s)
    a = alpha
    limb(d, hip, knee_b, w_leg, pa + (a,))
    limb(d, knee_b, back_foot, w_leg, pa + (a,))
    limb(d, sh_pt, elbow2, w_arm, sk + (a,))
    limb(d, elbow2, hand2, w_arm, sk + (a,))
    limb(d, hip, knee_f, w_leg, pa + (a,))
    limb(d, knee_f, (fx, fy), w_leg, pa + (a,))
    limb(d, hip, neck, int(26 * s), sh + (a,))
    limb(d, sh_pt, elbow1, w_arm, sk + (a,))
    limb(d, elbow1, hand1, w_arm, sk + (a,))
    r = 14 * s
    d.ellipse([head[0] - r, head[1] - r, head[0] + r, head[1] + r], fill=sk + (a,))
    e = 2.6 * s
    eye = rot((head[0] + 7 * s, head[1] - 2 * s), head, 0)
    d.ellipse([eye[0] - e, eye[1] - e, eye[0] + e, eye[1] + e], fill=ey + (a,))


def glow_line(im, pts, width, color):
    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.line(pts, fill=color + (150,), width=width * 5, joint="curve")
    layer = layer.filter(ImageFilter.GaussianBlur(width * 3))
    d = ImageDraw.Draw(layer)
    d.line(pts, fill=color + (255,), width=width, joint="curve")
    im.alpha_composite(layer)


def poster(size=512):
    s = size / 512
    im = background(size, size).convert("RGBA")
    d = ImageDraw.Draw(im)
    f1 = font(int(86 * s))
    d.text((int(30 * s), int(24 * s)), "TRIPPING", font=f1, fill=WHITE)
    # teal second line with a soft glow
    glow = Image.new("RGBA", im.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.text((int(30 * s), int(108 * s)), "MP FIX", font=f1, fill=TEAL + (200,))
    glow = glow.filter(ImageFilter.GaussianBlur(10 * s))
    im.alpha_composite(glow)
    d = ImageDraw.Draw(im)
    d.text((int(30 * s), int(108 * s)), "MP FIX", font=f1, fill=TEAL)
    # badges
    fb = font(int(26 * s), "SemiBold")
    bx, by, bh = int(318 * s), int(132 * s), int(40 * s)
    d.rounded_rectangle([bx, by, bx + int(72 * s), by + bh], radius=int(7 * s), fill=TEAL)
    d.text((bx + int(16 * s), by + int(5 * s)), "MP", font=fb, fill=(10, 30, 32))
    bx2 = bx + int(84 * s)
    d.rounded_rectangle([bx2, by, bx2 + int(84 * s), by + bh], radius=int(7 * s), outline=(200, 208, 214), width=max(1, int(2 * s)))
    d.text((bx2 + int(16 * s), by + int(5 * s)), "B42", font=fb, fill=(220, 226, 230))
    # ground
    gy = int(372 * s)
    d.rectangle([0, gy, size, size], fill=(17, 23, 27))
    d.line([(0, gy), (size, gy)], fill=(40, 52, 60), width=max(1, int(2 * s)))
    # the copy (teal ghost) and the real zombie, falling the same way at the same time
    ghost = Image.new("RGBA", im.size, (0, 0, 0, 0))
    zombie(ghost, (int(300 * s), gy), 1.4 * s, 0.5,
           colors=(TEAL, (20, 130, 122), (16, 104, 98), (220, 255, 250)), alpha=105)
    ghost = ghost.filter(ImageFilter.GaussianBlur(1.2 * s))
    im.alpha_composite(ghost, (int(-26 * s), 0))
    real = Image.new("RGBA", im.size, (0, 0, 0, 0))
    zombie(real, (int(300 * s), gy), 1.4 * s, 0.5)
    im.alpha_composite(real)
    d = ImageDraw.Draw(im)
    # glow line with the step trace
    pts = [(x * s, (440 + 10 * math.sin(x / 70.0)) * s) for x in range(0, 513, 8)]
    steps = [(60 * s, 412 * s), (120 * s, 412 * s), (120 * s, 396 * s), (190 * s, 396 * s), (190 * s, 412 * s),
             (260 * s, 412 * s), (260 * s, 396 * s), (330 * s, 396 * s)]
    d.line(steps, fill=(70, 86, 96), width=max(1, int(2 * s)))
    glow_line(im, pts, max(2, int(3 * s)), TEAL)
    d = ImageDraw.Draw(im)
    fc = font(int(19 * s), "SemiBold")
    cap = "SAME TRIPS FOR EVERY PLAYER"
    w = text_width(d, cap, fc, 3 * s)
    spaced(d, ((size - w) / 2, int(474 * s)), cap, fc, (190, 200, 210), 3 * s)
    return im.convert("RGB")


def icon(size=128):
    im = background(size, size).convert("RGBA")
    gy = int(size * 0.86)
    d = ImageDraw.Draw(im)
    d.line([(0, gy), (size, gy)], fill=(40, 52, 60), width=2)
    s = size / 128
    ghost = Image.new("RGBA", im.size, (0, 0, 0, 0))
    zombie(ghost, (int(70 * s), gy), 0.78 * s, 0.62, colors=(TEAL, (20, 130, 122), (16, 104, 98), (220, 255, 250)), alpha=130)
    im.alpha_composite(ghost, (int(-10 * s), int(-3 * s)))
    real = Image.new("RGBA", im.size, (0, 0, 0, 0))
    zombie(real, (int(70 * s), gy), 0.78 * s, 0.62)
    im.alpha_composite(real)
    d = ImageDraw.Draw(im)
    fb = font(int(26 * s), "Bold")
    d.rounded_rectangle([int(6 * s), int(6 * s), int(52 * s), int(36 * s)], radius=int(5 * s), fill=TEAL)
    d.text((int(12 * s), int(7 * s)), "MP", font=fb, fill=(10, 30, 32))
    return im.convert("RGB")


if __name__ == "__main__":
    mod42 = os.path.join(PROJ, "mod", "TrippingZombiesMPFix", "42")
    if not os.path.isdir(mod42):  # GitHub repo: 42/ at the root
        mod42 = os.path.join(PROJ, "42")
    docs = os.path.join(PROJ, "docs")
    os.makedirs(docs, exist_ok=True)
    p = poster(512)
    p.save(os.path.join(mod42, "poster.png"))
    p.save(os.path.join(docs, "preview.png"))
    icon(128).save(os.path.join(mod42, "icon.png"))
    print("written:", os.path.join(mod42, "poster.png"), os.path.join(mod42, "icon.png"), os.path.join(docs, "preview.png"))
