from __future__ import annotations

import copy
import os
from pathlib import Path

from PIL import Image, ImageFilter, ImageOps

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk

from .history import HistoryStore, Settings
from .images import frame_image, pil_to_pixbuf, render_document
from .model import Annotation, Document
from .ocr import OCRError, sensitive_words, text as recognize_text
from .pin import PinnedImageWindow
from .style import css


TOOLS = [
    ("pointer", "Select", "V"),
    ("hand", "Hand", "H"),
    ("rectangle", "Rectangle", "R"),
    ("ellipse", "Ellipse", "O"),
    ("arrow", "Arrow", "A"),
    ("pen", "Pen", "P"),
    ("text", "Text", "T"),
    ("mosaic", "Mosaic", "M"),
    ("erase", "Erase", "E"),
    ("step", "Step", "N"),
]

MIN_ZOOM = 0.1
MAX_ZOOM = 4.0


def zoom_after_scroll(current: float, direction: Gdk.ScrollDirection, delta_y: float = 0.0) -> float:
    """Return the next zoom level for a discrete or smooth wheel event."""
    if direction == Gdk.ScrollDirection.UP:
        factor = 1.15
    elif direction == Gdk.ScrollDirection.DOWN:
        factor = 1 / 1.15
    elif direction == Gdk.ScrollDirection.SMOOTH and delta_y:
        factor = 1.15 ** -delta_y
    else:
        return current
    return max(MIN_ZOOM, min(MAX_ZOOM, current * factor))


