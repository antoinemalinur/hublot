from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
import unittest.mock
from pathlib import Path

import sessions


class SessionActivityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_projects = sessions.CLAUDE_PROJECTS
        sessions.CLAUDE_PROJECTS = Path(self.temporary.name)
        self.repos = Path(self.temporary.name) / "repos"
        self.project = self.repos / "office-chess"
        self.project.mkdir(parents=True)
        self.cwd = str(self.project)

    def tearDown(self) -> None:
        sessions.CLAUDE_PROJECTS = self.previous_projects
        self.temporary.cleanup()

    def test_opening_a_conversation_does_not_become_its_last_activity(self) -> None:
        path = sessions.project_dir(self.cwd) / "session-1.jsonl"
        path.parent.mkdir(parents=True)
        events = [
            {
                "type": "user", "timestamp": "2026-08-10T14:00:00.000Z",
                "message": {"content": "Corrige le compteur"},
            },
            {
                "type": "assistant", "timestamp": "2026-08-10T14:01:00.000Z",
                "message": {"content": "C'est fait"},
            },
            # Claude peut écrire un événement utilisateur technique pendant
            # une reprise : il ne vient pas de la personne et ne compte pas.
            {
                "type": "user", "timestamp": "2026-08-10T19:12:00.000Z",
                "message": {"content": "<system-reminder>reprise</system-reminder>"},
            },
        ]
        path.write_text(
            "".join(json.dumps(event) + "\n" for event in events), encoding="utf-8"
        )
        os.utime(path, (1_786_389_180, 1_786_389_180))

        listed = sessions.list_sessions(self.cwd)

        self.assertEqual(len(listed), 1)
        self.assertEqual(listed[0]["updatedAt"], "2026-08-10T14:00:00.000Z")
        projects = sessions.list_projects(str(self.repos))
        self.assertEqual(projects[0]["updatedAt"], "2026-08-10T14:00:00.000Z")

    def test_last_real_prompt_wins_over_the_first_one(self) -> None:
        path = sessions.project_dir(self.cwd) / "session-2.jsonl"
        path.parent.mkdir(parents=True)
        path.write_text("\n".join([
            json.dumps({
                "type": "user", "timestamp": "2026-08-10T14:00:00Z",
                "message": {"content": "Première question"},
            }),
            json.dumps({
                "type": "user", "timestamp": "2026-08-10T17:30:00Z",
                "message": {"content": "Dernière question"},
            }),
        ]) + "\n", encoding="utf-8")

        listed = sessions.list_sessions(self.cwd)

        self.assertEqual(listed[0]["updatedAt"], "2026-08-10T17:30:00.000Z")
        self.assertEqual(listed[0]["exchanges"], 2)


