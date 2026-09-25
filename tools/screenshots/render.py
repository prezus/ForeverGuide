# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Paint the frame trees tools/screenshots/dump_ui.lua writes into PNG screenshots.

    luajit tools/screenshots/dump_ui.lua build/screenshots
    uv run tools/screenshots/render.py build/screenshots [--font <ttf>] [--scale 2]

Each <scene>.json becomes <scene>.png: the window cropped with a margin, over a dark
backdrop standing in for the game world, at `--scale` times the UI size so it stays
sharp on high-density screens. Anchors resolve the way the client resolves them;
textures come from Textures/ (WHITE8x8 is a solid colour); hover-only HIGHLIGHT
layers are not drawn. The game's font (Friz Quadrata) is not redistributable: pass
it with --font if you have it, otherwise a close system sans is used.
"""
import argparse
import glob
import json
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TEXTURES = os.path.join(ROOT, "Textures")

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "C:/Windows/Fonts/arial.ttf",
]

LAYERS = {"BACKGROUND": 0, "BORDER": 1, "ARTWORK": 2, "OVERLAY": 3}
MARGIN = 28

H_POS = {"LEFT": "left", "TOPLEFT": "left", "BOTTOMLEFT": "left", "RIGHT": "right", "TOPRIGHT": "right", "BOTTOMRIGHT": "right"}
V_POS = {"TOP": "top", "TOPLEFT": "top", "TOPRIGHT": "top", "BOTTOM": "bottom", "BOTTOMLEFT": "bottom", "BOTTOMRIGHT": "bottom"}


def rgba(c, alpha=1.0):
    c = list(c or [1, 1, 1, 1]) + [1] * 4
    return tuple(int(max(0, min(1, v)) * 255) for v in (c[0], c[1], c[2], c[3] * alpha))


class Layout:
    """Rects in UI units, y down from the canvas's top-left, resolved lazily through anchors."""

    def __init__(self, scene, fonts):
        self.canvas = (0, 0, scene["canvas"]["w"], scene["canvas"]["h"])
        self.regions = {r["id"]: r for r in scene["regions"]}
        self.fonts = fonts
        self.rects = {}
        # font strings sized to their own text: the client never cuts those
        self.auto_width = set()

    def text_size(self, r, width=None):
        font = self.fonts(r.get("font") or 12)
        text = plain(r.get("text") or "")
        lines = wrap(text, font, width) if width and not r.get("oneLine") else [text.split("\n")[0]]
        w = max((font.getlength(line) for line in lines), default=0)
        return w, line_height(font) * max(1, len(lines))

    def rect(self, rid):
        if rid is None or rid == 0:
            return self.canvas
        if rid in self.rects:
            return self.rects[rid]
        r = self.regions[rid]
        if r.get("allPoints") is not None:
            out = self.rect(r["allPoints"] or r.get("parent"))
            self.rects[rid] = out
            return out
        edges = {}
        for p in r["points"]:
            tl, tt, tr, tb = self.rect(p.get("rel"))
            rp = p["relPoint"]
            x = {"left": tl, "right": tr}.get(H_POS.get(rp), (tl + tr) / 2) + p["x"]
            y = {"top": tt, "bottom": tb}.get(V_POS.get(rp), (tt + tb) / 2) - p["y"]
            edges[H_POS.get(p["point"], "cx")] = x
            edges[V_POS.get(p["point"], "cy")] = y
        w, h = r.get("w"), r.get("h")
        if "left" in edges and "right" in edges:
            w = edges["right"] - edges["left"]
        if "top" in edges and "bottom" in edges:
            h = edges["bottom"] - edges["top"]
        if r["kind"] == "FontString" and (w is None or h is None):
            if w is None:
                self.auto_width.add(rid)
            tw, th = self.text_size(r, w)
            w, h = (w if w is not None else tw), (h if h is not None else th)
        w, h = w or 0, h or 0
        left = edges.get("left", edges["right"] - w if "right" in edges else edges.get("cx", 0) - w / 2)
        top = edges.get("top", edges["bottom"] - h if "bottom" in edges else edges.get("cy", 0) - h / 2)
        out = (left, top, left + w, top + h)
        self.rects[rid] = out
        return out


CODE = re.compile(r"\|c([0-9a-fA-F]{8})|\|r")


