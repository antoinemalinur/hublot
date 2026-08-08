from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
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
    # Les trois verdicts que le relais rend sur une sortie de moteur. Les
    # doublures répondent « non » : chaque test arme celui qu'il exerce.
    is_stale_session=lambda _error: False,
    is_quota_error=lambda _error: False,
    mark_claude_unavailable=lambda _reason, **_kwargs: None,
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


class ContextPersistenceTests(unittest.IsolatedAsyncioTestCase):
    """Ce qui donne son passé à la marée de contexte.

    Sans ces deux garanties, rouvrir une conversation affichait une jauge vide
    jusqu'au message suivant — alors que la radiographie, elle, retrouvait tout
    son historique.
    """

    async def test_a_context_measurement_is_written_to_the_thread(self) -> None:
        session = acp_server.Session(BrokenConnection(), "session-test", "/tmp/repos/projet")
        recorded: list[dict] = []

        with mock.patch.object(
            acp_server.continuity, "record_usage",
            side_effect=lambda _cwd, _session, payload: recorded.append(payload),
        ):
            await session.update({
                "sessionUpdate": "usage_update", "used": 84_000, "size": 200_000,
            })

        self.assertEqual(recorded[0]["used"], 84_000)

    async def test_a_replayed_measurement_is_not_written_back(self) -> None:
        # `_load_session` rejoue le journal avec `persist=False`. Sans ce
        # garde-fou, chaque réouverture doublerait les mesures du fil et la
        # marée montrerait des paliers qui n'ont jamais existé.
        session = acp_server.Session(BrokenConnection(), "session-test", "/tmp/repos/projet")
        recorded: list[dict] = []

        with mock.patch.object(
            acp_server.continuity, "record_usage",
            side_effect=lambda _cwd, _session, payload: recorded.append(payload),
        ):
            await session.update(
                {"sessionUpdate": "usage_update", "used": 1, "size": 2}, persist=False
            )

        self.assertEqual(recorded, [])


class AuthSession:
    """Ce que la conversation reçoit vraiment : du texte et des bascules."""

    id = "session-test"
    cwd = "/tmp/repos/projet"

    def __init__(self) -> None:
        self.texts: list[str] = []
        self.engines: list[tuple[str, str]] = []

    async def send_text(self, text: str, _message_id: str) -> None:
        self.texts.append(text)

    async def notify_engine(self, engine: str, reason: str) -> None:
        self.engines.append((engine, reason))

    async def send_status(self, used: int = 0, size: int = 0) -> None:
        pass

    async def update(self, _payload: dict, persist: bool = True) -> None:
        pass


class FakeProcess:
    """Un `claude -p` déjà terminé : ses lignes, son stderr, son code."""

    def __init__(self, lines: list[bytes], stderr: bytes = b"",
                 returncode: int = 1) -> None:
        self.stdout = asyncio.StreamReader()
        for line in lines:
            self.stdout.feed_data(line)
        self.stdout.feed_eof()
        self.stderr = asyncio.StreamReader()
        self.stderr.feed_data(stderr)
        self.stderr.feed_eof()
        self.returncode = returncode

    async def wait(self) -> int:
        return self.returncode


# La ligne exacte relevée sur le VPS le jour de la panne. Tout est dans le
# piège qu'elle tend : `subtype` dit « success », stderr est vide, et l'échec
# tient dans un `result` qui ressemble à n'importe quelle fin de tour.
OAUTH_FAILURE = (
    "Failed to authenticate: OAuth session expired and could not be refreshed"
)
OAUTH_RESULT_LINE = json.dumps({
    "type": "result", "subtype": "success", "is_error": True,
    "result": OAUTH_FAILURE, "stop_reason": "stop_sequence",
}).encode() + b"\n"


