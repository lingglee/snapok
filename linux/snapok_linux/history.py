from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import uuid
from pathlib import Path

from PIL import Image

from .model import Document

try:
    RESAMPLE_LANCZOS = Image.Resampling.LANCZOS
except AttributeError:  # Pillow shipped by older Ubuntu LTS releases
    RESAMPLE_LANCZOS = Image.LANCZOS


def data_root() -> Path:
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "snapok" / "history"


def config_root() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "snapok"


def cache_root() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    return base / "snapok" / "drafts"


class Settings:
    defaults = {
        "auto_save": True,
        "retention_days": 30,
        "hotkey": "Ctrl+Shift+P",
        "scroll_hotkey": "Ctrl+Shift+O",
        "hotkey_schema": 2,
        "last_tool": "rectangle",
        "stroke_color": "#ec4899",
        "stroke_width": 4,
        "mosaic_style": "pixelate",
    }

    def __init__(self) -> None:
        self.path = config_root() / "settings.json"
        self.values = dict(self.defaults)
        loaded = {}
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
            self.values.update(loaded)
        except (OSError, ValueError, TypeError):
            pass
        removed_ai_settings = False
        for key in ("ai_base_url", "ai_model"):
            if key in self.values:
                self.values.pop(key)
                removed_ai_settings = True
        if int(loaded.get("hotkey_schema", 1)) < 2:
            if self.values.get("hotkey") == "Ctrl+Super+A":
                self.values["hotkey"] = "Ctrl+Shift+P"
            self.values["hotkey_schema"] = 2
            self.save()
        elif removed_ai_settings:
            self.save()

    def __getitem__(self, key):
        return self.values[key]

    def __setitem__(self, key, value) -> None:
        self.values[key] = value
        self.save()

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.values, indent=2, ensure_ascii=False), encoding="utf-8")
        temporary.replace(self.path)


class HistoryStore:
    def __init__(self, root: Path | None = None) -> None:
        self.root = root or data_root()
        self.root.mkdir(parents=True, exist_ok=True)

    @property
    def trash_root(self) -> Path:
        return self.root / ".trash"

    def create(self, image: Image.Image, title: str = "Screenshot", transient: bool = False) -> Document:
        now = dt.datetime.now(dt.timezone.utc)
        identifier = f"{now.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:8]}"
        folder = (cache_root() if transient else self.root) / identifier
        folder.mkdir(parents=True)
        image.convert("RGB").save(folder / "original.png", "PNG")
        document = Document(
            image_path=folder / "original.png",
            title=title,
            identifier=identifier,
            created_at=now.isoformat(),
            transient=transient,
        )
        if not transient:
            self.save(document, image)
        return document

    def save(self, document: Document, rendered: Image.Image | None = None) -> None:
        old_folder = document.image_path.parent if document.transient else None
        folder = self.root / document.identifier
        folder.mkdir(parents=True, exist_ok=True)
        if document.image_path.resolve() != (folder / "original.png").resolve():
            shutil.copy2(document.image_path, folder / "original.png")
            document.image_path = folder / "original.png"
        self._write_metadata(folder, document)
        source = rendered or Image.open(document.image_path)
        source.convert("RGB").save(folder / "rendered.png", "PNG")
        thumbnail = source.copy()
        thumbnail.thumbnail((420, 260), RESAMPLE_LANCZOS)
        thumbnail.convert("RGB").save(folder / "thumbnail.jpg", "JPEG", quality=86)
        document.transient = False
        if old_folder and old_folder != folder and old_folder.exists():
            shutil.rmtree(old_folder)

    def _write_metadata(self, folder: Path, document: Document) -> None:
        path = folder / "meta.json"
        temporary = path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(document.metadata(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temporary.replace(path)

    def update_metadata(self, document: Document) -> None:
        """Save title/category/tags without re-rendering or replacing the edited image."""
        folder = document.image_path.parent
        if folder.parent not in {self.root, self.trash_root}:
            raise ValueError("Document is outside the Snapok library")
        self._write_metadata(folder, document)

    def list(self, query: str = "", category: str = "") -> list[Document]:
        query = query.casefold().strip()
        documents: list[Document] = []
        for metadata in self.root.glob("*/meta.json"):
            try:
                item = Document.load(metadata.parent)
            except (OSError, ValueError, TypeError):
                continue
            haystack = f"{item.title} {item.category} {' '.join(item.tags)}".casefold()
            category_matches = (
                not category
                or (category == "__uncategorized__" and not item.category)
                or item.category.casefold() == category.casefold()
            )
            if category_matches and (not query or query in haystack):
                documents.append(item)
        return sorted(documents, key=lambda item: item.created_at, reverse=True)

    def categories(self) -> list[str]:
        return sorted({item.category for item in self.list() if item.category}, key=str.casefold)

    def list_trashed(self, query: str = "") -> list[Document]:
        query = query.casefold().strip()
        documents: list[Document] = []
        if not self.trash_root.exists():
            return documents
        for metadata in self.trash_root.glob("*/meta.json"):
            try:
                item = Document.load(metadata.parent)
            except (OSError, ValueError, TypeError):
                continue
            item.trashed = True
            haystack = f"{item.title} {item.category} {' '.join(item.tags)}".casefold()
            if not query or query in haystack:
                documents.append(item)
        return sorted(documents, key=lambda item: item.created_at, reverse=True)

    def rendered_path(self, document: Document) -> Path:
        rendered = self.root / document.identifier / "rendered.png"
        return rendered if rendered.exists() else document.image_path

    def thumbnail_path(self, document: Document) -> Path:
        thumbnail = self.root / document.identifier / "thumbnail.jpg"
        return thumbnail if thumbnail.exists() else self.rendered_path(document)

    def delete(self, document: Document) -> None:
        folder = document.image_path.parent
        if folder.parent in {self.root, self.trash_root} and folder.exists():
            shutil.rmtree(folder)

    def trash(self, document: Document) -> None:
        folder = document.image_path.parent
        if folder.parent != self.root or not folder.exists():
            return
        self.trash_root.mkdir(exist_ok=True)
        destination = self.trash_root / document.identifier
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(folder), str(destination))
        document.image_path = destination / "original.png"
        document.trashed = True

    def restore(self, document: Document) -> None:
        folder = document.image_path.parent
        if folder.parent != self.trash_root or not folder.exists():
            return
        destination = self.root / document.identifier
        if destination.exists():
            raise FileExistsError(f"A library item named {document.identifier} already exists")
        shutil.move(str(folder), str(destination))
        document.image_path = destination / "original.png"
        document.trashed = False

    def discard(self, document: Document) -> None:
        if document.transient and document.image_path.parent.exists():
            shutil.rmtree(document.image_path.parent)

    def prune(self, retention_days: int) -> None:
        if retention_days <= 0:
            return
        cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=retention_days)
        for item in self.list():
            try:
                created = dt.datetime.fromisoformat(item.created_at)
            except ValueError:
                continue
            if created < cutoff:
                self.delete(item)
