from __future__ import annotations

import json
import unittest
from pathlib import Path


FIXTURES = Path(__file__).parents[1] / "IAClient-UITests" / "Fixtures"


class SharedProtocolFixtureTests(unittest.TestCase):
    """Les memes captures sont des contrats pour Python et pour Swift."""

    def test_every_recorded_jsonl_frame_is_valid_json_rpc(self) -> None:
        for path in sorted(FIXTURES.glob("*.jsonl")):
            with self.subTest(path=path.name):
                lines = path.read_text(encoding="utf-8").splitlines()
                self.assertGreater(len(lines), 10)
                for number, line in enumerate(lines, 1):
                    with self.subTest(line=number):
                        frame = json.loads(line)
                        self.assertEqual(frame.get("jsonrpc"), "2.0")
                        self.assertTrue(
                            "method" in frame or "result" in frame or "error" in frame
                        )

    def test_session_updates_keep_the_discriminator_swift_decodes(self) -> None:
        updates = []
        for path in FIXTURES.glob("*.jsonl"):
            for line in path.read_text(encoding="utf-8").splitlines():
                frame = json.loads(line)
                if frame.get("method") != "session/update":
                    continue
                update = frame.get("params", {}).get("update", {})
                updates.append(update)
                self.assertIsInstance(update.get("sessionUpdate"), str)

        self.assertGreater(len(updates), 20)
        kinds = {update["sessionUpdate"] for update in updates}
        self.assertIn("agent_message_chunk", kinds)
        self.assertIn("tool_call", kinds)
        self.assertIn("usage_update", kinds)


if __name__ == "__main__":
    unittest.main()
