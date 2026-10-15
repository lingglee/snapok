from __future__ import annotations

import base64
import io
import json
import re
import subprocess
import urllib.error
import urllib.request
from typing import Any

from PIL import Image

from .model import Annotation


class AIError(RuntimeError):
    pass


class SecretStore:
    attributes = ["application", "snapok", "account", "default"]

    @classmethod
    def get(cls) -> str:
        try:
            result = subprocess.run(
                ["secret-tool", "lookup", *cls.attributes],
                capture_output=True,
                text=True,
                timeout=10,
            )
            return result.stdout.strip() if result.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            return ""

    @classmethod
    def set(cls, value: str) -> None:
        if not value:
            return
        try:
            subprocess.run(
                ["secret-tool", "store", "--label=Snapok AI API key", *cls.attributes],
                input=value,
                text=True,
                check=True,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise AIError(f"Could not save the API key in Ubuntu Keyring: {error}") from error


SYSTEM_PROMPT = """You are Snapok Agent, an image annotation planner. Analyze the attached screenshot and obey the user's edit request.
Return JSON only, with this schema:
{"message":"brief explanation","actions":[{"tool":"rectangle|ellipse|arrow|pen|text|mosaic|erase|step","points":[[x,y],[x,y]],"color":"#rrggbb","width":4,"text":"optional","style":"pixelate|blur|solid"}]}
Coordinates are source-image pixels with origin at the upper-left. Use mosaic to redact private material. Use text to add or translate labels. Keep every point inside WIDTH x HEIGHT. Do not claim to have edited pixels outside these tools. If the user only asks a question, return an empty actions array and answer in message."""


class AIClient:
    def __init__(self, base_url: str, model: str, api_key: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key = api_key

    def endpoint(self) -> str:
        if self.base_url.endswith("/chat/completions"):
            return self.base_url
        return self.base_url + "/chat/completions"

    def request(self, image: Image.Image, prompt: str) -> dict[str, Any]:
        if not self.api_key:
            raise AIError("Configure an API key in Settings first.")
        buffer = io.BytesIO()
        image.convert("RGB").save(buffer, "JPEG", quality=90)
        encoded = base64.b64encode(buffer.getvalue()).decode("ascii")
        system = SYSTEM_PROMPT.replace("WIDTH", str(image.width)).replace("HEIGHT", str(image.height))
        payload = {
            "model": self.model,
            "temperature": 0.1,
            "messages": [
                {"role": "system", "content": system},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": prompt},
                        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{encoded}"}},
                    ],
                },
            ],
        }
        request = urllib.request.Request(
            self.endpoint(),
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.api_key}"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                result = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            details = error.read().decode("utf-8", "replace")[:1000]
            raise AIError(f"Model request failed ({error.code}): {details}") from error
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            raise AIError(f"Model request failed: {error}") from error
        try:
            content = result["choices"][0]["message"]["content"]
            if isinstance(content, list):
                content = "".join(item.get("text", "") for item in content if isinstance(item, dict))
            return parse_plan(str(content))
        except (KeyError, IndexError, TypeError) as error:
            raise AIError("The model returned an unsupported response.") from error


def parse_plan(content: str) -> dict[str, Any]:
    content = content.strip()
    fenced = re.search(r"```(?:json)?\s*(.*?)```", content, re.DOTALL | re.IGNORECASE)
    if fenced:
        content = fenced.group(1).strip()
    try:
        data = json.loads(content)
    except ValueError as error:
        raise AIError(f"The model did not return a valid edit plan: {content[:500]}") from error
    if isinstance(data, list):
        data = {"message": "", "actions": data}
    if not isinstance(data, dict) or not isinstance(data.get("actions", []), list):
        raise AIError("The model returned an invalid edit-plan shape.")
    return data


def annotations_from_plan(plan: dict[str, Any], width: int, height: int) -> list[Annotation]:
    allowed = {"rectangle", "ellipse", "arrow", "pen", "text", "mosaic", "erase", "step"}
    annotations: list[Annotation] = []
    next_step = 1
    for action in plan.get("actions", []):
        if not isinstance(action, dict) or action.get("tool") not in allowed:
            continue
        points = []
        for point in action.get("points", []):
            if isinstance(point, (list, tuple)) and len(point) >= 2:
                try:
                    points.append((max(0.0, min(float(width), float(point[0]))),
                                   max(0.0, min(float(height), float(point[1])))))
                except (TypeError, ValueError):
                    pass
        if not points:
            continue
        tool = str(action["tool"])
        if tool not in {"text", "step"} and len(points) < 2:
            continue
        annotations.append(Annotation(
            kind=tool,
            points=points,
            color=str(action.get("color", "#ec4899")),
            width=max(1, min(30, int(action.get("width", 4)))),
            text=str(action.get("text", "")),
            number=next_step if tool == "step" else 0,
            style=str(action.get("style", "pixelate")),
        ))
        if tool == "step":
            next_step += 1
    return annotations
