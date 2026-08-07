"""Événements Codex rendus exploitables par la radiographie Hublot.

Le CLI expose les commandes et les modifications de fichiers sous deux formes
distinctes. Ce module les traduit sans dépendre du serveur WebSocket, afin que
les règles de localisation restent testables sans lancer un moteur.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any


_PATH = re.compile(
    r"(?<![\w.-])("  # ne pas entrer au milieu d'un mot ou d'un nombre SQL
    r"/(?:[\w@+.,=~-]+/)*[\w@+.,=~-]+"
    r"|(?:\.{1,2}/)?(?:[\w@+.,=~-]+/)+[\w@+.,=~-]+"
    r"|[\w@+,=-]+\.[A-Za-z][\w+-]{0,11}"
    r")"
)

_FILE_SUFFIXES = {
    ".bash", ".c", ".cpp", ".css", ".db", ".go", ".h", ".hpp",
    ".html", ".java", ".js", ".json", ".jsonl", ".jsx", ".kt",
    ".md", ".mjs", ".pbxproj", ".php", ".plist", ".py", ".rb",
    ".rs", ".scss", ".sh", ".sql", ".sqlite", ".swift", ".toml",
    ".ts", ".tsx", ".txt", ".xcconfig", ".yaml", ".yml", ".zsh",
}

_IGNORED_ROOTS = tuple(Path(value) for value in (
    "/bin", "/dev", "/proc", "/sbin", "/sys", "/usr",
))
_REPOSITORIES = Path("/root/repos")
_SERVICES = Path("/opt")


def _inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def command_locations(command: str, cwd: str, limit: int = 8) -> list[dict[str, str]]:
    """Repère les chemins factuels d'une commande, sans interpréter le shell.

    Seuls les chemins existants, les fichiers d'un type connu ou les cibles
    sous le dépôt et ``/opt`` sont retenus. Cela écarte ``/bin/bash`` ainsi que
    les identifiants SQL qui ressemblent accidentellement à des fichiers.
    """
    root = Path(cwd).resolve()
    found: list[tuple[int, int, Path]] = []
    seen: set[str] = set()

    for order, match in enumerate(_PATH.finditer(command)):
        raw = match.group(1).rstrip(".,:;")
        # Le second slash de ``https://…`` n'est pas un chemin local.
        if command[max(0, match.start() - 8):match.start()].endswith(":/"):
            continue

        source = Path(raw)
        candidate = source if source.is_absolute() else root / source
        try:
            resolved = candidate.resolve(strict=False)
        except OSError:
            continue

        if any(_inside(resolved, ignored) for ignored in _IGNORED_ROOTS):
            continue

        scoped = _inside(resolved, root)
        allowed_absolute = _inside(resolved, _REPOSITORIES) or _inside(resolved, _SERVICES)
        if not (scoped or allowed_absolute):
            continue
        exists = resolved.exists()
        known_file = resolved.suffix.lower() in _FILE_SUFFIXES
        parent_exists = resolved.parent.exists()

        if source.is_absolute():
            if not (exists or known_file):
                continue
        elif not (exists or known_file or ("/" in raw and parent_exists)):
            continue

        key = str(resolved)
        if key in seen:
            continue
        seen.add(key)
        # Le chemin le plus précis arrive en premier : c'est celui que le
        # client utilise pour nommer la région principale de la commande.
        found.append((len(resolved.parts), order, resolved))

    found.sort(key=lambda entry: (-entry[0], entry[1]))
    return [{"path": str(path)} for _, _, path in found[:limit]]


def codex_tool_updates(
    event_kind: str, item: dict[str, Any], cwd: str
) -> list[dict[str, Any]]:
    """Traduit un item Codex en un ou plusieurs appels d'outils ACP."""
    if event_kind not in {"item.started", "item.updated", "item.completed"}:
        return []

    item_id = str(item.get("id") or "codex-tool")
    done = event_kind == "item.completed"
    session_update = "tool_call" if event_kind == "item.started" else "tool_call_update"
    failed = done and (
        item.get("status") == "failed" or item.get("exit_code") not in (0, None)
    )
    status = ("failed" if failed else "completed") if done else "in_progress"

    if item.get("type") == "command_execution":
        command = str(item.get("command") or "commande")
        update: dict[str, Any] = {
            "sessionUpdate": session_update,
            "toolCallId": item_id,
            "title": command,
            "kind": "execute",
            "status": status,
            "rawInput": {"command": command},
            "_meta": {"claudeCode": {"toolName": "Bash"}},
        }
        locations = command_locations(command, cwd)
        if locations:
            update["locations"] = locations
        output = str(item.get("aggregated_output") or "")
        if done and output.strip():
            update["content"] = [{
                "type": "content",
                "content": {"type": "text", "text": output[:4000]},
            }]
        return [update]

    if item.get("type") == "file_change":
        updates: list[dict[str, Any]] = []
        changes = item.get("changes") if isinstance(item.get("changes"), list) else []
        for index, change in enumerate(changes):
            if not isinstance(change, dict) or not change.get("path"):
                continue
            path = str(change["path"])
            source = Path(path)
            location = source if source.is_absolute() else Path(cwd) / source
            try:
                location = location.resolve(strict=False)
            except OSError:
                pass
            change_kind = str(change.get("kind") or "update")
            tool_kind = {"delete": "delete", "move": "move"}.get(change_kind, "edit")
            updates.append({
                "sessionUpdate": session_update,
                "toolCallId": f"{item_id}:{index}",
                "title": source.name or path,
                "kind": tool_kind,
                "status": status,
                "locations": [{"path": str(location)}],
                "rawInput": {"path": path, "changeKind": change_kind},
                "_meta": {"claudeCode": {"toolName": "ApplyPatch"}},
            })
        return updates

    return []
