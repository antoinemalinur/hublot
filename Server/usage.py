"""Le contexte réellement consommé, lu chez celui qui le mesure.

Hublot affichait « CTX » à partir du seul événement `result` de Claude, arrivé
en toute fin de tour. Trois conséquences, toutes vues à l'écran :

* rouvrir une conversation effaçait le chiffre — la barre repartait de zéro et
  ne le retrouvait qu'après un tour complet ;
* une conversation menée par **Codex** n'en avait jamais, puisque ce chemin
  n'émettait aucun `result` ;
* un simple changement de réglage remettait `used` à 0 et faisait disparaître
  la cellule.

Or les deux moteurs écrivent déjà la mesure sur le disque : Claude dans le
JSONL de sa session, Codex dans le journal de son fil. Ce module va la chercher
là plutôt que de la reconstituer — un chiffre estimé devant une fenêtre de
contexte vaut moins que pas de chiffre du tout.

Les fichiers en question atteignent des dizaines de mégaoctets, et une ligne
peut à elle seule peser plusieurs mégaoctets — la sortie d'un `Read`. On les lit
donc **par la fin**, par blocs, en s'arrêtant dès qu'on a trouvé.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Iterator

CLAUDE_PROJECTS = Path(os.environ.get("CLAUDE_PROJECTS", "/root/.claude/projects"))
CODEX_SESSIONS = Path(
    os.environ.get("CODEX_SESSIONS")
    or (Path(os.environ.get("CODEX_HOME") or (Path.home() / ".codex")) / "sessions")
)

# Au-delà, on renonce : la mesure n'est pas assez précieuse pour justifier de
# relire un fichier entier de plusieurs centaines de mégaoctets.
TAIL_BUDGET = 8 * 1024 * 1024
TAIL_CHUNK = 256 * 1024


def entries_from_end(path: Path, budget: int = TAIL_BUDGET) -> Iterator[dict[str, Any]]:
    """Les objets JSON d'un fichier ligne à ligne, du dernier vers le premier.

    Une ligne coupée par la fenêtre de lecture est reportée sur le bloc suivant ;
    une ligne illisible est sautée. Le lecteur s'arrête quand il veut : c'est un
    générateur, donc rien n'est lu au-delà de ce qu'on consomme.
    """
    try:
        size = path.stat().st_size
    except OSError:
        return

    position = size
    trailing = b""
    consumed = 0
    try:
        with path.open("rb") as handle:
            while position > 0 and consumed < budget:
                step = min(TAIL_CHUNK, position)
                position -= step
                consumed += step
                handle.seek(position)
                block = handle.read(step)
                parts = (block + trailing).split(b"\n")
                # Le premier morceau est incomplet tant qu'on n'a pas atteint le
                # début du fichier : il attend le bloc précédent.
                trailing = parts[0] if position > 0 else b""
                complete = parts[1:] if position > 0 else parts
                for line in reversed(complete):
                    line = line.strip()
                    if not line.startswith(b"{"):
                        continue
                    try:
                        yield json.loads(line)
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        continue
    except OSError:
        return


# ---------------------------------------------------------------------------
# Claude
# ---------------------------------------------------------------------------
# `cache_creation_input_tokens` compte : sur une session reprise il pèse plus
# que tout le reste, et l'oublier donnait un contexte faux d'un facteur deux.
CLAUDE_INPUT_TOKEN_FIELDS = (
    "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens",
)


def _token_sum(usage: Any, fields: tuple[str, ...]) -> int:
    if not isinstance(usage, dict):
        return 0
    total = 0
    for field in fields:
        try:
            total += int(usage.get(field) or 0)
        except (TypeError, ValueError):
            continue
    return total


def claude_input_tokens(usage: Any) -> int:
    """Entrée réellement portée, cache compris, sans la sortie provisoire."""
    return _token_sum(usage, CLAUDE_INPUT_TOKEN_FIELDS)


def claude_output_tokens(usage: Any) -> int:
    """Sortie cumulative du message courant."""
    return _token_sum(usage, ("output_tokens",))


def claude_tokens(usage: Any) -> int:
    return claude_input_tokens(usage) + claude_output_tokens(usage)


def claude_stream_context(start_usage: Any, delta_usage: Any = None) -> int:
    """Contexte d'un message streamé.

    `message_start` porte l'entrée complète mais seulement une sortie
    provisoire. `message_delta` remplace cette sortie par son total cumulatif ;
    il ne faut donc surtout pas additionner les deux compteurs de sortie.
    """
    start_output = claude_output_tokens(start_usage)
    final_output = claude_output_tokens(delta_usage)
    return claude_input_tokens(start_usage) + max(start_output, final_output)


def bounded_context(used: int, size: int) -> int:
    """Une jauge ne dépasse jamais sa fenêtre, même devant une source corrompue."""
    used = max(0, int(used or 0))
    size = max(0, int(size or 0))
    return min(used, size) if size else used


def claude_context(path: Path) -> int:
    """Le contexte occupé par une session Claude, d'après son propre journal.

    Zéro quand le fichier n'existe pas ou n'a pas encore de tour : c'est le cas
    d'une conversation neuve, et afficher 0 % y serait un mensonge — l'appelant
    traite donc zéro comme « rien à dire ».
    """
    for event in entries_from_end(path):
        message = event.get("message")
        if not isinstance(message, dict):
            continue
        used = claude_tokens(message.get("usage"))
        if used:
            return used
    return 0


def claude_session_path(cwd: str, session_id: str,
                        projects: Path | None = None) -> Path:
    """Le JSONL natif d'une session, sous le nom de projet échappé par Claude."""
    root = projects or CLAUDE_PROJECTS
    key = "".join(c if c.isalnum() else "-" for c in cwd)
    return root / key / f"{session_id}.jsonl"


# ---------------------------------------------------------------------------
# Codex
# ---------------------------------------------------------------------------
def codex_rollout(thread_id: str, sessions: Path | None = None) -> Path | None:
    """Le journal du fil, rangé par date sous un nom qui finit par son identité."""
    if not thread_id:
        return None
    root = sessions or CODEX_SESSIONS
    try:
        found = sorted(root.glob(f"**/rollout-*-{thread_id}.jsonl"))
    except OSError:
        return None
    return found[-1] if found else None


def codex_context(thread_id: str, sessions: Path | None = None) -> tuple[int, int]:
    """`(occupé, fenêtre)` pour un fil Codex, ou `(0, 0)` si rien n'est mesuré.

    Codex publie deux totaux. `total_token_usage` cumule toute la vie du fil —
    quatorze millions de jetons sur une longue journée — et ne dit donc rien de
    la fenêtre. C'est `last_token_usage` qui décrit le contexte réellement porté
    par le dernier tour, et c'est ce chiffre que son interface affiche.
    """
    path = codex_rollout(thread_id, sessions)
    if path is None:
        return 0, 0

    for event in entries_from_end(path):
        payload = event.get("payload")
        if not isinstance(payload, dict) or payload.get("type") != "token_count":
            continue
        info = payload.get("info")
        if not isinstance(info, dict):
            continue
        last = info.get("last_token_usage")
        if not isinstance(last, dict):
            continue
        try:
            used = int(last.get("total_tokens") or 0)
            window = int(info.get("model_context_window") or 0)
        except (TypeError, ValueError):
            continue
        if used:
            return used, window
    return 0, 0
