// Teste ao vivo da API do Ollama. Nao roda em CI: se nao houver um Ollama
// respondendo em OLLAMA_BASE (default http://127.0.0.1:11434), ele se auto-pula
// com exit 0. Localmente, com a stack no ar, valida o caminho que o painel usa:
// api/version, api/tags, api/generate e api/chat.
//
//   node tests/t-api-live.mjs
//   OLLAMA_BASE=http://127.0.0.1:11434 node tests/t-api-live.mjs
const BASE = (process.env.OLLAMA_BASE || "http://127.0.0.1:11434").replace(/\/$/, "");
const MODEL = process.env.OLLAMA_MODEL || "";

let pass = 0;
let fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log("  ok    " + msg); }
  else { fail++; console.log("  FALHA " + msg); }
}

async function api(path, body) {
  const r = await fetch(BASE + path, body
    ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }
    : undefined);
  if (!r.ok) throw new Error(`${path} -> HTTP ${r.status}`);
  return r.json();
}

let tags;
try {
  tags = await api("/api/tags");
} catch (e) {
  console.log(`\nPULADO: sem Ollama em ${BASE} (${e.message}).`);
  console.log("        Sobe a stack e rode de novo para validar a API de verdade.");
  process.exit(0);
}

console.log(`\nOllama vivo em ${BASE}`);
const ver = await api("/api/version");
ok(typeof ver.version === "string" && ver.version.length > 0, "api/version -> " + ver.version);
ok(Array.isArray(tags.models), "api/tags devolve lista de modelos");
ok(tags.models.length > 0, `${tags.models.length} modelo(s): ${tags.models.map((m) => m.name).join(", ")}`);

const modelo = MODEL || (tags.models.find((m) => /tinyllama|0\.5b|0\.6b/.test(m.name)) || tags.models[0]).name;
console.log(`\ngerando com '${modelo}' (contexto curto de proposito)...`);

const t0 = Date.now();
const gen = await api("/api/generate", {
  model: modelo,
  prompt: "Responda apenas: OK",
  stream: false,
  keep_alive: "1m",
  options: { num_predict: 8, num_ctx: 512, num_thread: Number(process.env.CPU_THREADS || 2) },
});
const dt = ((Date.now() - t0) / 1000).toFixed(1);
ok(typeof gen.response === "string" && gen.response.length > 0, `api/generate respondeu em ${dt}s`);
ok(gen.done === true, "api/generate terminou (done=true)");
ok((gen.eval_count || 0) > 0, `${gen.eval_count} tokens gerados`);

const chat = await api("/api/chat", {
  model: modelo,
  stream: false,
  keep_alive: "1m",
  messages: [{ role: "user", content: "Responda apenas: OK" }],
  options: { num_predict: 8, num_ctx: 512, num_thread: Number(process.env.CPU_THREADS || 2) },
});
ok(typeof chat.message?.content === "string", "api/chat respondeu (formato OpenAI-like do Ollama)");
ok(chat.done === true, "api/chat terminou");

// streaming: o formato NDJSON que o Open WebUI e os clientes usam
const r = await fetch(BASE + "/api/generate", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ model: modelo, prompt: "1, 2, 3", stream: true, keep_alive: "1m",
                         options: { num_predict: 6, num_ctx: 512 } }),
});
const pedacos = (await r.text()).trim().split("\n").filter(Boolean);
ok(pedacos.length > 1, `api/generate stream=true mandou ${pedacos.length} pedacos NDJSON`);
ok(pedacos.every((p) => { try { JSON.parse(p); return true; } catch { return false; } }),
   "todo pedaco e JSON valido");

console.log(`\n${fail === 0 ? "PASSOU" : "FALHOU"}: ${pass} asserts ok, ${fail} falhas`);
process.exit(fail === 0 ? 0 : 1);
