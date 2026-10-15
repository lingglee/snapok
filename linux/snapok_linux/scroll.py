from __future__ import annotations

import numpy as np
import shutil
import subprocess
from PIL import Image

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk

from .capture import capture_x11

try:
    import cv2
except ImportError:  # Ubuntu's OpenCV package is recommended; a slower fallback remains available.
    cv2 = None


def _gray(image: Image.Image) -> np.ndarray:
    array = np.asarray(image.convert("RGB"), dtype=np.uint8)
    if cv2 is not None:
        return cv2.cvtColor(array, cv2.COLOR_RGB2GRAY)
    return (array[:, :, 0] * 0.299 + array[:, :, 1] * 0.587 + array[:, :, 2] * 0.114).astype(np.uint8)


def fixed_edges(previous: Image.Image, current: Image.Image) -> tuple[int, int]:
    first = np.asarray(previous.convert("RGB"), dtype=np.int16)
    second = np.asarray(current.convert("RGB"), dtype=np.int16)
    difference = np.mean(np.abs(first - second), axis=(1, 2))
    top = 0
    for value in difference:
        if value > 2.5:
            break
        top += 1
    bottom = 0
    for value in difference[::-1]:
        if value > 2.5:
            break
        bottom += 1
    limit = previous.height // 3
    return min(top, limit), min(bottom, limit)


