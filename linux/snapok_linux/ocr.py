from __future__ import annotations

import csv
import io
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image


class OCRError(RuntimeError):
    pass


@dataclass
class OCRWord:
    text: str
    left: int
    top: int
    width: int
    height: int
    confidence: float


def _executable() -> str:
    executable = shutil.which("tesseract")
    if not executable:
        raise OCRError("Install the Ubuntu package ‘tesseract-ocr’ to use OCR and automatic redaction.")
    return executable


def words(image: Image.Image, language: str = "eng") -> list[OCRWord]:
    executable = _executable()
    with tempfile.TemporaryDirectory(prefix="snapok-ocr-") as directory:
        source = Path(directory) / "capture.png"
        image.convert("RGB").save(source)
        result = subprocess.run(
            [executable, str(source), "stdout", "-l", language, "tsv"],
            text=True,
            capture_output=True,
        )
    if result.returncode != 0:
        raise OCRError(result.stderr.strip() or "Tesseract returned an error.")
    output: list[OCRWord] = []
    for row in csv.DictReader(io.StringIO(result.stdout), delimiter="\t"):
        text = (row.get("text") or "").strip()
        if not text:
            continue
        try:
            confidence = float(row.get("conf", "-1"))
            if confidence < 15:
                continue
            output.append(OCRWord(
                text=text,
                left=int(row.get("left", 0)),
                top=int(row.get("top", 0)),
                width=int(row.get("width", 0)),
                height=int(row.get("height", 0)),
                confidence=confidence,
            ))
        except (TypeError, ValueError):
            continue
    return output


def text(image: Image.Image, language: str = "eng") -> str:
    executable = _executable()
    with tempfile.TemporaryDirectory(prefix="snapok-ocr-") as directory:
        source = Path(directory) / "capture.png"
        image.convert("RGB").save(source)
        result = subprocess.run(
            [executable, str(source), "stdout", "-l", language],
            text=True,
            capture_output=True,
        )
    if result.returncode != 0:
        raise OCRError(result.stderr.strip() or "Tesseract returned an error.")
    return result.stdout


SENSITIVE = [
    re.compile(r"^[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}$"),
    re.compile(r"^(?:\+?\d[\d() .-]{6,}\d)$"),
    re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$"),
    re.compile(r"^(?:\d[ -]*?){13,19}$"),
    re.compile(r"^(?:https?://|www\.)", re.IGNORECASE),
]


def sensitive_words(image: Image.Image, language: str = "eng") -> list[OCRWord]:
    return [word for word in words(image, language) if any(pattern.search(word.text) for pattern in SENSITIVE)]
