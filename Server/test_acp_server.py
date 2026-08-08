from __future__ import annotations

import os
import sys
import threading
import time
import types
import unittest
from unittest import mock


# Le dépôt iOS ne contient pas les modules d'exploitation du VPS. Le relais ne
# les exerce pas dans ces tests : de petits substituts suffisent pour importer
# ses classes et tester le contrat de streaming lui-même.
os.environ.setdefault("ACP_TOKEN", "test-token")
sys.modules.setdefault("bot", types.SimpleNamespace(
    REPOS_BASE="/tmp/repos",
    CODEX_MODEL="gpt-test",
    CODEX_EFFORTS=("low",),
    DEFAULT_CODEX_EFFORT="low",
    CODEX_LAST_MESSAGE="/tmp/codex-last-message",
    CODEX_EFFORT_FILE="/tmp/codex-effort",
    state_lock=threading.RLock(),
    state={"codex_effort": "low"},
    save_effort=lambda _path, _effort: None,
    log=lambda _message: None,
))
sys.modules.setdefault("handoff", types.SimpleNamespace())
sys.modules.setdefault("sessions", types.SimpleNamespace())

import acp_server  # noqa: E402


class RecordingSession:
    id = "session-test"
    cwd = "/tmp/repos/projet"

    def __init__(self) -> None:
        self.statuses: list[tuple[int, int]] = []

    async def send_status(self, used: int = 0, size: int = 0) -> None:
        self.statuses.append((used, size))


class ContextStreamingTests(unittest.IsolatedAsyncioTestCase):
    async def test_message_delta_completes_the_live_context(self) -> None:
        session = RecordingSession()
        turn = acp_server.PromptTurn(session, "question")

        await turn._translate_stream({
            "type": "message_start",
            "message": {"usage": {
                "input_tokens": 100,
                "cache_creation_input_tokens": 400,
                "cache_read_input_tokens": 5_000,
                "output_tokens": 1,
            }},
        })
        self.assertEqual(turn.context_used, 5_501)

        await turn._translate_stream({
            "type": "message_delta", "usage": {"output_tokens": 500},
        })
        self.assertEqual(turn.context_used, 6_000)

        await turn._push_context(force=True)
        self.assertEqual(session.statuses[-1], (6_000, 0))

    async def test_context_is_republished_after_eight_seconds_without_a_new_event(self) -> None:
        session = RecordingSession()
        turn = acp_server.PromptTurn(session, "question")
        turn.context_used = 42
        turn.context_pushed_at = time.monotonic() - turn.CONTEXT_INTERVAL

        await turn._push_context()

        self.assertEqual(session.statuses, [(42, 0)])


class BrokenConnection:
    async def notify(self, _method: str, _params: dict) -> None:
        raise ConnectionError("socket fermé")


class ConnectionSurvivalTests(unittest.IsolatedAsyncioTestCase):
    async def test_a_dead_socket_does_not_abort_the_turn_update(self) -> None:
        session = acp_server.Session(BrokenConnection(), "session-test", "/tmp/repos/projet")
        recorded: list[dict] = []

        with mock.patch.object(
            acp_server.continuity, "record_tool",
            side_effect=lambda _cwd, _session, payload: recorded.append(payload),
        ):
            await session.update({"sessionUpdate": "agent_message_chunk"})

        self.assertEqual(recorded, [{"sessionUpdate": "agent_message_chunk"}])
        self.assertTrue(session._notification_failed)


if __name__ == "__main__":
    unittest.main()
