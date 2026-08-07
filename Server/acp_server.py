#!/usr/bin/env python3
"""Serveur ACP du VPS — la logique de `bot.py`, exposée en WebSocket.

Ce daemon n'est pas un second cerveau : il **importe** `bot.py` et réutilise sa
logique telle quelle — bascule de quota, passation de contexte, sessions
natives, épinglage `/switch`, journal, persistance. Rien n'est réimplémenté ici,
parce que deux implémentations d'une même règle finissent toujours par diverger.

Ce qu'il ajoute, et lui seul :

* le transport : JSON-RPC 2.0 sur WebSocket, une trame par ligne ;
* le **streaming**. `bot.py` lance ``claude -p`` et attend la sortie complète —
  ce qui convient à Telegram, qui ne sait de toute façon afficher qu'un message
  fini. ACP veut le texte au fil de l'eau, donc on passe par
  ``--output-format stream-json`` et on traduit chaque événement en
  ``session/update``.

Le rendu, lui, n'est plus notre affaire : `render.py` existait pour contourner
l'absence de tableaux dans Telegram. Le client iOS reçoit le Markdown brut et
le rend lui-même.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import json
import os
import struct
import sys
import urllib.error
import urllib.request
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

BASE = os.environ.get("TG_CLAUDE_BASE", "/opt/tg-claude")
sys.path.insert(0, BASE)

import bot  # noqa: E402  (dépend du chemin ci-dessus)
import continuity  # noqa: E402
import handoff as handoff_builder  # noqa: E402
import radiography as radiography_events  # noqa: E402
import sessions as store  # noqa: E402

HOST = os.environ.get("ACP_HOST", "127.0.0.1")
PORT = int(os.environ.get("ACP_PORT", "8325"))
TOKEN = os.environ.get("ACP_TOKEN") or ""
QUOTA_WEB_URL = os.environ.get(
    "ACP_QUOTA_URL", "http://127.0.0.1:8322/api/quota"
)
QUOTA_WEB_TOKEN = os.environ.get("QUOTA_WEB_TOKEN", "")
PROTOCOL_VERSION = 1


class RPCErrorCode:
    """Les codes JSON-RPC 2.0 employés. Ils ont un sens pour le client."""

    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL = -32603
REPOS_BASE = getattr(bot, "REPOS_BASE", "/root/repos")

if not TOKEN:
    raise SystemExit("ACP_TOKEN est obligatoire : sans jeton, le serveur est ouvert.")


def log(message: str) -> None:
    bot.log(f"[acp] {message}")


# ---------------------------------------------------------------------------
# Catalogue Codex
#
# Le CLI maintient lui-même la liste des modèles autorisés pour ce compte dans
# ``models_cache.json``. C'est une bien meilleure source qu'une constante dans
# Hublot : quand OpenAI ajoute ou retire un modèle, la capsule suit le CLI sans
# redéploiement. Les trois variantes 5.6 servent seulement de repli au tout
# premier démarrage, avant que Codex ait créé son cache.
# ---------------------------------------------------------------------------
CODEX_HOME = Path(os.environ.get("CODEX_HOME") or (Path.home() / ".codex"))
CODEX_MODELS_CACHE = Path(
    os.environ.get("CODEX_MODELS_CACHE") or (CODEX_HOME / "models_cache.json")
)
CODEX_MODEL_FILE = Path(
    os.environ.get("ACP_CODEX_MODEL_FILE") or (Path(BASE) / "state" / "codex-model")
)
FALLBACK_CODEX_MODELS: tuple[dict[str, Any], ...] = (
    {
        "model": "gpt-5.6-sol", "displayName": "GPT-5.6-Sol",
        "description": "Capacité maximale pour les tâches complexes.",
        "efforts": ("low", "medium", "high", "xhigh", "max", "ultra"),
        "defaultEffort": "low",
    },
    {
        "model": "gpt-5.6-terra", "displayName": "GPT-5.6-Terra",
        "description": "Équilibre entre intelligence, vitesse et coût.",
        "efforts": ("low", "medium", "high", "xhigh", "max", "ultra"),
        "defaultEffort": "medium",
    },
    {
        "model": "gpt-5.6-luna", "displayName": "GPT-5.6-Luna",
        "description": "Rapide et économique pour les tâches courantes.",
        "efforts": ("low", "medium", "high", "xhigh", "max"),
        "defaultEffort": "medium",
    },
)


def codex_model_catalog() -> dict[str, dict[str, Any]]:
    """Modèles visibles du CLI, dans l'ordre de son sélecteur natif."""
    raw_models: Any = None
    try:
        payload = json.loads(CODEX_MODELS_CACHE.read_text(encoding="utf-8"))
        raw_models = payload.get("models") if isinstance(payload, dict) else None
    except (OSError, json.JSONDecodeError):
        pass

    source = raw_models if isinstance(raw_models, list) else FALLBACK_CODEX_MODELS
    catalog: dict[str, dict[str, Any]] = {}
    for raw in source:
        if not isinstance(raw, dict):
            continue
        # Le cache emploie ``visibility: list`` pour ce que le sélecteur natif
        # montre. Le repli n'a pas ce champ et est donc visible lui aussi.
        if raw.get("visibility") not in (None, "list"):
            continue
        slug = raw.get("slug") or raw.get("model")
        if not isinstance(slug, str) or not slug:
            continue
        raw_efforts = raw.get("supported_reasoning_levels") or raw.get("efforts") or ()
        efforts: list[str] = []
        for entry in raw_efforts:
            effort = entry.get("effort") if isinstance(entry, dict) else entry
            if isinstance(effort, str) and effort and effort not in efforts:
                efforts.append(effort)
        if not efforts:
            efforts = list(bot.CODEX_EFFORTS)
        display_name = raw.get("display_name") or raw.get("displayName") or slug
        description = raw.get("description")
        default_effort = (
            raw.get("default_reasoning_level") or raw.get("defaultEffort") or efforts[0]
        )
        catalog[slug] = {
            "model": slug,
            "displayName": str(display_name),
            "description": str(description) if description else None,
            "efforts": tuple(efforts),
            "defaultEffort": str(default_effort),
        }

    # Une valeur imposée par l'environnement reste utilisable même si le cache
    # est ancien ou si le CLI la masque volontairement du sélecteur public.
    current = str(bot.CODEX_MODEL)
    if current not in catalog:
        catalog[current] = {
            "model": current, "displayName": current, "description": None,
            "efforts": tuple(bot.CODEX_EFFORTS),
            "defaultEffort": bot.DEFAULT_CODEX_EFFORT,
        }
    return catalog


def codex_model_efforts(model: str) -> tuple[str, ...]:
    details = codex_model_catalog().get(model)
    return tuple(details["efforts"]) if details else tuple(bot.CODEX_EFFORTS)


def _compatible_codex_effort(current: str, details: dict[str, Any]) -> str:
    allowed = tuple(details["efforts"])
    if current in allowed:
        return current
    order = {name: index for index, name in enumerate(bot.CODEX_EFFORTS)}
    current_rank = order.get(current, len(order))
    lower = [value for value in allowed if order.get(value, current_rank + 1) <= current_rank]
    if lower:
        return max(lower, key=lambda value: order.get(value, -1))
    default = str(details.get("defaultEffort") or "")
    return default if default in allowed else allowed[0]


def select_codex_model(model: str, *, persist: bool = True) -> None:
    """Applique le modèle au prochain tour et conserve un effort compatible."""
    details = codex_model_catalog().get(model)
    if details is None:
        raise ValueError(f"modèle Codex refusé : {model}")
    with bot.state_lock:
        previous_effort = bot.state["codex_effort"]
        effort = _compatible_codex_effort(previous_effort, details)
        bot.CODEX_MODEL = model
        bot.state["codex_effort"] = effort
    if effort != previous_effort:
        bot.save_effort(bot.CODEX_EFFORT_FILE, effort)
    if persist:
        try:
            CODEX_MODEL_FILE.write_text(model, encoding="utf-8")
        except OSError as exc:
            log(f"codex model save error: {exc}")


def restore_codex_model() -> None:
    try:
        saved = CODEX_MODEL_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        saved = ""
    catalog = codex_model_catalog()
    selected = saved if saved in catalog else str(bot.CODEX_MODEL)
    select_codex_model(selected, persist=False)


restore_codex_model()


