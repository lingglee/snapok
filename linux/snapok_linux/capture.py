from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse

from PIL import Image

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk

from .images import pixbuf_to_pil


class CaptureError(RuntimeError):
    pass


@dataclass
class ScreenCapture:
    image: Image.Image
    origin: tuple[int, int] = (0, 0)
    monitor: int = 0


def current_monitor() -> tuple[int, Gdk.Rectangle]:
    screen = Gdk.Screen.get_default()
    display = Gdk.Display.get_default()
    if screen is None or display is None:
        raise CaptureError("No graphical display is available")
    seat = display.get_default_seat()
    pointer = seat.get_pointer() if seat else None
    if pointer:
        _pointer_screen, x, y = pointer.get_position()
        monitor = screen.get_monitor_at_point(x, y)
    else:
        monitor = screen.get_primary_monitor()
    if monitor < 0:
        monitor = 0
    return monitor, screen.get_monitor_geometry(monitor)


def capture_x11() -> Image.Image:
    root = Gdk.get_default_root_window()
    if root is None:
        raise CaptureError("No X11 root window is available")
    width = root.get_width()
    height = root.get_height()
    pixbuf = Gdk.pixbuf_get_from_window(root, 0, 0, width, height)
    if pixbuf is None:
        raise CaptureError("The desktop denied access to screen pixels")
    return pixbuf_to_pil(pixbuf)


def capture_x11_monitor() -> ScreenCapture:
    root = Gdk.get_default_root_window()
    if root is None:
        raise CaptureError("No X11 root window is available")
    monitor, geometry = current_monitor()
    pixbuf = Gdk.pixbuf_get_from_window(root, geometry.x, geometry.y, geometry.width, geometry.height)
    if pixbuf is None:
        raise CaptureError("The desktop denied access to screen pixels")
    return ScreenCapture(pixbuf_to_pil(pixbuf), (geometry.x, geometry.y), monitor)


def capture_portal(parent: Gtk.Window | None = None) -> Image.Image:
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    proxy = Gio.DBusProxy.new_sync(
        bus,
        Gio.DBusProxyFlags.NONE,
        None,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Screenshot",
        None,
    )
    token = f"snapok_{os.getpid()}"
    options = {"interactive": GLib.Variant("b", False), "handle_token": GLib.Variant("s", token)}
    result = proxy.call_sync(
        "Screenshot",
        GLib.Variant("(sa{sv})", ("", options)),
        Gio.DBusCallFlags.NONE,
        -1,
        None,
    )
    request_path = result.unpack()[0]
    loop = GLib.MainLoop()
    outcome: dict[str, object] = {}

    def response(_connection, _sender, _path, _interface, _signal, parameters, _data) -> None:
        code, values = parameters.unpack()
        outcome["code"] = code
        outcome["values"] = values
        loop.quit()

    subscription = bus.signal_subscribe(
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        request_path,
        None,
        Gio.DBusSignalFlags.NONE,
        response,
        None,
    )
    timeout = GLib.timeout_add_seconds(120, lambda: (outcome.update(code=2), loop.quit(), False)[-1])
    loop.run()
    GLib.source_remove(timeout)
    bus.signal_unsubscribe(subscription)
    if outcome.get("code") != 0:
        raise CaptureError("Screen capture was cancelled or denied")
    uri = outcome.get("values", {}).get("uri")  # type: ignore[union-attr]
    if not uri:
        raise CaptureError("The screenshot portal returned no image")
    parsed = urlparse(str(uri))
    path = Path(unquote(parsed.path))
    try:
        return Image.open(path).convert("RGB")
    finally:
        try:
            path.unlink()
        except OSError:
            pass


def _portal_monitor_crop(image: Image.Image) -> ScreenCapture:
    monitor, geometry = current_monitor()
    screen = Gdk.Screen.get_default()
    if screen is None:
        return ScreenCapture(image, (0, 0), monitor)
    geometries = [screen.get_monitor_geometry(index) for index in range(screen.get_n_monitors())]
    min_x = min(item.x for item in geometries)
    min_y = min(item.y for item in geometries)
    max_x = max(item.x + item.width for item in geometries)
    max_y = max(item.y + item.height for item in geometries)
    virtual_width, virtual_height = max_x - min_x, max_y - min_y
    if virtual_width > 0 and virtual_height > 0:
        scale_x = image.width / virtual_width
        scale_y = image.height / virtual_height
        if abs(scale_x - scale_y) < 0.05:
            box = (
                int((geometry.x - min_x) * scale_x),
                int((geometry.y - min_y) * scale_y),
                int((geometry.x + geometry.width - min_x) * scale_x),
                int((geometry.y + geometry.height - min_y) * scale_y),
            )
            if box[2] <= image.width and box[3] <= image.height:
                return ScreenCapture(image.crop(box), (geometry.x, geometry.y), monitor)
    return ScreenCapture(image, (geometry.x, geometry.y), monitor)


