"""Les projets et leurs conversations, lus là où ils existent vraiment.

Claude Code range déjà chaque conversation dans un fichier :

    /root/.claude/projects/<cwd échappé>/<sessionId>.jsonl

C'est la source de vérité, et la seule. Rien n'est dupliqué dans un index
maison : lister, reprendre ou supprimer une conversation, c'est lire, rejouer
ou effacer ces fichiers. Un dossier ajouté par un autre processus apparaît donc
tout seul, et une conversation supprimée l'est réellement.
"""
from __future__ import annotations

import json
import os
import shutil
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator

CLAUDE_PROJECTS = Path(os.environ.get("CLAUDE_PROJECTS", "/root/.claude/projects"))

# Résumer une conversation coûte la lecture et le décodage de tout son fichier —
# plusieurs mégaoctets pour un fil de travail, outils compris. Les listes le
# faisaient à chaque affichage, pour chaque conversation, et l'écran d'accueil
# les rouvrait toutes, tous projets confondus : le prix d'un simple retour en
# arrière était la relecture de l'historique entier.
#
# Un fil déjà terminé ne change plus jamais. La signature du fichier — sa taille
# et sa date — suffit à le savoir : identique, on garde le résumé ; différente,
# on relit. Aucune invalidation à tenir à jour, et un fichier modifié par un
# autre processus est vu immédiatement.
_SUMMARY_CACHE: dict[str, tuple[tuple[float, int], tuple[str, int, str | None]]] = {}
_SUMMARY_LOCK = threading.Lock()
# De quoi couvrir très largement un VPS réel sans laisser la mémoire filer si
# des milliers de fils s'accumulent.
_SUMMARY_CACHE_MAX = 2_048


def _iso(timestamp: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(timestamp))


def project_key(cwd: str) -> str:
    """Le nom de dossier que Claude Code dérive d'un répertoire de travail.

    Chaque caractère non alphanumérique devient un tiret : `/root/repos/x`
    donne `-root-repos-x`. Relevé sur le VPS, pas deviné.
    """
    return "".join(c if c.isalnum() else "-" for c in cwd)


def project_dir(cwd: str) -> Path:
    return CLAUDE_PROJECTS / project_key(cwd)


# ---------------------------------------------------------------------------
# Projets
# ---------------------------------------------------------------------------
def list_projects(repos_base: str) -> list[dict[str, Any]]:
    """Les dépôts présents, relus à chaque appel.

    Un vrai `ls` : aucun cache, aucune liste en dur. Un dépôt cloné il y a
    trente secondes par un autre processus est là.
    """
    root = Path(repos_base)
    projects: list[dict[str, Any]] = []
    if not root.is_dir():
        return projects

    for entry in sorted(root.iterdir(), key=lambda p: p.name.lower()):
        if not entry.is_dir() or entry.name.startswith("."):
            continue
        sessions = list_sessions(str(entry))
        projects.append({
            "name": entry.name,
            "path": str(entry),
            "sessionCount": len(sessions),
            # La date qui compte est celle de la dernière conversation, pas
            # celle du dossier : c'est « quand ai-je travaillé dessus ».
            "updatedAt": sessions[0]["updatedAt"] if sessions else _iso(entry.stat().st_mtime),
        })
    return projects


# ---------------------------------------------------------------------------
# Conversations
# ---------------------------------------------------------------------------
def list_sessions(cwd: str) -> list[dict[str, Any]]:
    """Les conversations d'un projet, la plus récente d'abord."""
    directory = project_dir(cwd)
    if not directory.is_dir():
        return []

    sessions: list[dict[str, Any]] = []
    for path in directory.glob("*.jsonl"):
        try:
            modified = path.stat().st_mtime
        except OSError:
            continue
        title, exchanges, last_prompt_at = _summarise(path)
        if not exchanges:
            # Une session sans un seul échange est un vestige : la montrer
            # promettrait un historique qui n'existe pas.
            continue
        sessions.append({
            "sessionId": path.stem,
            "cwd": cwd,
            "title": title,
            # Ouvrir ou reprendre une session peut réécrire son fichier. La
            # date montrée dans les listes est celle de la dernière demande
            # humaine, pas celle de cette activité technique.
            "updatedAt": last_prompt_at or _iso(modified),
            "exchanges": exchanges,
        })
    sessions.sort(key=lambda s: s["updatedAt"], reverse=True)
    return sessions


