"""Ce que chaque moteur a vu d'une conversation, et ce qu'il a manqué.

Le problème que ça résout, en une phrase : **une conversation, deux mémoires.**

Claude garde sa session native, Codex garde la sienne. Tant qu'on ne bascule
pas, chacun se souvient tout seul. Mais dès qu'on change de moteur, celui qui
reprend ignore ce que l'autre a fait — et si on revient au premier plus tard,
il reprend sa session là où il l'avait laissée, avec un trou au milieu.

La règle adoptée ici :

    Le fil de la conversation est la vérité. Les sessions natives sont des
    caches. Au moment de basculer, le moteur entrant reçoit **exactement ce
    qu'il a manqué** — pas tout l'historique (coûteux et redondant avec sa
    propre session), pas un résumé vague (lâche des faits), mais le delta.

Concrètement, on tient pour chaque conversation :

* le fil, ligne à ligne, avec l'auteur de chaque réponse ;
* un repère par moteur : jusqu'où il a vu.

Rester sur le même moteur ne produit donc aucune passation — son repère est à
jour. Basculer produit une passation qui contient les seuls tours manquants.
Revenir trois jours plus tard aussi, et seulement ceux-là.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

STATE = Path(os.environ.get("ACP_CONTINUITY", "/opt/tg-claude/state/acp-continuity"))


def _paths(cwd: str, session_id: str) -> tuple[Path, Path]:
    key = "".join(c if c.isalnum() else "-" for c in cwd)
    directory = STATE / key
    return directory / f"{session_id}.jsonl", directory / f"{session_id}.seen.json"


# ---------------------------------------------------------------------------
# Le fil
# ---------------------------------------------------------------------------
def record(cwd: str, session_id: str, role: str, text: str, engine: str | None = None) -> None:
    """Ajoute un tour au fil. Appelé pour la demande et pour la réponse."""
    if not text.strip():
        return
    transcript, _ = _paths(cwd, session_id)
    transcript.parent.mkdir(parents=True, exist_ok=True)
    with transcript.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(
            {"role": role, "engine": engine, "text": text}, ensure_ascii=False
        ) + "\n")


_TOOL_FIELDS = (
    "sessionUpdate", "toolCallId", "title", "kind", "status",
    "locations", "rawInput", "_meta",
)
_VISUAL_INPUT_FIELDS = (
    "command", "file_path", "path", "pattern", "url", "description",
    "changeKind",
)


def record_tool(cwd: str, session_id: str, update: dict[str, Any]) -> None:
    """Conserve la géographie d'un outil, sans sa sortie volumineuse.

    La radiographie a besoin de l'ordre, du type, du statut et des chemins —
    pas des milliers de lignes renvoyées par le terminal, ni du contenu complet
    d'un fichier écrit. La persistance est volontairement *best effort* : un
    disque momentanément indisponible ne doit jamais couper le flux vivant.
    """
    if update.get("sessionUpdate") not in {"tool_call", "tool_call_update"}:
        return
    if not update.get("toolCallId"):
        return

    compact = {key: update[key] for key in _TOOL_FIELDS if key in update}
    raw_input = compact.get("rawInput")
    if isinstance(raw_input, dict):
        compact["rawInput"] = {
            key: value for key, value in raw_input.items()
            if key in _VISUAL_INPUT_FIELDS
        }
        if not compact["rawInput"]:
            compact.pop("rawInput")

    transcript, _ = _paths(cwd, session_id)
    try:
        transcript.parent.mkdir(parents=True, exist_ok=True)
        with transcript.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(
                {"role": "tool", "update": compact}, ensure_ascii=False
            ) + "\n")
    except (OSError, TypeError, ValueError):
        pass


def _transcript(cwd: str, session_id: str) -> list[dict[str, Any]]:
    path, _ = _paths(cwd, session_id)
    entries: list[dict[str, Any]] = []
    try:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return entries


def replay(cwd: str, session_id: str) -> list[dict[str, Any]]:
    """Rejoue le fil canonique, outils compris, dans son ordre exact."""
    return _transcript(cwd, session_id)


def _iso(timestamp: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(timestamp))


def list_sessions(cwd: str) -> list[dict[str, Any]]:
    """Liste aussi les conversations Codex, absentes du stockage Claude."""
    directory = _paths(cwd, "unused")[0].parent
    if not directory.is_dir():
        return []

    sessions: list[dict[str, Any]] = []
    for path in directory.glob("*.jsonl"):
        entries = _transcript(cwd, path.stem)
        prompts = [
            str(entry.get("text") or "").strip()
            for entry in entries if entry.get("role") == "user"
        ]
        prompts = [prompt for prompt in prompts if prompt]
        if not prompts:
            continue
        try:
            modified = path.stat().st_mtime
        except OSError:
            continue
        flat = " ".join(prompts[0].split())
        title = flat[:79] + "…" if len(flat) > 80 else flat
        sessions.append({
            "sessionId": path.stem,
            "cwd": cwd,
            "title": title or "Conversation",
            "updatedAt": _iso(modified),
            "exchanges": len(prompts),
        })
    sessions.sort(key=lambda session: session["updatedAt"], reverse=True)
    return sessions


# ---------------------------------------------------------------------------
# Les repères
# ---------------------------------------------------------------------------
def _seen(cwd: str, session_id: str) -> dict[str, int]:
    _, marks = _paths(cwd, session_id)
    try:
        return json.loads(marks.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def acknowledge(cwd: str, session_id: str, engine: str) -> None:
    """Ce moteur vient de travailler : il a désormais tout vu."""
    _, marks = _paths(cwd, session_id)
    marks.parent.mkdir(parents=True, exist_ok=True)
    seen = _seen(cwd, session_id)
    seen[engine] = len(_transcript(cwd, session_id))
    marks.write_text(json.dumps(seen, indent=1), encoding="utf-8")


def missing(cwd: str, session_id: str, engine: str) -> list[dict[str, Any]]:
    """Les tours que ce moteur n'a pas vus, dans l'ordre.

    Vide s'il est à jour — et c'est le cas normal : tant qu'on ne bascule pas,
    aucune passation n'est écrite, exactement comme dans le relais Telegram.
    """
    entries = _transcript(cwd, session_id)
    unseen = entries[_seen(cwd, session_id).get(engine, 0):]
    # Les appels d'outils appartiennent au rendu et à la chronologie visuelle,
    # pas au document de passation remis au moteur suivant.
    return [entry for entry in unseen if entry.get("role") in {"user", "assistant"}]


def has_history(cwd: str, session_id: str, engine: str) -> bool:
    """Ce moteur a-t-il déjà participé à cette conversation ?

    Sert à distinguer « il lui manque trois tours » de « il découvre tout » :
    dans le second cas la passation doit être présentée comme une prise de
    connaissance, pas comme un rattrapage.
    """
    return engine in _seen(cwd, session_id)


# ---------------------------------------------------------------------------
# La passation
# ---------------------------------------------------------------------------
def journal_events(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Traduit le delta dans la forme que `handoff.py` sait relire.

    On réutilise le constructeur existant plutôt que d'en écrire un second :
    ses règles de budget, son en-tête et ses consignes de reprise ont déjà été
    éprouvées sur Telegram.
    """
    events: list[dict[str, Any]] = []
    for entry in entries:
        if entry.get("role") == "user":
            events.append({"kind": "message", "text": entry.get("text", "")})
        elif entry.get("role") == "assistant":
            events.append({
                "kind": "response",
                "engine": entry.get("engine") or "?",
                "text": entry.get("text", ""),
            })
    return events


def forget(cwd: str, session_id: str) -> bool:
    """Supprime le fil et les repères d'une conversation effacée."""
    removed = False
    for path in _paths(cwd, session_id):
        try:
            path.unlink()
            removed = True
        except FileNotFoundError:
            pass
        except OSError:
            pass
    return removed
