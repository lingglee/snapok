import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

from PIL import Image, ImageDraw

from snapok_linux.ai import annotations_from_plan, parse_plan
from snapok_linux.app import APPLICATION_ID, LEGACY_APPLICATION_ID, stop_older_instances
from snapok_linux.editor import MAX_ZOOM, MIN_ZOOM, zoom_after_scroll
from snapok_linux.history import HistoryStore, Settings
from snapok_linux.hotkey import X11HotKey
from snapok_linux.images import frame_image, render_document
from snapok_linux.model import Annotation
from snapok_linux.scroll import ScrollStitcher, estimate_scroll
from gi.repository import Gdk


class CoreTests(unittest.TestCase):
    def test_annotations_and_history_round_trip(self):
        base = Image.new("RGB", (320, 200), "white")
        annotations = [
            Annotation("rectangle", [(10, 10), (100, 80)], "#ff0000", 4),
            Annotation("ellipse", [(120, 10), (200, 80)], "#00aa00", 3),
            Annotation("arrow", [(10, 120), (100, 160)], "#0000ff", 5),
            Annotation("pen", [(120, 120), (140, 150), (180, 130)], "#111111", 3),
            Annotation("text", [(210, 20), (211, 21)], "#000000", 4, text="Snapok"),
            Annotation("mosaic", [(210, 100), (300, 170)], "#000000", 5),
            Annotation("step", [(280, 50)], "#ec4899", 4, number=1),
        ]
        rendered = render_document(base, annotations)
        with tempfile.TemporaryDirectory() as directory:
            store = HistoryStore(Path(directory))
            document = store.create(base)
            document.annotations = annotations
            store.save(document, rendered)
            loaded = store.list()[0]
            self.assertEqual(len(loaded.annotations), len(annotations))
            self.assertTrue(store.thumbnail_path(loaded).exists())

    def test_frame(self):
        image = Image.new("RGBA", (320, 180), "white")
        result = frame_image(image, {
            "enabled": True, "padding_x": 40, "padding_y": 30,
            "corner_radius": 20, "shadow": True, "background": "gradient",
            "color_start": "#7c3aed", "color_end": "#ec4899",
        })
        self.assertEqual(result.size, (448, 288))

    def test_transient_capture_can_be_promoted(self):
        image = Image.new("RGB", (40, 30), "white")
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as cache:
            import os
            previous = os.environ.get("XDG_CACHE_HOME")
            os.environ["XDG_CACHE_HOME"] = cache
            try:
                store = HistoryStore(Path(directory))
                document = store.create(image, transient=True)
                draft = document.image_path.parent
                self.assertTrue(document.transient)
                self.assertEqual(store.list(), [])
                store.save(document, image)
                self.assertFalse(document.transient)
                self.assertFalse(draft.exists())
                self.assertEqual(len(store.list()), 1)
            finally:
                if previous is None:
                    os.environ.pop("XDG_CACHE_HOME", None)
                else:
                    os.environ["XDG_CACHE_HOME"] = previous

    def test_scroll_stitch(self):
        tall = Image.new("RGB", (500, 1000), "white")
        draw = ImageDraw.Draw(tall)
        for y in range(0, 1000, 35):
            draw.rectangle((10, y + 2, 490, y + 25), fill=((y * 3) % 255, (y * 5) % 255, (y * 7) % 255))
            draw.text((20, y + 5), f"row {y}", fill="black")
        frames = [tall.crop((0, offset, 500, offset + 400)) for offset in (0, 150, 300)]
        shift, confidence, _top, _bottom = estimate_scroll(frames[0], frames[1])
        self.assertAlmostEqual(shift, 150, delta=2)
        self.assertGreater(confidence, 0.7)
        stitcher = ScrollStitcher(frames[0])
        self.assertTrue(stitcher.add(frames[1]))
        self.assertTrue(stitcher.add(frames[2]))
        self.assertAlmostEqual(stitcher.result.height, 700, delta=3)

    def test_agent_plan_validation(self):
        plan = parse_plan('{"message":"ok","actions":[{"tool":"mosaic","points":[[-2,5],[1200,500]]}]}')
        annotations = annotations_from_plan(plan, 800, 400)
        self.assertEqual(annotations[0].points, [(0.0, 5.0), (800.0, 400.0)])

    def test_old_default_hotkey_is_migrated(self):
        import json
        import os
        with tempfile.TemporaryDirectory() as directory:
            previous = os.environ.get("XDG_CONFIG_HOME")
            os.environ["XDG_CONFIG_HOME"] = directory
            try:
                folder = Path(directory) / "snapok"
                folder.mkdir()
                (folder / "settings.json").write_text(
                    json.dumps({"hotkey": "Ctrl+Super+A"}), encoding="utf-8"
                )
                settings = Settings()
                self.assertEqual(settings["hotkey"], "Ctrl+Shift+P")
                self.assertEqual(settings["hotkey_schema"], 2)
            finally:
                if previous is None:
                    os.environ.pop("XDG_CONFIG_HOME", None)
                else:
                    os.environ["XDG_CONFIG_HOME"] = previous

    def test_new_hotkey_modifiers(self):
        hotkey = X11HotKey(lambda: None)
        key, modifiers = hotkey._parse("Ctrl+Shift+P")
        self.assertEqual(key, "P")
        self.assertEqual(modifiers, hotkey.CONTROL | hotkey.SHIFT)

    def test_editor_wheel_zoom_is_bounded(self):
        self.assertGreater(zoom_after_scroll(1.0, Gdk.ScrollDirection.UP), 1.0)
        self.assertLess(zoom_after_scroll(1.0, Gdk.ScrollDirection.DOWN), 1.0)
        self.assertEqual(zoom_after_scroll(MAX_ZOOM, Gdk.ScrollDirection.UP), MAX_ZOOM)
        self.assertEqual(zoom_after_scroll(MIN_ZOOM, Gdk.ScrollDirection.DOWN), MIN_ZOOM)

    def test_new_version_stops_legacy_single_instance(self):
        self.assertEqual(APPLICATION_ID, "ai.thinkany.snapok.linux.v0_1_3")
        with patch("snapok_linux.app._running_snapok_app_ids", return_value=set()), \
             patch("snapok_linux.app.time.sleep"), \
             patch("snapok_linux.app.subprocess.run") as run:
            stop_older_instances()
        self.assertIn(
            call(
                ["gapplication", "action", LEGACY_APPLICATION_ID, "quit"],
                capture_output=True,
                check=False,
                timeout=2,
            ),
            run.call_args_list,
        )


if __name__ == "__main__":
    unittest.main()
