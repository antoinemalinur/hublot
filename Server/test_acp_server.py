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
from typing import Any
from unittest import mock

# Les charger avant `acp_server` est essentiel : en production celui-ci place
# `/opt/tg-claude` en tête du chemin pour trouver `bot.py`. Sur le VPS de test,
# cela ferait sinon importer les copies déployées (potentiellement plus
# anciennes) au lieu des fichiers de cette branche.
import continuity  # noqa: F401, E402
import radiography  # noqa: F401, E402
import sessions  # noqa: F401, E402
import usage  # noqa: F401, E402


# Le dépôt ne contient pas `bot.py` ni le constructeur de passation du VPS.
# Les modules de sessions, continuité et radiographie sont en revanche bien
# présents ici : les remplacer polluerait `sys.modules` et ferait tester leurs
# propres suites contre une coquille vide lors d'une découverte globale.
os.environ.setdefault("ACP_TOKEN", "test-token")
# `acp_server` donne normalement priorité à `/opt/tg-claude`. En test, cela
# chargeait les anciennes copies de `continuity.py` et `sessions.py` installées
# sur la machine, puis les laissait dans `sys.modules` pour toute la découverte.
# La suite dépendait donc de son ordre et de l'état du VPS local.
os.environ.setdefault("TG_CLAUDE_BASE", str(Path(__file__).resolve().parent))
sys.modules.setdefault("bot", types.SimpleNamespace(
    REPOS_BASE="/tmp/repos",
    CODEX_MODEL="gpt-test",
    CODEX_EFFORTS=("low",),
    DEFAULT_CODEX_EFFORT="low",
    CODEX_LAST_MESSAGE="/tmp/codex-last-message",
    CODEX_EFFORT_FILE="/tmp/codex-effort",
    state_lock=threading.RLock(),
    # `send_status` lit l'état comme le ferait le relais : le moteur épinglé,
    # le modèle Claude et son effort. Une doublure amputée faisait passer une
    # `KeyError` pour un comportement du serveur.
    state={
        "codex_effort": "low", "manual_engine": "claude",
        "model": "opus", "claude_effort": "high",
    },
    MODELS={"opus": ("claude-opus-5", "Opus", 200_000)},
    CLAUDE_EFFORTS=("high",),
    CLAUDE_EFFORT_FILE="/tmp/claude-effort",
    engine_for_next_task=lambda: "claude",
    save_effort=lambda _path, _effort: None,
    log=lambda _message: None,
    # Les trois verdicts que le relais rend sur une sortie de moteur. Les
    # doublures répondent « non » : chaque test arme celui qu'il exerce.
    is_stale_session=lambda _error: False,
    is_quota_error=lambda _error: False,
    mark_claude_unavailable=lambda _reason, **_kwargs: None,
))
sys.modules.setdefault("handoff", types.SimpleNamespace())

import acp_server  # noqa: E402


class RecordingSession:
    id = "session-test"
    cwd = "/tmp/repos/projet"

    def __init__(self) -> None:
        self.statuses: list[tuple[int, int]] = []
        # `persist` doit être retenu, pas jeté : c'est lui qui décide si la
        # mesure d'un tour entre au fil. Sans lui ici, retirer le `persist=True`
        # de `_push_context` ne faisait broncher aucun test.
        self.persisted: list[bool] = []

    async def send_status(self, used: int = 0, size: int = 0,
                          *, persist: bool = False) -> None:
        self.statuses.append((used, size))
        self.persisted.append(persist)


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
        # Une mesure prise pendant le tour n'existe nulle part ailleurs : elle
        # doit entrer dans le fil, sinon la marée de contexte est vide à la
        # réouverture.
        self.assertTrue(session.persisted[-1])

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


class SilentConnection:
    """Une liaison qui accepte tout sans rien faire.

    Ce qui compte ici est ce que le serveur **écrit sur disque**, pas ce qu'il
    envoie au téléphone.
    """

    def __init__(self) -> None:
        self.sessions: dict[str, Any] = {}

    async def notify(self, _method: str, _params: dict) -> None:
        return None