# ---------------------------------------------------------------------------
# WebSocket
#
# RFC 6455 en une centaine de lignes plutôt qu'une dépendance : le serveur ne
# parle qu'à un client maison, sur du texte, derrière Caddy qui fait déjà TLS.
# ---------------------------------------------------------------------------
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WebSocket:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader = reader
        self.writer = writer
        self.closed = False
        self._send_lock = asyncio.Lock()

    @staticmethod
    async def accept(
        reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
        authorise: "Callable[[dict[str, str]], bool]",
    ) -> "WebSocket | None":
        request = await reader.readuntil(b"\r\n\r\n")
        lines = request.decode("latin-1").split("\r\n")
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                name, _, value = line.partition(":")
                headers[name.strip().lower()] = value.strip()

        key = headers.get("sec-websocket-key")
        if not key or headers.get("upgrade", "").lower() != "websocket":
            writer.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            await writer.drain()
            writer.close()
            return None

        # Refusé **avant** la mise à niveau : accepter puis fermer ouvrirait
        # brièvement une liaison qui n'aurait jamais dû exister, et confirmerait
        # à un intrus qu'il parle au bon service.
        if not authorise(headers):
            writer.write(b"HTTP/1.1 401 Unauthorized\r\n\r\n")
            await writer.drain()
            writer.close()
            return None

        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        writer.write(
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n"
            b"Sec-WebSocket-Accept: " + accept.encode() + b"\r\n\r\n"
        )
        await writer.drain()
        return WebSocket(reader, writer)

    async def receive(self) -> str | None:
        """Une trame texte, ou `None` quand la liaison se ferme."""
        buffer = ""
        while True:
            header = await self._read(2)
            if header is None:
                return None
            final = bool(header[0] & 0x80)
            opcode = header[0] & 0x0F
            masked = bool(header[1] & 0x80)
            length = header[1] & 0x7F

            if length == 126:
                extra = await self._read(2)
                if extra is None:
                    return None
                length = struct.unpack(">H", extra)[0]
            elif length == 127:
                extra = await self._read(8)
                if extra is None:
                    return None
                length = struct.unpack(">Q", extra)[0]

            mask = await self._read(4) if masked else b""
            if masked and mask is None:
                return None
            payload = await self._read(length) if length else b""
            if payload is None:
                return None
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

            if opcode == 0x8:  # fermeture
                return None
            if opcode == 0x9:  # ping → pong, sinon les mandataires coupent
                await self._frame(0xA, payload)
                continue
            if opcode == 0xA:  # pong
                continue

            buffer += payload.decode("utf-8", "replace")
            if final:
                return buffer

    async def send(self, text: str) -> None:
        await self._frame(0x1, text.encode("utf-8"))

    async def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            await self._frame(0x8, b"")
            self.writer.close()
        except Exception:
            pass

    async def _read(self, count: int) -> bytes | None:
        try:
            return await self.reader.readexactly(count)
        except (asyncio.IncompleteReadError, ConnectionError):
            return None

    async def _frame(self, opcode: int, payload: bytes) -> None:
        if self.closed:
            return
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(length)
        elif length < 65536:
            header.append(126)
            header += struct.pack(">H", length)
        else:
            header.append(127)
            header += struct.pack(">Q", length)
        async with self._send_lock:
            try:
                self.writer.write(bytes(header) + payload)
                await self.writer.drain()
            except (ConnectionError, RuntimeError):
                self.closed = True


# ---------------------------------------------------------------------------
# Traduction du flux Claude vers ACP
#
# Vocabulaire relevé sur le VPS avec `--output-format stream-json
# --include-partial-messages` (voir README) :
#
#   stream_event/content_block_start   type thinking | text | tool_use
#   stream_event/content_block_delta   thinking_delta | text_delta | input_json_delta
#   user                               tool_result → l'outil a rendu
#   result                             stop_reason, usage, coût
#   rate_limit_event                   l'état de quota, en direct
# ---------------------------------------------------------------------------
TOOL_KINDS = {
    "Read": "read", "Glob": "search", "Grep": "search",
    "Edit": "edit", "Write": "edit", "NotebookEdit": "edit",
    "Bash": "execute", "BashOutput": "execute", "KillShell": "execute",
    "WebFetch": "fetch", "WebSearch": "fetch",
    "Task": "think", "TodoWrite": "other",
}


def tool_kind(name: str) -> str:
    return TOOL_KINDS.get(name, "other")


