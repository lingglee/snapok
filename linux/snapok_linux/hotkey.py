from __future__ import annotations

import ctypes
import ctypes.util
import os
import threading
import time

from gi.repository import GLib


class X11HotKey:
    """Small XGrabKey wrapper with no third-party Python dependency."""

    CONTROL = 1 << 2
    SHIFT = 1 << 0
    MOD1 = 1 << 3
    MOD4 = 1 << 6
    LOCK = 1 << 1
    MOD2 = 1 << 4
    KEY_PRESS = 2

    def __init__(self, callback) -> None:
        self.callback = callback
        self.display = None
        self.root = 0
        self.keycode = 0
        self.modifiers = self.CONTROL | self.MOD4
        self.running = False
        self.thread: threading.Thread | None = None
        self.error: str | None = None
        self._x11 = None

    def start(self, shortcut: str = "Ctrl+Shift+P") -> bool:
        if os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland":
            self.error = "Global shortcuts require desktop portal support on Wayland"
            return False
        library = ctypes.util.find_library("X11")
        if not library:
            self.error = "libX11 is unavailable"
            return False
        self._x11 = ctypes.cdll.LoadLibrary(library)
        self._x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self._x11.XOpenDisplay.restype = ctypes.c_void_p
        self._x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self._x11.XDefaultRootWindow.restype = ctypes.c_ulong
        self._x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self._x11.XStringToKeysym.restype = ctypes.c_ulong
        self._x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self._x11.XKeysymToKeycode.restype = ctypes.c_uint
        self._x11.XPending.argtypes = [ctypes.c_void_p]
        self._x11.XPending.restype = ctypes.c_int
        self._x11.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self._x11.XGrabKey.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong,
                                      ctypes.c_int, ctypes.c_int, ctypes.c_int]
        self._x11.XUngrabKey.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong]
        self._x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self._x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.display = self._x11.XOpenDisplay(None)
        if not self.display:
            self.error = "Cannot connect to the X11 display"
            return False
        self.root = self._x11.XDefaultRootWindow(self.display)
        key, self.modifiers = self._parse(shortcut)
        keysym = self._x11.XStringToKeysym(key.encode("ascii", "ignore"))
        self.keycode = self._x11.XKeysymToKeycode(self.display, keysym)
        if not self.keycode:
            self.error = f"Unknown hotkey key: {key}"
            return False
        for ignored in (0, self.LOCK, self.MOD2, self.LOCK | self.MOD2):
            self._x11.XGrabKey(self.display, self.keycode, self.modifiers | ignored, self.root, True, 1, 1)
        self._x11.XSync(self.display, False)
        self.running = True
        self.thread = threading.Thread(target=self._run, name="snapok-hotkey", daemon=True)
        self.thread.start()
        return True

    def _parse(self, shortcut: str) -> tuple[str, int]:
        parts = [part.strip() for part in shortcut.replace("<", "").replace(">", "+").split("+") if part.strip()]
        key = parts[-1] if parts else "A"
        modifiers = 0
        for part in parts[:-1]:
            lowered = part.casefold()
            if lowered in {"ctrl", "control", "primary"}:
                modifiers |= self.CONTROL
            elif lowered == "shift":
                modifiers |= self.SHIFT
            elif lowered in {"alt", "mod1"}:
                modifiers |= self.MOD1
            elif lowered in {"super", "meta", "win", "mod4"}:
                modifiers |= self.MOD4
        return key, modifiers

    def _run(self) -> None:
        event = ctypes.create_string_buffer(192)
        while self.running and self.display:
            while self._x11.XPending(self.display):
                self._x11.XNextEvent(self.display, ctypes.byref(event))
                event_type = ctypes.cast(event, ctypes.POINTER(ctypes.c_int)).contents.value
                if event_type == self.KEY_PRESS:
                    GLib.idle_add(self.callback)
            time.sleep(0.03)

    def stop(self) -> None:
        self.running = False
        if self.display and self._x11:
            for ignored in (0, self.LOCK, self.MOD2, self.LOCK | self.MOD2):
                self._x11.XUngrabKey(self.display, self.keycode, self.modifiers | ignored, self.root)
            self._x11.XCloseDisplay(self.display)
            self.display = None
