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

On X11, the default global shortcut is `Ctrl+Shift+P`. On Wayland, use the
desktop's screenshot shortcut or the **New capture** button until the desktop
portal exposes the Global Shortcuts interface. Screen capture itself uses the
standard `org.freedesktop.portal.Screenshot` portal on Wayland.

## Install for the current user

```bash
./linux/install.sh
```

This installs only launchers and application files under `~/.local`; it does
not use `sudo` or change system packages.

## Build and install a Debian package

Run these commands from the repository root:

```bash
cd /home/mdpi/workspace/snapok
make linux-test
make linux-package
pkexec apt install -y "$PWD/dist/snapok_0.1.3_amd64.deb"
snapok
```

The package is written to `dist/`. If you rebuild the same version, close its
running instance and use `--reinstall` so APT replaces the installed files:

```bash
gapplication action ai.thinkany.snapok.linux.v0_1_3 quit || true
make linux-test
make linux-package
pkexec apt install --reinstall -y "$PWD/dist/snapok_0.1.3_amd64.deb"
snapok
```

For a new version, change `__version__` in
`linux/snapok_linux/__init__.py`, then build the Debian package with the same
version value:

```bash
SNAPOK_VERSION=0.1.4
VERSION="$SNAPOK_VERSION" ./linux/build-deb.sh
pkexec apt install -y "$PWD/dist/snapok_${SNAPOK_VERSION}_amd64.deb"
snapok
```

Use a higher version for feature updates. Versioned application IDs let a new
release close an older running Snapok instance instead of activating stale
code.

## Optional features

- OCR needs the `tesseract-ocr` package and the desired language packs.
- Clipboard integration requires a running graphical desktop session.
- Wayland capture requires `xdg-desktop-portal` and the portal backend supplied
  by the desktop environment (GNOME, KDE, wlroots, and so on).
