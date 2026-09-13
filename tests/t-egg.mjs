// Checagens estaticas da egg e dos scripts. Nao precisa de Ollama nem de servidor:
// valida o JSON que vai ser importado no painel e garante que nada que foi
// removido (o chat LATAM IA e o proxy Node) voltou de fininho.
//
// Roda em CI e local: node tests/t-egg.mjs
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(fileURLToPath(new URL(".", import.meta.url)), "..");
const read = (p) => readFileSync(resolve(ROOT, p), "utf8");

let pass = 0;
let fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log("  ok    " + msg); }
  else { fail++; console.log("  FALHA " + msg); }
}

// ---------------------------------------------------------------- estrutura da egg
console.log("\n[1] egg-ollama.json");
const egg = JSON.parse(read("egg-ollama.json"));
ok(egg.meta.version === "PTDL_v2", "meta.version = PTDL_v2 (formato importavel)");
ok(egg.startup === "bash /home/container/ollama-start.sh", "startup chama o start script -> " + egg.startup);
ok(Object.values(egg.docker_images).some((i) => i.includes("yolks")), "usa imagem yolks");

const install = egg.scripts.installation.script;
ok(install.length < 65536, `instalador embutido ${install.length} bytes < 65536 (corte do painel)`);
ok(install.length < 60000, "folga ate o limite duro de 60000 do build_egg.py");
ok(egg.scripts.installation.container.startsWith("debian"),
   "container de instalacao debian -> " + egg.scripts.installation.container);

// ---------------------------------------------------------------- variaveis
console.log("\n[2] variaveis da aba Startup");
const vars = egg.variables.map((v) => v.env_variable);
const ESPERADAS = [
  "MODEL", "AUTO_PULL", "KEEP_ALIVE", "NUM_PARALLEL", "MAX_LOADED_MODELS",
  "CONTEXT_LENGTH", "KV_CACHE_TYPE", "ORIGINS", "FLASH_ATTENTION", "DEBUG",
  "LLM_LIBRARY", "ENABLE_OPENWEBUI", "CPU_THREADS", "UI_REPO", "UI_REF",
  "OLLAMA_VERSION", "STRIP_GPU_LIBS",
];
ok(vars.length === ESPERADAS.length, `${vars.length} variaveis (esperado ${ESPERADAS.length})`);
ok(JSON.stringify(vars) === JSON.stringify(ESPERADAS), "lista e ordem conferem");
for (const v of egg.variables) {
  ok(typeof v.description === "string" && v.description.length > 20,
     `${v.env_variable} tem descricao util (${v.description.length} chars)`);
}
const owui = egg.variables.find((v) => v.env_variable === "ENABLE_OPENWEBUI");
ok(owui.default_value === "true", "ENABLE_OPENWEBUI liga por padrao (a interface e o Open WebUI)");

// ---------------------------------------------------------------- nada de variavel orfa
console.log("\n[3] instalador vs variaveis declaradas");
const startScript = read("src/ollama-start.sh");
// Comentarios nao contam como uso: $ORIGIN aparece num comentario (RUNPATH) e nao
// e uma variavel de ambiente de verdade.
const semComentarios = (txt) => txt.split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
const codInstall = semComentarios(install);
const codStart = semComentarios(startScript);
const codigo = codInstall + "\n" + codStart;

// O Pterodactyl entrega as variaveis da aba Startup como variaveis de ambiente
// dentro do container de instalacao e no start. Contrato: tudo que a egg declara
// tem que ser lido como $VAR ou ${VAR} por algum dos dois scripts.
const leu = (v) => new RegExp("\\$\\{?" + v + "\\b").test(codigo);
const mortas = vars.filter((v) => !leu(v));
ok(mortas.length === 0, "toda variavel declarada e lida por algum script" +
   (mortas.length ? " -> mortas: " + mortas.join(", ") : ""));

// E o contrario: script nao pode ler variavel que a egg nao declara (ela chegaria
// vazia em producao e o comportamento mudaria sem ninguem perceber).
const lidas = new Set([...codigo.matchAll(/\$\{?([A-Z][A-Z_0-9]{2,})\b/g)].map((m) => m[1]));
// O que o proprio painel injeta.
const doPainel = new Set(["SERVER_PORT", "SERVER_MEMORY", "SERVER_IP", "P_SERVER_ALLOCATION_ID"]);
// O que o proprio script cria: atribuicao (inclusive dentro de case), for..in e export.
const atribuidas = new Set([
  ...[...codigo.matchAll(/(?:^|[\s;)(])([A-Z][A-Z_0-9]{2,})=/g)].map((m) => m[1]),
  ...[...codigo.matchAll(/\bfor\s+([A-Z][A-Z_0-9]{2,})\s+in\b/g)].map((m) => m[1]),
  ...[...codigo.matchAll(/\bexport\s+([A-Z][A-Z_0-9]{2,})\b/g)].map((m) => m[1]),
]);
const naoDeclaradas = [...lidas].filter((v) => !vars.includes(v) && !doPainel.has(v) && !atribuidas.has(v));
ok(naoDeclaradas.length === 0, "nenhum script le variavel que a egg nao declara" +
   (naoDeclaradas.length ? " -> " + naoDeclaradas.join(", ") : ""));

// ---------------------------------------------------------------- sincronia build
console.log("\n[4] arquivos em sincronia com o build");
ok(install === read("scripts/ollama-install.sh"),
   "instalador embutido == scripts/ollama-install.sh (build nao esta velho)");
ok(read("scripts/ollama-start.sh") === read("src/ollama-start.sh"),
   "scripts/ollama-start.sh == src/ollama-start.sh");

// ---------------------------------------------------------------- o que NAO pode voltar
console.log("\n[5] o chat LATAM IA foi removido de vez");
for (const f of ["src/chat.html", "src/proxy.js", "scripts/ui-chat.html", "scripts/ui-proxy.js"]) {
  ok(!existsSync(resolve(ROOT, f)), `${f} nao existe`);
}
const haystack = install + read("src/ollama-start.sh") + JSON.stringify(egg);
for (const token of ["ENABLE_UI", "UI_TOKEN", "OPENWEBUI_PORT", "proxy.js", "chat.html", "latam_panel"]) {
  ok(!haystack.includes(token), `nenhuma ocorrencia de '${token}'`);
}

// ---------------------------------------------------------------- contrato do start
console.log("\n[6] contrato do start script");
const start = read("src/ollama-start.sh");
ok(start.includes('exec "${OWUI_BIN}" serve --host 0.0.0.0 --port "${SERVER_PORT}"'),
   "Open WebUI e o processo da allocation (bind na SERVER_PORT)");
ok(start.includes('export OLLAMA_HOST="127.0.0.1:${INTERNAL_PORT}"'),
   "com interface ligada o Ollama fica em localhost");
ok(start.includes('export OLLAMA_HOST="0.0.0.0:${SERVER_PORT}"'),
   "sem interface o Ollama assume a allocation");
ok(start.includes('export ENABLE_API_KEYS="${ENABLE_API_KEYS:-true}"'),
   "API keys do Open WebUI ligadas (unica API externa agora)");
ok(start.includes("cpu.max") || start.includes("cfs_quota_us"),
   "teto de threads le o cgroup (o painel limita por quota, nao so por cpuset)");

console.log(`\n${fail === 0 ? "PASSOU" : "FALHOU"}: ${pass} asserts ok, ${fail} falhas`);
process.exit(fail === 0 ? 0 : 1);
