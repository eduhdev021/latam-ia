// Teste funcional do start script: executa src/ollama-start.sh DE VERDADE contra
// binarios-stub, sem precisar de Ollama instalado nem de modelo baixado.
//
// Cada caso monta um BASE_DIR temporario com um `ollama` e um `open-webui`
// falsos que imprimem os argumentos e as variaveis de ambiente que receberam.
// Assim da para afirmar qual porta cada um pegou, se o Ollama ficou em localhost
// e se o Open WebUI assumiu a allocation - que e exatamente o que a egg promete.
//
// Roda em CI (ubuntu-latest) e local: node tests/t-start.mjs
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const START = resolve(HERE, "../src/ollama-start.sh");

let pass = 0;
let fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log("  ok    " + msg); }
  else { fail++; console.log("  FALHA " + msg); }
}

const OLLAMA_STUB = `#!/bin/bash
echo "OLLAMA-ARGS:$*"
echo "OLLAMA-HOST:$OLLAMA_HOST"
echo "OLLAMA-THREADS:$CPU_THREADS"
exit 0
`;

const OWUI_STUB = `#!/bin/bash
echo "OWUI-ARGS:$*"
echo "OWUI-DATA_DIR:$DATA_DIR"
echo "OWUI-BASE_URL:$OLLAMA_BASE_URL"
echo "OWUI-APIKEYS:$ENABLE_API_KEYS"
echo "OWUI-NAME:$WEBUI_NAME"
exit 0
`;

function setup({ withOwui = false } = {}) {
  const base = mkdtempSync(join(tmpdir(), "eggstart-"));
  mkdirSync(join(base, "ollama", "bin"), { recursive: true });
  writeFileSync(join(base, "ollama", "VERSION"), "v0.0.0-teste\n");
  writeFileSync(join(base, "ollama", "bin", "ollama"), OLLAMA_STUB);
  spawnSync("chmod", ["+x", join(base, "ollama", "bin", "ollama")]);
  if (withOwui) {
    mkdirSync(join(base, "owui-venv", "bin"), { recursive: true });
    writeFileSync(join(base, "owui-venv", "bin", "open-webui"), OWUI_STUB);
    spawnSync("chmod", ["+x", join(base, "owui-venv", "bin", "open-webui")]);
  }
  return base;
}

function run(base, env) {
  const r = spawnSync("bash", [START], {
    env: { ...process.env, ...env, BASE_DIR: base },
    encoding: "utf8",
    timeout: 30000,
  });
  return (r.stdout || "") + (r.stderr || "");
}

function field(out, key) {
  const m = out.match(new RegExp("^" + key + ":(.*)$", "m"));
  return m ? m[1] : null;
}

const COMMON = {
  SERVER_MEMORY: "4096",
  AUTO_PULL: "false",
  MODEL: "",
  CPU_THREADS: "0",
  CONTEXT_LENGTH: "2048",
  KEEP_ALIVE: "5m",
  NUM_PARALLEL: "1",
  MAX_LOADED_MODELS: "1",
};

