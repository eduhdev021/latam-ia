// Teste funcional do start script: executa src/ollama-start.sh DE VERDADE contra
// binarios-stub, sem precisar de Ollama instalado nem de modelo baixado.
//
// Cada caso monta um BASE_DIR temporario com um `ollama` e um `open-webui`
// falsos que imprimem os argumentos e as variaveis de ambiente que receberam.
// Assim da para afirmar qual porta cada um pegou, se o Ollama ficou em localhost
// e se o Open WebUI assumiu a allocation - que e exatamente o que a egg promete.
//
// Roda em CI (ubuntu-latest) e local: node tests/t-start.mjs
import { spawnSync, execSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, readlinkSync } from "node:fs";
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
  // curl falso: o start script espera o Ollama responder em 127.0.0.1 antes de
  // gravar o num_thread. Sem isso cada caso queimaria os 60 s da espera.
  mkdirSync(join(base, "stub-bin"), { recursive: true });
  writeFileSync(join(base, "stub-bin", "curl"), "#!/bin/bash\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "stub-bin", "curl")]);
  if (withOwui) {
    mkdirSync(join(base, "owui-venv", "bin"), { recursive: true });
    writeFileSync(join(base, "owui-venv", "bin", "open-webui"), OWUI_STUB);
    spawnSync("chmod", ["+x", join(base, "owui-venv", "bin", "open-webui")]);
  }
  return base;
}

