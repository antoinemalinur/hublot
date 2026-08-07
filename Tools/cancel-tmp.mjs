import WebSocket from "ws";
const socket = new WebSocket("wss://acp.95-216-190-3.sslip.io", {
  headers: { Authorization: `Bearer ${process.env.HUBLOT_TOKEN}` } });
const pending = new Map(); let next = 1;
const call = (m, p = {}) => new Promise((res, rej) => { const id = next++; pending.set(id, { res, rej });
  socket.send(JSON.stringify({ jsonrpc: "2.0", id, method: m, params: p })); });
const notify = (m, p) => socket.send(JSON.stringify({ jsonrpc: "2.0", method: m, params: p }));
socket.on("message", (d) => { for (const l of d.toString().split("\n")) { if (!l.trim()) continue;
  const m = JSON.parse(l);
  if (m.id != null && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id);
    m.error ? rej(new Error(m.error.message)) : res(m.result); }
  else if (m.method === "session/request_permission") {
    const a = m.params.options.find((o) => o.kind === "allow_always") ?? m.params.options[0];
    socket.send(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { outcome: { outcome: "selected", optionId: a.optionId } } })); } } });
socket.on("open", async () => {
  await call("initialize", { protocolVersion: 1, clientCapabilities: {} });
  const s = await call("session/new", { cwd: "/root/repos/office-chess", mcpServers: [] });
  const started = Date.now();
  const turn = call("session/prompt", { sessionId: s.sessionId,
    prompt: [{ type: "text", text: "Compte lentement de 1 à 400 en écrivant chaque nombre en toutes lettres, une ligne par nombre." }] });
  setTimeout(() => { console.log("→ arrêt demandé à 6 s"); notify("session/cancel", { sessionId: s.sessionId }); }, 6000);
  const r = await turn;
  console.log(`stopReason = ${r.stopReason}   après ${((Date.now() - started) / 1000).toFixed(1)} s`);
  socket.close(); process.exit(0);
});
