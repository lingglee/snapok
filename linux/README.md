# Snapok for Ubuntu

This directory contains the native Linux port of Snapok. It is intentionally
separate from the AppKit target in `Sources/Snapok`, so the macOS application
continues to build unchanged.

## Run from source

Ubuntu 22.04 or later is recommended. Install the system runtime packages:

```bash
sudo apt install python3-gi gir1.2-gtk-3.0 python3-pil python3-numpy python3-opencv
```

Then run:

```bash
./linux/snapok
```

## Editor navigation

- Scroll the mouse wheel over the image to zoom around the pointer (10%–400%).
- Select the hand tool or press `H`, then drag with the left mouse button to pan.
- Hold `Space` and drag for temporary panning, or drag with the middle mouse button from any tool.

On X11, the default global shortcut is `Ctrl+Shift+P`; scrolling capture is
`Ctrl+Shift+O`. Move the pointer onto the screen you want before pressing a
shortcut: the region selector opens on the monitor under the pointer. On Wayland, use the
desktop's screenshot shortcut or the **New capture** button until the desktop
portal exposes the Global Shortcuts interface. Screen capture itself uses the
standard `org.freedesktop.portal.Screenshot` portal on Wayland.

Scrolling capture is available on X11. Press `Ctrl+Shift+O` and select the
scrolling content area (not the browser chrome). When `xdotool` is installed,
Snapok automatically scrolls in small steps and captures every section; click
**Done here** or press `Ctrl+Shift+O` again at the endpoint you choose. Move the
pointer outside the capture area to pause and inspect the current position; move
it back inside to resume. Wayland deliberately prevents the continuous
silent screen reads this feature requires.

Without `xdotool`, scroll at a steady pace so adjacent frames overlap. Snapok
samples several times per second; if overlap is lost, it pauses instead of
silently joining a later frame and tells you to scroll back slightly. A generic
desktop capture cannot read content an application has not rendered yet, so
automatic scroll-and-capture is used to provide the full-page experience.

## Install for the current user

```bash
./linux/install.sh
```

This installs only launchers and application files under `~/.local`; it does
not use `sudo` or change system packages. Reinstalling replaces the application
code but preserves the screenshot library in `~/.local/share/snapok/history`.

## Library management

Each screenshot card has a **⋮** menu (also available with right-click) for
opening, renaming, organizing, or moving the item to Trash. **Organize** assigns
one category and any number of comma-separated tags. Use the category filter at
the top of Library to show a category, unfiled screenshots, or Trash. Trashed
items can be restored or deleted permanently; search matches names, categories,
and tags.

## Build and install a Debian package

For a one-command clean rebuild, package replacement, and launch:

```bash
cd /home/mdpi/workspace/snapok
./linux/rebuild-install.sh
```

The script preserves screenshots and settings, removes the per-user application,
stops old background processes, runs tests, rebuilds the package, purges the old
Debian package, installs the new package, launches `/usr/bin/snapok`, and verifies
that the system-package process remains running. The equivalent Make target is
`make linux-reinstall`.

For the same steps manually:

Do not keep both the per-user installation and Debian package. First remove the
per-user application (screenshots and settings are preserved), then build and
install the package:

```bash
cd /home/mdpi/workspace/snapok
./linux/uninstall-user.sh
make linux-test
make linux-package
pkexec apt install -y "$PWD/dist/snapok_0.1.4_amd64.deb"
/usr/bin/snapok
```

`make linux-package` reads the version from `snapok_linux/__init__.py`, so the
package filename and application ID stay in sync. The Debian package stops any
running `/usr/lib/snapok` process before upgrade or removal. Its desktop entry
uses the absolute `/usr/bin/snapok` path, so an old executable elsewhere in
`PATH` cannot intercept it.

If you rebuild the same version, use `--reinstall` so APT replaces every file:

```bash
make linux-test
make linux-package
pkexec apt install --reinstall -y "$PWD/dist/snapok_0.1.4_amd64.deb"
/usr/bin/snapok
```

To inspect or manually stop a background instance:

```bash
ps -eo pid,args | grep '[s]napok_linux.py'
pkill -TERM -f '^python3 /usr/lib/snapok/snapok_linux\.py($| )'
pkill -TERM -f "^python3 $HOME/.local/bin/snapok( |$)"
```

For a new release, change only `__version__` in
`linux/snapok_linux/__init__.py`; do not pass a separate version unless you are
deliberately building a prerelease. Versioned application IDs let a new release
close an older running Snapok instance instead of activating stale code.

## Optional features

- OCR needs the `tesseract-ocr` package and the desired language packs.
- Clipboard integration requires a running graphical desktop session.
- Wayland capture requires `xdg-desktop-portal` and the portal backend supplied
  by the desktop environment (GNOME, KDE, wlroots, and so on).
