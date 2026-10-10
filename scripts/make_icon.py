#!/usr/bin/env python3
"""Draws the app icon (Resources/AppIcon.icns and docs/icon.png). Needs Pillow: pip3 install pillow."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # drawn at 2x, then downsampled for smooth edges
ROOT = Path(__file__).resolve().parent.parent


def rounded_mask(box, radius):
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    return mask


def gradient(top_left, bottom_right):
    """Diagonal gradient between two RGB colours."""
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(top_left, bottom_right))
    return small.resize((S, S), Image.BICUBIC)


def draw_icon():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    box = (200, 190, 1848, 1838)  # macOS icon grid: ~80% of the canvas, slightly raised for the shadow
    radius = 370

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(rounded_mask((box[0], box[1] + 24, box[2], box[3] + 24), radius).point(lambda a: a * 0.35))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(40)))

    body = gradient((59, 130, 246), (139, 92, 246))  # blue-500 → violet-500
    icon.paste(body, (0, 0), rounded_mask(box, radius))

    # Soft highlight on the upper half for depth.
    gloss = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    ImageDraw.Draw(gloss).ellipse((-200, -1100, S + 200, 1000), fill=(255, 255, 255, 38))
    gloss = gloss.filter(ImageFilter.GaussianBlur(120))
    icon.alpha_composite(Image.composite(gloss, Image.new("RGBA", (S, S)), rounded_mask(box, radius)))

    draw = ImageDraw.Draw(icon)
    # Waveform: seven rounded bars.
    heights = [0.30, 0.55, 0.82, 1.0, 0.70, 0.45, 0.26]
    bar_w, gap, max_h = 92, 62, 860
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x, cy = (S - total) // 2, 1080
    for h in heights:
        half = max_h * h / 2
        draw.rounded_rectangle((x, cy - half, x + bar_w, cy + half), bar_w // 2, fill="white")
        x += bar_w + gap

    # Four-point sparkle (AI notes) in the top-right corner.
    cx, cy, r, w = 1520, 560, 170, 46
    draw.polygon([(cx, cy - r), (cx + w, cy - w), (cx + r, cy), (cx + w, cy + w),
                  (cx, cy + r), (cx - w, cy + w), (cx - r, cy), (cx - w, cy - w)], fill="white")
    return icon.resize((1024, 1024), Image.LANCZOS)


if __name__ == "__main__":
    icon = draw_icon()
    (ROOT / "docs").mkdir(exist_ok=True)
    icon.save(ROOT / "docs" / "icon.png")
    icon.save(ROOT / "Resources" / "AppIcon.icns",
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("Wrote Resources/AppIcon.icns and docs/icon.png")