function run(base, env) {
  const r = spawnSync("bash", [START], {
    env: { ...process.env, PATH: join(base, "stub-bin") + ":" + process.env.PATH,
           ...env, BASE_DIR: base },
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

// ---------------------------------------------------------------- 8. venv com caminho da instalacao
{
  console.log("\n[8] venv gravado com o caminho da instalacao (/mnt/server != /home/container)");
  const base = setup({ withOwui: false });
  const ERRADO = "/prefixo-da-instalacao";
  const VER = "cpython-3.11.16-linux-x86_64-gnu";   // diretorio real
  const ALIAS = "cpython-3.11-linux-x86_64-gnu";    // atalho que o uv cria (absoluto!)
  const pyReal = join(base, ".uv", "python", VER, "bin");
  mkdirSync(pyReal, { recursive: true });
  // stub do interpretador: recebe o script como $1 e roda com bash, que e o que o
  // CPython faz com um console script. ("exec \"$@\"" daria loop infinito: o
  // script tem shebang apontando de volta pro proprio interpretador.)
  writeFileSync(join(pyReal, "python3.11"), "#!/bin/bash\nexec /bin/bash \"$@\"\n");
  spawnSync("chmod", ["+x", join(pyReal, "python3.11")]);
  // o uv grava este atalho como ABSOLUTO, apontando pro prefixo da instalacao.
  // Foi o que quebrou no server de verdade: reescrever so o venv nao basta.
  spawnSync("ln", ["-sfn", `${ERRADO}/.uv/python/${VER}`, join(base, ".uv", "python", ALIAS)]);

  mkdirSync(join(base, "owui-venv", "bin"), { recursive: true });
  writeFileSync(join(base, "owui-venv", "pyvenv.cfg"),
    `home = ${ERRADO}/.uv/python/${ALIAS}/bin\nuv = 0.12.13\nversion_info = 3.11\n`);
  spawnSync("ln", ["-sfn", `${ERRADO}/.uv/python/${ALIAS}/bin/python3.11`,
                   join(base, "owui-venv", "bin", "python")]);
  writeFileSync(join(base, "owui-venv", "bin", "open-webui"),
    `#!${ERRADO}/owui-venv/bin/python\necho "OWUI-ARGS:$*"\nexit 0\n`);
  spawnSync("chmod", ["+x", join(base, "owui-venv", "bin", "open-webui")]);

  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true" });
  ok(out.includes(`ajustando caminhos do venv (${ERRADO} -> ${base})`), "detecta e anuncia a reescrita");
  ok(readlinkSync(join(base, ".uv", "python", ALIAS)) === `${base}/.uv/python/${VER}`,
     "ATALHO ABSOLUTO do .uv reapontado -> " + readlinkSync(join(base, ".uv", "python", ALIAS)));
  ok(readFileSync(join(base, "owui-venv", "pyvenv.cfg"), "utf8")
       .includes(`home = ${base}/.uv/python/${ALIAS}/bin`), "pyvenv.cfg aponta pro BASE_DIR real");
  ok(readlinkSync(join(base, "owui-venv", "bin", "python")).startsWith(base + "/"),
     "symlink bin/python reapontado");
  ok(readFileSync(join(base, "owui-venv", "bin", "open-webui"), "utf8")
       .startsWith(`#!${base}/owui-venv/bin/python`), "shebang do open-webui reescrito");
  ok(field(out, "OWUI-ARGS") === "serve --host 0.0.0.0 --port 25565",
     "e o Open WebUI sobe na allocation em vez de morrer com 'required file not found'");

  const out2 = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true" });
  ok(!out2.includes("ajustando caminhos"), "idempotente: segunda execucao nao reescreve");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 9. teto de threads gravado no modelo
{
  console.log("\n[9] CPU_THREADS e gravado como num_thread dentro de cada modelo");
  const base = mkdtempSync(join(tmpdir(), "eggstart-"));
  const bin = join(base, "stub-bin");
  const log = join(base, "create.log");
  mkdirSync(join(base, "ollama", "bin"), { recursive: true });
  mkdirSync(join(base, "owui-venv", "bin"), { recursive: true });
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(base, "ollama", "VERSION"), "v0.0.0-teste\n");

  // curl falso: a espera pelo Ollama passa na hora (sem servidor de verdade)
  writeFileSync(join(bin, "curl"), "#!/bin/bash\nexit 0\n");
  spawnSync("chmod", ["+x", join(bin, "curl")]);

  // ollama falso. O script chama `create` com stdout no /dev/null, entao o que
  // interessa vai para um arquivo.
  writeFileSync(join(base, "ollama", "bin", "ollama"), `#!/bin/bash
case "$1" in
  serve) echo "OLLAMA-ARGS:$*"; echo "OLLAMA-HOST:$OLLAMA_HOST"; exit 0 ;;
  list)  printf 'NAME              ID     SIZE    MODIFIED\nqwen3:0.6b        a1     1 GB    agora\ntinyllama:latest  b2     1 GB    agora\n'; exit 0 ;;
  show)  [ -n "$STUB_JA_TEM" ] && printf '  Parameters\n    num_thread    %s\n' "$STUB_JA_TEM"; exit 0 ;;
  create) echo "$2 <= $(tr '\n' '|' < "$4")" >> "$STUB_LOG"; exit 0 ;;
esac
exit 0
`);
  spawnSync("chmod", ["+x", join(base, "ollama", "bin", "ollama")]);

  writeFileSync(join(base, "owui-venv", "bin", "open-webui"),
    "#!/bin/bash\nsleep 2\necho \"OWUI-ARGS:$*\"\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "owui-venv", "bin", "open-webui")]);

  const envBase = { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true",
                    CPU_THREADS: "2", STUB_LOG: log, PATH: bin + ":" + process.env.PATH };
  const gravados = () => { try { return readFileSync(log, "utf8"); } catch { return ""; } };

  const out = run(base, envBase);
  const g1 = gravados();
  ok(g1.includes("qwen3:0.6b <= FROM qwen3:0.6b|PARAMETER num_thread 2|"),
     "qwen3:0.6b regravado com num_thread 2");
  ok(g1.includes("tinyllama:latest <= FROM tinyllama:latest|PARAMETER num_thread 2|"),
     "tinyllama:latest regravado com num_thread 2");
  ok(out.includes("num_thread=2 gravado no modelo"), "avisa no console o que gravou");

  rmSync(log, { force: true });
  run(base, { ...envBase, STUB_JA_TEM: "2" });
  ok(gravados() === "", "idempotente: nao regravou o que ja tem num_thread 2");

  rmSync(log, { force: true });
  run(base, { ...envBase, STUB_JA_TEM: "8" });
  ok(gravados().split("\n").filter(Boolean).length === 2,
     "regravou os 2 quando o valor gravado era outro (8 -> 2)");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 10. CPU_THREADS=auto e checagem de memoria
{
  console.log("\n[10] CPU_THREADS=auto resolve para o teto do container, e a memoria e conferida");
  const base = mkdtempSync(join(tmpdir(), "eggstart-"));
  const bin = join(base, "stub-bin");
  mkdirSync(join(base, "ollama", "bin"), { recursive: true });
  mkdirSync(join(base, "owui-venv", "bin"), { recursive: true });
  mkdirSync(join(base, "stub-bin"), { recursive: true });
  mkdirSync(join(base, "models", "blobs"), { recursive: true });
  writeFileSync(join(base, "ollama", "VERSION"), "v0.0.0-teste\n");
  writeFileSync(join(base, "stub-bin", "curl"), "#!/bin/bash\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "stub-bin", "curl")]);
  // modelo de ~5 MB no disco, para a conta de memoria ser deterministica
  writeFileSync(join(base, "models", "blobs", "sha256-fake"), Buffer.alloc(5 * 1024 * 1024, 7));
  writeFileSync(join(base, "ollama", "bin", "ollama"),
    "#!/bin/bash\ncase \"$1\" in serve) exit 0 ;; list) printf 'NAME              ID     SIZE     MODIFIED\\npequeno:0.6b      a1     523 MB   agora\\ngrande:7b          b2     4.7 GB   agora\\n' ;; esac\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "ollama", "bin", "ollama")]);
  writeFileSync(join(base, "owui-venv", "bin", "open-webui"),
    "#!/bin/bash\nsleep 2\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "owui-venv", "bin", "open-webui")]);

  const ncpu = Number(execSync("nproc").toString().trim());
  const envBase = { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true",
                    PATH: bin + ":" + process.env.PATH };

  let out = run(base, { ...envBase, CPU_THREADS: "auto" });
  ok(out.includes(`threads   : ${ncpu} (vCPU visiveis: ${ncpu})`),
     `CPU_THREADS=auto virou o teto do container (${ncpu})`);
  out = run(base, { ...envBase, CPU_THREADS: "abc" });
  ok(out.includes(`threads   : ${ncpu} (`), "CPU_THREADS nao numerico tambem cai no teto");

  out = run(base, { ...envBase, CPU_THREADS: "auto", MEM_LIMIT_MB: "1" });
  ok(out.includes("AVISO: NAO CABE"), "avisa quando modelo + interface nao cabem na RAM");
  ok(out.includes("O chat vai travar"), "explica a consequencia, nao so o numero");
  ok(out.includes("maior modelo 4812 MB"),
     "a conta usa o MAIOR modelo (4.7 GB), nao a soma dos instalados");
  ok(!out.includes("maior modelo 5 MB"), "nao somou os modelos todos do disco");
  out = run(base, { ...envBase, CPU_THREADS: "auto", MEM_LIMIT_MB: "8000" });
  ok(!out.includes("AVISO: NAO CABE"), "com RAM suficiente nao avisa nada");
  // disco e a primeira parede: o aviso tem que sair ANTES do pull
  out = run(base, { ...envBase, CPU_THREADS: "auto", DISK_FREE_MB: "500", AUTO_PULL: "true", MODEL: "llama3.1:8b" });
  ok(out.includes("AVISO: menos de 2 GB livres"), "avisa quando o disco esta curto");
  ok(out.indexOf("AVISO: menos de 2 GB livres") < out.indexOf("Baixando 'llama3.1:8b'"),
     "o aviso de disco sai ANTES de comecar o download");
  out = run(base, { ...envBase, CPU_THREADS: "auto", DISK_FREE_MB: "20000" });
  ok(!out.includes("menos de 2 GB livres"), "com disco sobrando nao avisa");
  ok(out.includes("disco     : 20000 MB livres"), "mostra quanto disco tem");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 11. login no ollama.com
{
  console.log("\n[11] SIGNIN=1 imprime a URL de login no console (container nao tem navegador)");
  const base = mkdtempSync(join(tmpdir(), "eggstart-"));
  for (const d of ["ollama/bin", "owui-venv/bin", "stub-bin"]) mkdirSync(join(base, d), { recursive: true });
  writeFileSync(join(base, "ollama", "VERSION"), "v0.0.0-teste\n");
  writeFileSync(join(base, "stub-bin", "curl"),
    `#!/bin/bash
case "$*" in
  *api/generate*) [ -n "$STUB_AUTH" ] && echo '{"response":"hi"}' || echo '{"error":"Unauthorized"}' ;;
esac
exit 0
`);
  spawnSync("chmod", ["+x", join(base, "stub-bin", "curl")]);
  writeFileSync(join(base, "ollama", "bin", "ollama"), `#!/bin/bash
case "$1" in
  serve)  exit 0 ;;
  list)   printf 'NAME\n' ;;
  signin) [ "$BROWSER" = "/bin/true" ] || { echo "NAO_SET_BROWSER"; }
          echo "If your browser did not open, navigate to:"
          echo "    https://ollama.com/connect?name=teste&key=CHAVE"
          exit 0 ;;
esac
exit 0
`);
  spawnSync("chmod", ["+x", join(base, "ollama", "bin", "ollama")]);
  writeFileSync(join(base, "owui-venv", "bin", "open-webui"), "#!/bin/bash\nsleep 2\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "owui-venv", "bin", "open-webui")]);

  const envBase = { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true",
                    PATH: join(base, "stub-bin") + ":" + process.env.PATH };
  const out = run(base, { ...envBase, SIGNIN: "1", _signin_tries: "2" });
  ok(out.includes("https://ollama.com/connect?name=teste&key=CHAVE"),
     "a URL de login aparece no console");
  ok(!out.includes("NAO_SET_BROWSER"), "BROWSER=/bin/true (sem a pilha de erros do xdg-open)");
  ok(!out.includes("LOGIN CONFIRMADO"),
     "sem autorizar NAO diz que logou (signin sai na hora, exit 0 nao prova nada)");
  ok(out.includes("Esperando voce autorizar"), "fica esperando a autorizacao de verdade");
  const sim = run(base, { ...envBase, SIGNIN: "1", STUB_AUTH: "1", _signin_tries: "2" });
  ok(sim.includes("LOGIN CONFIRMADO"), "quando o cloud responde, confirma");
  const sem = run(base, { ...envBase, SIGNIN: "0" });
  ok(!sem.includes("ollama.com/connect"), "com SIGNIN=0 nao tenta logar");
  // sem a variavel na egg, o arquivo .signin faz o mesmo servico
  writeFileSync(join(base, ".signin"), "");
  const porArquivo = run(base, { ...envBase, SIGNIN: "0", STUB_AUTH: "1", _signin_tries: "2" });
  ok(porArquivo.includes("ollama.com/connect"),
     "o arquivo .signin aciona o login mesmo com SIGNIN=0 (nao precisa reimportar a egg)");
  ok(porArquivo.includes("apague ele depois"), "manda apagar o arquivo");
  rmSync(join(base, ".signin"));
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 12. varios modelos em MODEL
{
  console.log("\n[12] MODEL aceita varios nomes (no painel e a unica entrada sem terminal)");
  const base = mkdtempSync(join(tmpdir(), "eggstart-"));
  for (const d of ["ollama/bin", "owui-venv/bin", "stub-bin"]) mkdirSync(join(base, d), { recursive: true });
  writeFileSync(join(base, "ollama", "VERSION"), "v0.0.0-teste\n");
  writeFileSync(join(base, "stub-bin", "curl"), "#!/bin/bash\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "stub-bin", "curl")]);
  writeFileSync(join(base, "ollama", "bin", "ollama"),
    "#!/bin/bash\ncase \"$1\" in serve) exit 0 ;; list) printf 'NAME\n' ;; esac\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "ollama", "bin", "ollama")]);
  writeFileSync(join(base, "owui-venv", "bin", "open-webui"), "#!/bin/bash\nsleep 2\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "owui-venv", "bin", "open-webui")]);

  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true",
                          AUTO_PULL: "true", MODEL: "qwen3:0.6b, tinyllama",
                          PATH: join(base, "stub-bin") + ":" + process.env.PATH });
  ok(out.includes("Baixando 'qwen3:0.6b'"), "baixou o primeiro");
  ok(out.includes("Baixando 'tinyllama'"), "baixou o segundo da lista separada por virgula");
  ok(!out.includes("Baixando 'qwen3:0.6b, tinyllama'"), "nao tratou a lista como um nome so");
  rmSync(base, { recursive: true, force: true });
}

// ---------------------------------------------------------------- 13. CORS no modo API pura
{
  console.log("\n[13] sem interface, o aviso de CORS aparece (403 nao se explica sozinho)");
  const base = mkdtempSync(join(tmpdir(), "eggstart-"));
  for (const d of ["ollama/bin", "stub-bin"]) mkdirSync(join(base, d), { recursive: true });
  writeFileSync(join(base, "ollama", "VERSION"), "v0.0.0-teste\n");
  writeFileSync(join(base, "stub-bin", "curl"), "#!/bin/bash\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "stub-bin", "curl")]);
  writeFileSync(join(base, "ollama", "bin", "ollama"),
    "#!/bin/bash\ncase \"$1\" in serve) echo \"OLLAMA-ARGS:$*\"; sleep 2 ;; list) printf 'NAME\n' ;; esac\nexit 0\n");
  spawnSync("chmod", ["+x", join(base, "ollama", "bin", "ollama")]);

  const envBase = { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "false",
                    PATH: join(base, "stub-bin") + ":" + process.env.PATH };
  let out = run(base, { ...envBase, ORIGINS: "" });
  ok(out.includes("ORIGINS esta vazio"), "avisa que a API vai dar 403 de fora");
  ok(out.includes("volta 403"), "explica o sintoma, nao so a causa");
  out = run(base, { ...envBase, ORIGINS: "*" });
  ok(out.includes("origens   : *"), "mostra as origens quando estao definidas");
  ok(!out.includes("ORIGINS esta vazio"), "com ORIGINS definido nao avisa");
  rmSync(base, { recursive: true, force: true });
}

// ------------------------------------------------- 14. URL do Ollama gravada no banco do OWUI
{
  console.log("\n[14] URL do Ollama no banco (env nao sobrescreve depois da 1a init)");
  const src = readFileSync(join(import.meta.dirname, "..", "src", "ollama-start.sh"), "utf8");
  ok(src.includes("owui_fix_ollama_url()"), "existe a funcao que corrige o banco");
  ok(src.indexOf("owui_fix_ollama_url\n") > src.indexOf('export OLLAMA_BASE_URL='),
     "e chamada depois de definir OLLAMA_BASE_URL");
  ok(src.indexOf('curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:${_ip}/api/version"')
       < src.indexOf('exec "${OWUI_BIN}" serve'),
     "espera o Ollama responder antes de entregar a allocation ao Open WebUI");
  ok(src.includes("Network Problem"), "o aviso cita o sintoma que o usuario ve");
  // O CI pegou isto: um printf sem '\n' antes da espera deixava o "serve" do
  // Ollama (background) colado na mesma linha, e o assert ^OLLAMA-ARGS: nao
  // casava. Trava a forma de imprimir, nao so o conteudo.
  ok(!/printf '\[egg\]/.test(src), "nenhum printf deixa linha aberta na saida");
  ok(src.includes('echo "[egg] API do Ollama em 127.0.0.1:${_ip}: ${_st} (${_i}s)"'),
     "o relato da espera sai em uma linha unica e completa");

  // funcional: banco com URL errada -> script corrige
  const base = mkdtempSync(join(tmpdir(), "eggstart-"));
  for (const d of ["ollama/bin", "owui-venv/bin", "open-webui", "stub-bin"]) mkdirSync(join(base, d), { recursive: true });
  writeFileSync(join(base, "ollama", "VERSION"), "v0.0.0-teste\n");
  writeFileSync(join(base, "ollama", "bin", "ollama"),
    "#!/bin/bash\ncase \"$1\" in serve) sleep 3 ;; list) printf 'NAME\\n' ;; esac\nexit 0\n");
  writeFileSync(join(base, "owui-venv", "bin", "open-webui"), "#!/bin/bash\necho OWUI-SUBIU\nexit 0\n");
  writeFileSync(join(base, "stub-bin", "curl"), "#!/bin/bash\nexit 0\n");
  for (const f of ["ollama/bin/ollama", "owui-venv/bin/open-webui", "stub-bin/curl"])
    spawnSync("chmod", ["+x", join(base, f)]);
  const db = join(base, "open-webui", "webui.db");
  spawnSync("python3", ["-c",
    "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);" +
    "c.execute(\"create table config(key text primary key, value text, updated_at int)\");" +
    "c.execute(\"insert into config values('ollama.base_urls','[\\\"http://SEU_IP:25565\\\"]',0)\");" +
    "c.commit()", db]);

  const out = run(base, { ...COMMON, SERVER_PORT: "25565", ENABLE_OPENWEBUI: "true",
                          PATH: join(base, "stub-bin") + ":" + process.env.PATH });
  ok(out.includes("conexao Ollama:"), "imprime a correcao que fez");
  ok(out.includes("http://SEU_IP:25565"), "mostra o valor errado que estava la");
  ok(out.includes("http://127.0.0.1:11434"), "mostra o valor certo que entrou");
  const after = spawnSync("python3", ["-c",
    "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(" +
    "\"select value from config where key='ollama.base_urls'\").fetchone()[0])", db]).stdout.toString().trim();
  ok(after === '["http://127.0.0.1:11434"]', `banco realmente corrigido (${after})`);
  ok(out.includes("OWUI-SUBIU"), "e o Open WebUI subiu depois");
  rmSync(base, { recursive: true, force: true });
}

console.log(`\n${fail === 0 ? "PASSOU" : "FALHOU"}: ${pass} asserts ok, ${fail} falhas`);
process.exit(fail === 0 ? 0 : 1);