class Canvas(Gtk.DrawingArea):
    def __init__(self, document: Document, base: Image.Image, changed) -> None:
        super().__init__()
        self.document = document
        self.base = base.convert("RGBA")
        self.changed = changed
        self.tool = "rectangle"
        self.color = "#ec4899"
        self.width = 4
        self.mosaic_style = "pixelate"
        self.zoom = 1.0
        self.start: tuple[float, float] | None = None
        self.current: Annotation | None = None
        self.undo_stack: list[list[Annotation]] = []
        self.redo_stack: list[list[Annotation]] = []
        self.selected: int | None = None
        self.drag_origin: tuple[float, float] | None = None
        self.original_points: list[tuple[float, float]] | None = None
        self.scroller: Gtk.ScrolledWindow | None = None
        self.zoom_request = None
        self.pan_origin: tuple[float, float] | None = None
        self.pan_adjustments: tuple[float, float] | None = None
        self.pan_button: int | None = None
        self.space_pan = False
        self.set_can_focus(True)
        self.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
            | Gdk.EventMask.SCROLL_MASK
            | Gdk.EventMask.SMOOTH_SCROLL_MASK
            | Gdk.EventMask.KEY_PRESS_MASK
        )
        self.connect("draw", self._draw)
        self.connect("button-press-event", self._press)
        self.connect("motion-notify-event", self._motion)
        self.connect("button-release-event", self._release)
        self.connect("scroll-event", self._scroll)
        self.connect("key-press-event", self._key)
        self.connect("realize", lambda *_: self.update_cursor())
        self._resize()

    def bind_scroller(self, scroller: Gtk.ScrolledWindow, zoom_request) -> None:
        self.scroller = scroller
        self.zoom_request = zoom_request

    def set_tool(self, tool: str) -> None:
        self.tool = tool
        self.update_cursor()

    def update_cursor(self, dragging: bool = False) -> None:
        window = self.get_window()
        if window is None:
            return
        if dragging:
            name = "grabbing"
        elif self.tool == "hand" or self.space_pan:
            name = "grab"
        elif self.tool == "pointer":
            name = "default"
        else:
            name = "crosshair"
        cursor = Gdk.Cursor.new_from_name(self.get_display(), name)
        window.set_cursor(cursor)

    def set_zoom(self, value: float, anchor: tuple[float, float] | None = None) -> None:
        value = max(MIN_ZOOM, min(MAX_ZOOM, value))
        if abs(value - self.zoom) < 0.0001:
            return
        old_zoom = self.zoom
        restore = None
        if self.scroller is not None:
            horizontal = self.scroller.get_hadjustment()
            vertical = self.scroller.get_vadjustment()
            allocation = self.get_allocation()
            if anchor is None:
                view_x = horizontal.get_page_size() / 2
                view_y = vertical.get_page_size() / 2
                local_x = horizontal.get_value() + view_x - allocation.x
                local_y = vertical.get_value() + view_y - allocation.y
            else:
                local_x, local_y = anchor
                view_x = allocation.x + local_x - horizontal.get_value()
                view_y = allocation.y + local_y - vertical.get_value()
            restore = (horizontal, vertical, local_x, local_y, view_x, view_y, value / old_zoom)
        self.zoom = value
        self._resize()
        if restore is not None:
            GLib.idle_add(self._restore_zoom_anchor, *restore)

    def _restore_zoom_anchor(
        self,
        horizontal: Gtk.Adjustment,
        vertical: Gtk.Adjustment,
        local_x: float,
        local_y: float,
        view_x: float,
        view_y: float,
        ratio: float,
    ) -> bool:
        allocation = self.get_allocation()
        horizontal.set_value(allocation.x + local_x * ratio - view_x)
        vertical.set_value(allocation.y + local_y * ratio - view_y)
        return False

    def _resize(self) -> None:
        width, height = self.base.size
        if self.document.frame.get("enabled"):
            width += 2 * (int(self.document.frame.get("padding_x", 48)) + (24 if self.document.frame.get("shadow") else 0))
            height += 2 * (int(self.document.frame.get("padding_y", 48)) + (24 if self.document.frame.get("shadow") else 0))
        self.set_size_request(max(1, int(width * self.zoom)), max(1, int(height * self.zoom)))
        self.queue_draw()

    def point(self, x: float, y: float) -> tuple[float, float]:
        ox, oy = self._frame_offset()
        return (max(0, min(self.base.width, x / self.zoom - ox)),
                max(0, min(self.base.height, y / self.zoom - oy)))

    def _frame_offset(self) -> tuple[int, int]:
        if not self.document.frame.get("enabled"):
            return 0, 0
        margin = 24 if self.document.frame.get("shadow") else 0
        return int(self.document.frame.get("padding_x", 48)) + margin, int(self.document.frame.get("padding_y", 48)) + margin

    def rendered(self, include_current: bool = True, styled: bool = False) -> Image.Image:
        annotations = list(self.document.annotations)
        if include_current and self.current:
            annotations.append(self.current)
        image = render_document(self.base, annotations)
        return frame_image(image, self.document.frame) if styled else image

    def _draw(self, _widget, context) -> bool:
        image = self.rendered(styled=True)
        context.save()
        context.scale(self.zoom, self.zoom)
        Gdk.cairo_set_source_pixbuf(context, pil_to_pixbuf(image), 0, 0)
        context.paint()
        context.restore()
        if self.selected is not None and self.selected < len(self.document.annotations):
            item = self.document.annotations[self.selected]
            xs = [point[0] for point in item.points]
            ys = [point[1] for point in item.points]
            if xs and ys:
                ox, oy = self._frame_offset()
                context.set_source_rgb(0.15, 0.55, 1.0)
                context.set_line_width(1)
                context.set_dash([5, 4])
                context.rectangle((min(xs) + ox) * self.zoom - 4, (min(ys) + oy) * self.zoom - 4,
                                  max(8, (max(xs) - min(xs)) * self.zoom + 8),
                                  max(8, (max(ys) - min(ys)) * self.zoom + 8))
                context.stroke()
        return True

    def checkpoint(self) -> None:
        self.undo_stack.append(copy.deepcopy(self.document.annotations))
        if len(self.undo_stack) > 100:
            self.undo_stack.pop(0)
        self.redo_stack.clear()

    def undo(self) -> None:
        if not self.undo_stack:
            return
        self.redo_stack.append(copy.deepcopy(self.document.annotations))
        self.document.annotations = self.undo_stack.pop()
        self.selected = None
        self.changed()
        self.queue_draw()

    def redo(self) -> None:
        if not self.redo_stack:
            return
        self.undo_stack.append(copy.deepcopy(self.document.annotations))
        self.document.annotations = self.redo_stack.pop()
        self.selected = None
        self.changed()
        self.queue_draw()

    def _hit(self, point: tuple[float, float]) -> int | None:
        x, y = point
        tolerance = 10 / self.zoom
        for index in range(len(self.document.annotations) - 1, -1, -1):
            item = self.document.annotations[index]
            if not item.points:
                continue
            xs = [p[0] for p in item.points]
            ys = [p[1] for p in item.points]
            if min(xs) - tolerance <= x <= max(xs) + tolerance and min(ys) - tolerance <= y <= max(ys) + tolerance:
                return index
            if item.kind in {"text", "step"} and abs(xs[0] - x) <= 30 and abs(ys[0] - y) <= 30:
                return index
        return None

    def _press(self, _widget, event) -> bool:
        self.grab_focus()
        if event.button == 2 or (event.button == 1 and (self.tool == "hand" or self.space_pan)):
            if self.scroller is not None:
                self.pan_origin = (event.x_root, event.y_root)
                self.pan_adjustments = (
                    self.scroller.get_hadjustment().get_value(),
                    self.scroller.get_vadjustment().get_value(),
                )
                self.pan_button = event.button
                self.update_cursor(dragging=True)
            return True
        if event.button != 1:
            return False
        point = self.point(event.x, event.y)
        if self.tool == "pointer":
            self.selected = self._hit(point)
            if self.selected is not None:
                self.checkpoint()
                self.drag_origin = point
                self.original_points = copy.deepcopy(self.document.annotations[self.selected].points)
            self.queue_draw()
            return True
        self.checkpoint()
        self.start = point
        if self.tool == "step":
            number = max((item.number for item in self.document.annotations if item.kind == "step"), default=0) + 1
            self.document.annotations.append(Annotation("step", [point], self.color, self.width, number=number))
            self.start = None
            self.changed()
            self.queue_draw()
            return True
        self.current = Annotation(
            self.tool,
            [point],
            self.color,
            self.width,
            style=self.mosaic_style,
        )
        return True

    def _motion(self, _widget, event) -> bool:
        if self.pan_origin and self.pan_adjustments and self.scroller is not None:
            dx = event.x_root - self.pan_origin[0]
            dy = event.y_root - self.pan_origin[1]
            self.scroller.get_hadjustment().set_value(self.pan_adjustments[0] - dx)
            self.scroller.get_vadjustment().set_value(self.pan_adjustments[1] - dy)
            return True
        point = self.point(event.x, event.y)
        if self.tool == "pointer" and self.selected is not None and self.drag_origin and self.original_points:
            dx, dy = point[0] - self.drag_origin[0], point[1] - self.drag_origin[1]
            self.document.annotations[self.selected].points = [(x + dx, y + dy) for x, y in self.original_points]
            self.queue_draw()
        elif self.current:
            if self.current.kind == "pen":
                self.current.points.append(point)
            elif len(self.current.points) == 1:
                self.current.points.append(point)
            else:
                self.current.points[-1] = point
            self.queue_draw()
        return True

    def _release(self, _widget, event) -> bool:
        if self.pan_origin and event.button == self.pan_button:
            self.pan_origin = None
            self.pan_adjustments = None
            self.pan_button = None
            self.update_cursor()
            return True
        if event.button != 1:
            return False
        if self.tool == "pointer":
            if self.drag_origin:
                self.changed()
            self.drag_origin = None
            self.original_points = None
            return True
        if not self.current:
            return True
        point = self.point(event.x, event.y)
        if len(self.current.points) == 1:
            self.current.points.append(point)
        elif self.current.kind != "pen":
            self.current.points[-1] = point
        if self.current.kind == "text":
            dialog = Gtk.Dialog(title="Add text", transient_for=self.get_toplevel(), modal=True)
            dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
            dialog.add_button("Add", Gtk.ResponseType.OK)
            entry = Gtk.Entry()
            entry.set_activates_default(True)
            entry.set_margin_top(12)
            entry.set_margin_bottom(12)
            entry.set_margin_start(12)
            entry.set_margin_end(12)
            dialog.get_content_area().add(entry)
            dialog.set_default_response(Gtk.ResponseType.OK)
            dialog.show_all()
            if dialog.run() == Gtk.ResponseType.OK and entry.get_text().strip():
                self.current.text = entry.get_text()
            else:
                self.current = None
            dialog.destroy()
        if self.current:
            distance = max(abs(self.current.points[-1][0] - self.current.points[0][0]),
                           abs(self.current.points[-1][1] - self.current.points[0][1]))
            if self.current.kind == "text" or distance >= 2:
                self.document.annotations.append(self.current)
                self.changed()
        self.current = None
        self.start = None
        self.queue_draw()
        return True

    def _scroll(self, _widget, event) -> bool:
        delta_y = 0.0
        if event.direction == Gdk.ScrollDirection.SMOOTH:
            _ok, _delta_x, delta_y = event.get_scroll_deltas()
        value = zoom_after_scroll(self.zoom, event.direction, delta_y)
        if abs(value - self.zoom) < 0.0001:
            return True
        if self.zoom_request:
            self.zoom_request(value, (event.x, event.y))
        else:
            self.set_zoom(value, (event.x, event.y))
        return True

    def delete_selected(self) -> None:
        if self.selected is None:
            return
        self.checkpoint()
        del self.document.annotations[self.selected]
        self.selected = None
        self.changed()
        self.queue_draw()

    def _key(self, _widget, event) -> bool:
        control = bool(event.state & Gdk.ModifierType.CONTROL_MASK)
        if control and event.keyval in (Gdk.KEY_z, Gdk.KEY_Z):
            self.redo() if event.state & Gdk.ModifierType.SHIFT_MASK else self.undo()
            return True
        if event.keyval in (Gdk.KEY_Delete, Gdk.KEY_BackSpace):
            self.delete_selected()
            return True
        return False