def plain(text):
    """Text without the client's |cAARRGGBB ... |r colour codes."""
    return CODE.sub("", text)


def segments(text, default):
    """(text, colour) runs of a line with colour codes."""
    out, colour, pos = [], default, 0
    for m in CODE.finditer(text):
        if m.start() > pos:
            out.append((text[pos:m.start()], colour))
        if m.group(1):
            a, rr, g, b = (int(m.group(1)[i:i + 2], 16) for i in (0, 2, 4, 6))
            colour = (rr, g, b, default[3])
        else:
            colour = default
        pos = m.end()
    if pos < len(text):
        out.append((text[pos:], colour))
    return out


def line_height(font):
    ascent, descent = font.getmetrics()
    return ascent + descent + 1


def wrap(text, font, width):
    lines = []
    for para in text.split("\n"):
        line = ""
        for word in para.split(" "):
            candidate = word if line == "" else line + " " + word
            if width is None or font.getlength(candidate) <= width or line == "":
                line = candidate
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def truncate(text, font, width):
    """One line as the client draws it: cut with an ellipsis when it does not fit. No slack: a
    label that only just overflows here is cut in the game too (the header's R once showed "..")."""
    line = text.split("\n")[0]
    if width is None or font.getlength(plain(line)) <= width:
        return line
    line = plain(line)
    while line and font.getlength(line + "\u2026") > width:
        line = line[:-1]
    return line.rstrip() + "\u2026"


def texture_image(path, size, coords, tint):
    name = path.replace("\\", "/").rsplit("/", 1)[-1]
    img = Image.open(os.path.join(TEXTURES, name)).convert("RGBA")
    if coords and len(coords) >= 4:
        l, r, t, b = coords[:4]
        img = img.crop((int(l * img.width), int(t * img.height), int(r * img.width), int(b * img.height)))
    img = img.resize(size, Image.LANCZOS)
    if tint:
        tr, tg, tb, ta = (list(tint) + [1])[:4]
        bands = img.split()
        img = Image.merge("RGBA", [bands[0].point(lambda v: v * tr), bands[1].point(lambda v: v * tg), bands[2].point(lambda v: v * tb), bands[3].point(lambda v: v * ta)])
    return img


def world_backdrop(size):
    """A dark, softly lit stand-in for the game world behind the window."""
    w, h = size
    img = Image.new("RGB", size, (22, 26, 34))
    glow = Image.new("L", size, 0)
    ImageDraw.Draw(glow).ellipse((-w * 0.2, -h * 0.6, w * 0.9, h * 0.9), fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(max(w, h) / 6))
    img.paste(Image.new("RGB", size, (58, 70, 88)), (0, 0), glow)
    return img.convert("RGBA")


TIP_PAD = 8
TIP_SIZES = (13, 11)


def tooltip_box(target, lines, fonts, anchor="TOP"):
    """Where the game puts a tooltip: centred above the region (ANCHOR_TOP) or below it (BOTTOM)."""
    w = max(fonts(TIP_SIZES[0] if i == 0 else TIP_SIZES[1]).getlength(line) for i, line in enumerate(lines)) + 2 * TIP_PAD
    h = sum(line_height(fonts(TIP_SIZES[0] if i == 0 else TIP_SIZES[1])) for i in range(len(lines))) + 2 * TIP_PAD
    cx = (target[0] + target[2]) / 2
    if anchor == "BOTTOM":
        return (cx - w / 2, target[3] + 6, cx + w / 2, target[3] + 6 + h)
    return (cx - w / 2, target[1] - 6 - h, cx + w / 2, target[1] - 6)


