#!/usr/bin/env python3
"""Make Vane Dev's icons from Vane's.

Debug builds install as a separate app, "Vane Dev", beside the real Vane on
every device (see the `configs: Debug` blocks in project.yml). The two have to
be told apart at a glance: on an iPad home screen, in the Dock, on the TV's top
row. So the Dev icon is the same artwork with the colour taken out and an
orange DEV tag on it. Grey tells them apart at 16 px, where the words cannot be
read; the tag says why at every size where they can.

Derived, never drawn by hand, so a change to Vane's icon reaches Vane Dev by
running this again:

    python3 Scripts/make-dev-icons.py

Writes AppIcon-Dev.appiconset (Mac and iOS) and AppIcon-Dev.brandassets (tvOS)
next to the originals, which it only reads.
"""

import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent.parent
MAC_IOS = ROOT / "Weather/Assets.xcassets"
TV = ROOT / "VaneTV/Assets.xcassets"

TAG = (255, 106, 26)  # orange: the one colour left in the icon, so the eye goes to it
FONT = "/System/Library/Fonts/SFNS.ttf"


def grey(img: Image.Image) -> Image.Image:
    """The artwork with its colour removed, and its transparency kept."""
    img = img.convert("RGBA")
    g = ImageOps.grayscale(img.convert("RGB"))
    out = Image.merge("RGBA", (g, g, g, img.getchannel("A")))
    return out


def tag(img: Image.Image, cx: float, cy: float, height: float) -> Image.Image:
    """Draw the DEV pill centred at (cx, cy), in fractions of the image size.

    Drawn at 4x and scaled down, because PIL does not antialias shapes."""
    w, h = img.size
    s = 4
    layer = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    ph = height * h * s
    font = ImageFont.truetype(FONT, int(ph * 0.62))
    font.set_variation_by_name("Heavy")
    text = "DEV"
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    pw = (r - l) + ph * 1.1
    x0, y0 = cx * w * s - pw / 2, cy * h * s - ph / 2
    d.rounded_rectangle((x0, y0, x0 + pw, y0 + ph), radius=ph / 2, fill=TAG + (255,))
    d.text((x0 + pw / 2, y0 + ph / 2), text, font=font, fill=(255, 255, 255, 255), anchor="mm")
    layer = layer.resize((w, h), Image.LANCZOS)
    return Image.alpha_composite(img.convert("RGBA"), layer)


def mac_and_ios() -> None:
    src = MAC_IOS / "AppIcon.appiconset"
    dst = MAC_IOS / "AppIcon-Dev.appiconset"
    shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir()
    shutil.copy(src / "Contents.json", dst / "Contents.json")

    # Every size from the largest source, so the tag is drawn once at full
    # resolution rather than squeezed into a 16 px original.
    mac = tag(grey(Image.open(src / "icon_512x512@2x.png")), 0.5, 0.80, 0.13)
    ios = tag(grey(Image.open(src / "icon-ios-1024.png")), 0.5, 0.80, 0.14)

    for entry in json.loads((src / "Contents.json").read_text())["images"]:
        name = entry["filename"]
        size = Image.open(src / name).size
        base = ios if entry["idiom"] == "universal" else mac
        out = base.resize(size, Image.LANCZOS)
        if entry["idiom"] == "universal":
            out = out.convert("RGB")  # the App Store refuses an iOS icon with alpha
        out.save(dst / name)


def tv() -> None:
    src = TV / "App Icon & Top Shelf Image.brandassets"
    dst = TV / "AppIcon-Dev.brandassets"
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)

    for png in dst.rglob("*.png"):
        img = grey(Image.open(png))
        # The tag rides the front layer, so it floats with the needle when the
        # icon tilts under focus instead of sliding against it.
        if "Front.imagestacklayer" in png.parts:
            img = tag(img, 0.5, 0.84, 0.16)
        elif "Top Shelf" in str(png):
            img = tag(img, 0.5, 0.86, 0.09)
        img.save(png)


if __name__ == "__main__":
    mac_and_ios()
    tv()
    print("Wrote AppIcon-Dev.appiconset and AppIcon-Dev.brandassets")
