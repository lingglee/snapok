from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageColor, ImageDraw, ImageFilter, ImageFont

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib

from .model import Annotation

try:
    RESAMPLE_BOX = Image.Resampling.BOX
    RESAMPLE_BILINEAR = Image.Resampling.BILINEAR
    RESAMPLE_NEAREST = Image.Resampling.NEAREST
except AttributeError:  # Pillow shipped by older Ubuntu LTS releases
    RESAMPLE_BOX = Image.BOX
    RESAMPLE_BILINEAR = Image.BILINEAR
    RESAMPLE_NEAREST = Image.NEAREST


def pil_to_pixbuf(image: Image.Image) -> GdkPixbuf.Pixbuf:
    image = image.convert("RGBA")
    width, height = image.size
    return GdkPixbuf.Pixbuf.new_from_bytes(
        GLib.Bytes.new(image.tobytes()),
        GdkPixbuf.Colorspace.RGB,
        True,
        8,
        width,
        height,
        width * 4,
    )


def pixbuf_to_pil(pixbuf: GdkPixbuf.Pixbuf) -> Image.Image:
    channels = pixbuf.get_n_channels()
    mode = "RGBA" if pixbuf.get_has_alpha() else "RGB"
    raw = bytes(pixbuf.get_pixels())
    image = Image.frombytes(
        mode,
        (pixbuf.get_width(), pixbuf.get_height()),
        raw,
        "raw",
        mode,
        pixbuf.get_rowstride(),
        1,
    )
    return image.convert("RGBA") if channels == 4 else image.convert("RGB")


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, max(8, size))
    return ImageFont.load_default()


def normalized_box(points: list[tuple[float, float]]) -> tuple[int, int, int, int]:
    if len(points) < 2:
        x, y = points[0] if points else (0, 0)
        return int(x), int(y), int(x + 1), int(y + 1)
    x1, y1 = points[0]
    x2, y2 = points[-1]
    return int(min(x1, x2)), int(min(y1, y2)), int(max(x1, x2)), int(max(y1, y2))


def _arrow(draw: ImageDraw.ImageDraw, start: tuple[float, float], end: tuple[float, float], color: str, width: int) -> None:
    draw.line([start, end], fill=color, width=width)
    angle = math.atan2(end[1] - start[1], end[0] - start[0])
    size = max(12, width * 4)
    left = (end[0] - size * math.cos(angle - math.pi / 6), end[1] - size * math.sin(angle - math.pi / 6))
    right = (end[0] - size * math.cos(angle + math.pi / 6), end[1] - size * math.sin(angle + math.pi / 6))
    draw.polygon([end, left, right], fill=color)


def _effect(image: Image.Image, annotation: Annotation) -> None:
    box = normalized_box(annotation.points)
    left, top, right, bottom = box
    left, top = max(0, left), max(0, top)
    right, bottom = min(image.width, right), min(image.height, bottom)
    if right <= left or bottom <= top:
        return
    crop = image.crop((left, top, right, bottom))
    if annotation.kind == "erase":
        sample_box = (max(0, left - 3), max(0, top - 3), min(image.width, right + 3), min(image.height, bottom + 3))
        sample = image.crop(sample_box).resize((1, 1), RESAMPLE_BOX).getpixel((0, 0))
        replacement = Image.new(image.mode, crop.size, sample)
    elif annotation.style == "blur":
        replacement = crop.filter(ImageFilter.GaussianBlur(radius=max(4, annotation.width * 2)))
    elif annotation.style == "solid":
        replacement = Image.new(image.mode, crop.size, annotation.color)
    else:
        block = max(6, annotation.width * 2)
        tiny = crop.resize((max(1, crop.width // block), max(1, crop.height // block)), RESAMPLE_BILINEAR)
        replacement = tiny.resize(crop.size, RESAMPLE_NEAREST)
    image.paste(replacement, (left, top))


def render_document(base: Image.Image, annotations: list[Annotation]) -> Image.Image:
    image = base.convert("RGBA").copy()
    for item in annotations:
        if item.kind in {"mosaic", "erase"}:
            _effect(image, item)
            continue
        draw = ImageDraw.Draw(image)
        width = max(1, int(item.width))
        if item.kind == "rectangle":
            draw.rectangle(normalized_box(item.points), outline=item.color, width=width)
        elif item.kind == "ellipse":
            draw.ellipse(normalized_box(item.points), outline=item.color, width=width)
        elif item.kind == "arrow" and len(item.points) >= 2:
            _arrow(draw, item.points[0], item.points[-1], item.color, width)
        elif item.kind == "pen" and len(item.points) >= 2:
            draw.line(item.points, fill=item.color, width=width, joint="curve")
        elif item.kind == "text" and item.points:
            draw.text(item.points[0], item.text, fill=item.color, font=load_font(max(12, width * 5)))
        elif item.kind == "step" and item.points:
            x, y = item.points[0]
            radius = max(12, width * 4)
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=item.color)
            label = str(item.number)
            font = load_font(max(12, int(radius * 1.1)), bold=True)
            bounds = draw.textbbox((0, 0), label, font=font)
            tw, th = bounds[2] - bounds[0], bounds[3] - bounds[1]
            draw.text((x - tw / 2, y - th / 2 - bounds[1]), label, fill="white", font=font)
    return image


def _hex_color(value: str) -> tuple[int, int, int, int]:
    try:
        color = ImageColor.getcolor(value, "RGBA")
        return tuple(color)
    except (ValueError, TypeError):
        pass
    value = value.lstrip("#")
    if len(value) == 6:
        return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4)) + (255,)
    if len(value) == 8:
        return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4, 6))
    return 0, 0, 0, 255