class ClaudeAuthenticationTests(unittest.IsolatedAsyncioTestCase):
    """La panne d'identifiants doit se dire, et ne pas bloquer la conversation.

    Vu à l'écran : « ⚠️ Failed to authenticate: OAuth session expired and could
    not be refreshed », en anglais, sous l'étiquette « refusé par le moteur ».
    Le moteur n'avait rien refusé — il n'avait jamais été joint — et chaque
    envoi suivant se cognait au même mur pendant que Codex, lui, répondait.
    """

    def test_the_failure_line_is_told_apart_from_a_real_refusal(self) -> None:
        self.assertTrue(acp_server.is_auth_error(OAUTH_FAILURE))
        self.assertTrue(acp_server.is_auth_error("Invalid API key · Please run /login"))
        # Confondre les deux couperait Claude pour une simple phrase filtrée.
        self.assertFalse(acp_server.is_auth_error(
            "Output blocked by content filtering policy"
        ))
        self.assertFalse(acp_server.is_auth_error(""))

    async def test_an_expired_session_hands_over_instead_of_looking_like_a_refusal(
        self,
    ) -> None:
        session = AuthSession()
        turn = acp_server.PromptTurn(session, "question")
        marks: list[str] = []

        with mock.patch.object(
            acp_server.bot, "mark_claude_unavailable",
            side_effect=lambda reason, **_kwargs: marks.append(reason),
        ), mock.patch(
            "asyncio.create_subprocess_exec",
            mock.AsyncMock(return_value=FakeProcess([OAUTH_RESULT_LINE])),
        ):
            reason = await turn._stream(["claude"])

        self.assertEqual(reason, "refusal")
        self.assertEqual(len(marks), 1, "Claude doit être marqué indisponible")
        self.assertEqual(session.engines, [("codex", "Claude n'est plus authentifié")])
        message = "".join(session.texts)
        self.assertIn("authentifié", message)
        self.assertIn("setup-token", message)
        # L'anglais du CLI était tout ce que la conversation montrait.
        self.assertNotIn("Failed to authenticate", message)

    async def test_a_cli_that_dies_before_any_json_is_treated_the_same(self) -> None:
        # Même panne, autre canal : le CLI peut aussi échouer avant d'avoir émis
        # la moindre ligne, et l'erreur arrive alors par stderr.
        session = AuthSession()
        turn = acp_server.PromptTurn(session, "question")

        with mock.patch.object(
            acp_server.bot, "mark_claude_unavailable", side_effect=lambda *_a, **_k: None,
        ), mock.patch(
            "asyncio.create_subprocess_exec",
            mock.AsyncMock(return_value=FakeProcess([], OAUTH_FAILURE.encode())),
        ):
            reason = await turn._stream(["claude"])

        self.assertEqual(reason, "refusal")
        self.assertEqual(session.engines, [("codex", "Claude n'est plus authentifié")])
        self.assertNotIn("Failed to authenticate", "".join(session.texts))

    def test_the_startup_line_names_the_credential_that_will_serve(self) -> None:
        # C'est cette ligne qui manquait : rien ne disait que le service avait
        # perdu son jeton et retombait sur le trousseau.
        with mock.patch.dict(os.environ, {"CLAUDE_CODE_OAUTH_TOKEN": "jeton"}):
            self.assertEqual(acp_server.claude_auth_source(), "jeton d'environnement")
        with tempfile.TemporaryDirectory() as empty:
            with mock.patch.dict(os.environ, {
                "CLAUDE_CODE_OAUTH_TOKEN": "", "CLAUDE_CONFIG_DIR": empty,
            }):
                self.assertIn("aucune", acp_server.claude_auth_source())
            with mock.patch.dict(os.environ, {
                "CLAUDE_CODE_OAUTH_TOKEN": "", "CLAUDE_CONFIG_DIR": empty,
            }):
                (Path(empty) / ".credentials.json").write_text("{}", encoding="utf-8")
                self.assertIn("OAuth", acp_server.claude_auth_source())


if __name__ == "__main__":
    unittest.main()
