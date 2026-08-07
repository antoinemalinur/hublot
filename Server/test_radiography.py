from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import radiography


class RadiographyTranslationTests(unittest.TestCase):
    def test_command_prefers_the_deepest_real_project_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("root", encoding="utf-8")
            (root / "office_chess").mkdir()
            target = root / "office_chess" / "database.py"
            target.write_text("db", encoding="utf-8")

            locations = radiography.command_locations(
                "/bin/bash -lc 'sed -n 1p README.md office_chess/database.py'",
                directory,
            )

            self.assertEqual(locations[0]["path"], str(target.resolve()))
            self.assertFalse(any(entry["path"] == "/bin/bash" for entry in locations))

    def test_command_update_keeps_input_and_location(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "App.swift"
            target.write_text("", encoding="utf-8")
            updates = radiography.codex_tool_updates(
                "item.started",
                {"id": "cmd", "type": "command_execution", "command": "sed App.swift"},
                directory,
            )

            self.assertEqual(len(updates), 1)
            self.assertEqual(updates[0]["rawInput"]["command"], "sed App.swift")
            self.assertEqual(updates[0]["locations"], [{"path": str(target.resolve())}])

    def test_relative_escape_is_not_exposed_as_a_project_location(self) -> None:
        locations = radiography.command_locations(
            "cat ../../../../etc/passwd", "/root/repos/office-chess"
        )

        self.assertEqual(locations, [])

    def test_each_file_change_becomes_its_own_region(self) -> None:
        updates = radiography.codex_tool_updates(
            "item.completed",
            {
                "id": "patch",
                "type": "file_change",
                "status": "completed",
                "changes": [
                    {"path": "App/A.swift", "kind": "update"},
                    {"path": "/root/repos/p/Old.swift", "kind": "delete"},
                ],
            },
            "/root/repos/p",
        )

        self.assertEqual([entry["toolCallId"] for entry in updates], ["patch:0", "patch:1"])
        self.assertEqual([entry["kind"] for entry in updates], ["edit", "delete"])
        self.assertEqual(
            updates[0]["locations"], [{"path": "/root/repos/p/App/A.swift"}]
        )
        self.assertTrue(all(entry["status"] == "completed" for entry in updates))


if __name__ == "__main__":
    unittest.main()
