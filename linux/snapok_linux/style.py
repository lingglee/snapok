from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk


CSS = b"""
* {
  font-family: Inter, "Noto Sans", Ubuntu, sans-serif;
}
window, .snapok-root, .content-page {
  background: #f7f7f9;
  color: #202024;
}
.sidebar {
  background: #f0f0f3;
  border-right: 1px solid #dedee3;
}
.brand-name {
  font-size: 24px;
  font-weight: 800;
  color: #202024;
}
.page-title {
  font-size: 30px;
  font-weight: 800;
  color: #18181b;
}
.page-subtitle, .muted {
  color: #77777f;
  font-size: 13px;
}
.section-title {
  font-size: 17px;
  font-weight: 700;
  color: #242429;
}
.nav-button {
  border: 0;
  border-radius: 9px;
  padding: 12px 14px;
  background: transparent;
  box-shadow: none;
  color: #707078;
  font-weight: 600;
}
.nav-button:hover { background: rgba(30,30,40,.06); }
.nav-button:checked, .nav-selected {
  background: rgba(236,72,153,.10);
  color: #29292e;
}
.shortcut-card, .settings-card {
  background: #ffffff;
  border: 1px solid #e5e5e8;
  border-radius: 13px;
  padding: 16px;
}
.keycap {
  background: #fff;
  border: 1px solid #c9c9cf;
  border-radius: 7px;
  padding: 5px 9px;
  font-weight: 700;
}
.accent-button {
  color: white;
  background: #dc4b97;
  border: 0;
  border-radius: 10px;
  padding: 10px 18px;
  font-weight: 700;
  box-shadow: none;
}
.accent-button:hover { background: #c83f86; }
.library-card {
  background: #ffffff;
  border: 1px solid #e4e4e7;
  border-radius: 12px;
  padding: 10px;
}
.library-card:hover {
  border-color: rgba(220,75,151,.55);
  box-shadow: 0 3px 10px rgba(0,0,0,.08);
}
flowboxchild { padding: 2px; background: transparent; }
flowboxchild:selected { background: transparent; }
.thumbnail-well {
  background: #f0f0f3;
  border-radius: 9px;
  padding: 8px;
}
.card-title { font-size: 14px; font-weight: 700; color: #26262a; }
.card-menu-button {
  min-width: 24px;
  min-height: 22px;
  padding: 0 6px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  box-shadow: none;
  color: #77777f;
  font-weight: 800;
}
.card-menu-button:hover { background: rgba(30,30,40,.08); color: #242429; }
.editor-header { background: #f3f3f5; border-bottom: 1px solid #dddddf; }
.canvas-area { background: #171923; }
.inspector { background: #f4f4f6; border-left: 1px solid #dcdce1; }
.toolbar-area { background: #f3f3f5; border-top: 1px solid #dadade; }
.tool-button {
  background: #fff;
  border: 1px solid #d3d3d8;
  border-radius: 7px;
  padding: 5px 9px;
  box-shadow: none;
}
.tool-button:checked { background: rgba(220,75,151,.14); border-color: #dc4b97; color: #c23880; }
.flat-action {
  background: #fff;
  border: 1px solid #d6d6da;
  border-radius: 8px;
  padding: 7px 13px;
  box-shadow: none;
}
.inspector-title { font-size: 16px; font-weight: 800; }
.inspector-section { font-size: 14px; font-weight: 800; margin-top: 8px; }
.dim-overlay { background: rgba(0,0,0,.30); }
.settings-panel { background: #f7f7f9; border-radius: 14px; box-shadow: 0 12px 45px rgba(0,0,0,.25); }
entry, searchentry, combobox button, spinbutton {
  border-radius: 7px;
  border-color: #d3d3d8;
  background: #fff;
}
"""


def install_styles() -> None:
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    screen = Gdk.Screen.get_default()
    if screen:
        Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def css(widget: Gtk.Widget, *classes: str) -> Gtk.Widget:
    context = widget.get_style_context()
    for name in classes:
        context.add_class(name)
    return widget
