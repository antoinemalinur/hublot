from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import usage


def write_jsonl(path: Path, entries: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for entry in entries:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


class TailReadingTests(unittest.TestCase):
    def test_entries_arrive_from_the_end(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fil.jsonl"
            write_jsonl(path, [{"n": index} for index in range(5)])
            self.assertEqual(
                [entry["n"] for entry in usage.entries_from_end(path)],
                [4, 3, 2, 1, 0],
            )

    def test_a_line_longer_than_a_block_stays_whole(self) -> None:
        """Une sortie de `Read` pèse des mégaoctets : elle traverse plusieurs
        blocs de lecture et ne doit pas être coupée en deux morceaux illisibles."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fil.jsonl"
            write_jsonl(path, [
                {"message": {"usage": {"input_tokens": 11}}},
                {"gros": "x" * (usage.TAIL_CHUNK * 3)},
                {"queue": True},
            ])
            found = list(usage.entries_from_end(path))
            self.assertEqual(found[0], {"queue": True})
            self.assertEqual(len(found[1]["gros"]), usage.TAIL_CHUNK * 3)
            self.assertEqual(found[2]["message"]["usage"]["input_tokens"], 11)

    def test_a_missing_file_is_not_an_error(self) -> None:
        self.assertEqual(list(usage.entries_from_end(Path("/absent.jsonl"))), [])


class ClaudeContextTests(unittest.TestCase):
    def test_the_cache_counts_in_the_context(self) -> None:
        # Le morceau oublié la première fois, et le plus lourd sur une session
        # reprise : sans lui le contexte affiché valait la moitié du vrai.
        self.assertEqual(
            usage.claude_tokens({
                "input_tokens": 100,
                "cache_creation_input_tokens": 4000,
                "cache_read_input_tokens": 60000,
                "output_tokens": 900,
            }),
            65000,
        )

    def test_stream_delta_replaces_the_provisional_output(self) -> None:
        start = {
            "input_tokens": 100,
            "cache_creation_input_tokens": 400,
            "cache_read_input_tokens": 5_000,
            "output_tokens": 1,
        }
        delta = {"output_tokens": 500}
        self.assertEqual(usage.claude_stream_context(start, delta), 6_000)

    def test_context_is_bounded_by_its_window(self) -> None:
        self.assertEqual(usage.bounded_context(1_540, 100), 100)
        self.assertEqual(usage.bounded_context(42, 100), 42)
        self.assertEqual(usage.bounded_context(42, 0), 42)

    def test_the_last_measured_turn_wins(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            write_jsonl(path, [
                {"type": "assistant", "message": {"usage": {"input_tokens": 1000}}},
                {"type": "user", "message": {"content": "et ensuite ?"}},
                {"type": "assistant", "message": {"usage": {
                    "input_tokens": 2000, "output_tokens": 500,
                }}},
            ])
            self.assertEqual(usage.claude_context(path), 2500)

    def test_a_conversation_without_a_turn_measures_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            write_jsonl(path, [{"type": "user", "message": {"content": "bonjour"}}])
            # Zéro, pas une estimation : devant une fenêtre de contexte, un
            # chiffre inventé est pire que pas de chiffre.
            self.assertEqual(usage.claude_context(path), 0)

    def test_the_project_path_follows_claude_escaping(self) -> None:
        path = usage.claude_session_path(
            "/root/repos/office-chess", "abc-123", Path("/tmp/projects")
        )
        self.assertEqual(
            path, Path("/tmp/projects/-root-repos-office-chess/abc-123.jsonl")
        )


class CodexContextTests(unittest.TestCase):
    def rollout(self, root: Path, thread: str, events: list[dict]) -> None:
        path = root / "2026" / "08" / "07" / f"rollout-2026-08-07T10-00-00-{thread}.jsonl"
        write_jsonl(path, events)

    def test_the_last_turn_gives_the_context_not_the_lifetime_total(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.rollout(root, "019fdc3d", [
                {"type": "event_msg", "payload": {"type": "token_count", "info": {
                    "total_token_usage": {"total_tokens": 14_000_000},
                    "last_token_usage": {"total_tokens": 12_000},
                    "model_context_window": 258_400,
                }}},
                {"type": "event_msg", "payload": {"type": "token_count", "info": {
                    # Le cumul de la journée n'a rien à voir avec la fenêtre.
                    "total_token_usage": {"total_tokens": 14_400_000},
                    "last_token_usage": {"total_tokens": 53_785},
                    "model_context_window": 258_400,
                }}},
                {"type": "response_item", "payload": {"type": "message"}},
            ])
            self.assertEqual(
                usage.codex_context("019fdc3d", root), (53_785, 258_400)
            )

    def test_an_unknown_thread_measures_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(usage.codex_context("absent", Path(directory)), (0, 0))
            self.assertEqual(usage.codex_context("", Path(directory)), (0, 0))


if __name__ == "__main__":
    unittest.main()