def frame_image(image: Image.Image, options: dict) -> Image.Image:
    if not options.get("enabled"):
        return image
    padding_x = max(0, int(options.get("padding_x", 48)))
    padding_y = max(0, int(options.get("padding_y", 48)))
    shadow = bool(options.get("shadow", True))
    shadow_margin = 24 if shadow else 0
    width = image.width + padding_x * 2 + shadow_margin * 2
    height = image.height + padding_y * 2 + shadow_margin * 2
    start = _hex_color(str(options.get("color_start", "#7c3aed")))
    end = _hex_color(str(options.get("color_end", "#ec4899")))
    if options.get("background") == "solid":
        background = Image.new("RGBA", (width, height), start)
    else:
        start_layer = Image.new("RGBA", (width, height), start)
        end_layer = Image.new("RGBA", (width, height), end)
        # A native Pillow resize keeps large screenshot exports fast while still
        # producing a diagonal-looking two-color gradient.
        horizontal = Image.linear_gradient("L").rotate(90, expand=True).resize((width, height), RESAMPLE_BILINEAR)
        vertical = Image.linear_gradient("L").resize((width, height), RESAMPLE_BILINEAR)
        angle = float(options.get("angle", 35)) % 360
        horizontal_weight = abs(math.cos(math.radians(angle)))
        mask = Image.blend(vertical, horizontal, horizontal_weight)
        background = Image.composite(end_layer, start_layer, mask)
    x = padding_x + shadow_margin
    y = padding_y + shadow_margin
    radius = max(0, min(int(options.get("corner_radius", 18)), min(image.size) // 2))
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width, image.height), radius=radius, fill=255)
    if shadow:
        shadow_layer = Image.new("RGBA", background.size, (0, 0, 0, 0))
        shadow_mask = Image.new("L", background.size, 0)
        ImageDraw.Draw(shadow_mask).rounded_rectangle(
            (x + 5, y + 9, x + image.width + 5, y + image.height + 9), radius=radius, fill=150
        )
        blurred = shadow_mask.filter(ImageFilter.GaussianBlur(14))
        shadow_layer.paste((0, 0, 0, 120), (0, 0), blurred)
        background.alpha_composite(shadow_layer)
    background.paste(image.convert("RGBA"), (x, y), mask)
    border_width = max(0, int(options.get("border_width", 0)))
    if border_width:
        overlay = ImageDraw.Draw(background)
        inset = border_width / 2
        overlay.rounded_rectangle(
            (x + inset, y + inset, x + image.width - inset, y + image.height - inset),
            radius=max(0, radius - int(inset)),
            outline=str(options.get("border_color", "#ffffff")),
            width=border_width,
        )
    if options.get("watermark"):
        draw = ImageDraw.Draw(background)
        font = load_font(max(12, min(image.width, image.height) // 35), bold=True)
        label = "Snapok"
        bounds = draw.textbbox((0, 0), label, font=font)
        tw, th = bounds[2] - bounds[0], bounds[3] - bounds[1]
        draw.text((x + image.width - tw - 14, y + image.height - th - 14), label,
                  fill=(255, 255, 255, 190), font=font, stroke_width=1, stroke_fill=(0, 0, 0, 90))
    return background
