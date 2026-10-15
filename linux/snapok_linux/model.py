from __future__ import annotations

import copy
import dataclasses
import json
import uuid
from pathlib import Path
from typing import Any


@dataclasses.dataclass
class Annotation:
    kind: str
    points: list[tuple[float, float]]
    color: str = "#ec4899"
    width: int = 4
    text: str = ""
    number: int = 0
    style: str = "pixelate"

    def to_dict(self) -> dict[str, Any]:
        value = dataclasses.asdict(self)
        value["points"] = [list(point) for point in self.points]
        return value

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "Annotation":
        data = dict(value)
        data["points"] = [tuple(point) for point in data.get("points", [])]
        return cls(**data)


@dataclasses.dataclass
class Document:
    image_path: Path
    annotations: list[Annotation] = dataclasses.field(default_factory=list)
    title: str = "Screenshot"
    tags: list[str] = dataclasses.field(default_factory=list)
    identifier: str = dataclasses.field(default_factory=lambda: str(uuid.uuid4()))
    created_at: str = ""
    transient: bool = False
    frame: dict[str, Any] = dataclasses.field(default_factory=lambda: {
        "enabled": False,
        "padding_x": 48,
        "padding_y": 48,
        "corner_radius": 18,
        "shadow": True,
        "background": "gradient",
        "color_start": "#7c3aed",
        "color_end": "#ec4899",
        "angle": 35,
        "border_width": 0,
        "border_color": "#ffffff",
        "watermark": False,
    })

    def snapshot(self) -> list[Annotation]:
        return copy.deepcopy(self.annotations)

    def metadata(self) -> dict[str, Any]:
        return {
            "id": self.identifier,
            "title": self.title,
            "tags": self.tags,
            "created_at": self.created_at,
            "annotations": [item.to_dict() for item in self.annotations],
            "frame": self.frame,
        }

    @classmethod
    def load(cls, folder: Path) -> "Document":
        data = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
        return cls(
            image_path=folder / "original.png",
            annotations=[Annotation.from_dict(item) for item in data.get("annotations", [])],
            title=data.get("title", "Screenshot"),
            tags=data.get("tags", []),
            identifier=data.get("id", folder.name),
            created_at=data.get("created_at", ""),
            transient=False,
            frame=data.get("frame") or cls.__dataclass_fields__["frame"].default_factory(),
        )