class OpeningAConversationTests(unittest.IsolatedAsyncioTestCase):
    """Ouvrir une conversation ne doit pas compter comme y avoir écrit.

    Le cas signalé depuis l'iPhone le 10 août 2026 : toucher une discussion
    sans rien taper, et la voir aussitôt datée « il y a deux secondes ».

    Le fil de ce test n'a **aucun horodatage par message** : c'est l'état de
    toutes les conversations déjà sur le VPS, écrites avant que `record` ne
    date chaque ligne. Pour elles, la liste retombe sur le `mtime` du journal —
    et `send_status()` le réécrivait à chaque ouverture.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_state = acp_server.continuity.STATE
        acp_server.continuity.STATE = Path(self.temporary.name)
        self.cwd = "/tmp/repos/projet"
        self.session_id = "fil-sans-horodatage"

        transcript, _ = acp_server.continuity._paths(self.cwd, self.session_id)
        transcript.parent.mkdir(parents=True, exist_ok=True)
        with transcript.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps(
                {"role": "user", "engine": "claude", "text": "Ma demande d'hier"},
                ensure_ascii=False,
            ) + "\n")
        # Une conversation d'il y a une heure, pas d'il y a deux secondes.
        old = time.time() - 3_600
        os.utime(transcript, (old, old))
        self.transcript = transcript

    def tearDown(self) -> None:
        acp_server.continuity.STATE = self.previous_state
        self.temporary.cleanup()

    def _listed_date(self) -> str:
        listed = acp_server.continuity.list_sessions(self.cwd)
        return str(listed[0]["updatedAt"])

    def _offline(self):
        """Ni `claude -p /usage`, ni le journal du moteur : ni l'un ni l'autre
        n'existe sur la machine de test, et aucun des deux n'est le sujet."""
        return (
            mock.patch.object(acp_server, "quota_snapshot", return_value={}),
            mock.patch.object(
                acp_server.Session, "measure_context", return_value=(0, 200_000)
            ),
        )

    async def test_opening_a_conversation_does_not_redate_it(self) -> None:
        # La date attendue est celle du fichier, calculée ici : comparer le fil
        # à lui-même laisserait passer un repli devenu constant — ou devenu
        # « maintenant », qui est justement le bug.
        expected = acp_server.continuity._iso(self.transcript.stat().st_mtime)
        self.assertEqual(self._listed_date(), expected)

        quota, measure = self._offline()
        with quota, measure:
            # Le geste exact de l'utilisateur : ouvrir, sans rien écrire. C'est
            # ce que `_load_session` fait en dernier.
            session = acp_server.Session(SilentConnection(), self.session_id, self.cwd)
            await session.send_status()

        self.assertEqual(self._listed_date(), expected)

    async def test_a_turns_own_measurement_still_enters_the_thread(self) -> None:
        """Le garde-fou ne doit pas emporter la marée de contexte avec lui.

        Une mesure prise pendant un tour n'existe nulle part ailleurs : sans
        elle, rouvrir un fil afficherait une jauge vide jusqu'au tour suivant.
        """
        session = acp_server.Session(SilentConnection(), self.session_id, self.cwd)

        quota, measure = self._offline()
        with quota, measure:
            await session.send_status(used=17_050, size=200_000, persist=True)

        measured = [
            entry for entry in acp_server.continuity.replay(self.cwd, self.session_id)
            if entry.get("role") == "usage"
        ]
        self.assertEqual(len(measured), 1)
        self.assertEqual(measured[0]["update"]["used"], 17_050)


class ConcurrentConversationCatalogTests(unittest.IsolatedAsyncioTestCase):
    """Une seconde demande doit exister avant son premier travail lent.

    Le cas vu dans l'app : quitter un premier fil encore actif, en ouvrir un
    second, envoyer puis revenir aussitôt à la liste. Le rangement des images
    passait par un thread avant l'inscription du second tour. Pendant cette
    fenêtre, `session/list` et `hublot/running` ne voyaient que le premier fil,
    et la liste ne se rechargeait plus ensuite.
    """

    async def asyncSetUp(self) -> None:
        acp_server.ACTIVE_TURNS.clear()

    async def asyncTearDown(self) -> None:
        acp_server.ACTIVE_TURNS.clear()

    async def test_second_prompt_is_listed_while_its_attachment_is_stored(self) -> None:
        cwd = "/tmp/repos/projet"
        first_session = types.SimpleNamespace(id="premier", cwd=cwd)
        first_turn = acp_server.PromptTurn(first_session, "Première demande")
        acp_server.ACTIVE_TURNS[first_session.id] = first_turn

        connection = acp_server.Connection(types.SimpleNamespace())
        second = acp_server.Session(connection, "second", cwd)
        connection.sessions[second.id] = second

        storage_started = asyncio.Event()
        release_storage = asyncio.Event()

        async def blocked_storage(_function, *_args, **_kwargs):
            storage_started.set()
            await release_storage.wait()
            return ["/tmp/repos/projet/.hublot/images/deuxieme.jpg"]

        async def completed_turn(_turn) -> str:
            return "end_turn"

        blocks = [
            {"type": "text", "text": "Deuxième demande"},
            {"type": "image", "data": "aW1hZ2U=", "mimeType": "image/jpeg"},
        ]
        with mock.patch("asyncio.to_thread", side_effect=blocked_storage), \
             mock.patch.object(acp_server.PromptTurn, "run", completed_turn), \
             mock.patch.object(acp_server.store, "list_sessions", create=True, return_value=[{
                 "sessionId": "premier", "cwd": cwd, "title": "Première demande",
                 "updatedAt": "2026-08-10T19:00:00.000Z", "exchanges": 1,
             }]), \
             mock.patch.object(acp_server.continuity, "list_sessions", return_value=[]):
            prompt = asyncio.create_task(connection._prompt({
                "sessionId": second.id, "prompt": blocks,
            }))
            await asyncio.wait_for(storage_started.wait(), timeout=1)

            self.assertEqual(
                {turn["sessionId"] for turn in acp_server.running_turns()},
                {"premier", "second"},
            )
            self.assertEqual(
                {session["sessionId"] for session in acp_server.session_catalog(cwd)},
                {"premier", "second"},
            )

            release_storage.set()
            self.assertEqual((await prompt)["stopReason"], "end_turn")

    async def test_text_only_prompt_never_waits_for_attachment_storage(self) -> None:
        connection = acp_server.Connection(types.SimpleNamespace())
        session = acp_server.Session(connection, "texte-seul", "/tmp/repos/projet")
        connection.sessions[session.id] = session
        turn_started = asyncio.Event()
        release_turn = asyncio.Event()

        async def running_turn(_turn) -> str:
            turn_started.set()
            await release_turn.wait()
            return "end_turn"

        with mock.patch("asyncio.to_thread", new_callable=mock.AsyncMock) as storage, \
             mock.patch.object(acp_server.PromptTurn, "run", running_turn):
            prompt = asyncio.create_task(connection._prompt({
                "sessionId": session.id,
                "prompt": [{"type": "text", "text": "Demande sans image"}],
            }))
            await asyncio.wait_for(turn_started.wait(), timeout=1)

            storage.assert_not_awaited()
            self.assertIn(session.id, acp_server.ACTIVE_TURNS)
            release_turn.set()
            self.assertEqual((await prompt)["stopReason"], "end_turn")

    async def test_cancel_during_attachment_storage_never_starts_the_engine(self) -> None:
        connection = acp_server.Connection(types.SimpleNamespace())
        session = acp_server.Session(connection, "annule", "/tmp/repos/projet")
        connection.sessions[session.id] = session
        storage_started = asyncio.Event()
        release_storage = asyncio.Event()

        async def blocked_storage(_function, *_args, **_kwargs):
            storage_started.set()
            await release_storage.wait()
            return ["/tmp/repos/projet/.hublot/images/annule.jpg"]

        with mock.patch("asyncio.to_thread", side_effect=blocked_storage), \
             mock.patch.object(acp_server.PromptTurn, "run", new_callable=mock.AsyncMock) as run:
            prompt = asyncio.create_task(connection._prompt({
                "sessionId": session.id,
                "prompt": [{"type": "image", "data": "aW1hZ2U=",
                            "mimeType": "image/jpeg"}],
            }))
            await asyncio.wait_for(storage_started.wait(), timeout=1)

            await connection._cancel({"sessionId": session.id})
            release_storage.set()

            self.assertEqual((await prompt)["stopReason"], "cancelled")
            run.assert_not_awaited()


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


class CodexContextWindowTests(unittest.TestCase):
    def test_every_selectable_model_uses_its_documented_global_window(
        self,
    ) -> None:
        expected = {
            "gpt-5.6-sol": 1_050_000,
            "gpt-5.6-terra": 1_050_000,
            "gpt-5.6-luna": 1_050_000,
            "gpt-5.5": 1_050_000,
            "gpt-5.4": 1_050_000,
            "gpt-5.4-mini": 400_000,
        }
        # Valeur exacte du journal qui produisait la capture « 258 400 ».
        for model, window in expected.items():
            with self.subTest(model=model):
                self.assertEqual(
                    acp_server.codex_model_context_window(model, 258_400),
                    window,
                )

    def test_an_unknown_model_keeps_the_window_measured_by_codex(self) -> None:
        self.assertEqual(
            acp_server.codex_model_context_window("future-model", 384_000),
            384_000,
        )


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

    async def send_status(self, used: int = 0, size: int = 0,
                          *, persist: bool = False) -> None:
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


class CancelledTurnTests(unittest.IsolatedAsyncioTestCase):
    """Arrêter un tour est un geste réussi, pas un incident.

    Signalé depuis l'iPhone le 10 août 2026 : toucher le bouton d'arrêt
    inscrivait « ⚠️ error_during_execution » dans le fil, juste avant
    « interrompu ». Le moteur meurt sur son signal et Claude clôt le tour par un
    `result` en erreur — c'est la mécanique de l'arrêt, pas une panne à lire.
    """

    async def test_stopping_a_turn_writes_no_error_in_the_thread(self) -> None:
        session = AuthSession()
        turn = acp_server.PromptTurn(session, "question")
        await turn.cancel()

        reason = await turn._translate({
            "type": "result",
            "is_error": True,
            "subtype": "error_during_execution",
        })

        self.assertEqual(reason, "cancelled")
        self.assertEqual(session.texts, [])

    async def test_a_real_failure_is_still_reported(self) -> None:
        """Le garde-fou ne doit pas rendre le serveur muet sur les vraies pannes."""
        session = AuthSession()
        turn = acp_server.PromptTurn(session, "question")

        reason = await turn._translate({
            "type": "result",
            "is_error": True,
            "result": "Output blocked by content filtering policy",
        })

        self.assertEqual(reason, "refusal")
        self.assertTrue(
            any("content filtering" in text for text in session.texts), session.texts
        )


class ClaudeQuotaTests(unittest.TestCase):
    """Ce que `/usage` sait dire, et ce qu'il faut en tirer sans se tromper.

    Les deux exemples viennent de vrais relevés du 8 août 2026 — un Mac en CLI
    2.1.225 et le VPS, une version plus ancienne. Ils n'écrivent pas la date de
    la même façon, ce qui est tout le problème de cette lecture : le CLI n'offre
    aucune sortie structurée.
    """

    MAC = (
        "You are currently using your subscription to power your Claude Code usage\n"
        "\n"
        "Current session: 42% used · resets Aug 8 at 9:10pm (America/Toronto)\n"
        "Current week (all models): 91% used · resets Aug 10 at 12:59pm (America/Toronto)\n"
    )
    VPS = (
        "You are currently using your subscription to power your Claude Code usage\n"
        "\n"
        "Current session: 52% used · resets Aug 8, 9:10pm (America/Toronto)\n"
        "Current week (all models): 92% used · resets Aug 10, 1pm (America/Toronto)\n"
    )

    def test_both_wordings_give_the_same_two_windows(self) -> None:
        for label, text, session in (("mac", self.MAC, 42), ("vps", self.VPS, 52)):
            with self.subTest(label):
                windows = acp_server.parse_claude_usage(text)
                self.assertEqual(windows["five_hour"]["percent"], session)
                self.assertIsNotNone(windows["five_hour"]["resetsAt"])
                self.assertIn("seven_day", windows)

    def test_the_session_window_is_the_five_hour_one(self) -> None:
        # « Current session » est la fenêtre 5 h, « Current week » l'hebdo. Les
        # intervertir afficherait la semaine sous l'étiquette « 5H ».
        windows = acp_server.parse_claude_usage(self.VPS)
        self.assertEqual(windows["five_hour"]["percent"], 52)
        self.assertEqual(windows["seven_day"]["percent"], 92)

    def test_an_hour_without_minutes_is_read(self) -> None:
        # « resets Aug 10, 1pm » — le CLI omet les minutes à l'heure pile.
        moment = acp_server.parse_usage_moment("Aug 10, 1pm (America/Toronto)")
        self.assertIsNotNone(moment)
        self.assertIn("13:00", str(moment))

    def test_an_unreadable_reset_keeps_the_percentage(self) -> None:
        # Une jauge sans compte à rebours vaut mieux que pas de jauge.
        windows = acp_server.parse_claude_usage("Current session: 7% used · resets bientôt\n")
        self.assertEqual(windows["five_hour"]["percent"], 7)
        self.assertIsNone(windows["five_hour"]["resetsAt"])

    def test_prose_without_any_window_yields_nothing(self) -> None:
        self.assertEqual(acp_server.parse_claude_usage("Total cost: $0.0000"), {})

    def test_the_environment_token_is_dropped_for_this_call_only(self) -> None:
        # Le jeton de `setup-token` fait tourner les moteurs mais ferme
        # `/usage`, et il l'emporte sur la session dès qu'il est présent.
        seen: dict[str, Any] = {}

        def fake_run(_args, **kwargs):
            seen.update(kwargs["env"])
            return types.SimpleNamespace(
                returncode=0, stdout=json.dumps({"result": self.VPS}), stderr="",
            )

        with mock.patch.dict(os.environ, {"CLAUDE_CODE_OAUTH_TOKEN": "jeton"}), \
             mock.patch.object(acp_server.subprocess, "run", side_effect=fake_run):
            windows = acp_server.claude_quota_windows()
            # L'environnement du serveur, lui, garde son jeton : les tours en
            # dépendent, et c'est ce qui fait qu'une session morte ne coûte que
            # la jauge.
            self.assertEqual(os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"), "jeton")

        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", seen)
        self.assertEqual(windows["five_hour"]["percent"], 52)


class CodexQuotaTests(unittest.TestCase):
    """La réponse réelle de `account/rateLimits/read`, relevée le 8 août 2026."""

    SNAPSHOT = {
        "limitId": "codex",
        "primary": {"usedPercent": 0, "windowDurationMins": 10080,
                    "resetsAt": 1786830360},
        "secondary": None,
        "planType": "plus",
    }

    def test_the_weekly_window_is_ranged_by_its_announced_duration(self) -> None:
        # Ce compte n'expose que l'hebdomadaire, en `primary`. La ranger d'office
        # en « 5 h » affichait une semaine sous une étiquette de cinq heures.
        with mock.patch.object(acp_server, "codex_rate_limits", return_value=self.SNAPSHOT):
            windows = acp_server.codex_quota_windows()
        self.assertEqual(list(windows), ["seven_day"])
        self.assertEqual(windows["seven_day"]["percent"], 0)
        self.assertTrue(str(windows["seven_day"]["resetsAt"]).startswith("2026-"))

    def test_a_short_window_would_land_on_the_five_hour_slot(self) -> None:
        snapshot = dict(self.SNAPSHOT)
        snapshot["secondary"] = {"usedPercent": 12.4, "windowDurationMins": 300,
                                 "resetsAt": 1786830360}
        with mock.patch.object(acp_server, "codex_rate_limits", return_value=snapshot):
            windows = acp_server.codex_quota_windows()
        self.assertEqual(windows["five_hour"]["percent"], 12)
        self.assertEqual(windows["seven_day"]["percent"], 0)

    def test_an_empty_snapshot_never_raises(self) -> None:
        with mock.patch.object(acp_server, "codex_rate_limits", return_value={}):
            self.assertEqual(acp_server.codex_quota_windows(), {})


class QuotaCacheTests(unittest.TestCase):
    """`send_status` passe ici toutes les huit secondes pendant un tour."""

    def test_a_second_reader_within_the_window_does_not_relaunch_anything(self) -> None:
        calls = []

        def fetch() -> dict[str, Any]:
            calls.append(1)
            return {"five_hour": {"percent": 3, "resetsAt": None}}

        cache = acp_server.QuotaCache(ttl=900.0, retry=120.0)
        self.assertEqual(cache.read(fetch)["five_hour"]["percent"], 3)
        cache.read(fetch)
        cache.read(fetch)
        self.assertEqual(len(calls), 1, "une seule lecture par fenêtre")

    def test_a_failure_keeps_the_last_measurement_and_backs_off(self) -> None:
        # Sans ce garde-fou, un moteur mal authentifié faisait naître un
        # processus toutes les huit secondes, et la jauge clignotait.
        cache = acp_server.QuotaCache(ttl=900.0, retry=120.0)
        cache.read(lambda: {"five_hour": {"percent": 55, "resetsAt": None}})
        cache.next_read = 0.0

        boom = []

        def failing() -> dict[str, Any]:
            boom.append(1)
            raise RuntimeError("/usage a rendu 1")

        self.assertEqual(cache.read(failing)["five_hour"]["percent"], 55)
        self.assertEqual(cache.read(failing)["five_hour"]["percent"], 55)
        self.assertEqual(len(boom), 1, "on ne réessaie pas à chaque mesure")


class ActiveTurnConfigurationTests(unittest.IsolatedAsyncioTestCase):
    async def test_engine_cannot_be_changed_under_a_running_turn(self) -> None:
        connection = acp_server.Connection(types.SimpleNamespace())
        session = types.SimpleNamespace(turn=object())
        connection.sessions["session-test"] = session

        with self.assertRaisesRegex(ValueError, "tour en cours"):
            await connection._set_config_option({
                "sessionId": "session-test", "configId": "engine",
                "type": "select", "value": "claude",
            })

    async def test_status_is_republished_after_the_running_engine_detaches(self) -> None:
        connection = acp_server.Connection(types.SimpleNamespace())

        class Session:
            id = "session-test"
            cwd = "/tmp/repos/projet"
            turn = None

            def __init__(self) -> None:
                self.statuses = 0

            async def send_status(self, used: int = 0, size: int = 0,
                                  *, persist: bool = False) -> None:
                self.statuses += 1

        class Turn:
            def __init__(self, session, _text) -> None:
                self.session = session
                self.finished = asyncio.Event()
                # Le rangement des pièces jointes a déplacé le départ du moteur
                # dans le `try` : le tour y est consulté avant de courir.
                self.cancelled = False
                self.text = _text

            async def run(self) -> str:
                return "end_turn"

            def detach(self) -> None:
                self.session.turn = None

        session = Session()
        connection.sessions[session.id] = session
        with mock.patch.object(acp_server, "PromptTurn", Turn):
            result = await connection._prompt({
                "sessionId": session.id,
                "prompt": [{"type": "text", "text": "question"}],
            })

        self.assertEqual(result, {"stopReason": "end_turn"})
        self.assertEqual(session.statuses, 1)
        self.assertIsNone(session.turn)

    async def test_a_failed_status_republication_never_hides_the_turn_verdict(
        self,
    ) -> None:
        """Le tour a répondu ; la jauge est un confort, pas son verdict.

        La republication vit dans un `finally` : sans garde-fou, une lecture de
        quota en panne y lèverait après coup et le client recevrait une erreur
        JSON-RPC pour une réponse qu'il a pourtant reçue en entier.
        """
        connection = acp_server.Connection(types.SimpleNamespace())

        class Session:
            id = "session-test"
            cwd = "/tmp/repos/projet"
            turn = None

            async def send_status(self, used: int = 0, size: int = 0,
                                  *, persist: bool = False) -> None:
                raise RuntimeError("quota illisible")

        class Turn:
            def __init__(self, session, text) -> None:
                self.session = session
                self.finished = asyncio.Event()
                self.cancelled = False
                self.text = text

            async def run(self) -> str:
                return "end_turn"

            def detach(self) -> None:
                self.session.turn = None

        session = Session()
        connection.sessions[session.id] = session
        with mock.patch.object(acp_server, "PromptTurn", Turn):
            result = await connection._prompt({
                "sessionId": session.id,
                "prompt": [{"type": "text", "text": "question"}],
            })

        self.assertEqual(result, {"stopReason": "end_turn"})
        # Et le tour est bien sorti du registre : une panne de statut ne doit
        # pas non plus laisser la conversation « occupée » pour toujours.
        self.assertNotIn(session.id, acp_server.ACTIVE_TURNS)
        self.assertIsNone(session.turn)


if __name__ == "__main__":
    unittest.main()