def capture_screen(parent: Gtk.Window | None = None) -> ScreenCapture:
    session = os.environ.get("XDG_SESSION_TYPE", "").lower()
    if session == "wayland" or os.environ.get("WAYLAND_DISPLAY"):
        return _portal_monitor_crop(capture_portal(parent))
    return capture_x11_monitor()


class RegionSelector(Gtk.Window):
    def __init__(self, capture: ScreenCapture, on_selected) -> None:
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.image = capture.image
        self.origin = capture.origin
        self.monitor = capture.monitor
        self.on_selected = on_selected
        self.start: tuple[float, float] | None = None
        self.end: tuple[float, float] | None = None
        self.scale = 1.0
        self.offset = (0.0, 0.0)
        self.set_decorated(False)
        self.set_keep_above(True)
        screen = Gdk.Screen.get_default()
        if screen is not None:
            self.fullscreen_on_monitor(screen, self.monitor)
        else:
            self.fullscreen()
        self.set_app_paintable(True)
        self.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
            | Gdk.EventMask.KEY_PRESS_MASK
        )
        self.connect("draw", self._draw)
        self.connect("button-press-event", self._press)
        self.connect("motion-notify-event", self._motion)
        self.connect("button-release-event", self._release)
        self.connect("key-press-event", self._key)
        self.show_all()
        self.get_window().set_cursor(Gdk.Cursor.new_from_name(self.get_display(), "crosshair"))

    def _layout(self) -> tuple[float, float, float]:
        allocation = self.get_allocation()
        scale = min(allocation.width / self.image.width, allocation.height / self.image.height)
        width, height = self.image.width * scale, self.image.height * scale
        return scale, (allocation.width - width) / 2, (allocation.height - height) / 2

    def _draw(self, _widget, context) -> bool:
        from .images import pil_to_pixbuf

        self.scale, ox, oy = self._layout()
        self.offset = (ox, oy)
        context.save()
        context.translate(ox, oy)
        context.scale(self.scale, self.scale)
        Gdk.cairo_set_source_pixbuf(context, pil_to_pixbuf(self.image), 0, 0)
        context.paint()
        context.restore()
        context.set_source_rgba(0, 0, 0, 0.42)
        context.paint()
        if self.start and self.end:
            x1, y1 = self.start
            x2, y2 = self.end
            x, y = min(x1, x2), min(y1, y2)
            w, h = abs(x2 - x1), abs(y2 - y1)
            context.save()
            context.rectangle(x, y, w, h)
            context.clip()
            context.translate(ox, oy)
            context.scale(self.scale, self.scale)
            Gdk.cairo_set_source_pixbuf(context, pil_to_pixbuf(self.image), 0, 0)
            context.paint()
            context.restore()
            context.set_source_rgb(0.925, 0.282, 0.6)
            context.set_line_width(2)
            context.rectangle(x, y, w, h)
            context.stroke()
        return True

    def _press(self, _widget, event) -> bool:
        if event.button == 1:
            self.start = (event.x, event.y)
            self.end = self.start
            self.queue_draw()
        elif event.button == 3:
            self.destroy()
        return True

    def _motion(self, _widget, event) -> bool:
        if self.start:
            self.end = (event.x, event.y)
            self.queue_draw()
        return True

    def _release(self, _widget, event) -> bool:
        if event.button != 1 or not self.start:
            return True
        self.end = (event.x, event.y)
        x1, y1 = self.start
        x2, y2 = self.end
        if abs(x2 - x1) < 4 or abs(y2 - y1) < 4:
            self.start = None
            self.end = None
            self.queue_draw()
            return True
        ox, oy = self.offset
        left = max(0, int((min(x1, x2) - ox) / self.scale))
        top = max(0, int((min(y1, y2) - oy) / self.scale))
        right = min(self.image.width, int((max(x1, x2) - ox) / self.scale))
        bottom = min(self.image.height, int((max(y1, y2) - oy) / self.scale))
        crop = self.image.crop((left, top, right, bottom))
        self.destroy()
        origin_x, origin_y = self.origin
        self.on_selected(crop, (left + origin_x, top + origin_y, right + origin_x, bottom + origin_y))
        return True

    def _key(self, _widget, event) -> bool:
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
        elif event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter) and self.start and self.end:
            class Event:
                button = 1
                x, y = self.end

            self._release(self, Event())
        return True
