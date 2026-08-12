#!/usr/bin/env python3
"""Generate EggplantRecorder Dock/Finder app icon (1024 master → build/appicon.png).

Shape rules (shared with macos-app-icon skill / Fred app-icon.md):
- 1024×1024 canvas
- continuous rounded rect, corner radius ≈ 22.37% of edge
- transparent corners for classic .icns

This app’s art: near-black field, light monitor, red REC.
(EggplantFred’s purple field is Fred-only artwork — not a shared brand rule.)

Usage:
  python3 scripts/generate_app_icon.py
  # then: wails3 package  (classic icons.icns only; no Assets.car)
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "appicon.png"
MASTER = ROOT / "build" / "AppIcon-1024-master.png"

CORNER_RADIUS_FRAC = 0.2237

# Near-black field (slight cool lift toward top-left)
BG_CENTER = (38, 40, 46, 255)
BG_MID = (22, 23, 27, 255)
BG_EDGE = (10, 11, 14, 255)

# Light aluminum monitor
BEZEL = (236, 238, 242, 255)
BEZEL_SHADE = (198, 202, 210, 255)
BEZEL_DARK = (150, 155, 165, 255)
SCREEN = (18, 19, 24, 255)
SCREEN_INNER = (28, 30, 38, 255)
REC_RED = (230, 62, 62, 255)
REC_RED_DARK = (170, 38, 42, 255)


def _lerp(a: tuple[int, ...], b: tuple[int, ...], t: float) -> tuple[int, ...]:
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def paint_background(size: int) -> Image.Image:
    """Soft charcoal radial — reads as black in Dock, not flat void."""
    im = Image.new("RGBA", (size, size))
    px = im.load()
    cx, cy = size * 0.40, size * 0.36
    max_d = (size * 0.90) ** 2
    for y in range(size):
        for x in range(size):
            d = ((x - cx) ** 2 + (y - cy) ** 2) / max_d
            t = min(1.0, d**0.9)
            if t < 0.4:
                c = _lerp(BG_CENTER, BG_MID, t / 0.4)
            else:
                c = _lerp(BG_MID, BG_EDGE, (t - 0.4) / 0.6)
            px[x, y] = c
    return im


def compose(size: int = 1024) -> Image.Image:
    base = paint_background(size)

    mx0, my0 = int(size * 0.18), int(size * 0.20)
    mx1, my1 = int(size * 0.82), int(size * 0.66)
    r = int(size * 0.055)

    # Soft contact shadow on dark field
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        (
            mx0 + int(size * 0.01),
            my0 + int(size * 0.02),
            mx1 + int(size * 0.01),
            my1 + int(size * 0.04),
        ),
        radius=r,
        fill=(0, 0, 0, 120),
    )
    # Stand shadow
    sd.ellipse(
        (int(size * 0.30), int(size * 0.78), int(size * 0.70), int(size * 0.88)),
        fill=(0, 0, 0, 90),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=size * 0.02))
    base = Image.alpha_composite(base, shadow)

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Bezel
    d.rounded_rectangle((mx0, my0, mx1, my1), radius=r, fill=BEZEL)
    inset = int(size * 0.012)
    d.rounded_rectangle(
        (mx0 + inset, my0 + inset, mx1 - inset // 2, my1 - inset // 2),
        radius=max(1, r - inset),
        fill=BEZEL_SHADE,
    )
    d.rounded_rectangle(
        (mx0 + inset, my0 + inset, mx1 - int(size * 0.04), my1 - int(size * 0.04)),
        radius=max(1, r - inset),
        fill=BEZEL,
    )

    # Screen
    sx0, sy0 = int(size * 0.24), int(size * 0.27)
    sx1, sy1 = int(size * 0.76), int(size * 0.58)
    sr = int(size * 0.03)
    d.rounded_rectangle((sx0, sy0, sx1, sy1), radius=sr, fill=SCREEN)
    d.rounded_rectangle(
        (
            sx0 + int(size * 0.015),
            sy0 + int(size * 0.015),
            sx1 - int(size * 0.015),
            sy1 - int(size * 0.015),
        ),
        radius=max(1, sr - 3),
        fill=SCREEN_INNER,
    )
    d.rounded_rectangle(
        (
            sx0 + int(size * 0.025),
            sy0 + int(size * 0.025),
            sx1 - int(size * 0.025),
            sy1 - int(size * 0.025),
        ),
        radius=max(1, sr - 5),
        fill=SCREEN,
    )

    # REC
    cx, cy = (sx0 + sx1) // 2, (sy0 + sy1) // 2
    rad = int(size * 0.09)
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        (cx - rad - 16, cy - rad - 16, cx + rad + 16, cy + rad + 16),
        fill=(230, 62, 62, 60),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=14))
    layer = Image.alpha_composite(layer, glow)
    d = ImageDraw.Draw(layer)
    d.ellipse(
        (cx - rad + 3, cy - rad + 6, cx + rad + 1, cy + rad + 3),
        fill=REC_RED_DARK,
    )
    d.ellipse((cx - rad, cy - rad, cx + rad, cy + rad), fill=REC_RED)

    # Stand
    neck_w = int(size * 0.06)
    neck_x0 = (size - neck_w) // 2
    neck_y0, neck_y1 = my1 - int(size * 0.01), int(size * 0.78)
    d.rectangle((neck_x0, neck_y0, neck_x0 + neck_w, neck_y1), fill=BEZEL_SHADE)
    d.rectangle((neck_x0 + 2, neck_y0, neck_x0 + neck_w // 2, neck_y1), fill=BEZEL)

    bx0, bx1 = int(size * 0.32), int(size * 0.68)
    by0, by1 = int(size * 0.76), int(size * 0.84)
    d.ellipse((bx0, by0, bx1, by1), fill=BEZEL_DARK)
    d.ellipse((bx0 + 6, by0 + 2, bx1 - 6, by1 - 8), fill=BEZEL)

    return Image.alpha_composite(base, layer)


def apply_macos_icon_mask(im: Image.Image) -> Image.Image:
    im = im.convert("RGBA")
    w, h = im.size
    if im.getpixel((0, 0))[3] < 16 and im.getpixel((w - 1, 0))[3] < 16:
        return im
    radius = max(1, int(round(min(w, h) * CORNER_RADIUS_FRAC)))
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=255)
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(im, (0, 0), mask=mask)
    return out


def main() -> None:
    im = apply_macos_icon_mask(compose(1024))
    MASTER.parent.mkdir(parents=True, exist_ok=True)
    im.save(MASTER, format="PNG")
    im.save(OUT, format="PNG")
    print(f"wrote {MASTER}")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
