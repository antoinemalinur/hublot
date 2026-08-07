#!/usr/bin/env node
//
// acp-probe.mjs — que sait vraiment faire l'agent ?
//
// `session/list` et `session/resume` sont récents. Plutôt que de bâtir la
// couche sessions sur ce que promet la documentation, on demande à l'agent et
// on imprime ce qu'il annonce. Le résultat commande le périmètre v1.
//
//   node Tools/acp-probe.mjs [--url ws://localhost:8317]
//
import WebSocket from "ws";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const URL_ = flag("url", "ws://localhost:8317");
const TOKEN = process.env.HUBLOT_TOKEN ?? "dev-token";

const socket = new WebSocket(URL_, { headers: { Authorization: `Bearer ${TOKEN}` } });
const pending = new Map();
let nextId = 1;

const call = (method, params) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    setTimeout(() => {
      if (pending.delete(id)) reject(new Error(`${method} : pas de réponse en 20 s`));
    }, 20_000);
  });

socket.on("message", (data) => {
  for (const line of data.toString("utf8").split("\n")) {
    if (!line.trim()) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      continue;
    }
    if (message.id != null && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result);
    } else if (message.method) {
      console.log(`  ← ${message.method}`);
    }
  }
});

socket.on("error", (error) => {
  console.error("✕ socket :", error.message);
  process.exit(1);
});

socket.on("open", async () => {
  try {
    const result = await call("initialize", {
      protocolVersion: 1,
      clientCapabilities: {
        fs: { readTextFile: false, writeTextFile: false },
        terminal: false,
      },
    });

    console.log("\n=== initialize ===");
    console.log(JSON.stringify(result, null, 2));

    // La question qui décide de l'écran « sessions » : la liste est-elle
    // servie par l'agent, ou faudra-t-il la tenir localement ?
    console.log("\n=== méthodes optionnelles ===");
    for (const method of ["session/list", "session/resume"]) {
      try {
        await call(method, method === "session/list" ? {} : { sessionId: "sonde" });
        console.log(`  ✓ ${method} répond`);
      } catch (error) {
        const known = /-32601|not found|unknown method|Method not found/i.test(error.message);
        console.log(`  ${known ? "✕" : "~"} ${method} → ${known ? "absent" : error.message}`);
      }
    }
  } catch (error) {
    console.error("✕", error.message);
  } finally {
    socket.close();
    process.exit(0);
  }
});