class EditorWindow(Gtk.Window):
    def __init__(self, document: Document, store: HistoryStore, settings: Settings, on_saved=None) -> None:
        super().__init__(title=f"{document.title} — Snapok")
        self.document = document
        self.store = store
        self.settings = settings
        self.on_saved = on_saved
        self.pinned: list[PinnedImageWindow] = []
        self.base = Image.open(document.image_path).convert("RGBA")
        self.dirty = False
        self._pending_zoom_anchor: tuple[float, float] | None = None
        self.set_default_size(1100, 760)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.canvas = Canvas(document, self.base, self._changed)
        self.canvas.set_tool(str(settings["last_tool"]))
        self.canvas.color = str(settings["stroke_color"])
        self.canvas.width = int(settings["stroke_width"])
        self.canvas.mosaic_style = str(settings["mosaic_style"])
        self.add(self._build())
        self.connect("delete-event", self._close)
        self.connect("key-press-event", self._shortcut)
        self.connect("key-release-event", self._shortcut_released)
        self.show_all()

    def _build(self) -> Gtk.Widget:
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        top = css(Gtk.Box(spacing=12, margin_start=24, margin_end=20, margin_top=16, margin_bottom=16), "editor-header")
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        titles.pack_start(css(Gtk.Label(label="Edit Image", xalign=0), "page-title"), False, False, 0)
        titles.pack_start(css(Gtk.Label(label="Annotate your image and adjust the background and padding.", xalign=0), "page-subtitle"), False, False, 0)
        top.pack_start(titles, True, True, 0)
        for label, callback in [
            ("↶  Revert to Original", self._revert),
            ("Copy Image", self.copy),
            ("Save PNG", self.export),
        ]:
            button = css(Gtk.Button(label=label), "flat-action")
            button.connect("clicked", callback)
            top.pack_start(button, False, False, 0)
        text_tools = css(Gtk.Button(label="Text Tools"), "flat-action")
        text_tools.connect("clicked", self._show_text_menu)
        top.pack_start(text_tools, False, False, 0)
        root.pack_start(top, False, False, 0)

        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        scroll = css(Gtk.ScrolledWindow(), "canvas-area")
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        alignment = Gtk.Alignment.new(0.5, 0.5, 0, 0)
        alignment.set_padding(32, 32, 32, 32)
        alignment.add(self.canvas)
        viewport = scroll.add_with_viewport(alignment)
        left.pack_start(scroll, True, True, 0)

        toolbar_area = css(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7), "toolbar-area")
        toolbar_area.set_border_width(8)
        toolbar = Gtk.Box(spacing=5)
        group = None
        self.tool_buttons: dict[str, Gtk.ToggleButton] = {}
        symbols = {"pointer": "↖", "hand": "✋", "rectangle": "□", "ellipse": "○", "arrow": "↗", "pen": "〰",
                   "mosaic": "▦", "text": "Aa", "step": "①", "erase": "◇"}
        for name, label, key in TOOLS:
            button = css(Gtk.RadioButton.new_with_label_from_widget(group, symbols[name]), "tool-button")
            if group is None:
                group = button
            button.set_mode(False)
            button.set_tooltip_text(f"{label} — {key}")
            button.connect("toggled", self._tool_changed, name)
            toolbar.pack_start(button, False, False, 0)
            self.tool_buttons[name] = button
        undo = css(Gtk.Button(label="↶"), "tool-button"); undo.set_tooltip_text("Undo")
        undo.connect("clicked", lambda *_: self.canvas.undo()); toolbar.pack_start(undo, False, False, 6)
        pin = css(Gtk.Button(label="⚑"), "tool-button"); pin.set_tooltip_text("Pin above other windows")
        pin.connect("clicked", self.pin); toolbar.pack_start(pin, False, False, 0)
        library = css(Gtk.Button(label="⇩"), "tool-button"); library.set_tooltip_text("Save to Library")
        library.connect("clicked", lambda *_: self.persist()); toolbar.pack_start(library, False, False, 0)
        self.tool_buttons.get(self.canvas.tool, self.tool_buttons["rectangle"]).set_active(True)

        options = Gtk.Box(spacing=8)
        options.pack_start(Gtk.Label(label="Size"), False, False, 0)
        color = Gtk.ColorButton()
        rgba = Gdk.RGBA()
        rgba.parse(self.canvas.color)
        color.set_rgba(rgba)
        color.set_tooltip_text("Annotation color")
        color.connect("color-set", self._color_changed)
        options.pack_start(color, False, False, 4)
        width = Gtk.SpinButton.new_with_range(1, 30, 1)
        width.set_value(self.canvas.width)
        width.set_tooltip_text("Stroke width")
        width.connect("value-changed", self._width_changed)
        options.pack_start(width, False, False, 0)

        mosaic = Gtk.ComboBoxText()
        for value, label in [("pixelate", "Pixelate"), ("blur", "Blur"), ("solid", "Solid")]:
            mosaic.append(value, label)
        mosaic.set_active_id(self.canvas.mosaic_style)
        mosaic.connect("changed", self._mosaic_changed)
        options.pack_start(mosaic, False, False, 4)

        self.zoom_scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, MIN_ZOOM, MAX_ZOOM, 0.1)
        self.zoom_scale.set_value(1)
        self.zoom_scale.set_size_request(130, -1)
        self.zoom_scale.set_tooltip_text("Mouse wheel to zoom around the pointer")
        self.zoom_scale.connect("value-changed", self._zoom_changed)
        options.pack_end(self.zoom_scale, False, False, 4)
        options.pack_end(Gtk.Label(label="Zoom"), False, False, 0)
        self.canvas.bind_scroller(scroll, self._canvas_zoom_requested)
        toolbar_area.pack_start(toolbar, False, False, 0)
        toolbar_area.pack_start(options, False, False, 0)
        left.pack_start(toolbar_area, False, False, 0)
        body.pack_start(left, True, True, 0)
        body.pack_start(self._build_inspector(), False, False, 0)
        root.pack_start(body, True, True, 0)
        return root

    def _revert(self, *_args) -> None:
        if not self.document.annotations:
            return
        self.canvas.checkpoint()
        self.document.annotations.clear()
        self._changed()
        self.canvas.queue_draw()

    def _show_text_menu(self, button: Gtk.Button) -> None:
        menu = Gtk.Menu()
        for label, callback in [
            ("Recognize Text", lambda *_: self.run_ocr()),
            ("Redact Sensitive Text", lambda *_: self.auto_redact()),
        ]:
            item = Gtk.MenuItem(label=label)
            item.connect("activate", callback)
            menu.append(item)
        menu.show_all()
        menu.popup_at_widget(button, Gdk.Gravity.SOUTH_WEST, Gdk.Gravity.NORTH_WEST, None)

    def _build_inspector(self) -> Gtk.Widget:
        panel = css(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8), "inspector")
        panel.set_size_request(282, -1)
        panel.set_border_width(18)
        panel.pack_start(css(Gtk.Label(label="Background", xalign=0), "inspector-title"), False, False, 0)
        background = Gtk.ComboBoxText()
        background.append("gradient", "Gradient")
        background.append("solid", "Solid Color")
        background.set_active_id(str(self.document.frame.get("background", "gradient")))
        panel.pack_start(background, False, False, 0)

        colors = Gtk.Box(spacing=8)
        colors.pack_start(Gtk.Label(label="Start"), False, False, 0)
        start = Gtk.ColorButton(); start_rgba = Gdk.RGBA(); start_rgba.parse(str(self.document.frame.get("color_start", "#7c3aed"))); start.set_rgba(start_rgba)
        colors.pack_start(start, False, False, 0)
        colors.pack_start(Gtk.Label(label="End"), False, False, 0)
        end = Gtk.ColorButton(); end_rgba = Gdk.RGBA(); end_rgba.parse(str(self.document.frame.get("color_end", "#ec4899"))); end.set_rgba(end_rgba)
        colors.pack_start(end, False, False, 0)
        panel.pack_start(colors, False, False, 4)

        angle = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 360, 1)
        angle.set_value(float(self.document.frame.get("angle", 35)))
        panel.pack_start(self._inspector_row("Angle", angle), False, False, 0)
        panel.pack_start(css(Gtk.Label(label="Padding", xalign=0), "inspector-section"), False, False, 3)
        padding_x = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 600, 4)
        padding_x.set_value(int(self.document.frame.get("padding_x", 48)))
        padding_y = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 600, 4)
        padding_y.set_value(int(self.document.frame.get("padding_y", 48)))
        panel.pack_start(self._inspector_row("Horizontal", padding_x), False, False, 0)
        panel.pack_start(self._inspector_row("Vertical", padding_y), False, False, 0)
        panel.pack_start(css(Gtk.Label(label="Appearance", xalign=0), "inspector-section"), False, False, 3)
        border = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 20, 1)
        border.set_value(int(self.document.frame.get("border_width", 0)))
        panel.pack_start(self._inspector_row("Border", border), False, False, 0)
        border_color = Gtk.ColorButton(); border_rgba = Gdk.RGBA(); border_rgba.parse(str(self.document.frame.get("border_color", "#ffffff"))); border_color.set_rgba(border_rgba)
        panel.pack_start(self._inspector_row("Border color", border_color), False, False, 0)
        radius = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 80, 1)
        radius.set_value(int(self.document.frame.get("corner_radius", 18)))
        panel.pack_start(self._inspector_row("Corner radius", radius), False, False, 0)
        shadow = Gtk.CheckButton(label="Soft shadow"); shadow.set_active(bool(self.document.frame.get("shadow", True)))
        panel.pack_start(shadow, False, False, 0)
        watermark = Gtk.CheckButton(label="Add watermark"); watermark.set_active(bool(self.document.frame.get("watermark", False)))
        panel.pack_start(css(Gtk.Label(label="Watermark", xalign=0), "inspector-section"), False, False, 4)
        panel.pack_start(watermark, False, False, 0)
        enabled = Gtk.CheckButton(label="Apply background frame"); enabled.set_active(bool(self.document.frame.get("enabled", False)))
        panel.pack_end(enabled, False, False, 4)
        self.export_size = css(Gtk.Label(xalign=0), "muted")
        panel.pack_end(self.export_size, False, False, 0)

        def changed(*_args) -> None:
            self.document.frame.update({
                "enabled": enabled.get_active(), "background": background.get_active_id() or "gradient",
                "color_start": start.get_rgba().to_string(), "color_end": end.get_rgba().to_string(),
                "angle": int(angle.get_value()), "padding_x": int(padding_x.get_value()),
                "padding_y": int(padding_y.get_value()), "border_width": int(border.get_value()),
                "border_color": border_color.get_rgba().to_string(), "corner_radius": int(radius.get_value()),
                "shadow": shadow.get_active(), "watermark": watermark.get_active(),
            })
            self._changed()
            self.canvas._resize()
            self._update_export_size()

        for widget, signal in [(background, "changed"), (start, "color-set"), (end, "color-set"),
                               (angle, "value-changed"), (padding_x, "value-changed"),
                               (padding_y, "value-changed"), (border, "value-changed"),
                               (border_color, "color-set"), (radius, "value-changed"),
                               (shadow, "toggled"), (watermark, "toggled"), (enabled, "toggled")]:
            widget.connect(signal, changed)
        self._update_export_size()
        return panel

    def _inspector_row(self, label: str, widget: Gtk.Widget) -> Gtk.Widget:
        row = Gtk.Box(spacing=8)
        title = Gtk.Label(label=label, xalign=0)
        title.set_size_request(82, -1)
        row.pack_start(title, False, False, 0)
        row.pack_start(widget, True, True, 0)
        return row

    def _update_export_size(self) -> None:
        width, height = self.rendered().size
        if hasattr(self, "export_size"):
            self.export_size.set_text(f"Export size  {width} × {height} px")

    def _changed(self) -> None:
        self.dirty = True

    def _tool_changed(self, button: Gtk.ToggleButton, tool: str) -> None:
        if button.get_active():
            self.canvas.set_tool(tool)
            self.canvas.selected = None
            self.settings["last_tool"] = tool
            self.canvas.queue_draw()

    def _color_changed(self, button: Gtk.ColorButton) -> None:
        self.canvas.color = button.get_rgba().to_string()
        self.settings["stroke_color"] = self.canvas.color

    def _width_changed(self, button: Gtk.SpinButton) -> None:
        self.canvas.width = button.get_value_as_int()
        self.settings["stroke_width"] = self.canvas.width

    def _mosaic_changed(self, box: Gtk.ComboBoxText) -> None:
        self.canvas.mosaic_style = box.get_active_id() or "pixelate"
        self.settings["mosaic_style"] = self.canvas.mosaic_style

    def _zoom_changed(self, scale: Gtk.Scale) -> None:
        anchor = self._pending_zoom_anchor
        self._pending_zoom_anchor = None
        self.canvas.set_zoom(scale.get_value(), anchor)

    def _canvas_zoom_requested(self, value: float, anchor: tuple[float, float]) -> None:
        self._pending_zoom_anchor = anchor
        self.zoom_scale.set_value(value)

    def rendered(self, styled: bool = True) -> Image.Image:
        image = self.canvas.rendered(include_current=False)
        return frame_image(image, self.document.frame) if styled else image

    def persist(self) -> None:
        self.store.save(self.document, self.rendered())
        self.dirty = False
        if self.on_saved:
            self.on_saved()

    def copy(self, *_args) -> None:
        pixbuf = pil_to_pixbuf(self.rendered())
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_image(pixbuf)
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).store()
        if self.settings["auto_save"]:
            self.persist()

    def configure_frame(self, *_args) -> None:
        options = self.document.frame
        dialog = Gtk.Dialog(title="Frame screenshot", transient_for=self, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Apply", Gtk.ResponseType.OK)
        grid = Gtk.Grid(column_spacing=12, row_spacing=10, margin=16)
        enabled = Gtk.Switch(active=bool(options.get("enabled")))
        padding_x = Gtk.SpinButton.new_with_range(0, 600, 4)
        padding_x.set_value(int(options.get("padding_x", 48)))
        padding_y = Gtk.SpinButton.new_with_range(0, 600, 4)
        padding_y.set_value(int(options.get("padding_y", 48)))
        radius = Gtk.SpinButton.new_with_range(0, 100, 1)
        radius.set_value(int(options.get("corner_radius", 18)))
        shadow = Gtk.Switch(active=bool(options.get("shadow", True)))
        background = Gtk.ComboBoxText()
        background.append("gradient", "Gradient")
        background.append("solid", "Solid color")
        background.set_active_id(str(options.get("background", "gradient")))
        start = Gtk.ColorButton()
        start_color = Gdk.RGBA()
        start_color.parse(str(options.get("color_start", "#7c3aed")))
        start.set_rgba(start_color)
        end = Gtk.ColorButton()
        end_color = Gdk.RGBA()
        end_color.parse(str(options.get("color_end", "#ec4899")))
        end.set_rgba(end_color)
        rows = [
            ("Enable frame", enabled), ("Horizontal padding", padding_x),
            ("Vertical padding", padding_y), ("Corner radius", radius),
            ("Shadow", shadow), ("Background", background),
            ("Start / solid color", start), ("End color", end),
        ]
        for row, (label, widget) in enumerate(rows):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, row, 1, 1)
            grid.attach(widget, 1, row, 1, 1)
        dialog.get_content_area().add(grid)
        dialog.show_all()
        if dialog.run() == Gtk.ResponseType.OK:
            self.document.frame = {
                "enabled": enabled.get_active(),
                "padding_x": padding_x.get_value_as_int(),
                "padding_y": padding_y.get_value_as_int(),
                "corner_radius": radius.get_value_as_int(),
                "shadow": shadow.get_active(),
                "background": background.get_active_id() or "gradient",
                "color_start": start.get_rgba().to_string(),
                "color_end": end.get_rgba().to_string(),
            }
            self._changed()
            if self.settings["auto_save"]:
                self.persist()
        dialog.destroy()

    def pin(self, *_args) -> None:
        window = PinnedImageWindow(self.rendered())
        window.connect("destroy", lambda item: self.pinned.remove(item) if item in self.pinned else None)
        self.pinned.append(window)

    def export(self, *_args) -> None:
        dialog = Gtk.FileChooserDialog(
            title="Save PNG",
            parent=self,
            action=Gtk.FileChooserAction.SAVE,
            buttons=("Cancel", Gtk.ResponseType.CANCEL, "Save", Gtk.ResponseType.OK),
        )
        dialog.set_current_name(f"{self.document.title}.png")
        dialog.set_do_overwrite_confirmation(True)
        png_filter = Gtk.FileFilter()
        png_filter.set_name("PNG image")
        png_filter.add_pattern("*.png")
        dialog.add_filter(png_filter)
        if dialog.run() == Gtk.ResponseType.OK:
            path = Path(dialog.get_filename())
            if path.suffix.lower() != ".png":
                path = path.with_suffix(".png")
            self.rendered().convert("RGB").save(path, "PNG")
            if self.settings["auto_save"]:
                self.persist()
        dialog.destroy()

    def run_ocr(self) -> None:
        try:
            recognized = recognize_text(self.rendered(styled=False))
        except OCRError as error:
            self._message("OCR unavailable", str(error))
            return
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(recognized, -1)
        self._message("Text copied", recognized[:800] or "No text was found.")

    def auto_redact(self) -> None:
        try:
            matches = sensitive_words(self.rendered(styled=False))
        except OCRError as error:
            self._message("Automatic redaction unavailable", str(error))
            return
        if not matches:
            self._message("Nothing detected", "No email address, phone number, IP address, payment-card-like number, or URL was detected.")
            return
        self.canvas.checkpoint()
        for word in matches:
            margin = max(2, word.height // 8)
            self.document.annotations.append(Annotation(
                "mosaic",
                [(word.left - margin, word.top - margin),
                 (word.left + word.width + margin, word.top + word.height + margin)],
                "#111111",
                max(5, word.height // 3),
                style="pixelate",
            ))
        self._changed()
        self.canvas.queue_draw()
        self._message("Sensitive text redacted", f"Redacted {len(matches)} detected item(s). Review the result before sharing.")

    def _shortcut(self, _widget, event) -> bool:
        control = bool(event.state & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(event.state & Gdk.ModifierType.SHIFT_MASK)
        key = Gdk.keyval_name(event.keyval) or ""
        if key == "space":
            self.canvas.space_pan = True
            self.canvas.update_cursor()
            return True
        if control and key.lower() == "c":
            self.copy()
            return True
        if control and key.lower() == "s":
            self.export()
            return True
        if control and key.lower() == "z":
            self.canvas.redo() if shift else self.canvas.undo()
            return True
        shortcuts = {shortcut.lower(): name for name, _label, shortcut in TOOLS}
        if not control and key.lower() in shortcuts:
            self.tool_buttons[shortcuts[key.lower()]].set_active(True)
            return True
        return False

    def _shortcut_released(self, _widget, event) -> bool:
        key = Gdk.keyval_name(event.keyval) or ""
        if key == "space":
            self.canvas.space_pan = False
            if self.canvas.pan_origin is None:
                self.canvas.update_cursor()
            return True
        return False

    def _message(self, title: str, message: str) -> None:
        dialog = Gtk.MessageDialog(self, Gtk.DialogFlags.MODAL, Gtk.MessageType.INFO, Gtk.ButtonsType.OK, title)
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()

    def _close(self, *_args) -> bool:
        if self.dirty and (self.settings["auto_save"] or not self.document.transient):
            self.persist()
        elif self.document.transient:
            self.store.discard(self.document)
        return False