class SummaryCacheTests(unittest.TestCase):
    """Lister un projet ne doit pas relire l'historique qui n'a pas bougé.

    Résumer une conversation coûte le décodage de tout son fichier — plusieurs
    mégaoctets sur un fil de travail. L'écran d'accueil le faisait pour chaque
    conversation de chaque projet, à chaque affichage : mesuré à 55 ms pour
    19 Mo répartis en 96 fils, et bien davantage sur un vrai VPS.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_projects = sessions.CLAUDE_PROJECTS
        sessions.CLAUDE_PROJECTS = Path(self.temporary.name)
        sessions._SUMMARY_CACHE.clear()
        self.cwd = str(Path(self.temporary.name) / "repos" / "office-chess")
        self.path = sessions.project_dir(self.cwd) / "session-1.jsonl"
        self.path.parent.mkdir(parents=True)
        self._write("Corrige le compteur", "2026-08-10T14:00:00.000Z")

    def tearDown(self) -> None:
        sessions.CLAUDE_PROJECTS = self.previous_projects
        sessions._SUMMARY_CACHE.clear()
        self.temporary.cleanup()

    def _write(self, prompt: str, moment: str) -> None:
        self.path.write_text(json.dumps({
            "type": "user", "timestamp": moment,
            "message": {"content": prompt},
        }) + "\n", encoding="utf-8")

    def _reads(self) -> int:
        """Le nombre de fois où le fichier est réellement ouvert."""
        opened = 0
        original = Path.open

        def counting(this: Path, *args, **kwargs):
            nonlocal opened
            if this == self.path:
                opened += 1
            return original(this, *args, **kwargs)

        with unittest.mock.patch.object(Path, "open", counting):
            sessions.list_sessions(self.cwd)
        return opened

    def test_an_unchanged_conversation_is_read_once(self) -> None:
        self.assertEqual(self._reads(), 1)
        # Les affichages suivants doivent se contenter du résumé retenu.
        self.assertEqual(self._reads(), 0)
        self.assertEqual(self._reads(), 0)

    def test_a_changed_conversation_is_read_again(self) -> None:
        """Le cache ne doit jamais montrer un fil périmé."""
        listed = sessions.list_sessions(self.cwd)
        self.assertEqual(listed[0]["title"], "Corrige le compteur")

        self._write("Une toute autre demande", "2026-08-10T18:00:00.000Z")
        # `st_mtime` a la seconde pour granularité sur certains systèmes de
        # fichiers : la taille change ici aussi, et la signature avec elle.
        listed = sessions.list_sessions(self.cwd)

        self.assertEqual(listed[0]["title"], "Une toute autre demande")
        self.assertEqual(listed[0]["updatedAt"], "2026-08-10T18:00:00.000Z")


class ThreadsWithoutTimestampsTests(unittest.TestCase):
    """Les conversations déjà présentes sur le VPS.

    Elles ont été écrites avant que chaque message porte sa date. Pour elles, la
    liste n'a que le `mtime` du fichier — et c'est le cas qui a laissé passer,
    jusqu'en production, un projet daté « il y a deux secondes » dès qu'on
    l'ouvrait. Aucun test ne l'exerçait.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.previous_projects = sessions.CLAUDE_PROJECTS
        sessions.CLAUDE_PROJECTS = Path(self.temporary.name)
        sessions._SUMMARY_CACHE.clear()
        self.cwd = str(Path(self.temporary.name) / "repos" / "office-chess")
        self.directory = sessions.project_dir(self.cwd)
        self.directory.mkdir(parents=True)

    def tearDown(self) -> None:
        sessions.CLAUDE_PROJECTS = self.previous_projects
        sessions._SUMMARY_CACHE.clear()
        self.temporary.cleanup()

    def _write(self, name: str, events: list[dict], age: float) -> Path:
        path = self.directory / name
        path.write_text(
            "\n".join(json.dumps(event) for event in events) + "\n", encoding="utf-8"
        )
        moment = time.time() - age
        os.utime(path, (moment, moment))
        return path

    def test_a_thread_without_timestamps_is_dated_by_its_file(self) -> None:
        path = self._write("ancienne.jsonl", [
            {"type": "user", "message": {"content": "Ma demande d'hier"}},
            {"type": "assistant", "message": {"content": "Ma réponse"}},
        ], age=3_600)

        listed = sessions.list_sessions(self.cwd)

        # La valeur, pas seulement sa stabilité : un repli devenu « maintenant »
        # est exactement la régression qu'on retient ici.
        self.assertEqual(listed[0]["updatedAt"], sessions._iso(path.stat().st_mtime))
        self.assertEqual(listed[0]["title"], "Ma demande d'hier")

    def test_dated_and_undated_threads_sort_together_without_raising(self) -> None:
        """Le tri compare des chaînes : un `updatedAt` absent le ferait lever,
        et c'est toute la liste des conversations qui disparaîtrait."""
        self._write("ancienne.jsonl", [
            {"type": "user", "message": {"content": "Sans horodatage"}},
        ], age=7_200)
        self._write("recente.jsonl", [
            {
                "type": "user", "timestamp": "2099-01-01T00:00:00.000Z",
                "message": {"content": "Avec horodatage"},
            },
        ], age=86_400)

        listed = sessions.list_sessions(self.cwd)

        self.assertEqual(len(listed), 2)
        self.assertTrue(all(isinstance(item["updatedAt"], str) for item in listed))
        # La date portée par le message l'emporte sur l'âge du fichier.
        self.assertEqual(listed[0]["title"], "Avec horodatage")

    def test_an_unreadable_timestamp_does_not_lose_the_conversation(self) -> None:
        """Une seule ligne corrompue ne doit pas emporter la liste entière."""
        for moment in ("pas une date", "2026-08-10T14:00:00", 1_760_000_000):
            with self.subTest(timestamp=moment):
                sessions._SUMMARY_CACHE.clear()
                path = self._write("douteuse.jsonl", [
                    {
                        "type": "user", "timestamp": moment,
                        "message": {"content": "Demande lisible"},
                    },
                ], age=1_800)

                listed = sessions.list_sessions(self.cwd)

                self.assertEqual(len(listed), 1)
                # Un horodatage naïf ou illisible ne fait pas foi : on retombe
                # sur le fichier plutôt que d'inventer un fuseau.
                self.assertEqual(
                    listed[0]["updatedAt"], sessions._iso(path.stat().st_mtime)
                )
