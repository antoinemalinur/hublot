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

    def test_usage_samples_interleave_chronologically_with_the_thread(self) -> None:
        continuity.record(self.cwd, self.session_id, "user", "Où en est le contexte ?")
        continuity.record_usage(self.cwd, self.session_id, {
            "sessionUpdate": "usage_update", "used": 4_200, "size": 200_000,
            "ts": "2026-08-08T10:00:00.000Z",
        })
        continuity.record(self.cwd, self.session_id, "assistant", "À 2 %", "claude")
        continuity.record_usage(self.cwd, self.session_id, {
            "sessionUpdate": "usage_update", "used": 8_800, "size": 200_000,
            "ts": "2026-08-08T10:02:00.000Z",
        })

        entries = continuity.replay(self.cwd, self.session_id)

        # L'ordre du fichier *est* la chronologie : c'est ce qui évite d'avoir
        # une règle de tri à tenir au rejeu.
        self.assertEqual(
            [entry["role"] for entry in entries],
            ["user", "usage", "assistant", "usage"],
        )
        self.assertEqual(entries[1]["update"]["used"], 4_200)
        self.assertEqual(entries[1]["update"]["ts"], "2026-08-08T10:00:00.000Z")
        self.assertEqual(entries[3]["update"]["used"], 8_800)

    def test_usage_keeps_a_measurement_it_cannot_interpret(self) -> None:
        # `send_status` envoie réellement `0/0` quand Codex ne mesure rien. Le
        # journal la garde : c'est à la vue de décider ce qu'elle sait tracer,
        # pas à l'enregistreur de trier.
        continuity.record(self.cwd, self.session_id, "user", "Une demande")
        continuity.record_usage(self.cwd, self.session_id, {
            "sessionUpdate": "usage_update", "used": 0, "size": 0,
        })

        entries = continuity.replay(self.cwd, self.session_id)

        self.assertEqual([entry["role"] for entry in entries], ["user", "usage"])
        self.assertEqual(entries[1]["update"]["used"], 0)

    def test_usage_ignores_anything_that_is_not_a_measurement(self) -> None:
        continuity.record_usage(self.cwd, self.session_id, {
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "une réponse"},
        })
        continuity.record_usage(self.cwd, self.session_id, {
            "sessionUpdate": "tool_call", "toolCallId": "read-1",
        })

        self.assertEqual(continuity.replay(self.cwd, self.session_id), [])

    def test_measurements_never_enter_an_engine_handoff(self) -> None:
        # Une passation remet au moteur entrant ce qu'il a manqué de la
        # *conversation*. Des chiffres de contexte n'y ont pas leur place — ils
        # décrivent la machine, pas le sujet.
        continuity.record(self.cwd, self.session_id, "user", "Première demande")
        continuity.acknowledge(self.cwd, self.session_id, "codex")
        continuity.record_usage(self.cwd, self.session_id, {
            "sessionUpdate": "usage_update", "used": 4_200, "size": 200_000,
        })
        continuity.record(self.cwd, self.session_id, "assistant", "Une réponse", "claude")

        missing = continuity.missing(self.cwd, self.session_id, "codex")

        self.assertEqual([entry["role"] for entry in missing], ["assistant"])

    def test_a_session_of_measurements_alone_is_never_listed(self) -> None:
        # Une session neuve reçoit une mesure avant tout échange. Elle ne doit
        # pas pour autant apparaître dans la liste : il n'y a rien à rouvrir.
        continuity.record_usage(self.cwd, self.session_id, {
            "sessionUpdate": "usage_update", "used": 0, "size": 200_000,
        })

        self.assertEqual(continuity.list_sessions(self.cwd), [])

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