def tool_title(name: str, payload: dict[str, Any]) -> str:
    """Ce que l'outil fait, en une ligne lisible.

    Le titre générique (« Read File ») ne dit rien ; le chemin ou la commande
    disent tout. C'est la seule information qui compte quand on relit un fil.
    """
    for key in ("command", "file_path", "path", "pattern", "url", "description"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip().splitlines()[0][:200]
    return name


def write_gap_handoff(engine: str, gap: list[dict[str, Any]], reason: str,
                      cwd: str, objective: str = "") -> str:
    """Écrit la passation à partir du delta, avec le constructeur existant."""
    with bot.state_lock:
        previous = bot.state["last_engine"]
    document = handoff_builder.build_handoff(
        continuity.journal_events(gap),
        from_engine=previous,
        to_engine=engine,
        objective=objective,
        cwd=cwd,
        git=bot.git_state(cwd),
        reason=reason,
    )
    Path(bot.HANDOFF_FILE).write_text(document, encoding="utf-8")
    return bot.HANDOFF_FILE


# Les tours en vol, par identifiant de conversation — **toutes liaisons
# confondues**. Un tour survit au socket qui l'a lancé ; le registre est ce qui
# permet à la reprise suivante de le retrouver au lieu d'en lancer un second sur
# le même fichier de conversation.
ACTIVE_TURNS: dict[str, "PromptTurn"] = {}


class PromptTurn:
    """Un tour : lance le moteur choisi, traduit sa sortie, rend un stopReason."""

    def __init__(self, session: "Session", text: str) -> None:
        self.session = session
        self.text = text
        # Franchi quand le tour a vraiment rendu la main. Un `cancel()` envoie
        # un signal ; il ne dit pas que le processus est mort, et repartir avant
        # remettrait deux moteurs sur le même fichier.
        self.finished = asyncio.Event()
        self.process: asyncio.subprocess.Process | None = None
        self.cancelled = False
        self.tools: dict[str, dict[str, Any]] = {}
        self.message_id = str(uuid.uuid4())
        self.thought_id = str(uuid.uuid4())
        self.stderr = ""
        self.recovered = False
        self.reply = ""
        self.engine: str | None = None
        self.model: str | None = None
        # `--output-last-message` ne doit pas être partagé entre deux fils
        # Codex lancés en parallèle. Le flux JSON reste la source principale ;
        # ce fichier propre au tour est le filet si le CLI omet l'événement.
        self.codex_last_message = f"{bot.CODEX_LAST_MESSAGE}.{session.id}"

    async def run(self) -> str:
        engine = bot.engine_for_next_task()
        self.engine = engine
        task = {"text": self.text, "cwd": self.session.cwd, "id": str(uuid.uuid4())}

        # Le fil d'abord : la demande fait partie de ce que le moteur entrant
        # doit voir, même si c'est lui qui va y répondre.
        continuity.record(self.session.cwd, self.session.id, "user", self.text)

        # La passation ne contient que ce que ce moteur-là n'a pas vu **dans
        # cette conversation**. Rester sur le même moteur n'en produit aucune ;
        # basculer en produit une qui tient dans les tours manquants, jamais
        # dans tout l'historique.
        handoff_path = None
        gap = continuity.missing(self.session.cwd, self.session.id, engine)
        # Le dernier élément est la demande en cours : elle part par le prompt,
        # pas par le contexte.
        gap = gap[:-1] if gap and gap[-1].get("role") == "user" else gap
        if gap:
            known = continuity.has_history(self.session.cwd, self.session.id, engine)
            reason = ("rattrapage : %d tour(s) menés sans toi" % len(gap)) if known \
                else "reprise d'une conversation que tu découvres"
            handoff_path = await asyncio.to_thread(
                self._write_gap_handoff, engine, gap, reason
            )
            await self.session.notify_engine(engine, reason)

        bot.journal("message", text=bot.truncate(self.text), cwd=self.session.cwd,
                    git=bot.git_state(self.session.cwd), next_engine=engine)

        watcher = asyncio.create_task(self._watch_permissions())
        try:
            stop_reason = (
                await self._run_claude(handoff_path) if engine == "claude"
                else await self._run_codex(handoff_path, task)
            )
        finally:
            watcher.cancel()

        if self.reply.strip():
            continuity.record(
                self.session.cwd, self.session.id, "assistant", self.reply, engine=engine
            )
            bot.journal("response", engine=engine,
                        text=bot.truncate(self.reply, bot.MAX_JOURNAL_RESPONSE),
                        cwd=self.session.cwd, git=bot.git_state(self.session.cwd))

        # Ce moteur a maintenant tout vu de cette conversation.
        continuity.acknowledge(self.session.cwd, self.session.id, engine)
        with bot.state_lock:
            bot.state["last_engine"] = engine
        bot.persist_state_key("last_engine")
        return stop_reason

    def _write_gap_handoff(self, engine: str, gap: list[dict[str, Any]], reason: str) -> str:
        return write_gap_handoff(engine, gap, reason, self.session.cwd, self.text)

    # Trente-deux mégaoctets : de quoi contenir n'importe quel événement d'un
    # des deux moteurs, y compris le résultat d'une lecture de gros fichier.
    STREAM_LIMIT = 32 * 1024 * 1024

    async def _read_event(self, stream: asyncio.StreamReader) -> bytes:
        """Une ligne d'événement, ou vide à la fin du flux.

        Une ligne plus longue que le tampon est **sautée**, jamais fatale : le
        tour continue en perdant un événement, au lieu de s'arrêter net sur une
        exception. La limite est déjà large ; ceci est la ceinture qui va avec
        les bretelles, parce que le prix d'une erreur ici se paie sous la forme
        d'une conversation qui se fige sans explication.
        """
        while True:
            try:
                return await stream.readline()
            except ValueError:
                log("événement au-delà du tampon, sauté")
                # `readline` a laissé la ligne dans le tampon : on la jette
                # jusqu'au prochain saut de ligne pour reprendre sur un
                # événement entier.
                while True:
                    chunk = await stream.read(65536)
                    if not chunk:
                        return b""
                    if b"\n" in chunk:
                        break

    # -- Claude : le seul chemin réellement streamé -------------------------

    async def _run_claude(self, handoff_path: str | None) -> str:
        # L'identifiant vient de la conversation ouverte, pas d'un état global :
        # c'est ce qui permet d'avoir plusieurs fils par projet et de reprendre
        # celui qu'on a choisi, des semaines plus tard.
        session_id = self.session.id
        resume = store.exists(self.session.cwd, session_id)
        with bot.state_lock:
            model = bot.state["model"]
            effort = bot.state["claude_effort"]
            bot.state["claude_session_id"] = session_id
        bot.persist_state_key("claude_session_id")

        args = [
            "claude", "-p", self.text,
            "--output-format", "stream-json", "--include-partial-messages", "--verbose",
            "--allowedTools", *bot.ALLOWED_TOOLS,
            "--settings", bot.SETTINGS,
            "--model", bot.MODELS[model][0],
            "--effort", effort,
        ]
        args += ["--resume", session_id] if resume else ["--session-id", session_id]
        if handoff_path:
            args += ["--append-system-prompt-file", handoff_path]

        log(f"claude cwd={self.session.cwd} session={session_id} resume={resume}")
        reason = await self._stream(args)

        # Une session native peut avoir disparu — expirée, ou créée dans un
        # autre répertoire. `bot.py` repart alors à neuf en emportant une
        # passation pour ne rien perdre ; on fait exactement pareil, sinon la
        # première demande après un redémarrage échoue toujours.
        if reason == "refusal" and resume and bot.is_stale_session(self.stderr):
            with bot.state_lock:
                bot.state["claude_session_id"] = None
            bot.persist_state_key("claude_session_id")
            bot.journal("session_reset", engine="claude")
            log("session périmée, reprise à neuf")
            recovery = await asyncio.to_thread(
                bot.write_handoff, "claude", self.text, self.session.cwd,
                "session perdue, contexte reconstruit",
            )
            self.stderr = ""
            self.recovered = True
            return await self._run_claude(recovery)
        return reason

    async def _stream(self, args: list[str]) -> str:
        self.process = await asyncio.create_subprocess_exec(
            *args, cwd=self.session.cwd,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
            # La même limite que pour Codex, et pour la même raison — sauf
            # qu'ici elle manquait, sur le chemin qui sert tous les jours.
            #
            # Un événement de Claude tient sur **une** ligne, et certains sont
            # énormes : le résultat d'une lecture de fichier, une longue
            # réponse, une image encodée. Au-delà des 64 Kio par défaut,
            # `readline` ne tronque pas — il lève. Le tour mourait alors en
            # plein milieu sur une `ValueError`, l'app recevait un `-32602`
            # qu'elle n'affichait nulle part, et le dernier outil restait « en
            # cours » pour toujours. C'est très exactement le symptôme de la
            # réponse qui « s'arrête d'écrire ».
            limit=self.STREAM_LIMIT,
        )
        stop_reason = "end_turn"
        assert self.process.stdout is not None

        while True:
            line = await self._read_event(self.process.stdout)
            if not line:
                break
            line = line.strip()
            if not line.startswith(b"{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            reason = await self._translate(event)
            if reason:
                stop_reason = reason

        stderr = b""
        if self.process.stderr is not None:
            stderr = await self.process.stderr.read()
        await self.process.wait()

        if self.cancelled:
            return "cancelled"

        if self.process.returncode != 0:
            failure = stderr.decode("utf-8", "replace").strip()
            self.stderr = failure
            if bot.is_stale_session(failure):
                # Le rattrapage s'en charge : afficher l'erreur ici ferait
                # clignoter un échec que l'utilisateur ne verra jamais aboutir.
                return "refusal"
            # Une erreur de quota n'est pas un échec de tâche : elle bascule le
            # moteur, comme sur Telegram, et la prochaine demande partira chez
            # l'autre.
            if bot.is_quota_error(failure):
                bot.mark_claude_unavailable("quota atteint (CLI)")
                await self.session.notify_engine("codex", "quota Claude atteint")
            if failure:
                await self.session.send_text(f"\n\n⚠️ {failure[:800]}", self.message_id)
                return "refusal"
        return stop_reason

    async def _translate(self, event: dict[str, Any]) -> str | None:
        kind = event.get("type")

        if kind == "system" and event.get("subtype") == "init":
            # Claude énumère ici ses commandes — les intégrées comme celles
            # apportées par les skills et les plugins. On les relaie telles
            # quelles : les inventer côté app les ferait diverger au premier
            # plugin installé.
            commands = event.get("slash_commands") or []
            if commands:
                await self.session.update({
                    "sessionUpdate": "available_commands_update",
                    "availableCommands": [
                        {"name": str(name), "description": None} for name in commands
                    ],
                })
            return None

        if kind == "stream_event":
            await self._translate_stream(event.get("event") or {})
            return None

        if kind == "user":
            # Un `tool_result` : l'outil correspondant vient de rendre.
            for block in (event.get("message") or {}).get("content") or []:
                if block.get("type") != "tool_result":
                    continue
                await self._finish_tool(
                    str(block.get("tool_use_id") or ""),
                    failed=bool(block.get("is_error")),
                    content=block.get("content"),
                )
            return None

        if kind == "rate_limit_event":
            info = event.get("rate_limit_info") or {}
            if info.get("status") in {"blocked", "rejected"}:
                bot.mark_claude_unavailable("quota atteint (API)")
                await self.session.notify_engine("codex", "quota Claude atteint")
            return None

        if kind == "result":
            usage = event.get("usage") or {}
            # `cache_creation_input_tokens` manquait, et c'est justement le gros
            # morceau : sur une session reprise il pèse plus que tout le reste.
            # Le contexte affiché était donc faux — trop bas d'un facteur deux.
            used = sum(int(usage.get(key, 0) or 0) for key in (
                "input_tokens", "cache_creation_input_tokens",
                "cache_read_input_tokens", "output_tokens",
            ))
            await self.session.send_status(used=used)
            return "refusal" if event.get("is_error") else str(
                event.get("stop_reason") or "end_turn"
            )

        return None

    async def _translate_stream(self, inner: dict[str, Any]) -> None:
        kind = inner.get("type")

        if kind == "message_start":
            # Un tour de Claude, ce n'est pas *un* message : c'est une suite de
            # messages séparés par les outils qu'il appelle. Leur donner à tous
            # le même identifiant les faisait fusionner côté client en un seul
            # bloc, posé là où le premier était arrivé — donc **avant** les
            # commandes qui l'ont pourtant précédé. Le fil racontait l'histoire
            # dans le désordre. Un identifiant par message la remet d'aplomb.
            self.message_id = str(uuid.uuid4())
            self.thought_id = str(uuid.uuid4())
            return

        if kind == "content_block_start":
            block = inner.get("content_block") or {}
            if block.get("type") == "tool_use":
                tool_id = str(block.get("id") or uuid.uuid4())
                name = str(block.get("name") or "outil")
                self.tools[str(inner.get("index"))] = {"id": tool_id, "name": name}
                await self.session.update({
                    "sessionUpdate": "tool_call",
                    "toolCallId": tool_id,
                    "title": name,
                    "kind": tool_kind(name),
                    "status": "in_progress",
                    "_meta": {"claudeCode": {"toolName": name}},
                })
            return

        if kind == "content_block_delta":
            delta = inner.get("delta") or {}
            delta_kind = delta.get("type")
            if delta_kind == "text_delta":
                chunk = str(delta.get("text") or "")
                self.reply += chunk
                await self.session.send_text(chunk, self.message_id)
            elif delta_kind == "thinking_delta":
                await self.session.send_thought(
                    str(delta.get("thinking") or ""), self.thought_id
                )
            elif delta_kind == "input_json_delta":
                # Les arguments d'un outil arrivent par fragments de JSON ; on
                # les recolle pour pouvoir titrer l'appel avec la commande
                # réelle plutôt qu'avec le nom générique de l'outil.
                entry = self.tools.get(str(inner.get("index")))
                if entry is not None:
                    entry["json"] = entry.get("json", "") + str(delta.get("partial_json") or "")
            return

        if kind == "content_block_stop":
            entry = self.tools.get(str(inner.get("index")))
            if entry and entry.get("json"):
                try:
                    payload = json.loads(entry["json"])
                except json.JSONDecodeError:
                    payload = {}
                if payload:
                    entry["payload"] = payload
                    await self.session.update({
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": entry["id"],
                        "title": tool_title(entry["name"], payload),
                        "rawInput": payload,
                    })
            return

    async def _finish_tool(self, tool_use_id: str, failed: bool,
                           content: Any) -> None:
        entry = next((e for e in self.tools.values() if e["id"] == tool_use_id), None)
        if entry is None:
            return
        text = content if isinstance(content, str) else ""
        if isinstance(content, list):
            text = "\n".join(
                str(part.get("text") or "") for part in content
                if isinstance(part, dict) and part.get("type") == "text"
            )
        update: dict[str, Any] = {
            "sessionUpdate": "tool_call_update",
            "toolCallId": tool_use_id,
            "status": "failed" if failed else "completed",
        }
        if text.strip():
            # La sortie d'un outil peut faire des milliers de lignes ; le
            # client n'en affiche que le début tant qu'on ne la déplie pas.
            update["content"] = [{
                "type": "content",
                "content": {"type": "text", "text": text[:4000]},
            }]
        await self.session.update(update)

    # -- Codex : pas de flux, mais la même bascule et la même passation -----

    async def _run_codex(self, handoff_path: str | None, task: dict[str, Any]) -> str:
        """Codex, rendu comme Claude : au fil de l'eau, et interruptible.

        Il passait par `bot.run_codex`, un appel bloquant lancé dans un thread.
        Deux conséquences que l'app rendait très visibles. Rien ne s'affichait
        avant la fin — sur une tâche longue, l'écran paraissait figé. Et le
        processus n'était connu de personne, donc le bouton d'arrêt ne
        l'atteignait pas : on appuyait, il ne se passait rien.

        `codex exec --json` n'émet pas de jetons — pas de streaming mot à mot,
        contrairement à Claude. Mais il émet **chaque élément dès qu'il est
        terminé** : un message, une commande avec sa sortie et son code de
        retour. C'est assez pour que le fil vive, et pour qu'on voie ce qu'il
        fait pendant qu'il le fait.

        Son fil reste celui de **cette** conversation : `bot.py` n'en gardait
        qu'un pour tout le monde, si bien que reprendre une discussion donnait à
        Codex le contexte d'une autre.
        """
        # Le CLI n'émet le texte d'une réponse qu'une fois celle-ci terminée.
        # Sur une réponse longue, l'app n'avait donc aucun bloc vivant et
        # ressemblait exactement à un tour bloqué. Ce morceau ouvre tout de
        # suite un raisonnement en cours ; le `stopReason` le refermera.
        await self.session.send_thought("Codex travaille…", self.thought_id)

        prompt = bot.task_prompt("codex", task)
        mine = store.codex_thread(self.session.cwd, self.session.id)

        reason = await self._codex_attempt(prompt, handoff_path, mine)

        # Une session Codex peut avoir disparu. On repart à neuf plutôt que de
        # renvoyer une erreur que l'utilisateur ne peut pas corriger.
        if reason == "refusal" and mine and bot.is_stale_session(self.stderr):
            store.remember_codex_thread(self.session.cwd, self.session.id, "")
            bot.journal("session_reset", engine="codex")
            reason = await self._codex_attempt(prompt, handoff_path, None)

        if reason == "refusal" and bot.is_codex_quota_error(self.stderr):
            bot.mark_codex_unavailable("quota atteint")
            await self.session.notify_engine("claude", "quota Codex atteint")
        return reason

    async def _codex_attempt(self, prompt: str, handoff_path: str | None,
                             thread: str | None) -> str:
        with bot.state_lock:
            effort = bot.state["codex_effort"]
            model = str(bot.CODEX_MODEL)
        # Le statut de ce tour doit garder son véritable auteur même si un
        # autre client change le modèle global pendant qu'il travaille.
        self.model = model
        common = [
            "--model", model, "--json",
            "-c", f'model_reasoning_effort="{effort}"',
            "--output-last-message", self.codex_last_message,
            "--dangerously-bypass-approvals-and-sandbox",
            "--skip-git-repo-check",
        ]
        if thread:
            # `codex exec resume` refuse --cd : le dossier vient du cwd.
            args = ["codex", "exec", "resume", thread, *common, prompt]
        else:
            args = ["codex", "exec", *common, "--cd", self.session.cwd, prompt]

        log(f"codex model={model} cwd={self.session.cwd} "
            f"thread={thread or 'nouveau'} handoff={bool(handoff_path)}")
        return await self._stream_codex(args, handoff_path)

    async def _stream_codex(self, args: list[str], handoff_path: str | None) -> str:
        # Codex n'a pas d'option « fichier de contexte » : son entrée standard
        # est prévue pour ça, et la passation y arrive dans un bloc distinct.
        try:
            Path(self.codex_last_message).unlink()
        except OSError:
            pass

        stdin = open(handoff_path, "rb") if handoff_path else asyncio.subprocess.DEVNULL
        try:
            self.process = await asyncio.create_subprocess_exec(
                *args, cwd=self.session.cwd,
                stdin=stdin, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, start_new_session=True,
                # Une ligne JSON contient le message complet. La limite asyncio
                # par défaut (64 Kio) coupe donc précisément les longues
                # réponses que ce chemin doit savoir rendre.
                limit=self.STREAM_LIMIT,
            )
        finally:
            if handoff_path:
                stdin.close()

        stop_reason = "end_turn"
        assert self.process.stdout is not None
        while True:
            line = await self._read_event(self.process.stdout)
            if not line:
                break
            line = line.strip()
            if not line.startswith(b"{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            reason = await self._translate_codex(event)
            if reason:
                stop_reason = reason

        stderr = b""
        if self.process.stderr is not None:
            stderr = await self.process.stderr.read()
        await self.process.wait()
        process_stderr = stderr.decode("utf-8", "replace").strip()
        if process_stderr:
            self.stderr = "\n".join(part for part in (self.stderr, process_stderr) if part)

        # La documentation du CLI garantit aussi la réponse finale dans `-o`.
        # Le flux JSON est normalement suffisant, mais ce repli empêche un tour
        # réussi de finir sans rien afficher si un événement manque.
        if not self.reply.strip():
            try:
                fallback = Path(self.codex_last_message).read_text(encoding="utf-8").strip()
            except OSError:
                fallback = ""
            if fallback:
                self.reply = fallback
                await self.session.send_text(fallback, str(uuid.uuid4()))
        try:
            Path(self.codex_last_message).unlink()
        except OSError:
            pass

        if self.cancelled:
            return "cancelled"
        if self.process.returncode not in (0, None):
            failure = self.stderr.strip() or "erreur Codex sans détail"
            await self.session.send_text(f"\n\n⚠️ {failure[:800]}\n\n", str(uuid.uuid4()))
            return "refusal"
        if not self.reply.strip():
            # Un code 0 sans `agent_message` n'est pas une réussite. C'était le
            # cas le plus trompeur : le serveur répondait `end_turn`, le bouton
            # d'arrêt disparaissait, mais Codex n'avait jamais répondu.
            failure = self.stderr.strip() or "Codex a terminé sans message final."
            self.stderr = failure
            await self.session.send_text(f"\n\n⚠️ {failure[:800]}\n\n", str(uuid.uuid4()))
            return "refusal"
        return stop_reason

    async def _translate_codex(self, event: dict[str, Any]) -> str | None:
        kind = event.get("type")

        if kind == "error":
            self.stderr = self._codex_error(event) or self.stderr
            return None

        if kind == "thread.started" and event.get("thread_id"):
            store.remember_codex_thread(
                self.session.cwd, self.session.id, str(event["thread_id"])
            )
            return None

        if kind == "turn.completed":
            return "end_turn"
        if kind == "turn.failed":
            self.stderr = self._codex_error(event) or self.stderr
            return "refusal"

        if kind not in {"item.started", "item.updated", "item.completed"}:
            return None

        item = event.get("item") or {}
        done = kind == "item.completed"

        if item.get("type") == "agent_message":
            if not done:
                return None
            text = str(item.get("text") or "")
            if text:
                # Un identifiant par message : les remettre tous sous le même
                # ferait remonter la conclusion au-dessus des commandes qui
                # l'ont produite.
                self.reply = text
                await self.session.send_text(text, str(uuid.uuid4()))
            return None

        updates = radiography_events.codex_tool_updates(
            str(kind), item, self.session.cwd
        )
        if updates:
            for update in updates:
                await self.session.update(update)
            return None

        return None

    @staticmethod
    def _codex_error(event: dict[str, Any]) -> str:
        """Le message lisible des variantes `error` et `turn.failed`."""
        direct = event.get("message")
        if isinstance(direct, str):
            return direct.strip()
        error = event.get("error")
        if isinstance(error, str):
            return error.strip()
        if isinstance(error, dict):
            message = error.get("message")
            if isinstance(message, str):
                return message.strip()
            return json.dumps(error, ensure_ascii=False)
        return ""

    # -- Permissions --------------------------------------------------------
    #
    # `confirm_hook.py` (PreToolUse) écrit `state/pending` avec la commande
    # jugée dangereuse, puis attend `state/decision` pendant cinq minutes. On
    # ne touche pas au hook : on se contente de guetter ce fichier et de
    # traduire l'attente en `session/request_permission`. Sans ça, une commande
    # dangereuse lancée depuis l'app gelait le tour sans rien afficher, jusqu'à
    # un refus par expiration.

    PENDING = os.path.join(BASE, "state", "pending")
    DECISION = os.path.join(BASE, "state", "decision")

    async def _watch_permissions(self) -> None:
        # Une tâche détachée avale ses exceptions : sans ce filet, un guetteur
        # qui meurt à la première boucle laisse passer *toutes* les commandes
        # dangereuses sans que rien ne le signale. C'est exactement ce qui
        # arrivait.
        try:
            await self._watch_pending()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log(f"guetteur de permissions arrêté : {exc!r}")

    async def _watch_pending(self) -> None:
        handled: str | None = None
        while True:
            await asyncio.sleep(0.4)
            try:
                command = Path(self.PENDING).read_text(encoding="utf-8").strip()
            except OSError:
                handled = None
                continue
            if not command or command == handled:
                continue
            handled = command
            if self.session.connection._permission_mode() == "auto":
                # Décidé d'avance, dans l'app : on ne réveille personne.
                try:
                    Path(self.DECISION).write_text("allow", encoding="utf-8")
                except OSError as exc:
                    log(f"décision non écrite : {exc}")
                bot.journal("acp_permission", command=bot.truncate(command), verdict="auto")
                continue
            await self._ask_permission(command)

    async def _ask_permission(self, command: str) -> None:
        tool_call_id = str(uuid.uuid4())
        await self.session.update({
            "sessionUpdate": "tool_call",
            "toolCallId": tool_call_id,
            "title": command,
            "kind": "execute",
            "status": "pending",
            "_meta": {"claudeCode": {"toolName": "Bash"}},
        })

        try:
            answer = await self.session.connection.request("session/request_permission", {
                "sessionId": self.session.id,
                "toolCall": {
                    "toolCallId": tool_call_id,
                    "title": "Bash",
                    "kind": "execute",
                    "rawInput": {"command": command},
                    "_meta": {"claudeCode": {"toolName": "Bash"}},
                },
                "options": [
                    {"optionId": "deny", "name": "Refuser", "kind": "reject_once"},
                    {"optionId": "allow", "name": "Exécuter", "kind": "allow_once"},
                ],
            })
        except Exception as exc:  # noqa: BLE001
            log(f"demande de permission perdue : {exc}")
            return

        outcome = (answer or {}).get("outcome") or {}
        allowed = outcome.get("outcome") == "selected" and outcome.get("optionId") == "allow"

        # Le hook relit ce fichier chaque seconde ; il fait le reste.
        try:
            Path(self.DECISION).write_text("allow" if allowed else "deny", encoding="utf-8")
        except OSError as exc:
            log(f"décision non écrite : {exc}")

        await self.session.update({
            "sessionUpdate": "tool_call_update",
            "toolCallId": tool_call_id,
            "status": "in_progress" if allowed else "failed",
        })
        bot.journal("acp_permission", command=bot.truncate(command),
                    verdict="allow" if allowed else "deny")

    async def cancel(self) -> None:
        self.cancelled = True
        if self.process and self.process.returncode is None:
            bot._signal_process_group(self.process, 15)


# ---------------------------------------------------------------------------
# Session ACP
# ---------------------------------------------------------------------------
def quota_snapshot(engine: str = "claude") -> dict[str, Any]:
    """Les plafonds du moteur actif, tels que leurs sondes les ont relevés.

    Claude vient du snapshot de son moniteur. Codex vient du tableau de quotas
    local, lui-même alimenté par `account/rateLimits/read` de `codex app-server`.
    On ne mélange jamais les deux : montrer le 5 h Claude sous une pastille
    Codex était une donnée vraie attribuée au mauvais moteur — donc fausse.
    """
    if engine == "codex":
        return codex_quota_snapshot()

    try:
        raw = json.loads(Path(bot.CLAUDE_USAGE_STATE).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    usage = raw.get("usage_raw") or {}
    windows = {}
    for key in ("five_hour", "seven_day"):
        entry = usage.get(key) or {}
        percent = entry.get("utilization")
        if percent is None:
            continue
        windows[key] = {
            "percent": round(float(percent)),
            "resetsAt": entry.get("resets_at"),
        }
    return windows


def codex_quota_snapshot() -> dict[str, Any]:
    """Les fenêtres Codex déjà mises en cache par le service de quotas local."""
    request = urllib.request.Request(QUOTA_WEB_URL)
    if QUOTA_WEB_TOKEN:
        request.add_header("Authorization", f"Bearer {QUOTA_WEB_TOKEN}")
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return {}

    codex = payload.get("codex") if isinstance(payload, dict) else None
    if not isinstance(codex, dict):
        return {}

    windows: dict[str, Any] = {}
    # Le service nomme les fenêtres par leur durée réelle ; ACP garde les noms
    # employés par la structure `SessionStatus` du client.
    for source, target in (("short", "five_hour"), ("weekly", "seven_day")):
        entry = codex.get(source)
        if not isinstance(entry, dict) or entry.get("used_percent") is None:
            continue
        try:
            percent = round(float(entry["used_percent"]))
        except (TypeError, ValueError):
            continue
        windows[target] = {
            "percent": percent,
            "resetsAt": entry.get("resets_at"),
        }
    return windows


def session_catalog(cwd: str) -> list[dict[str, Any]]:
    """Fusionne les fils natifs Claude et le fil commun utilisé par Codex."""
    merged: dict[str, dict[str, Any]] = {}
    for session in store.list_sessions(cwd):
        session_id = str(session.get("sessionId") or "")
        if session_id:
            merged[session_id] = dict(session)

    for session in continuity.list_sessions(cwd):
        session_id = str(session.get("sessionId") or "")
        if not session_id:
            continue
        current = merged.get(session_id)
        if current is None:
            merged[session_id] = dict(session)
            continue
        current["updatedAt"] = max(
            str(current.get("updatedAt") or ""),
            str(session.get("updatedAt") or ""),
        )
        current["exchanges"] = max(
            int(current.get("exchanges") or 0),
            int(session.get("exchanges") or 0),
        )

    sessions = list(merged.values())
    sessions.sort(key=lambda session: str(session.get("updatedAt") or ""), reverse=True)
    return sessions


class Session:
    """Une session de conversation, adossée aux sessions natives de `bot.py`."""

    def __init__(self, connection: "Connection", session_id: str, cwd: str) -> None:
        self.connection = connection
        self.id = session_id
        self.cwd = cwd
        self.turn: PromptTurn | None = None

    async def send_status(self, used: int = 0, size: int = 0) -> None:
        """L'état complet, sur le même canal que la consommation de contexte.

        Les plafonds voyagent dans `_meta` : un client ACP ordinaire les ignore,
        Hublot les affiche. Rien n'est cassé pour personne.
        """
        # Au repos, la barre suit le choix explicite — même si son quota impose
        # momentanément un relais. Pendant un tour, le moteur qui travaille
        # gagne : il serait tout aussi trompeur d'afficher Claude pendant que
        # Codex exécute réellement la demande.
        with bot.state_lock:
            pinned = bot.state["manual_engine"]
        engine = (
            self.turn.engine if self.turn and self.turn.engine
            else str(pinned or bot.engine_for_next_task())
        )
        with bot.state_lock:
            if engine == "codex":
                model_label = (
                    self.turn.model if self.turn and self.turn.model else str(bot.CODEX_MODEL)
                )
                effort = bot.state["codex_effort"]
                context_size = size
            else:
                model = bot.state["model"]
                model_label = bot.MODELS[model][1]
                effort = bot.state["claude_effort"]
                context_size = size or bot.MODELS[model][2]
        limits = await asyncio.to_thread(quota_snapshot, engine)
        await self.update({
            "sessionUpdate": "usage_update",
            "used": used,
            "size": context_size,
            "_meta": {"hublot": {
                "model": model_label,
                "effort": effort,
                "engine": engine,
                "limits": limits,
            }},
        })

    async def update(self, payload: dict[str, Any], *, persist: bool = True) -> None:
        if persist:
            continuity.record_tool(self.cwd, self.id, payload)
        await self.connection.notify("session/update", {
            "sessionId": self.id, "update": payload,
        })

    async def send_text(self, text: str, message_id: str) -> None:
        if not text:
            return
        await self.update({
            "sessionUpdate": "agent_message_chunk",
            "messageId": message_id,
            "content": {"type": "text", "text": text},
        })

    async def send_thought(self, text: str, message_id: str) -> None:
        if not text:
            return
        await self.update({
            "sessionUpdate": "agent_thought_chunk",
            "messageId": message_id,
            "content": {"type": "text", "text": text},
        })

    async def notify_engine(self, engine: str, reason: str) -> None:
        """La bascule se dit dans le fil.

        Sur Telegram elle arrivait en message ; ici elle doit rester visible,
        sinon on croit lire Claude alors que Codex répond.
        """
        await self.send_text(
            f"\n\n> Moteur : **{engine}** — {reason}.\n\n", str(uuid.uuid4())
        )


class Connection:
    """Une liaison client : le multiplexage JSON-RPC et les sessions ouvertes."""

    def __init__(self, socket: WebSocket) -> None:
        self.socket = socket
        self.sessions: dict[str, Session] = {}
        self.next_id = 1
        self.pending: dict[int, asyncio.Future[Any]] = {}

    # -- Émission ----------------------------------------------------------

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        await self.socket.send(json.dumps(
            {"jsonrpc": "2.0", "method": method, "params": params}
        ))

    async def request(self, method: str, params: dict[str, Any]) -> Any:
        identifier = self.next_id
        self.next_id += 1
        future: asyncio.Future[Any] = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        await self.socket.send(json.dumps(
            {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}
        ))
        return await future

    async def reply(self, identifier: Any, result: Any) -> None:
        await self.socket.send(json.dumps(
            {"jsonrpc": "2.0", "id": identifier, "result": result}
        ))

    async def fail(self, identifier: Any, code: int, message: str) -> None:
        await self.socket.send(json.dumps(
            {"jsonrpc": "2.0", "id": identifier,
             "error": {"code": code, "message": message}}
        ))

    # -- Réception ---------------------------------------------------------

    async def serve(self) -> None:
        while True:
            raw = await self.socket.receive()
            if raw is None:
                break
            for line in raw.split("\n"):
                if line.strip():
                    asyncio.create_task(self._dispatch(line))

    async def _dispatch(self, line: str) -> None:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            return

        identifier = message.get("id")
        method = message.get("method")

        # Réponse à une requête qu'on a émise (permission).
        if method is None and identifier in self.pending:
            future = self.pending.pop(identifier)
            if not future.done():
                future.set_result(message.get("result"))
            return

        if method is None:
            return

        try:
            result = await self._handle(method, message.get("params") or {})
        except LookupError as exc:
            if identifier is not None:
                await self.fail(identifier, RPCErrorCode.METHOD_NOT_FOUND, str(exc))
            return
        except (ValueError, PermissionError, FileNotFoundError) as exc:
            # Paramètre refusé : c'est la demande qui est fautive, pas nous.
            if identifier is not None:
                await self.fail(identifier, RPCErrorCode.INVALID_PARAMS, str(exc))
            return
        except Exception as exc:  # noqa: BLE001 — une erreur ne doit pas tuer la liaison
            log(f"{method} a échoué : {exc}")
            if identifier is not None:
                await self.fail(identifier, RPCErrorCode.INTERNAL, str(exc))
            return

        if identifier is not None:
            await self.reply(identifier, result if result is not None else {})

    async def _handle(self, method: str, params: dict[str, Any]) -> Any:
        if method == "initialize":
            return self._initialize()
        if method == "session/new":
            return await self._new_session(params)
        if method == "session/load":
            return await self._load_session(params)
        if method == "session/list":
            return self._list_sessions(params)
        if method == "hublot/projects":
            return self._list_projects()
        if method == "hublot/instructions":
            return self._instructions(params)
        if method == "hublot/transcribe":
            return await self._transcribe(params)
        if method == "session/delete":
            return await self._delete_session(params)
        if method == "session/prompt":
            return await self._prompt(params)
        if method == "session/cancel":
            return await self._cancel(params)
        if method == "session/set_config_option":
            return await self._set_config_option(params)
        raise LookupError(f'"Method not found": {method}')

    # -- Méthodes ----------------------------------------------------------

    def _initialize(self) -> dict[str, Any]:
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "agentCapabilities": {
                "loadSession": True,
                "promptCapabilities": {"image": True, "embeddedContext": False},
                # `resume` n'est pas annoncé : on ne l'implémente pas, et le
                # client doit pouvoir se fier à ce qu'on déclare.
                "sessionCapabilities": {"list": {}, "delete": {}},
            },
            "agentInfo": {
                "name": "tg-claude-acp", "title": "Relais VPS", "version": "1.0.0",
            },
            "authMethods": [],
        }

    PERMISSION_FILE = os.path.join(BASE, "state", "acp-permission")

    def _permission_mode(self) -> str:
        try:
            value = Path(self.PERMISSION_FILE).read_text(encoding="utf-8").strip()
        except OSError:
            return "ask"
        return value if value in {"ask", "auto"} else "ask"

    @staticmethod
    def _configured_engine() -> str:
        """Le moteur dont les réglages sont édités, même s'il est à plat.

        Le moteur *effectif* peut être son relais de quota. Utiliser ce dernier
        pour construire les menus donnait précisément « Claude · GPT-5.6 » :
        l'épingle disait Claude, mais la liste de modèles suivait Codex.
        """
        with bot.state_lock:
            pinned = bot.state["manual_engine"]
        return str(pinned or bot.engine_for_next_task())

    def _config_options(self) -> list[dict[str, Any]]:
        """Les réglages du relais, décrits pour que le client n'invente rien.

        Le moteur est **un seul** sélecteur — `auto`, `claude` ou `codex` — et
        les réglages suivants dépendent de lui : proposer « Opus 4.8 » pendant
        que Codex répond n'avait aucun sens.
        """
        with bot.state_lock:
            model = bot.state["model"]
            claude_effort = bot.state["claude_effort"]
            codex_effort = bot.state["codex_effort"]
            codex_model = str(bot.CODEX_MODEL)
            pinned = bot.state["manual_engine"]

        active = bot.engine_for_next_task()
        configured = str(pinned or active)
        engine_label = {"auto": "Auto", "claude": "Claude", "codex": "Codex"}

        options = [{
            "id": "engine", "name": "Moteur", "category": "mode", "type": "select",
            "description": "Auto suit la bascule de quota ; un choix explicite la contourne.",
            "currentValue": pinned or "auto",
            "options": [
                {"value": "auto", "name": f"Auto · {engine_label[active]}",
                 "description": "Claude, puis Codex quand le quota est atteint"},
                {"value": "claude", "name": "Claude"},
                {"value": "codex", "name": "Codex"},
            ],
        }]

        if configured == "codex":
            catalog = codex_model_catalog()
            model_details = catalog.get(codex_model)
            efforts = tuple(model_details["efforts"]) if model_details else bot.CODEX_EFFORTS
            options.append({
                "id": "model", "name": "Modèle", "category": "model", "type": "select",
                "currentValue": codex_model,
                "options": [{
                    "value": slug,
                    "name": details["displayName"],
                    "description": details["description"],
                } for slug, details in catalog.items()],
            })
            options.append({
                "id": "effort", "name": "Effort", "category": "thought_level",
                "type": "select", "currentValue": codex_effort,
                "options": [{"value": e, "name": e.capitalize()} for e in efforts],
            })
        else:
            options.append({
                "id": "model", "name": "Modèle", "category": "model", "type": "select",
                "currentValue": model,
                "options": [{"value": key, "name": label}
                            for key, (_, label, _) in bot.MODELS.items()],
            })
            options.append({
                "id": "effort", "name": "Effort", "category": "thought_level",
                "type": "select", "currentValue": claude_effort,
                "options": [{"value": e, "name": e.capitalize()} for e in bot.CLAUDE_EFFORTS],
            })

        options.append({
            "id": "permission", "name": "Permissions", "category": "mode",
            "type": "select", "currentValue": self._permission_mode(),
            "description": "Qui tranche quand une commande est jugée dangereuse.",
            "options": [
                {"value": "ask", "name": "Demander",
                 "description": "L'app pose la question et attend"},
                {"value": "auto", "name": "Tout autoriser",
                 "description": "Exécute sans demander"},
            ],
        })
        return options

    async def _set_config_option(self, params: dict[str, Any]) -> dict[str, Any]:
        config_id = str(params.get("configId") or "")
        value = str(params.get("value") or "")
        switched = False

        if config_id == "permission":
            if value not in {"ask", "auto"}:
                raise ValueError(f"mode de permission inconnu : {value}")
            Path(self.PERMISSION_FILE).write_text(value, encoding="utf-8")
            bot.journal("acp_permission_mode", mode=value)
        elif config_id == "engine":
            if value not in {"auto", "claude", "codex"}:
                raise ValueError(f"moteur inconnu : {value}")
            with bot.state_lock:
                bot.state["manual_engine"] = None if value == "auto" else value
            bot.persist_state_key("manual_engine")
            bot.journal("acp_switch", engine=value)
            switched = True
        elif config_id == "model":
            if self._configured_engine() == "codex":
                select_codex_model(value)
                bot.journal("acp_codex_model", model=value)
            elif value in bot.MODELS:
                # Les deux, comme le fait le relais Telegram : le fichier pour
                # survivre au redémarrage, l'état vivant pour agir maintenant.
                with bot.state_lock:
                    bot.state["model"] = value
                    bot.save_model(value)
            else:
                raise ValueError(f"modèle Claude refusé : {value}")
        elif config_id == "effort":
            if self._configured_engine() == "codex":
                with bot.state_lock:
                    codex_model = str(bot.CODEX_MODEL)
                if value not in codex_model_efforts(codex_model):
                    raise ValueError(f"effort refusé pour Codex : {value}")
                bot.save_effort(bot.CODEX_EFFORT_FILE, value)
                with bot.state_lock:
                    bot.state["codex_effort"] = value
            else:
                if value not in bot.CLAUDE_EFFORTS:
                    raise ValueError(f"effort refusé pour Claude : {value}")
                bot.save_effort(bot.CLAUDE_EFFORT_FILE, value)
                with bot.state_lock:
                    bot.state["claude_effort"] = value
        else:
            raise ValueError(f"réglage inconnu ou valeur refusée : {config_id}={value}")

        session = self.sessions.get(str(params.get("sessionId") or ""))
        if session is not None:
            # Le client ne peut pas deviner ce que « Auto » a résolu : on le lui
            # dit, sinon la pastille du moteur reste sur sa valeur d'ouverture.
            await session.send_status()
            if switched:
                await self._handover(session)
        return {"configOptions": self._config_options()}

    async def _handover(self, session: Session) -> None:
        """Écrit la passation tout de suite, et la montre.

        Le principe ne change pas d'un iota : `handoff.py` condense le journal
        en un fichier remis au moteur entrant en prompt système. Ce qui change,
        c'est qu'on ne l'attend plus jusqu'à la demande suivante — on le fait à
        l'instant du choix, et le fil affiche **ce qui a été transféré** plutôt
        qu'une roue qui tourne.
        """
        target = bot.engine_for_next_task()
        # Ce que **ce moteur** n'a pas vu **de cette conversation-ci**. Le test
        # portait sur `bot.needs_handoff`, hérité du relais Telegram : il compare
        # au dernier moteur utilisé *toutes conversations confondues*. Sur un fil
        # vide, il n'y a rien à transmettre et pourtant une passation était
        # écrite — construite depuis le journal global, elle apportait en plus le
        # contexte d'autres projets.
        gap = continuity.missing(session.cwd, session.id, target)
        if not gap:
            return

        call_id = str(uuid.uuid4())
        await session.update({
            "sessionUpdate": "tool_call",
            "toolCallId": call_id,
            "title": f"Passation de contexte vers {target}",
            "kind": "think",
            "status": "in_progress",
            "_meta": {"claudeCode": {"toolName": "Passation"}},
        })

        try:
            path = await asyncio.to_thread(
                write_gap_handoff, target, gap, f"bascule vers {target}", session.cwd
            )
            document = await asyncio.to_thread(
                lambda: Path(path).read_text(encoding="utf-8")
            )
        except Exception as exc:  # noqa: BLE001
            await session.update({
                "sessionUpdate": "tool_call_update",
                "toolCallId": call_id, "status": "failed",
                "content": [{"type": "content",
                             "content": {"type": "text", "text": str(exc)}}],
            })
            return

        lines = len(document.splitlines())
        await session.update({
            "sessionUpdate": "tool_call_update",
            "toolCallId": call_id,
            "status": "completed",
            "title": f"Passation vers {target} · {lines} lignes",
            "content": [{
                "type": "content",
                "content": {"type": "text",
                            "text": f"```markdown\n{document[:6000]}\n```"},
            }],
        })

    def _resolve_cwd(self, raw: Any, create: bool = False) -> str:
        """Le répertoire piloté, borné aux dépôts.

        Le jeton donne accès à un shell root : sans cette borne, un client
        compromis choisirait `/` comme terrain de jeu.
        """
        candidate = Path(str(raw or REPOS_BASE)).resolve()
        root = Path(REPOS_BASE).resolve()
        if candidate != root and root not in candidate.parents:
            raise PermissionError(f"répertoire hors de {REPOS_BASE} : {candidate}")
        if not candidate.is_dir():
            if not create:
                raise FileNotFoundError(f"répertoire introuvable : {candidate}")
            # Ouvrir une session sur un dossier neuf, c'est démarrer un projet.
            candidate.mkdir(parents=True)
            bot.journal("acp_project_created", cwd=str(candidate))
        return str(candidate)

    async def _new_session(self, params: dict[str, Any]) -> dict[str, Any]:
        cwd = self._resolve_cwd(params.get("cwd"), create=True)
        # Un identifiant neuf : c'est lui que `claude --session-id` adoptera,
        # et donc le nom du fichier de conversation qui apparaîtra dans la
        # liste dès le premier échange.
        session = Session(self, str(uuid.uuid4()), cwd)
        self.sessions[session.id] = session
        bot.journal("acp_session_new", cwd=cwd)
        await session.send_status()
        return {"sessionId": session.id, "configOptions": self._config_options()}

    async def _load_session(self, params: dict[str, Any]) -> dict[str, Any]:
        session_id = str(params.get("sessionId") or "")
        cwd = self._resolve_cwd(params.get("cwd"))
        session = Session(self, session_id, cwd)
        self.sessions[session.id] = session

        # Le fil commun conserve aussi les outils : sans eux, fermer puis
        # rouvrir une conversation effaçait entièrement sa radiographie.
        history = continuity.replay(cwd, session_id)
        if any(entry.get("role") in {"user", "assistant"} for entry in history):
            for entry in history:
                role = entry.get("role")
                if role == "user":
                    await session.update({
                        "sessionUpdate": "user_message_chunk",
                        "messageId": str(uuid.uuid4()),
                        "content": {"type": "text", "text": str(entry.get("text") or "")},
                    }, persist=False)
                elif role == "assistant":
                    await session.send_text(
                        str(entry.get("text") or ""), str(uuid.uuid4())
                    )
                elif role == "tool" and isinstance(entry.get("update"), dict):
                    await session.update(entry["update"], persist=False)
        else:
            # Compatibilité avec les fils plus anciens, qui ne vivaient que
            # dans le JSONL natif de Claude.
            for role, text in store.replay(cwd, session_id):
                if role == "user":
                    await session.update({
                        "sessionUpdate": "user_message_chunk",
                        "messageId": str(uuid.uuid4()),
                        "content": {"type": "text", "text": text},
                    }, persist=False)
                else:
                    await session.send_text(text, str(uuid.uuid4()))

        await session.send_status()
        return {"sessionId": session.id, "configOptions": self._config_options()}

    def _list_sessions(self, params: dict[str, Any]) -> dict[str, Any]:
        """Les conversations d'un projet, relues sur disque à chaque appel."""
        cwd = self._resolve_cwd(params.get("cwd"))
        return {"sessions": session_catalog(cwd)}

    def _list_projects(self) -> dict[str, Any]:
        """Un vrai `ls` de `/root/repos`, jamais une liste figée.

        La racine elle-même est en tête : une question qui ne porte sur aucun
        projet — « comment j'organise mes branches ? » — doit avoir un endroit
        où vivre, et ses propres conversations.
        """
        root_sessions = session_catalog(REPOS_BASE)
        root = {
            "name": "Tous les dépôts",
            "path": REPOS_BASE,
            "sessionCount": len(root_sessions),
            "updatedAt": root_sessions[0]["updatedAt"] if root_sessions else None,
        }
        projects: list[dict[str, Any]] = []
        for project in store.list_projects(REPOS_BASE):
            merged = session_catalog(str(project["path"]))
            updated = dict(project)
            updated["sessionCount"] = len(merged)
            if merged:
                updated["updatedAt"] = merged[0]["updatedAt"]
            projects.append(updated)
        return {"projects": [root] + projects}

    def _instructions(self, params: dict[str, Any]) -> dict[str, Any]:
        """Le CLAUDE.md du dépôt. `null` s'il n'y en a pas — pas une erreur."""
        cwd = self._resolve_cwd(params.get("cwd"))
        return {"instructions": store.instructions(cwd)}

    # Groq tient Whisper large v3 turbo, et il est rapide : une dictée de
    # trente secondes revient en moins d'une seconde. La clé vit ici, dans
    # l'environnement du service — pas dans un binaire iOS, d'où on ne peut ni
    # la changer ni la révoquer.
    TRANSCRIBE_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
    TRANSCRIBE_MODEL = os.environ.get("HUBLOT_ASR_MODEL", "whisper-large-v3-turbo")
    TRANSCRIBE_LIMIT = 24 * 1024 * 1024

    async def _transcribe(self, params: dict[str, Any]) -> dict[str, Any]:
        """Une dictée en texte. L'app la pose dans la zone de saisie, pas dans
        le fil : on relit avant d'instruire un agent qui a un shell root."""
        key = os.environ.get("GROQ_API_KEY", "").strip()
        if not key:
            raise ValueError("GROQ_API_KEY absent du serveur")

        try:
            audio = base64.b64decode(str(params.get("audio") or ""), validate=True)
        except (ValueError, TypeError) as exc:
            raise ValueError(f"audio illisible : {exc}") from exc
        if not audio:
            raise ValueError("audio vide")
        if len(audio) > self.TRANSCRIBE_LIMIT:
            raise ValueError("audio trop long (limite 24 Mo)")

        name = str(params.get("filename") or "dictee.m4a")
        language = str(params.get("language") or "fr")
        text = await asyncio.to_thread(self._call_groq, key, audio, name, language)
        bot.journal("acp_transcribe", seconds=None, chars=len(text))
        return {"text": text}

    def _call_groq(self, key: str, audio: bytes, name: str, language: str) -> str:
        boundary = "----hublot" + uuid.uuid4().hex
        parts: list[bytes] = []

        def field(field_name: str, value: str) -> None:
            parts.append(
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{field_name}"\r\n\r\n'
                f"{value}\r\n".encode("utf-8")
            )

        field("model", self.TRANSCRIBE_MODEL)
        field("language", language)
        field("response_format", "text")
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
            f"Content-Type: application/octet-stream\r\n\r\n".encode("utf-8")
        )
        parts.append(audio)
        parts.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))

        request = urllib.request.Request(
            self.TRANSCRIBE_URL,
            data=b"".join(parts),
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                # Sans en-tête d'agent, urllib s'annonce Python-urllib et le
                # pare-feu de Groq referme la porte : 403, erreur 1010. Rien à
                # voir avec la clé, et le message ne le dit pas.
                "User-Agent": "Hublot/1.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read().decode("utf-8").strip()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:300]
            raise ValueError(f"Groq a refusé ({exc.code}) : {detail}") from exc
        except urllib.error.URLError as exc:
            raise ValueError(f"Groq injoignable : {exc.reason}") from exc

    async def _delete_session(self, params: dict[str, Any]) -> dict[str, Any]:
        cwd = self._resolve_cwd(params.get("cwd"))
        session_id = str(params.get("sessionId") or "")
        removed = store.delete(cwd, session_id)
        self.sessions.pop(session_id, None)

        # Si le relais pointait encore dessus, on le détache : sinon la
        # prochaine demande tenterait de reprendre une session effacée.
        with bot.state_lock:
            if bot.state["claude_session_id"] == session_id:
                bot.state["claude_session_id"] = None
        bot.persist_state_key("claude_session_id")
        store.forget_codex_thread(cwd, session_id)
        removed = continuity.forget(cwd, session_id) or removed
        bot.journal("acp_session_deleted", session=session_id, cwd=cwd)
        return {"deleted": removed}

    # Les formats qu'un iPhone produit, et rien de plus : une extension inconnue
    # deviendrait un fichier que le moteur ouvrirait sans savoir quoi en faire.
    IMAGE_TYPES = {
        "image/jpeg": ".jpg", "image/jpg": ".jpg", "image/png": ".png",
        "image/heic": ".heic", "image/heif": ".heif", "image/webp": ".webp",
        "image/gif": ".gif",
    }
    IMAGE_LIMIT = 12 * 1024 * 1024

    def _store_images(self, cwd: str, blocks: list[Any]) -> list[str]:
        """Pose les images jointes sur le disque du VPS et rend leurs chemins.

        Ni Claude ni Codex ne lisent du base64 : ils lisent des fichiers. Écrire
        l'image dans le dépôt et donner son chemin est donc le seul chemin qui
        marche pour les deux, sans dépendre d'un mode d'entrée particulier de
        l'un des deux CLI.

        Les images vivent dans `.hublot/images/`, un dossier qui s'ignore
        lui-même côté git : on ne salit pas le dépôt qu'on pilote avec des
        captures d'écran envoyées depuis le téléphone.
        """
        images = [
            block for block in blocks
            if isinstance(block, dict) and block.get("type") == "image"
        ]
        if not images:
            return []

        folder = Path(cwd) / ".hublot" / "images"
        folder.mkdir(parents=True, exist_ok=True)
        ignore = folder.parent / ".gitignore"
        if not ignore.exists():
            ignore.write_text("*\n", encoding="utf-8")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        paths: list[str] = []
        for index, block in enumerate(images, start=1):
            mime = str(block.get("mimeType") or "image/jpeg").lower()
            suffix = self.IMAGE_TYPES.get(mime)
            if suffix is None:
                log(f"image ignorée : type {mime} non pris en charge")
                continue
            try:
                raw = base64.b64decode(str(block.get("data") or ""), validate=True)
            except (ValueError, binascii.Error):
                log("image ignorée : base64 illisible")
                continue
            if not raw or len(raw) > self.IMAGE_LIMIT:
                log(f"image ignorée : {len(raw)} octets hors bornes")
                continue
            target = folder / f"{stamp}-{index}{suffix}"
            target.write_bytes(raw)
            paths.append(str(target))
        return paths

    async def _prompt(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions.get(str(params.get("sessionId") or ""))
        if session is None:
            raise ValueError("session inconnue")

        blocks = params.get("prompt") or []
        text = "\n".join(
            str(block.get("text") or "")
            for block in blocks
            if block.get("type") == "text"
        ).strip()

        # Les images d'abord : elles peuvent constituer à elles seules la
        # demande — « regarde ça » se dit très bien sans un mot.
        paths = await asyncio.to_thread(self._store_images, session.cwd, blocks)
        if paths:
            listing = "\n".join(f"- {path}" for path in paths)
            preamble = (
                "Image jointe à cette demande, lis-la avec l'outil Read avant de répondre :"
                if len(paths) == 1
                else "Images jointes à cette demande, lis-les avec l'outil Read "
                     "avant de répondre :"
            )
            joined = f"{preamble}\n{listing}"
            text = f"{text}\n\n{joined}" if text else joined

        if not text:
            return {"stopReason": "end_turn"}

        # Deux tours sur une même conversation, c'est deux processus qui se
        # disputent le même fichier de session — et une passation fantôme au
        # passage : le tour en cours n'a pas encore posé son repère, donc le
        # second croit découvrir une conversation dont il mène déjà la moitié.
        # Envoyer pendant que ça travaille se fait maintenant en deux temps :
        # on arrête, puis on parle.
        if session.turn is not None:
            raise ValueError("un tour est déjà en cours dans cette conversation")

        # Un tour survit à la liaison qui l'a lancé : le moteur continue, et sa
        # réponse sera rejouée au chargement suivant. Mais chaque reprise crée
        # une `Session` neuve, qui ne sait rien du tour resté en vol — et deux
        # `claude --resume` sur le **même** fichier de conversation se marchent
        # dessus. Le registre est global pour cette raison précise.
        orphan = ACTIVE_TURNS.get(session.id)
        if orphan is not None:
            log(f"tour orphelin arrêté sur {session.id}")
            await orphan.cancel()
            try:
                await asyncio.wait_for(orphan.finished.wait(), timeout=15)
            except asyncio.TimeoutError:
                log(f"tour orphelin toujours vivant sur {session.id}, on continue")

        turn = PromptTurn(session, text)
        session.turn = turn
        ACTIVE_TURNS[session.id] = turn
        try:
            stop_reason = await turn.run()
        finally:
            session.turn = None
            turn.finished.set()
            if ACTIVE_TURNS.get(session.id) is turn:
                del ACTIVE_TURNS[session.id]
        return {"stopReason": stop_reason}

    async def _cancel(self, params: dict[str, Any]) -> None:
        session = self.sessions.get(str(params.get("sessionId") or ""))
        if session and session.turn:
            await session.turn.cancel()
        return None


# ---------------------------------------------------------------------------
# Serveur
# ---------------------------------------------------------------------------
async def handle_client(reader: asyncio.StreamReader,
                        writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername")

    def authorise(headers: dict[str, str]) -> bool:
        presented = headers.get("authorization", "").removeprefix("Bearer ").strip()
        if presented == TOKEN:
            return True
        log(f"jeton refusé depuis {peer}")
        return False

    socket = await WebSocket.accept(reader, writer, authorise)
    if socket is None:
        return

    log(f"client connecté : {peer}")
    connection = Connection(socket)
    try:
        await connection.serve()
    except Exception as exc:  # noqa: BLE001
        log(f"liaison interrompue : {exc}")
    finally:
        await socket.close()
        log(f"client déconnecté : {peer}")


async def main() -> None:
    bot.restore_persisted_state()
    # Le même moniteur que le relais Telegram : c'est lui qui rend Claude
    # indisponible à 98 % et le restaure sur la fenêtre hebdomadaire.
    import threading
    threading.Thread(target=bot.usage_monitor, daemon=True,
                     name="claude-usage-monitor").start()

    server = await asyncio.start_server(handle_client, HOST, PORT)
    log(f"serveur ACP en écoute sur ws://{HOST}:{PORT}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