// ---------------------------------------------------------------- 1. Open WebUI ligado
{
  console.log("\n[1] ENABLE_OPENWEBUI=true com owui-venv/ presente");
  const base = setup({ withOwui: true });
  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true" });

  ok(field(out, "OLLAMA-HOST") === "127.0.0.1:11434",
     "Ollama escuta so em 127.0.0.1:11434 (nao na allocation) -> " + field(out, "OLLAMA-HOST"));
  ok(field(out, "OLLAMA-ARGS") === "serve", "Ollama sobe em background com 'serve'");
  ok(field(out, "OWUI-ARGS") === "serve --host 0.0.0.0 --port 25565",
     "Open WebUI assume a SERVER_PORT -> " + field(out, "OWUI-ARGS"));
  ok(field(out, "OWUI-BASE_URL") === "http://127.0.0.1:11434",
     "OWUI aponta pro Ollama interno -> " + field(out, "OWUI-BASE_URL"));
  ok(field(out, "OWUI-DATA_DIR") === join(base, "open-webui"),
     "dados em $BASE_DIR/open-webui (sobrevive a restart)");
  ok(field(out, "OWUI-APIKEYS") === "true",
     "ENABLE_API_KEYS=true: o /api/v1 e a unica API externa -> " + field(out, "OWUI-APIKEYS"));
  ok(field(out, "OWUI-NAME") === "LATAM IA", "WEBUI_NAME default 'LATAM IA'");
  ok(!/\bnode\b/.test(out), "nenhum 'node' no caminho (o proxy do chat nao existe mais)");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 2. API pura
{
  console.log("\n[2] ENABLE_OPENWEBUI=false -> API pura na allocation");
  const base = setup({ withOwui: true });
  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "false" });

  ok(field(out, "OLLAMA-HOST") === "0.0.0.0:25565",
     "Ollama assume a allocation -> " + field(out, "OLLAMA-HOST"));
  ok(field(out, "OLLAMA-ARGS") === "serve", "Ollama em primeiro plano com 'serve'");
  ok(field(out, "OWUI-ARGS") === null, "open-webui nao e chamado");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 3. OWUI pedido mas nao instalado
{
  console.log("\n[3] ENABLE_OPENWEBUI=true sem owui-venv/ (instalacao falhou)");
  const base = setup({ withOwui: false });
  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true" });

  ok(out.includes("owui-venv/ nao existe"), "avisa que falta instalar");
  ok(field(out, "OLLAMA-HOST") === "0.0.0.0:25565",
     "cai pra API pura em vez de deixar o server sem nada -> " + field(out, "OLLAMA-HOST"));
  ok(field(out, "OLLAMA-ARGS") === "serve", "Ollama sobe mesmo assim");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 4. valor numerico
{
  console.log("\n[4] ENABLE_OPENWEBUI=1 (valor numerico tambem liga)");
  const base = setup({ withOwui: true });
  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "1" });
  ok(field(out, "OWUI-ARGS") === "serve --host 0.0.0.0 --port 25565", "'1' e aceito como true");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 5. colisao de porta
{
  console.log("\n[5] SERVER_PORT=11434 colide com a porta interna do Ollama");
  const base = setup({ withOwui: true });
  const out = run(base, { ...COMMON, SERVER_PORT: "11434", ENABLE_OPENWEBUI: "true" });

  ok(field(out, "OLLAMA-HOST") === "127.0.0.1:11435",
     "interna sobe pra 11435 -> " + field(out, "OLLAMA-HOST"));
  ok(field(out, "OWUI-ARGS") === "serve --host 0.0.0.0 --port 11434",
     "Open WebUI fica com a 11434 da allocation");
  ok(field(out, "OWUI-BASE_URL") === "http://127.0.0.1:11435", "OWUI acompanha a nova interna");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 6. teto de threads
{
  console.log("\n[6] CPU_THREADS acima das vCPU visiveis e limitado");
  const base = setup({ withOwui: false });
  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "false", CPU_THREADS: "64" });
  const banner = out.match(/threads   : (\d+) \(vCPU visiveis: (\d+)\)/);
  ok(banner !== null, "banner de threads presente");
  if (banner) {
    ok(banner[1] === banner[2], `threads ${banner[1]} == vCPU visiveis ${banner[2]}`);
    ok(field(out, "OLLAMA-THREADS") === banner[2],
       "o stub recebeu o valor limitado -> " + field(out, "OLLAMA-THREADS"));
  }
  ok(out.includes("thrashing"), "explica o motivo do limite");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 7. nome customizado
{
  console.log("\n[7] WEBUI_NAME customizado passa atraves");
  const base = setup({ withOwui: true });
  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true", WEBUI_NAME: "Meu LLM" });
  ok(field(out, "OWUI-NAME") === "Meu LLM", "WEBUI_NAME='Meu LLM' -> " + field(out, "OWUI-NAME"));
  rmSync(base, { recursive: true, force: true });
}

console.log(`\n${fail === 0 ? "PASSOU" : "FALHOU"}: ${pass} asserts ok, ${fail} falhas`);
process.exit(fail === 0 ? 0 : 1);
