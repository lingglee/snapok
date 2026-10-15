from __future__ import annotations

from pathlib import Path

from PIL import Image

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk

from .images import pil_to_pixbuf


class PinnedImageWindow(Gtk.Window):
    def __init__(self, image: Image.Image) -> None:
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.image = image.convert("RGBA")
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_resizable(True)
        self.set_default_size(min(700, image.width), min(500, image.height))
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.connect("button-press-event", self._press)
        view = Gtk.Image.new_from_pixbuf(pil_to_pixbuf(self.image))
        view.set_hexpand(True)
        view.set_vexpand(True)
        self.add(view)
        self.show_all()

    def _press(self, _widget, event) -> bool:
        if event.button == 1 and event.type == Gdk.EventType._2BUTTON_PRESS:
            self.destroy()
            return True
        if event.button == 1:
            self.begin_move_drag(event.button, int(event.x_root), int(event.y_root), event.time)
            return True
        if event.button == 3:
            menu = Gtk.Menu()
            copy = Gtk.MenuItem(label="Copy")
            copy.connect("activate", lambda *_: self._copy())
            close = Gtk.MenuItem(label="Close")
            close.connect("activate", lambda *_: self.destroy())
            menu.append(copy)
            menu.append(close)
            menu.show_all()
            menu.popup_at_pointer(event)
            return True
        return False

    def _copy(self) -> None:
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clipboard.set_image(pil_to_pixbuf(self.image))
        clipboard.store()
