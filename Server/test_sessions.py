from __future__ import annotations

import json
import os
import tempfile
import unittest
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