def draw_tooltip(out, box_px, lines, font_at, scale):
    """A GameTooltip: near-black blue panel, grey-blue rim, the first line white, the rest grey."""
    x0, y0, x1, y1 = box_px
    layer = Image.new("RGBA", out.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((x0, y0, x1, y1), radius=round(3 * scale), fill=(6, 8, 20, 235), outline=(110, 118, 140, 255), width=max(1, round(scale)))
    y = y0 + TIP_PAD * scale
    for i, line in enumerate(lines):
        font = font_at(TIP_SIZES[0] if i == 0 else TIP_SIZES[1])
        d.text((x0 + TIP_PAD * scale, y), line, font=font, fill=(255, 255, 255, 255) if i == 0 else (200, 200, 200, 255))
        y += line_height(font)
    out.alpha_composite(layer)


def draw_ring(out, box_px, scale):
    """A soft gold ring around what the reader should click."""
    x0, y0, x1, y1 = box_px
    pad = round(4 * scale)
    glow = Image.new("RGBA", out.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((x0 - pad, y0 - pad, x1 + pad, y1 + pad), radius=round(6 * scale), outline=(255, 200, 40, 255), width=round(3 * scale))
    out.alpha_composite(glow.filter(ImageFilter.GaussianBlur(3 * scale)))
    out.alpha_composite(glow)


def render(scene, font_path, scale):
    fonts_cache = {}

    def fonts(size, s=1):
        key = (size, s)
        if key not in fonts_cache:
            fonts_cache[key] = ImageFont.truetype(font_path, max(1, round(size * s)))
        return fonts_cache[key]

    layout = Layout(scene, fonts)
    skipped = set()
    cut = set()
    regions = scene["regions"]
    by_id = {r["id"]: r for r in regions}

    def visible(r):
        while r is not None:
            if r.get("shown") is False:
                return False
            r = by_id.get(r.get("parent"))
        return True

    # Crop to everything shown (a drawer hangs below the window) plus the tooltips the marks add.
    shown_rects = [layout.rect(r["id"]) for r in regions if visible(r) and r["kind"] != "FontString"]
    tips = [(m, tooltip_box(layout.rect(m["id"]), m["tooltip"], fonts, m.get("anchor") or "TOP")) for m in scene.get("marks", []) if m.get("tooltip")]
    extent = shown_rects + [t for _, t in tips]
    window = (min(r[0] for r in extent), min(r[1] for r in extent), max(r[2] for r in extent), max(r[3] for r in extent))
    ox, oy = window[0] - MARGIN, window[1] - MARGIN
    size = (round((window[2] - window[0] + 2 * MARGIN) * scale), round((window[3] - window[1] + 2 * MARGIN) * scale))
    out = world_backdrop(size)

    def box(rect):
        return tuple(round(v) for v in ((rect[0] - ox) * scale, (rect[1] - oy) * scale, (rect[2] - ox) * scale, (rect[3] - oy) * scale))

    def clip_of(r):
        """The nearest ScrollFrame above r clips it."""
        p = r.get("parent")
        while p:
            parent = layout.regions[p]
            if parent["kind"] == "ScrollFrame":
                return box(layout.rect(p))
            p = parent.get("parent")
        return None

    def paste(layer_img, at, clip):
        if clip:
            mask = Image.new("L", out.size, 0)
            ImageDraw.Draw(mask).rectangle(clip, fill=255)
            full = Image.new("RGBA", out.size, (0, 0, 0, 0))
            full.paste(layer_img, at)
            full.putalpha(Image.composite(full.getchannel("A"), Image.new("L", out.size, 0), mask))
            out.alpha_composite(full)
        else:
            out.alpha_composite(layer_img, at)

    def draw_rect(rect, fill, clip=None):
        x0, y0, x1, y1 = box(rect)
        if x1 <= x0 or y1 <= y0:
            return
        paste(Image.new("RGBA", (x1 - x0, y1 - y0), fill), (x0, y0), clip)

    def draw_text(r, rect, color, clip):
        text = r.get("text") or ""
        if text == "":
            return
        font = fonts(r.get("font") or 12, scale)
        width = (rect[2] - rect[0]) * scale
        if r.get("oneLine"):
            lines = [truncate(text, font, None if r["id"] in layout.auto_width or width <= 0 else width)]
            if lines[0] != text.split("\n")[0]:
                # a label the client would cut too: say so, a button showing ".." is a UI bug
                cut.add(f"{plain(text)!r} shows as {plain(lines[0])!r}")
        else:
            lines = wrap(plain(text), font, width if width > 0 else None)
        lh = line_height(font)
        x0, y0, x1, y1 = box(rect)
        total = lh * len(lines)
        y = y0 if r.get("justifyV") in (None, "TOP") or r["kind"] == "EditBox" else (y0 + (y1 - y0 - total) / 2 if r.get("justifyV") == "MIDDLE" else y1 - total)
        layer_img = Image.new("RGBA", out.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer_img)
        for line in lines:
            lw = font.getlength(plain(line))
            x = {"CENTER": x0 + (x1 - x0 - lw) / 2, "RIGHT": x1 - lw}.get(r.get("justifyH"), x0)
            for part, colour in segments(line, color):
                if r.get("shadow"):
                    d.text((x + scale, y + scale), part, font=font, fill=(0, 0, 0, 204))
                d.text((x, y), part, font=font, fill=colour)
                x += font.getlength(part)
            y += lh
        paste(layer_img, (0, 0), clip)

    # Paint a frame's own surfaces (backdrop, then its textures by layer), then its children.
    children = {}
    for r in regions:
        children.setdefault(r.get("parent"), []).append(r)

    def paint(r):
        if r.get("shown") is False:
            return
        rect = layout.rect(r["id"])
        clip = clip_of(r)
        bd = r.get("backdrop")
        if bd:
            draw_rect(rect, rgba(bd.get("bg")), clip)
            edge = bd.get("edgeSize") or 1
            border = rgba(bd.get("border"))
            for side in ((rect[0], rect[1], rect[2], rect[1] + edge), (rect[0], rect[3] - edge, rect[2], rect[3]),
                         (rect[0], rect[1], rect[0] + edge, rect[3]), (rect[2] - edge, rect[1], rect[2], rect[3])):
                draw_rect(side, border, clip)
        if r.get("template") == "InputBoxTemplate":
            # Blizzard's input box: a dark field with a light rim.
            draw_rect(rect, (8, 8, 8, 235), clip)
            for side in ((rect[0] - 5, rect[1], rect[2], rect[1] + 1), (rect[0] - 5, rect[3] - 1, rect[2], rect[3]),
                         (rect[0] - 5, rect[1], rect[0] - 4, rect[3]), (rect[2] - 1, rect[1], rect[2], rect[3])):
                draw_rect(side, (120, 120, 120, 255), clip)
        kids = children.get(r["id"], [])
        textures = sorted((k for k in kids if k["kind"] == "Texture" and k.get("layer") in LAYERS), key=lambda k: LAYERS[k["layer"]])
        for t in textures:
            trect = layout.rect(t["id"])
            if t.get("colorTexture"):
                draw_rect(trect, rgba(t["colorTexture"], t.get("alpha") or 1), clip)
            elif t.get("texture", "").replace("\\", "/").endswith("WHITE8x8"):
                draw_rect(trect, rgba(t.get("vertex"), t.get("alpha") or 1), clip)
            elif t.get("texture") and "addons/foreverguide/textures/" not in t["texture"].replace("\\", "/").lower():
                # the game's own art (Interface\\Buttons, ChatFrame, ...) is not in this repo to paint
                skipped.add(t["texture"])
            elif t.get("texture"):
                x0, y0, x1, y1 = box(trect)
                if x1 > x0 and y1 > y0:
                    paste(texture_image(t["texture"], (x1 - x0, y1 - y0), t.get("texCoord"), t.get("vertex")), (x0, y0), clip)
        if r["kind"] in ("FontString", "EditBox"):
            inset = (rect[0] + 1, rect[1] + 5, rect[2] - 4, rect[3]) if r.get("template") == "InputBoxTemplate" else rect
            draw_text(r, inset, rgba(r.get("textColor") or [1, 1, 1, 1]), clip)
        for k in kids:
            if k["kind"] != "Texture":
                paint(k)

    paint(regions[0])
    for m in scene.get("marks", []):
        if m.get("ring"):
            draw_ring(out, box(layout.rect(m["id"])), scale)
    for m, tip in tips:
        draw_tooltip(out, box(tip), m["tooltip"], lambda size: fonts(size, scale), scale)
    for name in sorted(skipped):
        print(f"  {scene['scene']}: skipped game texture {name}")
    for label in sorted(cut):
        print(f"  {scene['scene']}: truncated {label}")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dir")
    ap.add_argument("--font")
    ap.add_argument("--scale", type=float, default=2)
    args = ap.parse_args()
    font = args.font or next((f for f in FONT_CANDIDATES if os.path.exists(f)), None)
    if font is None:
        sys.exit("no font found: pass one with --font")
    for path in sorted(glob.glob(os.path.join(args.dir, "*.json"))):
        png = path[:-5] + ".png"
        render(json.load(open(path)), font, args.scale).convert("RGB").save(png, optimize=True)
        print("wrote " + png)


if __name__ == "__main__":
    main()
