from __future__ import annotations

import os
import subprocess
import sys
import time
import traceback
from pathlib import Path

from PIL import Image

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk

from . import __version__
from .capture import CaptureError, RegionSelector, capture_screen
from .editor import EditorWindow
from .history import HistoryStore, Settings
from .hotkey import X11HotKey
from .model import Document
from .scroll import ScrollCaptureWindow
from .style import css, install_styles


APPLICATION_ID = f"ai.thinkany.snapok.linux.v{__version__.replace('.', '_').replace('-', '_')}"
LEGACY_APPLICATION_ID = "ai.thinkany.snapok.linux"


def _running_snapok_app_ids() -> set[str]:
    try:
        result = subprocess.run(
            ["gapplication", "list-apps"],
            capture_output=True,
            check=False,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return set()
    return {
        line.strip()
        for line in result.stdout.splitlines()
        if line.strip() == LEGACY_APPLICATION_ID or line.strip().startswith(f"{LEGACY_APPLICATION_ID}.v")
    }


def stop_older_instances() -> None:
    """Stop prior package versions before registering this version's app id."""
    # The original Linux releases used the stable id and can be addressed even
    # when an older GLib does not include them in `gapplication list-apps`.
    targets = ({LEGACY_APPLICATION_ID} | _running_snapok_app_ids()) - {APPLICATION_ID}
    for app_id in targets:
        try:
            subprocess.run(
                ["gapplication", "action", app_id, "quit"],
                capture_output=True,
                check=False,
                timeout=2,
            )
        except (OSError, subprocess.SubprocessError):
            continue
    if targets:
        time.sleep(0.1)
        for _attempt in range(20):
            if not (_running_snapok_app_ids() & targets):
                break
            time.sleep(0.05)


def icon_path() -> Path | None:
    package = Path(__file__).resolve().parent
    candidates = [
        package.parent / "AppIcon.png",
        Path("/usr/share/icons/hicolor/256x256/apps/ai.thinkany.snapok.png"),
        package.parent.parent / "Sources" / "Snapok" / "Resources" / "AppIcon.png",
    ]
    return next((path for path in candidates if path.exists()), None)


class MainWindow(Gtk.ApplicationWindow):
    def __init__(self, application: "SnapokApplication") -> None:
        super().__init__(application=application, title="Snapok")
        self.snapok = application
        self.set_default_size(1120, 740)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self._hide_on_close)
        self.flow = Gtk.FlowBox()
        self.flow.set_selection_mode(Gtk.SelectionMode.NONE)
        self.flow.set_max_children_per_line(3)
        self.flow.set_activate_on_single_click(False)
        self.flow.set_row_spacing(14)
        self.flow.set_column_spacing(14)
        self.flow.connect("child-activated", self._activated)
        self.search = Gtk.SearchEntry()
        self.search.set_placeholder_text("Search title or tags")
        self.search.connect("search-changed", lambda *_: self.refresh())
        self.category_filter = Gtk.ComboBoxText()
        self._refreshing_filters = False
        self.category_filter.connect("changed", self._category_changed)
        self.empty = Gtk.Label(label="No screenshots yet\nPress Ctrl+Shift+P or click New capture")
        self.empty.set_justify(Gtk.Justification.CENTER)
        self.add(self._build())
        self.refresh()

    def _build(self) -> Gtk.Widget:
        root = css(Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0), "snapok-root")
        sidebar = css(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0), "sidebar")
        sidebar.set_size_request(236, -1)
        brand = Gtk.Box(spacing=10, margin_top=38, margin_start=22, margin_end=18, margin_bottom=30)
        icon = icon_path()
        if icon:
            brand.pack_start(Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(icon), 38, 38, True)), False, False, 0)
        brand.pack_start(css(Gtk.Label(label="Snapok", xalign=0), "brand-name"), True, True, 0)
        sidebar.pack_start(brand, False, False, 0)

        library_nav = css(Gtk.ToggleButton(label="▣   Library"), "nav-button", "nav-selected")
        library_nav.set_active(True)
        library_nav.set_halign(Gtk.Align.FILL)
        nav = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin_start=14, margin_end=14)
        nav.pack_start(library_nav, False, False, 0)
        sidebar.pack_start(nav, False, False, 0)

        sidebar.pack_start(Gtk.Box(), True, True, 0)
        shortcut = css(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10), "shortcut-card")
        shortcut.set_margin_start(14); shortcut.set_margin_end(14); shortcut.set_margin_bottom(12)
        shortcut.pack_start(css(Gtk.Label(label="Capture anytime", xalign=0), "section-title"), False, False, 0)
        hint = css(Gtk.Label(label="Use the shortcut in any app.\nFinished screenshots are saved here automatically.", xalign=0), "muted")
        hint.set_line_wrap(True)
        shortcut.pack_start(hint, False, False, 0)
        keys = Gtk.Box(spacing=6)
        for key in ("Ctrl", "Shift", "P"):
            keys.pack_start(css(Gtk.Label(label=key), "keycap"), False, False, 0)
        shortcut.pack_start(keys, False, False, 0)
        take = css(Gtk.Button(label="Take Screenshot"), "accent-button")
        take.connect("clicked", lambda *_: self.snapok.start_capture())
        shortcut.pack_start(take, False, False, 0)
        scroll_shortcut = str(self.snapok.settings["scroll_hotkey"])
        scroll_capture = css(Gtk.Button(label=f"Scrolling Capture   {scroll_shortcut}"), "flat-action")
        scroll_capture.set_tooltip_text(f"{scroll_shortcut} — captures the screen under the pointer")
        scroll_capture.connect("clicked", lambda *_: self.snapok.start_capture(scrolling=True))
        shortcut.pack_start(scroll_capture, False, False, 0)
        sidebar.pack_start(shortcut, False, False, 0)
        footer = Gtk.Box(margin_start=20, margin_end=14, margin_bottom=14)
        footer.pack_start(css(Gtk.Label(label=f"Version {__version__}", xalign=0), "muted"), True, True, 0)
        settings = css(Gtk.Button(label="⚙  Settings"), "nav-button")
        settings.connect("clicked", lambda *_: self.snapok.show_settings(self))
        footer.pack_end(settings, False, False, 0)
        sidebar.pack_start(footer, False, False, 0)
        root.pack_start(sidebar, False, False, 0)

        page = css(Gtk.Box(orientation=Gtk.Orientation.VERTICAL), "content-page")
        page.set_border_width(36)
        heading = Gtk.Box(spacing=20)
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        titles.pack_start(css(Gtk.Label(label="Library", xalign=0), "page-title"), False, False, 0)
        self.subtitle = css(Gtk.Label(xalign=0), "page-subtitle")
        titles.pack_start(self.subtitle, False, False, 0)
        heading.pack_start(titles, True, True, 0)
        self.search.set_size_request(320, 38)
        self.search.set_placeholder_text("Search names, categories, or tags")
        heading.pack_end(self.search, False, False, 0)
        self.category_filter.set_size_request(170, 38)
        heading.pack_end(self.category_filter, False, False, 0)
        page.pack_start(heading, False, False, 0)
        self.group_title = css(Gtk.Label(label="Today", xalign=0), "section-title")
        self.group_title.set_margin_top(28); self.group_title.set_margin_bottom(12)
        page.pack_start(self.group_title, False, False, 0)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        viewport = Gtk.Viewport()
        viewport.set_shadow_type(Gtk.ShadowType.NONE)
        container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        container.set_border_width(2)
        container.pack_start(self.empty, True, True, 80)
        container.pack_start(self.flow, False, False, 0)
        viewport.add(container)
        scroll.add(viewport)
        page.pack_start(scroll, True, True, 0)
        root.pack_start(page, True, True, 0)
        return root

    def refresh(self) -> None:
        selected_id = self.category_filter.get_active_id() or "__all__"
        self._refreshing_filters = True
        self.category_filter.remove_all()
        self.category_filter.append("__all__", "All categories")
        self.category_filter.append("__uncategorized__", "Unfiled")
        for category in self.snapok.store.categories():
            self.category_filter.append(category, category)
        self.category_filter.append("__trash__", "Trash")
        self.category_filter.set_active_id(selected_id)
        if self.category_filter.get_active() < 0:
            selected_id = "__all__"
            self.category_filter.set_active_id("__all__")
        self._refreshing_filters = False
        selected_filter = "" if selected_id == "__all__" else selected_id
        for child in self.flow.get_children():
            self.flow.remove(child)
        if selected_filter == "__trash__":
            documents = self.snapok.store.list_trashed(self.search.get_text())
        else:
            documents = self.snapok.store.list(self.search.get_text(), selected_filter)
        days = int(self.snapok.settings["retention_days"])
        kept = "forever" if days <= 0 else f"for {days} days"
        if selected_filter == "__trash__":
            self.subtitle.set_text(f"{len(documents)} items in Trash · Restore or delete permanently")
            self.group_title.set_text(f"Trash · {len(documents)}")
        else:
            self.subtitle.set_text(f"{len(documents)} screenshots · Kept {kept} · Double-click to edit")
            label = "All screenshots" if not selected_filter else (
                "Unfiled" if selected_filter == "__uncategorized__" else selected_filter
            )
            self.group_title.set_text(f"{label} · {len(documents)}")
        self.empty.set_visible(not documents)
        for document in documents:
            self.flow.add(self._card(document))
        self.flow.show_all()

    def _card(self, document: Document) -> Gtk.FlowBoxChild:
        child = Gtk.FlowBoxChild()
        child.document = document
        box = css(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7), "library-card")
        box.set_size_request(238, 205)
        frame = css(Gtk.Frame(), "thumbnail-well")
        try:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                str(self.snapok.store.thumbnail_path(document)), 200, 135, True
            )
            frame.add(Gtk.Image.new_from_pixbuf(pixbuf))
        except GLib.Error:
            frame.add(Gtk.Image.new_from_icon_name("image-missing", Gtk.IconSize.DIALOG))
        title = css(Gtk.Label(label=document.title, xalign=0), "card-title")
        title.set_ellipsize(3)
        date = document.created_at[:10] if document.created_at else ""
        detail_text = "Trash" if document.trashed else (document.category or "Unfiled")
        detail = Gtk.Label(label=f"{detail_text}  ·  {date}", xalign=0)
        detail.get_style_context().add_class("dim-label")
        metadata = Gtk.Box(spacing=6)
        metadata.pack_start(detail, True, True, 0)
        more = css(Gtk.Button(label="⋮"), "card-menu-button")
        more.set_tooltip_text("File actions")
        more.connect("clicked", self._show_document_menu, document)
        metadata.pack_end(more, False, False, 0)
        box.pack_start(frame, True, True, 0)
        box.pack_start(title, False, False, 0)
        box.pack_start(metadata, False, False, 0)
        child.add(box)
        child.set_tooltip_text("Double-click to edit")
        child.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        child.connect("button-press-event", self._card_button_press, document)
        return child

    def _activated(self, _flow, child) -> None:
        if not child.document.trashed:
            self.snapok.open_editor(child.document)

    def _category_changed(self, *_args) -> None:
        if not self._refreshing_filters:
            self.refresh()

    def _card_button_press(self, child, event, document: Document) -> bool:
        if event.button == 3:
            self._show_document_menu(child, document)
            return True
        return False

    def _show_document_menu(self, button, document: Document) -> None:
        menu = Gtk.Menu()
        actions = (
            [("Restore", self._restore_document), ("Delete permanently…", self._delete_permanently)]
            if document.trashed
            else [
                ("Open", lambda item: self.snapok.open_editor(item)),
                ("Rename…", self._rename_document),
                ("Organize…", self._organize_document),
                ("Move to Trash…", self._trash_document),
            ]
        )
        for label, callback in actions:
            item = Gtk.MenuItem(label=label)
            item.connect("activate", lambda _item, cb=callback: cb(document))
            menu.append(item)
        menu.show_all()
        menu.popup_at_widget(button, Gdk.Gravity.SOUTH_EAST, Gdk.Gravity.NORTH_EAST, None)

    def _rename_document(self, document: Document) -> None:
        dialog = Gtk.Dialog(title="Rename screenshot", transient_for=self, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Rename", Gtk.ResponseType.OK)
        entry = Gtk.Entry(text=document.title)
        entry.set_activates_default(True)
        entry.set_margin_start(16); entry.set_margin_end(16)
        entry.set_margin_top(16); entry.set_margin_bottom(16)
        dialog.get_content_area().add(entry)
        dialog.set_default_response(Gtk.ResponseType.OK)
        dialog.show_all()
        if dialog.run() == Gtk.ResponseType.OK and entry.get_text().strip():
            document.title = entry.get_text().strip()
            self.snapok.store.update_metadata(document)
            self.refresh()
        dialog.destroy()

    def _organize_document(self, document: Document) -> None:
        dialog = Gtk.Dialog(title="Organize screenshot", transient_for=self, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Save", Gtk.ResponseType.OK)
        grid = Gtk.Grid(column_spacing=12, row_spacing=12, margin=16)
        category = Gtk.ComboBoxText.new_with_entry()
        known = self.snapok.store.categories()
        for value in dict.fromkeys(["Work", "Personal", "Reference", "Receipts", *known]):
            category.append_text(value)
        category.get_child().set_text(document.category)
        tags = Gtk.Entry(text=", ".join(document.tags))
        tags.set_placeholder_text("project, important, client")
        grid.attach(Gtk.Label(label="Category", xalign=1), 0, 0, 1, 1)
        grid.attach(category, 1, 0, 1, 1)
        grid.attach(Gtk.Label(label="Tags", xalign=1), 0, 1, 1, 1)
        grid.attach(tags, 1, 1, 1, 1)
        dialog.get_content_area().add(grid)
        dialog.show_all()
        if dialog.run() == Gtk.ResponseType.OK:
            document.category = category.get_child().get_text().strip()
            document.tags = list(dict.fromkeys(
                value.strip() for value in tags.get_text().split(",") if value.strip()
            ))
            self.snapok.store.update_metadata(document)
            self.refresh()
        dialog.destroy()

    def _confirm(self, title: str, details: str, action: str) -> bool:
        dialog = Gtk.MessageDialog(
            self, Gtk.DialogFlags.MODAL, Gtk.MessageType.WARNING, Gtk.ButtonsType.CANCEL, title
        )
        dialog.format_secondary_text(details)
        dialog.add_button(action, Gtk.ResponseType.OK)
        accepted = dialog.run() == Gtk.ResponseType.OK
        dialog.destroy()
        return accepted

    def _trash_document(self, document: Document) -> None:
        if self._confirm("Move screenshot to Trash?", document.title, "Move to Trash"):
            self.snapok.store.trash(document)
            self.refresh()

    def _restore_document(self, document: Document) -> None:
        try:
            self.snapok.store.restore(document)
        except FileExistsError as error:
            self.snapok.error("Could not restore screenshot", str(error))
        self.refresh()

    def _delete_permanently(self, document: Document) -> None:
        if self._confirm(
            "Delete screenshot permanently?",
            f"{document.title}\nThis cannot be undone.",
            "Delete permanently",
        ):
            self.snapok.store.delete(document)
            self.refresh()

    def _hide_on_close(self, *_args) -> bool:
        self.hide()
        return True


class SnapokApplication(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(application_id=APPLICATION_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.settings = Settings()
        self.store = HistoryStore()
        self.main_window: MainWindow | None = None
        self.selector: RegionSelector | None = None
        self.editors: list[EditorWindow] = []
        self.hotkey: X11HotKey | None = None
        self.scroll_hotkey: X11HotKey | None = None
        self.tray = None
        self.capture_mode = "normal"
        self.scroll_window: ScrollCaptureWindow | None = None

    def do_startup(self) -> None:
        Gtk.Application.do_startup(self)
        icon = icon_path()
        if icon:
            Gtk.Window.set_default_icon_from_file(str(icon))
        install_styles()
        self.store.prune(int(self.settings["retention_days"]))
        quit_action = Gio.SimpleAction.new("quit", None)
        quit_action.connect("activate", lambda *_: self.quit())
        self.add_action(quit_action)

    def do_activate(self) -> None:
        if self.main_window is None:
            self.main_window = MainWindow(self)
            icon = icon_path()
            if icon:
                self.main_window.set_icon_from_file(str(icon))
            self._start_hotkey()
            self._create_tray(icon)
        self.main_window.show_all()
        self.main_window.present()

    def _start_hotkey(self) -> None:
        self.hotkey = X11HotKey(self.start_capture)
        self.hotkey.start(str(self.settings["hotkey"]))
        self.scroll_hotkey = X11HotKey(lambda: self.start_capture(scrolling=True))
        self.scroll_hotkey.start(str(self.settings["scroll_hotkey"]))

    def _create_tray(self, icon: Path | None) -> None:
        if not hasattr(Gtk, "StatusIcon"):
            return
        self.tray = Gtk.StatusIcon()
        if icon:
            self.tray.set_from_file(str(icon))
        else:
            self.tray.set_from_icon_name("camera-photo")
        self.tray.set_tooltip_text("Snapok — click to capture")
        self.tray.connect("activate", lambda *_: self.start_capture())
        self.tray.connect("popup-menu", self._tray_menu)

    def _tray_menu(self, _icon, button, activate_time) -> None:
        menu = Gtk.Menu()
        for label, callback in [
            ("New capture", self.start_capture),
            ("Show library", self._show_library),
            ("Quit", self.quit),
        ]:
            item = Gtk.MenuItem(label=label)
            item.connect("activate", lambda _item, cb=callback: cb())
            menu.append(item)
        menu.show_all()
        menu.popup(None, None, Gtk.StatusIcon.position_menu, self.tray, button, activate_time)

    def _show_library(self) -> None:
        if self.main_window:
            self.main_window.show_all()
            self.main_window.present()

    def start_capture(self, scrolling: bool = False) -> bool:
        if self.scroll_window is not None:
            if scrolling:
                self.scroll_window.finish()
            return False
        if self.selector is not None:
            return False
        if scrolling and (os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland" or os.environ.get("WAYLAND_DISPLAY")):
            self.error(
                "Scrolling capture needs X11",
                "Wayland permits protected portal screenshots one at a time, so continuous scrolling capture is unavailable. "
                "Log in with ‘Ubuntu on Xorg’ to use it.",
            )
            return False
        self.capture_mode = "scroll" if scrolling else "normal"
        if self.main_window:
            self.main_window.hide()
        for editor in self.editors:
            editor.hide()
        GLib.timeout_add(220, self._capture_after_hide)
        return False

    def _capture_after_hide(self) -> bool:
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
        try:
            capture = capture_screen(self.main_window)
            self.selector = RegionSelector(capture, self._selected)
            self.selector.connect("destroy", self._selector_closed)
        except Exception as error:
            self._show_library()
            self.error("Could not capture the screen", str(error))
        return False

    def _selector_closed(self, *_args) -> None:
        had_selector = self.selector is not None
        self.selector = None
        if had_selector and not any(editor.get_visible() for editor in self.editors):
            self._show_library()

    def _selected(self, image: Image.Image, rect: tuple[int, int, int, int]) -> None:
        if self.capture_mode == "scroll":
            self.scroll_window = ScrollCaptureWindow(
                image,
                rect,
                self._scroll_finished,
                finish_shortcut=str(self.settings["scroll_hotkey"]),
            )
            self.scroll_window.connect("destroy", self._scroll_closed)
            return
        document = self.store.create(image, transient=not bool(self.settings["auto_save"]))
        self.open_editor(document)
        if self.main_window:
            self.main_window.refresh()

    def _scroll_finished(self, image: Image.Image) -> None:
        document = self.store.create(
            image,
            title="Scrolling capture",
            transient=not bool(self.settings["auto_save"]),
        )
        self.open_editor(document)
        if self.main_window:
            self.main_window.refresh()

    def _scroll_closed(self, *_args) -> None:
        self.scroll_window = None
        if not any(editor.get_visible() for editor in self.editors):
            self._show_library()

    def open_editor(self, document: Document) -> None:
        window = EditorWindow(document, self.store, self.settings, self._history_changed)
        window.set_application(self)
        window.connect("destroy", lambda item: self.editors.remove(item) if item in self.editors else None)
        self.editors.append(window)
        window.present()

    def _history_changed(self) -> None:
        if self.main_window:
            self.main_window.refresh()

    def show_settings(self, parent: Gtk.Window) -> None:
        dialog = Gtk.Dialog(title="Settings — Snapok", transient_for=parent, modal=True)
        dialog.set_default_size(940, 620)
        dialog.set_decorated(False)
        body = css(Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL), "settings-panel")
        sidebar = css(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8), "sidebar")
        sidebar.set_size_request(230, -1)
        sidebar.set_border_width(14)
        profile = css(Gtk.Box(spacing=10), "shortcut-card")
        icon = icon_path()
        if icon:
            profile.pack_start(Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(icon), 42, 42, True)), False, False, 0)
        profile_text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        profile_text.pack_start(css(Gtk.Label(label="Snapok", xalign=0), "section-title"), False, False, 0)
        profile_text.pack_start(css(Gtk.Label(label="Local screenshot library", xalign=0), "muted"), False, False, 0)
        profile.pack_start(profile_text, True, True, 0)
        sidebar.pack_start(profile, False, False, 8)

        stack = Gtk.Stack()
        stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        stack.set_transition_duration(120)
        nav_group = None
        for key, label in [("general", "⚙   General"), ("about", "ⓘ   About")]:
            button = css(Gtk.RadioButton.new_with_label_from_widget(nav_group, label), "nav-button")
            if nav_group is None:
                nav_group = button
            button.set_mode(False)
            button.connect("toggled", lambda item, name=key: stack.set_visible_child_name(name) if item.get_active() else None)
            sidebar.pack_start(button, False, False, 0)
            if key == "general":
                button.set_active(True)
        body.pack_start(sidebar, False, False, 0)

        auto_save = Gtk.Switch(active=bool(self.settings["auto_save"]))
        retention = Gtk.ComboBoxText()
        for value, label in [("7", "7 days"), ("30", "30 days"), ("90", "90 days"), ("0", "Forever")]:
            retention.append(value, label)
        retention.set_active_id(str(self.settings["retention_days"]))
        hotkey = Gtk.Entry(text=str(self.settings["hotkey"]))
        hotkey.set_tooltip_text("Restart Snapok after changing the global shortcut")
        scroll_hotkey = Gtk.Entry(text=str(self.settings["scroll_hotkey"]))
        scroll_hotkey.set_tooltip_text("Move the pointer to the target screen, then press this shortcut")

        def page(title: str, subtitle: str) -> tuple[Gtk.Box, Gtk.Box]:
            outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=38)
            outer.pack_start(css(Gtk.Label(label=title, xalign=0), "page-title"), False, False, 0)
            outer.pack_start(css(Gtk.Label(label=subtitle, xalign=0), "page-subtitle"), False, False, 0)
            card = css(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12), "settings-card")
            card.set_margin_top(24)
            outer.pack_start(card, False, False, 0)
            return outer, card

        general, general_card = page("General", "Appearance, shortcuts, and screenshot storage preferences.")
        grid = Gtk.Grid(column_spacing=18, row_spacing=14)
        rows = [("Automatically save screenshots", auto_save), ("Keep screenshots", retention),
                ("Screenshot shortcut", hotkey), ("Scrolling capture shortcut", scroll_hotkey)]
        for row, (label, widget) in enumerate(rows):
            grid.attach(Gtk.Label(label=label, xalign=1), 0, row, 1, 1)
            grid.attach(widget, 1, row, 1, 1)
        library_path = css(Gtk.Label(label=str(self.store.root), xalign=0), "muted")
        library_path.set_line_wrap(True)
        grid.attach(Gtk.Label(label="Library", xalign=1), 0, 4, 1, 1)
        grid.attach(library_path, 1, 4, 1, 1)
        general_card.pack_start(grid, False, False, 0)
        note = Gtk.Label(
            label="Wayland capture uses the secure desktop screenshot portal.\n"
                  "Global shortcuts depend on support from your desktop portal.",
            xalign=0,
        )
        css(note, "muted")
        note.set_line_wrap(True)
        general_card.pack_start(note, False, False, 0)
        stack.add_named(general, "general")

        about, about_card = page("About", "Snapok for Ubuntu")
        about_card.pack_start(Gtk.Label(label=f"Version {__version__}\nNative GTK Linux preview\nAGPL-3.0", xalign=0), False, False, 0)
        stack.add_named(about, "about")

        content = Gtk.Overlay()
        content.add(stack)
        close = css(Gtk.Button(label="×"), "nav-button")
        close.set_halign(Gtk.Align.END); close.set_valign(Gtk.Align.START)
        close.set_margin_top(12); close.set_margin_end(12)
        close.connect("clicked", lambda *_: dialog.response(Gtk.ResponseType.CLOSE))
        content.add_overlay(close)
        body.pack_start(content, True, True, 0)
        dialog.get_content_area().add(body)
        dialog.show_all()
        dialog.run()
        self.settings["auto_save"] = auto_save.get_active()
        self.settings["retention_days"] = int(retention.get_active_id() or 30)
        self.settings["hotkey"] = hotkey.get_text().strip() or "Ctrl+Shift+P"
        self.settings["scroll_hotkey"] = scroll_hotkey.get_text().strip() or "Ctrl+Shift+O"
        dialog.destroy()

    def error(self, title: str, details: str) -> None:
        dialog = Gtk.MessageDialog(
            self.main_window,
            Gtk.DialogFlags.MODAL,
            Gtk.MessageType.ERROR,
            Gtk.ButtonsType.CLOSE,
            title,
        )
        dialog.format_secondary_text(details)
        dialog.run()
        dialog.destroy()

    def do_shutdown(self) -> None:
        if self.hotkey:
            self.hotkey.stop()
        if self.scroll_hotkey:
            self.scroll_hotkey.stop()
        Gtk.Application.do_shutdown(self)


def run(argv: list[str] | None = None) -> int:
    stop_older_instances()
    application = SnapokApplication()
    return application.run(argv or sys.argv)