def _summarise(path: Path) -> tuple[str, int, str | None]:
    """Titre, nombre d'échanges et dernière demande — relus une seule fois.

    Le résultat est retenu tant que le fichier ne bouge pas. Voir
    `_SUMMARY_CACHE` : c'est ce qui sépare une liste instantanée d'une relecture
    de tout l'historique à chaque affichage.
    """
    key = str(path)
    try:
        status = path.stat()
        signature = (status.st_mtime, status.st_size)
    except OSError:
        # Sans signature, rien à retenir : on lit, et c'est tout.
        return _read_summary(path)

    with _SUMMARY_LOCK:
        remembered = _SUMMARY_CACHE.get(key)
        if remembered is not None and remembered[0] == signature:
            return remembered[1]

    summary = _read_summary(path)

    with _SUMMARY_LOCK:
        # Une éviction grossière suffit : ces entrées sont minuscules et le seuil
        # n'est jamais atteint sur un VPS réel.
        if len(_SUMMARY_CACHE) >= _SUMMARY_CACHE_MAX:
            _SUMMARY_CACHE.clear()
        _SUMMARY_CACHE[key] = (signature, summary)
    return summary


def _read_summary(path: Path) -> tuple[str, int, str | None]:
    """La lecture elle-même, sans cache.

    Claude écrit lui-même un `ai-title` quand il en a produit un ; à défaut on
    prend la première demande. Un titre inventé ici serait moins bon que le
    sien.
    """
    ai_title: str | None = None
    first_prompt: str | None = None
    last_prompt_at: str | None = None
    exchanges = 0

    for event in _events(path):
        kind = event.get("type")
        if kind == "ai-title" and event.get("aiTitle"):
            ai_title = str(event["aiTitle"])
        elif kind == "user":
            text = _text_of(event.get("message"))
            if text and not _is_synthetic(text):
                exchanges += 1
                if first_prompt is None:
                    first_prompt = text
                last_prompt_at = _timestamp_of(event) or last_prompt_at

    title = ai_title or first_prompt or "Conversation"
    flat = " ".join(title.split())
    return (flat[:79] + "…" if len(flat) > 80 else flat), exchanges, last_prompt_at


def _timestamp_of(event: dict[str, Any]) -> str | None:
    """Normalise l'horodatage ISO écrit par Claude, ou l'écarte s'il est faux."""
    value = event.get("timestamp")
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return _iso(parsed.timestamp())


def replay(cwd: str, session_id: str) -> Iterator[tuple[str, str]]:
    """Rejoue l'historique en (`rôle`, `texte`).

    Les appels d'outils sont écartés : reconstituer un déroulé d'outils
    vieux de trois semaines n'apprend rien, alors que les questions et les
    réponses, elles, sont ce qu'on revient chercher.
    """
    path = project_dir(cwd) / f"{session_id}.jsonl"
    if not path.is_file():
        return

    for event in _events(path):
        kind = event.get("type")
        if kind not in {"user", "assistant"}:
            continue
        text = _text_of(event.get("message"))
        if text and not _is_synthetic(text):
            yield kind, text


def delete(cwd: str, session_id: str) -> bool:
    """Supprime la conversation et son historique. Sans corbeille."""
    path = project_dir(cwd) / f"{session_id}.jsonl"
    try:
        path.unlink()
    except FileNotFoundError:
        return False
    except OSError:
        return False
    # Claude range aussi des pièces jointes à côté ; les laisser derrière
    # ferait grossir le disque sans que rien ne les référence plus.
    shutil.rmtree(project_dir(cwd) / session_id, ignore_errors=True)
    return True


# ---------------------------------------------------------------------------
# Lecture
# ---------------------------------------------------------------------------
def _events(path: Path) -> Iterator[dict[str, Any]]:
    try:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