def estimate_scroll(previous: Image.Image, current: Image.Image) -> tuple[int, float, int, int]:
    if previous.size != current.size:
        return 0, 0.0, 0, 0
    before = _gray(previous)
    after = _gray(current)
    height, width = before.shape
    fixed_top, fixed_bottom = fixed_edges(previous, current)
    left, right = width // 10, width - width // 10
    start = max(fixed_top + 4, height // 10)
    dynamic_bottom = min(height - fixed_bottom - 4, height - height // 12)
    template_height = max(24, min(height // 3, dynamic_bottom - start - 8))
    if dynamic_bottom - start <= template_height or right - left < 20:
        return 0, 0.0, fixed_top, fixed_bottom
    template = after[start:start + template_height, left:right]
    search = before[start:dynamic_bottom, left:right]
    if cv2 is not None:
        scores = cv2.matchTemplate(search, template, cv2.TM_CCOEFF_NORMED)
        _minimum, maximum, _min_point, max_point = cv2.minMaxLoc(scores)
        shift, confidence = max_point[1], float(maximum)
    else:
        best = (float("inf"), 0)
        for value in range(0, search.shape[0] - template_height + 1, 2):
            candidate = search[value:value + template_height]
            error = float(np.mean(np.abs(candidate.astype(np.int16) - template.astype(np.int16))))
            best = min(best, (error, value))
        shift, confidence = best[1], max(0.0, 1.0 - best[0] / 64.0)
    return int(shift), confidence, fixed_top, fixed_bottom


class ScrollStitcher:
    def __init__(self, first: Image.Image) -> None:
        self.last = first.convert("RGB")
        self.result = self.last.copy()
        self.frames = 1
        self.fixed_bottom = 0

    def add(self, frame: Image.Image) -> bool:
        frame = frame.convert("RGB")
        shift, confidence, _fixed_top, fixed_bottom = estimate_scroll(self.last, frame)
        if confidence < 0.58 or shift < 3:
            self.last = frame
            return False
        fixed_bottom = min(fixed_bottom, frame.height // 3)
        if self.fixed_bottom:
            self.result = self.result.crop((0, 0, self.result.width, self.result.height - self.fixed_bottom))
        dynamic_bottom = frame.height - fixed_bottom
        new_content = frame.crop((0, max(0, dynamic_bottom - shift), frame.width, dynamic_bottom))
        footer = frame.crop((0, dynamic_bottom, frame.width, frame.height)) if fixed_bottom else None
        footer_height = footer.height if footer else 0
        combined = Image.new("RGB", (frame.width, self.result.height + new_content.height + footer_height))
        combined.paste(self.result, (0, 0))
        combined.paste(new_content, (0, self.result.height))
        if footer:
            combined.paste(footer, (0, self.result.height + new_content.height))
        self.result = combined
        self.last = frame
        self.frames += 1
        self.fixed_bottom = fixed_bottom
        return True


class ScrollCaptureWindow(Gtk.Window):
    def __init__(self, initial: Image.Image, rect: tuple[int, int, int, int], on_finished) -> None:
        super().__init__(title="Scrolling capture")
        self.rect = rect
        self.on_finished = on_finished
        self.stitcher = ScrollStitcher(initial)
        self.timer = 0
        self.auto_timer = 0
        self.stalled_samples = 0
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_resizable(False)
        self.set_default_size(340, 120)
        self.connect("destroy", self._destroyed)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=14)
        self.status = Gtk.Label(label="Scroll inside the selected area. Snapok will add overlapping frames.", xalign=0)
        self.status.set_line_wrap(True)
        actions = Gtk.Box(spacing=8)
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda *_: self.destroy())
        finish = Gtk.Button(label="Done")
        finish.get_style_context().add_class("suggested-action")
        finish.connect("clicked", self._finish)
        self.auto = Gtk.ToggleButton(label="Scroll automatically")
        self.auto.set_sensitive(shutil.which("xdotool") is not None)
        self.auto.set_tooltip_text("Uses xdotool to scroll the selected X11 region")
        self.auto.connect("toggled", self._toggle_auto)
        actions.pack_start(self.auto, False, False, 0)
        actions.pack_end(finish, False, False, 0)
        actions.pack_end(cancel, False, False, 0)
        box.pack_start(self.status, True, True, 0)
        box.pack_start(actions, False, False, 0)
        self.add(box)
        self.show_all()
        self._place_outside_region()
        self.timer = GLib.timeout_add(450, self._sample)

    def _place_outside_region(self) -> None:
        screen = Gdk.Screen.get_default()
        if not screen:
            return
        x1, y1, x2, _y2 = self.rect
        panel_width = 350
        if x2 + panel_width + 20 < screen.get_width():
            self.move(x2 + 12, max(12, y1))
        elif x1 > panel_width + 20:
            self.move(max(12, x1 - panel_width - 12), max(12, y1))
        else:
            self.move(max(12, screen.get_width() - panel_width - 20), 20)

    def _sample(self) -> bool:
        try:
            frame = capture_x11().crop(self.rect)
            if self.stitcher.add(frame):
                self.stalled_samples = 0
                self.status.set_text(
                    f"Captured {self.stitcher.frames} frames — {self.stitcher.result.height:,} px tall. Keep scrolling or click Done."
                )
            elif self.auto.get_active():
                self.stalled_samples += 1
                if self.stalled_samples >= 8:
                    self.auto.set_active(False)
                    self.status.set_text("Automatic scrolling reached the end or lost alignment. Click Done, or scroll manually.")
        except Exception as error:
            self.status.set_text(f"Capture paused: {error}")
        return True

    def _toggle_auto(self, button: Gtk.ToggleButton) -> None:
        if button.get_active():
            self.stalled_samples = 0
            button.set_label("Stop automatic scroll")
            self.auto_timer = GLib.timeout_add(850, self._auto_scroll)
        else:
            button.set_label("Scroll automatically")
            if self.auto_timer:
                GLib.source_remove(self.auto_timer)
                self.auto_timer = 0

    def _auto_scroll(self) -> bool:
        executable = shutil.which("xdotool")
        if not executable:
            self.auto.set_active(False)
            return False
        left, top, right, bottom = self.rect
        x, y = (left + right) // 2, (top + bottom) // 2
        try:
            subprocess.run(
                [executable, "mousemove", str(x), str(y), "click", "--repeat", "5", "--delay", "35", "5"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            self.auto.set_active(False)
            return False
        return True

    def _finish(self, *_args) -> None:
        self.on_finished(self.stitcher.result)
        self.destroy()

    def _destroyed(self, *_args) -> None:
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0
        if self.auto_timer:
            GLib.source_remove(self.auto_timer)
            self.auto_timer = 0
