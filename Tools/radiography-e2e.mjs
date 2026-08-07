#!/usr/bin/env node
// Vérifie la radiographie sur le serveur réel avec une action Codex en lecture
// seule, puis une reconnexion. HUBLOT_TOKEN reste fourni par l'environnement.
import WebSocket from "ws";

const URL_ = process.env.HUBLOT_URL ?? "wss://acp.95-216-190-3.sslip.io";
const TOKEN = process.env.HUBLOT_TOKEN;
const CWD = "/root/repos/office-chess";
const EXPECTED = "/root/repos/office-chess/office_chess/database.py";

if (!TOKEN) throw new Error("HUBLOT_TOKEN manquant");

class Client {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.updates = [];
    socket.on("message", (data) => this.receive(data.toString()));
  }

  static connect() {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(URL_, {
        headers: { Authorization: `Bearer ${TOKEN}` },
      });
      const timer = setTimeout(() => reject(new Error("connexion : délai dépassé")), 20_000);
      socket.once("open", () => {
        clearTimeout(timer);
        resolve(new Client(socket));
      });
      socket.once("error", reject);
    });
  }

  receive(raw) {
    for (const line of raw.split("\n")) {
      if (!line.trim()) continue;
      const message = JSON.parse(line);
      if (message.id != null && this.pending.has(message.id)) {
        const entry = this.pending.get(message.id);
        this.pending.delete(message.id);
        clearTimeout(entry.timer);
        if (message.error) entry.reject(new Error(message.error.message));
        else entry.resolve(message.result);
      } else if (message.method === "session/update") {
        this.updates.push(message.params.update);
      } else if (message.method === "session/request_permission") {
        this.socket.send(JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          result: { outcome: { outcome: "selected", optionId: "allow_once" } },
        }));
      }
    }
  }

  call(method, params = {}, timeout = 45_000) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} : délai dépassé`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  close() { this.socket.close(); }
}

const handshake = {
  protocolVersion: 1,
  clientCapabilities: {
    fs: { readTextFile: false, writeTextFile: false },
    terminal: false,
  },
};

const toolUpdates = (client) => client.updates.filter((update) =>
  ["tool_call", "tool_call_update"].includes(update.sessionUpdate));

let client;
let sessionId;
let originalEngine = "auto";
let originalPermission = "ask";

try {
  client = await Client.connect();
  await client.call("initialize", handshake);
  const created = await client.call("session/new", { cwd: CWD, mcpServers: [] });
  sessionId = created.sessionId;
  const options = Object.fromEntries(
    created.configOptions.map((option) => [option.id, option])
  );
  originalEngine = options.engine.currentValue;
  originalPermission = options.permission.currentValue;

  await client.call("session/set_config_option", {
    sessionId, configId: "engine", type: "select", value: "codex",
  });
  await client.call("session/set_config_option", {
    sessionId, configId: "permission", type: "select", value: "auto",
  });
  client.updates = [];

  const turn = await client.call("session/prompt", {
    sessionId,
    prompt: [{
      type: "text",
      text: "Lance exactement cette commande de lecture : sed -n '1p' office_chess/database.py . Puis réponds exactement VISUAL-OK.",
    }],
  }, 300_000);
  if (turn.stopReason !== "end_turn") {
    throw new Error(`tour terminé sur ${turn.stopReason}`);
  }

  const live = toolUpdates(client);
  if (!live.some((update) =>
    update.locations?.some((location) => location.path === EXPECTED))) {
    throw new Error(`chemin absent du direct : ${JSON.stringify(live)}`);
  }
  const listed = await client.call("session/list", { cwd: CWD });
  if (!listed.sessions.some((session) => session.sessionId === sessionId)) {
    throw new Error("la session Codex n'apparaît pas dans la liste");
  }

  client.close();
  client = await Client.connect();
  await client.call("initialize", handshake);
  client.updates = [];
  await client.call("session/load", {
    sessionId, cwd: CWD, mcpServers: [],
  });

  const replayed = toolUpdates(client);
  if (!replayed.some((update) =>
    update.locations?.some((location) => location.path === EXPECTED))) {
    throw new Error(`chemin absent du rejeu : ${JSON.stringify(replayed)}`);
  }
  const order = client.updates.map((update) => update.sessionUpdate);
  const user = order.indexOf("user_message_chunk");
  const tool = order.findIndex((kind) =>
    kind === "tool_call" || kind === "tool_call_update");
  const assistant = order.indexOf("agent_message_chunk");
  if (!(user >= 0 && tool > user && assistant > tool)) {
    throw new Error(`ordre de rejeu incorrect : ${order.join(", ")}`);
  }

  console.log("✓ Office Chess : action localisée en direct");
  console.log("✓ Reconnexion : demande → actions → réponse");
  console.log(`  ${live.length} mise(s) à jour en direct, ${replayed.length} rejouée(s)`);
} finally {
  if (client && sessionId) {
    await client.call("session/set_config_option", {
      sessionId, configId: "permission", type: "select", value: originalPermission,
    }).catch(() => {});
    await client.call("session/set_config_option", {
      sessionId, configId: "engine", type: "select", value: originalEngine,
    }).catch(() => {});
    await client.call("session/delete", { sessionId, cwd: CWD }).catch(() => {});
  }
  client?.close();
}
