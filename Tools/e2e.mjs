#!/usr/bin/env node
//
// e2e.mjs — la batterie de bout en bout, contre le serveur réel.
//
// Elle parle le même protocole que l'app, sur la même liaison `wss://`, contre
// le même VPS. Ce qui passe ici passe dans Hublot ; ce qui casse ici casserait
// dans ta main.
//
// Chaque test est indépendant et nettoie derrière lui. Les tours qui appellent
// réellement un moteur sont marqués « lent » et consomment du quota : ils sont
// délibérément peu nombreux et posent des questions minuscules.
//
//   node Tools/e2e.mjs              tout
//   node Tools/e2e.mjs --fast       sans les tours qui appellent un moteur
//
import WebSocket from "ws";

const URL_ = process.env.HUBLOT_URL ?? "wss://acp.95-216-190-3.sslip.io";
const TOKEN = process.env.HUBLOT_TOKEN;
const FAST = process.argv.includes("--fast");
const SANDBOX = "/root/repos/hublot-e2e";

if (!TOKEN) {
  console.error("HUBLOT_TOKEN manquant");
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------
class Client {
  constructor(socket) {
    this.socket = socket;
    this.pending = new Map();
    this.nextId = 1;
    this.updates = [];
    this.onPermission = null;
    socket.on("message", (data) => this.receive(data.toString()));
  }

  static connect(token = TOKEN) {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(URL_, { headers: { Authorization: `Bearer ${token}` } });
      const timer = setTimeout(() => reject(new Error("connexion : délai dépassé")), 20000);
      socket.on("open", () => { clearTimeout(timer); resolve(new Client(socket)); });
      socket.on("error", (error) => { clearTimeout(timer); reject(error); });
      socket.on("close", (code) => { clearTimeout(timer); reject(new Error(`fermé (${code})`)); });
    });
  }

  receive(raw) {
    for (const line of raw.split("\n")) {
      if (!line.trim()) continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }

      if (message.id != null && this.pending.has(message.id)) {
        const { resolve, reject, timer } = this.pending.get(message.id);
        this.pending.delete(message.id);
        clearTimeout(timer);
        message.error ? reject(Object.assign(new Error(message.error.message), message.error))
                      : resolve(message.result);
        continue;
      }
      if (message.method === "session/update") { this.updates.push(message.params); continue; }
      if (message.method === "session/request_permission") {
        const answer = this.onPermission ? this.onPermission(message.params) : "deny";
        this.socket.send(JSON.stringify({
          jsonrpc: "2.0", id: message.id,
          result: { outcome: { outcome: "selected", optionId: answer } },
        }));
      }
    }
  }

  call(method, params = {}, timeout = 45000) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} : pas de réponse en ${timeout / 1000} s`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  notify(method, params = {}) {
    this.socket.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
  }

  /// Les mises à jour reçues d'un type donné, dans l'ordre.
  seen(kind) {
    return this.updates.filter((u) => u.update.sessionUpdate === kind);
  }

  text() {
    return this.seen("agent_message_chunk")
      .map((u) => u.update.content?.text ?? "").join("");
  }

  clear() { this.updates = []; }
  close() { this.socket.close(); }
}

// ---------------------------------------------------------------------------
// Cadre
// ---------------------------------------------------------------------------
const results = [];
let current = null;

async function test(name, body, { slow = false } = {}) {
  if (slow && FAST) { results.push({ name, state: "sauté" }); return; }
  current = { name, checks: [] };
  const started = Date.now();
  try {
    await body();
    const failed = current.checks.filter((c) => !c.ok);
    results.push({
      name, state: failed.length ? "ÉCHEC" : "ok",
      seconds: (Date.now() - started) / 1000, failures: failed,
    });
  } catch (error) {
    results.push({
      name, state: "ÉCHEC", seconds: (Date.now() - started) / 1000,
      failures: [{ what: error.message }],
    });
  }
  const last = results.at(-1);
  const mark = last.state === "ok" ? "✓" : last.state === "sauté" ? "·" : "✕";
  console.log(`${mark} ${name}${last.seconds ? `  ${last.seconds.toFixed(1)}s` : ""}`);
  for (const failure of last.failures ?? []) console.log(`    → ${failure.what}`);
}

function expect(ok, what) {
  current.checks.push({ ok: Boolean(ok), what });
}

// ---------------------------------------------------------------------------
// Les tests
// ---------------------------------------------------------------------------
const handshake = {
  protocolVersion: 1,
  clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
};

async function main() {
  console.log(`Hublot — bout en bout sur ${URL_}${FAST ? "  (rapide)" : ""}\n`);

  // -- Liaison -------------------------------------------------------------
  await test("Le jeton protège la liaison", async () => {
    try {
      const intruder = await Client.connect("jeton-invalide");
      intruder.close();
      expect(false, "un mauvais jeton a été accepté");
    } catch {
      expect(true, "refusé");
    }
  });

  const client = await Client.connect();

  await test("initialize annonce des capacités cohérentes", async () => {
    const result = await client.call("initialize", handshake);
    expect(result.protocolVersion === 1, "version de protocole");
    expect(result.agentCapabilities?.loadSession === true, "loadSession annoncé");
    expect(result.agentCapabilities?.sessionCapabilities?.list, "list annoncé");
    expect(result.agentCapabilities?.sessionCapabilities?.delete, "delete annoncé");
    // Ne jamais annoncer ce qu'on n'implémente pas.
    expect(!result.agentCapabilities?.sessionCapabilities?.resume,
      "resume ne doit pas être annoncé (non implémenté)");
    expect(result.agentInfo?.name, "l'agent se nomme");
  });

  // -- Projets -------------------------------------------------------------
  await test("hublot/projects fait un vrai ls", async () => {
    const { projects } = await client.call("hublot/projects");
    expect(Array.isArray(projects) && projects.length > 1, "des projets remontent");
    const root = projects.find((p) => p.path === "/root/repos");
    expect(root, "la portée « tous les dépôts » existe");
    expect(projects.every((p) => typeof p.sessionCount === "number"),
      "chaque projet annonce son nombre de conversations");
    expect(new Set(projects.map((p) => p.path)).size === projects.length,
      "aucun doublon");
  });

  await test("Un dossier créé à l'instant apparaît", async () => {
    // `session/new` crée le dossier s'il manque : c'est le chemin « nouveau
    // projet ». Le bac à sable peut survivre d'un run à l'autre, donc on
    // vérifie le résultat, pas l'état de départ.
    const created = await client.call("session/new", { cwd: SANDBOX, mcpServers: [] });
    expect(created.sessionId, "une conversation est ouverte");
    const after = (await client.call("hublot/projects")).projects.map((p) => p.path);
    expect(after.includes(SANDBOX), "le dossier est listé sans redémarrage du serveur");
  });

  await test("Un cwd hors de /root/repos est refusé", async () => {
    for (const cwd of ["/etc", "/root", "/root/repos/../../etc", "/"]) {
      let refused = false;
      try { await client.call("session/new", { cwd, mcpServers: [] }); }
      catch { refused = true; }
      expect(refused, `refusé : ${cwd}`);
    }
  });

  // -- Réglages ------------------------------------------------------------
  await test("Les réglages se décrivent et suivent le moteur", async () => {
    const session = await client.call("session/new", { cwd: SANDBOX, mcpServers: [] });
    const id = session.sessionId;
    const byId = (options) => Object.fromEntries(options.map((o) => [o.id, o]));

    let options = byId(session.configOptions);
    const originalEngine = options.engine.currentValue;
    expect(options.engine && options.model && options.effort && options.permission,
      "les quatre réglages sont décrits");
    expect(options.engine.options.length === 3, "moteur : auto, claude, codex");
    expect(options.model.options.length > 0, "le modèle propose des valeurs");

    client.clear();
    const claude = byId((await client.call("session/set_config_option",
      { sessionId: id, configId: "engine", type: "select", value: "claude" })).configOptions);
    expect(claude.engine.currentValue === "claude", "moteur épinglé sur Claude");
    expect(!claude.model.currentValue.toLowerCase().includes("gpt"),
      "le modèle suit Claude même quand son quota est épuisé");
    expect(!claude.model.options.some((o) => o.value.toLowerCase().includes("gpt")),
      "le menu Claude ne contient aucun modèle Codex");
    const claudeStatus = client.seen("usage_update").at(-1)?.update?._meta?.hublot;
    expect(claudeStatus?.engine === "claude", "la barre bascule immédiatement sur Claude");
    expect(claudeStatus?.model && !claudeStatus.model.toLowerCase().includes("gpt"),
      "la barre Claude annonce son propre modèle");

    client.clear();
    const codex = byId((await client.call("session/set_config_option",
      { sessionId: id, configId: "engine", type: "select", value: "codex" })).configOptions);
    expect(codex.model.currentValue.includes("gpt"), "le modèle devient celui de Codex");
    expect(codex.model.options.every((o) => o.value.toLowerCase().includes("gpt")),
      "le menu Codex ne contient que ses propres modèles");
    const originalCodexModel = codex.model.currentValue;
    const originalCodexEffort = codex.effort.currentValue;
    const codexModels = codex.model.options.map((o) => o.value);
    expect(codexModels.length > 1, "Codex propose plusieurs modèles");
    expect(["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
      .every((model) => codexModels.includes(model)), "les trois variantes GPT-5.6 sont proposées");
    // Le modèle courant appartient à l'utilisateur et peut légitimement être
    // Luna, qui ne propose pas ultra. Vérifier ultra sur un modèle qui
    // l'annonce, puis restaurer le choix initial, rend le test indépendant de
    // l'état laissé par l'app.
    let ultraCapable = codex;
    if (!ultraCapable.effort.options.some((o) => o.value === "ultra")) {
      const model = ["gpt-5.6-sol", "gpt-5.6-terra"]
        .find((candidate) => codexModels.includes(candidate));
      if (model) {
        ultraCapable = byId((await client.call("session/set_config_option",
          { sessionId: id, configId: "model", type: "select", value: model })).configOptions);
      }
    }
    expect(ultraCapable.effort.options.some((o) => o.value === "ultra"),
      "un modèle Codex compatible propose « ultra »");
    const codexStatus = client.seen("usage_update").at(-1)?.update?._meta?.hublot;
    expect(codexStatus?.engine === "codex", "la barre annonce Codex");
    expect(codexStatus?.model?.includes("gpt"), "la barre annonce le modèle Codex");
    expect(codexStatus?.limits?.seven_day || codexStatus?.limits?.five_hour,
      "la barre reçoit un quota Codex");

    // Le choix agit tout de suite sur le statut et adapte les efforts : Luna
    // ne propose pas ultra, contrairement à Sol et Terra.
    client.clear();
    const luna = byId((await client.call("session/set_config_option",
      { sessionId: id, configId: "model", type: "select", value: "gpt-5.6-luna" })).configOptions);
    expect(luna.model.currentValue === "gpt-5.6-luna", "Luna devient le modèle actif");
    expect(!luna.effort.options.some((o) => o.value === "ultra"),
      "les efforts suivent les capacités de Luna");
    const lunaStatus = client.seen("usage_update").at(-1)?.update?._meta?.hublot;
    expect(lunaStatus?.model === "gpt-5.6-luna", "la barre annonce Luna");

    await client.call("session/set_config_option",
      { sessionId: id, configId: "model", type: "select", value: originalCodexModel });
    await client.call("session/set_config_option",
      { sessionId: id, configId: "effort", type: "select", value: originalCodexEffort });

    // Une valeur absurde doit être refusée, pas absorbée en silence.
    let refused = false;
    try {
      await client.call("session/set_config_option",
        { sessionId: id, configId: "model", type: "select", value: "modèle-inexistant" });
    } catch { refused = true; }
    expect(refused, "une valeur inconnue est refusée");

    await client.call("session/set_config_option",
      { sessionId: id, configId: "engine", type: "select", value: originalEngine });
  });

  // -- Instructions --------------------------------------------------------
  await test("hublot/instructions lit le CLAUDE.md", async () => {
    const withFile = await client.call("hublot/instructions", { cwd: "/root/repos/tg-claude" });
    const without = await client.call("hublot/instructions", { cwd: SANDBOX });
    expect(without.instructions === null || without.instructions === undefined,
      "absence signalée par null, pas par une erreur");
    if (withFile.instructions) {
      expect(withFile.instructions.content.length > 0, "le contenu est là");
      expect(withFile.instructions.path.endsWith(".md"), "le chemin est un Markdown");
    }
  });

  // -- Erreurs -------------------------------------------------------------
  await test("Les erreurs sont propres, la liaison survit", async () => {
    let caught = false;
    try { await client.call("methode/inexistante"); } catch (error) {
      caught = true;
      expect(error.code === -32601, `code -32601 attendu, reçu ${error.code}`);
    }
    expect(caught, "une méthode inconnue échoue");

    caught = false;
    try {
      await client.call("session/prompt",
        { sessionId: "session-fantome", prompt: [{ type: "text", text: "x" }] });
    } catch { caught = true; }
    expect(caught, "une session inconnue échoue");

    // La liaison doit rester utilisable après deux erreurs.
    const still = await client.call("hublot/projects");
    expect(still.projects.length > 0, "la liaison a survécu");
  });

  // -- Un vrai tour --------------------------------------------------------
  let conversation = null;
  await test("Un tour complet : streaming, outil, usage", async () => {
    const session = await client.call("session/new", { cwd: SANDBOX, mcpServers: [] });
    conversation = session.sessionId;
    client.clear();
    const turn = await client.call("session/prompt", {
      sessionId: conversation,
      prompt: [{ type: "text", text: "Réponds exactement : PONG-E2E. Rien d'autre." }],
    }, 300000);

    expect(turn.stopReason === "end_turn", `stopReason ${turn.stopReason}`);
    expect(client.text().includes("PONG-E2E"), "la réponse est arrivée");
    expect(client.seen("agent_message_chunk").length >= 1, "le texte est streamé");
    const usage = client.seen("usage_update").at(-1)?.update;
    expect(usage, "la consommation est poussée");
    expect(usage?.used > 0, "le contexte consommé est mesuré");
    expect(usage?._meta?.hublot?.limits?.five_hour, "les plafonds accompagnent");
    expect(client.seen("available_commands_update").length >= 1,
      "les commandes du moteur sont annoncées");
    const commands = client.seen("available_commands_update").at(-1)
      ?.update.availableCommands.map((c) => c.name) ?? [];
    expect(commands.includes("compact"), "/compact est proposé");
  }, { slow: true });

  // -- Interruption --------------------------------------------------------
  await test("Un tour en cours s'interrompt", async () => {
    // Le bouton d'arrêt de l'app envoie exactement cette notification. Sans
    // elle, un tour parti pour dix minutes ne se rattrape pas.
    const session = await client.call("session/new", { cwd: SANDBOX, mcpServers: [] });
    client.clear();
    const started = Date.now();
    const turn = client.call("session/prompt", {
      sessionId: session.sessionId,
      prompt: [{ type: "text", text:
        "Compte de 1 à 400 en écrivant chaque nombre en toutes lettres, une ligne par nombre." }],
    }, 300000);
    await new Promise((r) => setTimeout(r, 6000));
    client.notify("session/cancel", { sessionId: session.sessionId });
    const result = await turn;
    const seconds = (Date.now() - started) / 1000;

    expect(result.stopReason === "cancelled", `stopReason ${result.stopReason}`);
    expect(seconds < 30, `rendu la main en ${seconds.toFixed(1)} s`);
    await client.call("session/delete", { sessionId: session.sessionId, cwd: SANDBOX });
  }, { slow: true });

  await test("Deux tours simultanés sont refusés", async () => {
    // Envoyer pendant que ça travaille lançait un second processus sur le même
    // fichier de session, et fabriquait une passation fantôme : le tour en vol
    // n'a pas encore posé son repère, donc le second croyait découvrir une
    // conversation dont il menait déjà la moitié.
    const session = await client.call("session/new", { cwd: SANDBOX, mcpServers: [] });
    const first = client.call("session/prompt", {
      sessionId: session.sessionId,
      prompt: [{ type: "text", text: "Compte de 1 à 200, un nombre par ligne." }],
    }, 300000);
    await new Promise((r) => setTimeout(r, 2500));

    let refused = null;
    try {
      await client.call("session/prompt", {
        sessionId: session.sessionId,
        prompt: [{ type: "text", text: "Et maintenant autre chose." }],
      }, 20000);
    } catch (error) { refused = error; }

    expect(refused, "le second envoi est refusé");
    expect(refused?.code === -32602, `code ${refused?.code}`);
    client.notify("session/cancel", { sessionId: session.sessionId });
    await first;
    await client.call("session/delete", { sessionId: session.sessionId, cwd: SANDBOX });
  }, { slow: true });

  // -- Conversations -------------------------------------------------------
  await test("La conversation apparaît, se recharge, puis s'efface", async () => {
    const listed = await client.call("session/list", { cwd: SANDBOX });
    const mine = listed.sessions.find((s) => s.sessionId === conversation);
    expect(mine, "la conversation est listée");
    expect(mine?.exchanges >= 1, "son nombre d'échanges est compté");
    expect(mine?.title && mine.title !== "Conversation", "elle a un titre");

    client.clear();
    await client.call("session/load",
      { sessionId: conversation, cwd: SANDBOX, mcpServers: [] });
    const roles = client.updates
      .map((u) => u.update.sessionUpdate)
      .filter((k) => k.endsWith("_message_chunk"));
    expect(roles.includes("user_message_chunk"), "la demande est rejouée");
    expect(roles.includes("agent_message_chunk"), "la réponse est rejouée");
    expect(roles.indexOf("user_message_chunk") < roles.indexOf("agent_message_chunk"),
      "dans l'ordre : la question avant la réponse");

    const removed = await client.call("session/delete",
      { sessionId: conversation, cwd: SANDBOX });
    expect(removed.deleted === true, "la suppression est confirmée");
    const after = await client.call("session/list", { cwd: SANDBOX });
    expect(!after.sessions.some((s) => s.sessionId === conversation),
      "elle a disparu de la liste");
  }, { slow: true });

  // -- Permissions ---------------------------------------------------------
  await test("Une commande dangereuse demande l'autorisation", async () => {
    const session = await client.call("session/new", { cwd: SANDBOX, mcpServers: [] });
    await client.call("session/set_config_option",
      { sessionId: session.sessionId, configId: "permission", type: "select", value: "ask" });
    await client.call("session/set_config_option",
      { sessionId: session.sessionId, configId: "engine", type: "select", value: "claude" });

    let asked = null;
    client.onPermission = (params) => { asked = params; return "deny"; };
    client.clear();
    await client.call("session/prompt", {
      sessionId: session.sessionId,
      prompt: [{ type: "text", text:
        // `chmod -R` déclenche le garde-fou, et sur son propre bac à sable
        // c'est sans conséquence : Claude la lance sans hésiter, alors qu'il
        // refuse — à raison — un `chmod -R` sur /tmp.
        `Lance avec l'outil Bash, sans commentaire : chmod -R 755 ${SANDBOX}` }],
    }, 300000);

    expect(asked, "la permission a été demandée");
    expect(client.seen("tool_call").some((u) => u.update.kind === "execute"),
      "Claude a bien tenté de lancer la commande (sinon le test ne prouve rien)");
    expect(asked?.toolCall?.rawInput?.command?.includes("chmod"),
      "la commande exacte est montrée");
    expect(asked?.options?.length >= 2, "des options sont proposées");
    expect(asked?.options?.some((o) => o.kind?.startsWith("allow")), "une option autorise");
    expect(asked?.options?.some((o) => o.kind?.startsWith("reject")), "une option refuse");
    client.onPermission = null;

    await client.call("session/delete",
      { sessionId: session.sessionId, cwd: SANDBOX }).catch(() => {});
  }, { slow: true });

  await test("Le mode « tout autoriser » ne demande rien", async () => {
    const session = await client.call("session/new", { cwd: SANDBOX, mcpServers: [] });
    await client.call("session/set_config_option",
      { sessionId: session.sessionId, configId: "permission", type: "select", value: "auto" });

    let asked = false;
    client.onPermission = () => { asked = true; return "allow"; };
    client.clear();
    await client.call("session/prompt", {
      sessionId: session.sessionId,
      prompt: [{ type: "text", text:
        `Lance avec l'outil Bash : chmod -R 755 ${SANDBOX} ; puis réponds FAIT.` }],
    }, 300000);

    expect(client.seen("tool_call").some((u) => u.update.kind === "execute"),
      "la commande a bien été tentée");
    expect(!asked, "aucune question posée en mode auto");
    client.onPermission = null;

    await client.call("session/set_config_option",
      { sessionId: session.sessionId, configId: "permission", type: "select", value: "ask" });
    await client.call("session/delete",
      { sessionId: session.sessionId, cwd: SANDBOX }).catch(() => {});
  }, { slow: true });

  // -- Continuité ----------------------------------------------------------
  await test("Une bascule transmet ce que l'autre moteur a manqué", async () => {
    const session = await client.call("session/new", { cwd: SANDBOX, mcpServers: [] });
    const id = session.sessionId;
    const ask = async (question) => {
      client.clear();
      await client.call("session/prompt",
        { sessionId: id, prompt: [{ type: "text", text: question }] }, 300000);
      return client.text();
    };
    const use = (engine) => client.call("session/set_config_option",
      { sessionId: id, configId: "engine", type: "select", value: engine });

    await use("claude");
    await ask("Retiens ce code : ZIRCON-88. Réponds juste OK.");

    await use("codex");
    const fromCodex = await ask("Quel code t'a-t-on donné ? Un seul mot.");
    expect(fromCodex.includes("ZIRCON-88"), `Codex a reçu le contexte (a dit : ${fromCodex.slice(-40)})`);
    expect(client.seen("agent_thought_chunk").some(
      (u) => u.update.content?.text?.includes("Codex travaille")),
      "Codex signale immédiatement qu'il travaille");

    await ask("Retiens aussi : la salle est BLEUE. Réponds juste OK.");

    await use("claude");
    const backToClaude = await ask("De quelle couleur est la salle ? Un seul mot.");
    expect(/bleue?/i.test(backToClaude),
      `Claude a rattrapé ce que Codex a fait (a dit : ${backToClaude.slice(-40)})`);

    await use("auto");
    await client.call("session/delete", { sessionId: id, cwd: SANDBOX }).catch(() => {});
  }, { slow: true });

  // -- Deux clients --------------------------------------------------------
  await test("Deux liaisons simultanées ne se marchent pas dessus", async () => {
    const second = await Client.connect();
    await second.call("initialize", handshake);
    const [a, b] = await Promise.all([
      client.call("hublot/projects"),
      second.call("hublot/projects"),
    ]);
    expect(a.projects.length === b.projects.length, "les deux voient la même chose");
    second.close();
  });

  // -- Nettoyage -----------------------------------------------------------
  await test("Le bac à sable est laissé propre", async () => {
    const { sessions } = await client.call("session/list", { cwd: SANDBOX });
    for (const session of sessions) {
      await client.call("session/delete",
        { sessionId: session.sessionId, cwd: SANDBOX }).catch(() => {});
    }
    const after = await client.call("session/list", { cwd: SANDBOX });
    expect(after.sessions.length === 0, `${after.sessions.length} conversation(s) restante(s)`);
  });

  client.close();

  // -- Verdict -------------------------------------------------------------
  const failed = results.filter((r) => r.state === "ÉCHEC");
  const skipped = results.filter((r) => r.state === "sauté").length;
  console.log(`\n${results.length - failed.length - skipped} réussi(s), ${failed.length} échec(s)`
    + (skipped ? `, ${skipped} sauté(s)` : ""));
  process.exit(failed.length ? 1 : 0);
}

main().catch((error) => {
  console.error("\n✕ la batterie s'est interrompue :", error.message);
  process.exit(1);
});