# Claude Code injecte des messages qui portent le rôle « user » sans venir de
# l'utilisateur : le préambule d'une commande slash, l'avertissement qui
# l'accompagne. Les afficher donnerait des conversations intitulées
# « <local-command-caveat>Caveat: The messages below… » et un fil truffé de
# plomberie.
# Claude Code écrit lui-même des messages qui portent le rôle « user » sans
# venir de personne : le préambule d'une commande slash, un rappel système, et
# le marqueur qu'il pose quand un tour est interrompu. Les rejouer tels quels
# fait dire à Antoine des phrases qu'il n'a jamais tapées — vu à l'écran :
# « [Request interrupted by user] » affiché comme une demande.
SYNTHETIC = ("<local-command-caveat>", "<command-name>", "<command-message>",
             "<command-args>", "<system-reminder>", "[Request interrupted")


def _is_synthetic(text: str) -> bool:
    return text.lstrip().startswith(SYNTHETIC)


def _text_of(message: Any) -> str:
    """Le texte d'un message, quelle que soit la forme du champ `content`.

    Claude écrit tantôt une chaîne, tantôt une liste de blocs. Les résultats
    d'outils portent le rôle « user » mais ne sont pas des demandes : on les
    saute, sinon relire une session ferait apparaître des sorties de `Read`
    comme si c'était Antoine qui parlait.
    """
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""

    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_result":
            return ""
        if block.get("type") == "text":
            parts.append(str(block.get("text") or ""))
    return "\n".join(parts).strip()


def exists(cwd: str, session_id: str) -> bool:
    """La conversation a-t-elle déjà un fichier ?

    C'est ce qui décide entre `--resume` et `--session-id` : reprendre une
    session que Claude ne connaît pas échoue, en créer une qui existe déjà
    écrase son historique.
    """
    return (project_dir(cwd) / f"{session_id}.jsonl").is_file()


# ---------------------------------------------------------------------------
# Fils Codex
#
# Codex tient ses propres sessions, sous des identifiants qui lui appartiennent
# et que `bot.py` gardait en un seul exemplaire — un fil global, partagé par
# tout le monde. Reprendre une conversation basculait donc Codex sur un
# contexte qui n'était pas le sien, et il répondait à côté.
#
# On associe donc chaque conversation à *son* fil Codex. La correspondance vit
# dans un petit fichier : elle doit survivre à un redémarrage du serveur, sinon
# la reprise se perd au premier `systemctl restart`.
# ---------------------------------------------------------------------------
CODEX_THREADS = Path(os.environ.get(
    "ACP_CODEX_THREADS", "/opt/tg-claude/state/acp-codex-threads.json"
))


def _threads() -> dict[str, str]:
    try:
        return json.loads(CODEX_THREADS.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def codex_thread(cwd: str, session_id: str) -> str | None:
    """Le fil Codex de cette conversation, s'il en a déjà un."""
    return _threads().get(f"{cwd}::{session_id}")


def remember_codex_thread(cwd: str, session_id: str, thread_id: str) -> None:
    threads = _threads()
    threads[f"{cwd}::{session_id}"] = thread_id
    CODEX_THREADS.parent.mkdir(parents=True, exist_ok=True)
    CODEX_THREADS.write_text(json.dumps(threads, indent=1), encoding="utf-8")


def forget_codex_thread(cwd: str, session_id: str) -> None:
    threads = _threads()
    if threads.pop(f"{cwd}::{session_id}", None) is not None:
        CODEX_THREADS.write_text(json.dumps(threads, indent=1), encoding="utf-8")


# ---------------------------------------------------------------------------
# Instructions du dépôt
# ---------------------------------------------------------------------------
#
# Claude Code lit ces fichiers au démarrage d'une session : ce sont eux qui
# expliquent comment travailler sur ce dépôt-là. Les consulter depuis le
# téléphone évite de deviner pourquoi l'agent se comporte d'une certaine façon.
INSTRUCTION_FILES = ("CLAUDE.md", ".claude/CLAUDE.md", "AGENTS.md")


def instructions(cwd: str) -> dict[str, Any] | None:
    """Le fichier d'instructions du dépôt, s'il en a un.

    On renvoie le premier trouvé dans l'ordre où Claude les considère, et le
    contenu tel quel — c'est le client qui sait le mettre en forme.
    """
    root = Path(cwd)
    for name in INSTRUCTION_FILES:
        candidate = root / name
        if not candidate.is_file():
            continue
        try:
            content = candidate.read_text(encoding="utf-8")
        except OSError:
            continue
        return {
            "path": name,
            "content": content,
            "bytes": len(content.encode("utf-8")),
            "updatedAt": _iso(candidate.stat().st_mtime),
        }
    return None
