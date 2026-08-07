from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import continuity


class ContinuityRadiographyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_state = continuity.STATE
        continuity.STATE = Path(self.temporary.name)
        self.cwd = "/root/repos/office-chess"
        self.session_id = "visual-session"

    def tearDown(self) -> None:
        continuity.STATE = self.previous_state
        self.temporary.cleanup()

    def test_replay_preserves_user_tool_assistant_order(self) -> None:
        continuity.record(self.cwd, self.session_id, "user", "Inspecte le projet")
        continuity.record_tool(self.cwd, self.session_id, {
            "sessionUpdate": "tool_call",
            "toolCallId": "read-1",
            "title": "database.py",
            "kind": "read",
            "status": "in_progress",
            "locations": [{"path": "/root/repos/office-chess/database.py"}],
            "rawInput": {
                "file_path": "/root/repos/office-chess/database.py",
                "content": "secret and deliberately omitted",
            },
            "content": [{"type": "content", "content": {"text": "large output"}}],
        })
        continuity.record(self.cwd, self.session_id, "assistant", "Inspection terminée", "codex")

        entries = continuity.replay(self.cwd, self.session_id)

        self.assertEqual([entry["role"] for entry in entries], ["user", "tool", "assistant"])
        saved = entries[1]["update"]
        self.assertNotIn("content", saved)
        self.assertEqual(saved["rawInput"], {
            "file_path": "/root/repos/office-chess/database.py"
        })

    def test_tools_never_enter_an_engine_handoff(self) -> None:
        continuity.record(self.cwd, self.session_id, "user", "Première demande")
        continuity.acknowledge(self.cwd, self.session_id, "codex")
        continuity.record_tool(self.cwd, self.session_id, {
            "sessionUpdate": "tool_call", "toolCallId": "cmd-1",
            "title": "ls", "kind": "execute",
        })
        continuity.record(self.cwd, self.session_id, "assistant", "Une réponse", "claude")

        missing = continuity.missing(self.cwd, self.session_id, "codex")

        self.assertEqual([entry["role"] for entry in missing], ["assistant"])
        self.assertEqual(continuity.journal_events(missing)[0]["kind"], "response")

    def test_codex_only_session_is_listed_and_can_be_forgotten(self) -> None:
        continuity.record(self.cwd, self.session_id, "user", "  Une   question très visuelle  ")
        continuity.record(self.cwd, self.session_id, "assistant", "Oui", "codex")

        sessions = continuity.list_sessions(self.cwd)

        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["sessionId"], self.session_id)
        self.assertEqual(sessions[0]["title"], "Une question très visuelle")
        self.assertEqual(sessions[0]["exchanges"], 1)
        self.assertTrue(continuity.forget(self.cwd, self.session_id))
        self.assertEqual(continuity.replay(self.cwd, self.session_id), [])
        self.assertFalse(continuity.forget(self.cwd, self.session_id))


if __name__ == "__main__":
    unittest.main()
