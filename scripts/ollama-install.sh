#!/bin/bash
#
# Ollama egg - script de instalacao (Pterodactyl / Pelican)
# Roda como root num container descartavel; os arquivos do server estao em /mnt/server.
# As variaveis da egg chegam aqui como variaveis de ambiente (o Wings faz isso).
#
set -o pipefail

SERVER_DIR="/mnt/server"
OLLAMA_DIR="${SERVER_DIR}/ollama"
BIN_DIR="${OLLAMA_DIR}/bin"
LIB_DIR="${OLLAMA_DIR}/lib/ollama"

echo "=============================================="
echo " Instalacao da egg Ollama"
echo "=============================================="
echo "[egg] server dir : ${SERVER_DIR}"
echo "[egg] arch       : $(uname -m)"

# --------------------------------------------------------------- dependencias
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
    curl ca-certificates zstd tar xz-utils jq >/dev/null 2>&1 || true

for DEP in curl zstd tar; do
    if ! command -v "${DEP}" >/dev/null 2>&1; then
        echo "[egg] ERRO: '${DEP}' nao esta disponivel no container de instalacao."
        exit 1
    fi
done

case "$(uname -m)" in
    x86_64)          ASSET_ARCH="amd64" ;;
    aarch64 | arm64) ASSET_ARCH="arm64" ;;
    *)
        echo "[egg] ERRO: arquitetura '$(uname -m)' nao tem build oficial do Ollama."
        exit 1
        ;;
esac

# --------------------------------------------------------------- versao
VERSION="${OLLAMA_VERSION:-latest}"
if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
    VERSION="$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d '"' -f 4)"
fi
if [ -z "${VERSION}" ]; then
    echo "[egg] ERRO: nao foi possivel resolver a versao do Ollama (GitHub fora do ar?)."
    exit 1
fi
echo "[egg] versao     : ${VERSION}"

# --------------------------------------------------------------- download
# ATENCAO: o Wings monta /tmp do container de instalacao como tmpfs de 100 MB
# (config.yml: docker.tmpfs_size), entao NAO da pra baixar o tarball la.
# Trabalhamos dentro do proprio diretorio do server e limpamos no final.
BASE_URL="https://github.com/ollama/ollama/releases/download/${VERSION}"
WORK="${SERVER_DIR}/.install-tmp"
rm -rf "${WORK}"
mkdir -p "${WORK}" || exit 1
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1

AVAIL_MB="$(df -BM --output=avail "${SERVER_DIR}" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${AVAIL_MB}" ] && [ "${AVAIL_MB}" -lt 4500 ]; then
    echo "[egg] AVISO: so tem ${AVAIL_MB} MB livres no disco do server."
    echo "[egg]        a instalacao precisa de ~4.5 GB de pico (download + extracao)"
    echo "[egg]        e depois fica em ~300 MB. Aumente o limite de disco no painel."
fi
echo "[egg] espaco livre: ${AVAIL_MB:-?} MB"

ASSET=""
for CANDIDATE in "ollama-linux-${ASSET_ARCH}.tar.zst" "ollama-linux-${ASSET_ARCH}.tgz"; do
    if curl -fsSLI -o /dev/null "${BASE_URL}/${CANDIDATE}"; then
        ASSET="${CANDIDATE}"
        break
    fi
done
if [ -z "${ASSET}" ]; then
    echo "[egg] ERRO: nenhum asset encontrado em ${BASE_URL}"
    echo "[egg]       confira se a variavel OLLAMA_VERSION esta certa (ex.: v0.34.0)."
    exit 1
fi

echo "[egg] baixando ${ASSET} (1.3 GB+ no amd64, aguarde)..."
if ! curl -fL --retry 3 --retry-delay 5 -o "${ASSET}" "${BASE_URL}/${ASSET}"; then
    echo "[egg] ERRO: falha no download de ${ASSET}"
    exit 1
fi
echo "[egg] download concluido: $(du -h "${ASSET}" | cut -f1)"

# --------------------------------------------------------------- checksum (melhor esforco)
if curl -fsSL -o sha256sum.txt "${BASE_URL}/sha256sum.txt" 2>/dev/null; then
    EXPECTED="$(grep -m1 " ${ASSET}\$" sha256sum.txt | awk '{print $1}')"
    if [ -n "${EXPECTED}" ]; then
        ACTUAL="$(sha256sum "${ASSET}" | awk '{print $1}')"
        if [ "${EXPECTED}" = "${ACTUAL}" ]; then
            echo "[egg] checksum OK (${ACTUAL:0:16}...)"
        else
            echo "[egg] ERRO: checksum confere nao."
            echo "[egg]   esperado: ${EXPECTED}"
            echo "[egg]   obtido  : ${ACTUAL}"
            exit 1
        fi
    fi
fi

# --------------------------------------------------------------- extracao
echo "[egg] extraindo em ${OLLAMA_DIR} ..."
rm -rf "${BIN_DIR}" "${LIB_DIR}"
mkdir -p "${BIN_DIR}" "${LIB_DIR}"

case "${ASSET}" in
    *.tar.zst) zstd -dc "${ASSET}" | tar -xf - -C "${OLLAMA_DIR}" ;;
    *.tgz)     tar -xzf "${ASSET}" -C "${OLLAMA_DIR}" ;;
esac
if [ ! -f "${BIN_DIR}/ollama" ]; then
    echo "[egg] ERRO: extracao nao produziu ${BIN_DIR}/ollama"
    echo "[egg] conteudo encontrado:"
    find "${OLLAMA_DIR}" -maxdepth 2 | head -20
    exit 1
fi
chmod +x "${BIN_DIR}/ollama"
echo "${VERSION}" > "${OLLAMA_DIR}/VERSION"
rm -f "${ASSET}"

# --------------------------------------------------------------- remover libs de GPU
# O Pterodactyl nao repassa GPU pro container, entao CUDA/ROCm/Vulkan/MLX so ocupam disco.
if [ "${STRIP_GPU_LIBS:-true}" = "true" ]; then
    BEFORE="$(du -sh "${OLLAMA_DIR}" 2>/dev/null | cut -f1)"
    find "${OLLAMA_DIR}/lib" -mindepth 1 -maxdepth 2 -type d \
        \( -iname '*cuda*' -o -iname '*rocm*' -o -iname '*vulkan*' -o -iname '*mlx*' -o -iname '*jetpack*' \) \
        -exec rm -rf {} + 2>/dev/null
    find "${OLLAMA_DIR}/lib" -mindepth 1 -maxdepth 2 -type f \
        \( -iname '*cuda*' -o -iname '*rocm*' -o -iname '*vulkan*' -o -iname '*mlx*' -o -iname '*jetpack*' -o -iname '*rocblas*' \) \
        -delete 2>/dev/null
    echo "[egg] libs de GPU removidas: ${BEFORE} -> $(du -sh "${OLLAMA_DIR}" | cut -f1)"
fi

# --------------------------------------------------------------- bibliotecas externas
# Nao e preciso copiar nada de sistema: as .so do Ollama usam RUNPATH=$ORIGIN e so
# dependem de libc/libstdc++/libgomp (a libgomp ja vem dentro de lib/ollama).
# Verificado no v0.34.0: nenhum arquivo do build CPU referencia OpenBLAS.
MISSING="$(ldd "${LIB_DIR}"/libggml-cpu-*.so 2>/dev/null | grep 'not found' | sort -u)"
if [ -n "${MISSING}" ]; then
    echo "[egg] AVISO: bibliotecas ausentes detectadas:"
    echo "${MISSING}"
else
    echo "[egg] bibliotecas do build CPU resolvidas (nada faltando)."
fi

# --------------------------------------------------------------- diretorios de runtime
mkdir -p "${SERVER_DIR}/models" "${SERVER_DIR}/.ollama" "${SERVER_DIR}/temp" "${SERVER_DIR}/ui"

# --------------------------------------------------------------- interface web (sidecar)
# O chat vem do Git, entao da pra atualizar sem reinstalar a egg inteira.
# Repo publico: nao precisa de credencial dentro do servidor.
UI_REPO="${UI_REPO:-https://github.com/eduhdev021/latam-ia.git}"
UI_REF="${UI_REF:-main}"
UI_FROM_GIT="false"

command -v git >/dev/null 2>&1 || apt-get install -y --no-install-recommends git >/dev/null 2>&1 || true
if command -v git >/dev/null 2>&1; then
    echo "[egg] buscando o chat em ${UI_REPO} (${UI_REF})..."
    rm -rf "${WORK}/ui-repo"
    if git clone --depth 1 --branch "${UI_REF}" "${UI_REPO}" "${WORK}/ui-repo" >/dev/null 2>&1; then
        if [ -f "${WORK}/ui-repo/scripts/ui-chat.html" ] && [ -f "${WORK}/ui-repo/scripts/ui-proxy.js" ]; then
            cp "${WORK}/ui-repo/scripts/ui-chat.html" "${SERVER_DIR}/ui/chat.html"
            cp "${WORK}/ui-repo/scripts/ui-proxy.js"  "${SERVER_DIR}/ui/proxy.js"
            git -C "${WORK}/ui-repo" rev-parse --short HEAD > "${SERVER_DIR}/ui/.git-ref" 2>/dev/null || true
            UI_FROM_GIT="true"
            echo "[egg] chat instalado do Git (commit $(cat "${SERVER_DIR}/ui/.git-ref" 2>/dev/null || echo '?'))"
        else
            echo "[egg] AVISO: o repo nao tem scripts/ui-chat.html e scripts/ui-proxy.js."
        fi
    else
        echo "[egg] AVISO: git clone falhou (repo fora do ar? branch '${UI_REF}' existe?)."
    fi
else
    echo "[egg] AVISO: git indisponivel no container de instalacao."
fi

# Fallback: se o Git nao entregou nada, usa a copia embutida na egg. O server sobe igual.
if [ "${UI_FROM_GIT}" != "true" ]; then
    echo "[egg] usando o chat embutido na egg (fallback)."
    cat > "${SERVER_DIR}/ui/proxy.js" << 'PROXYEOF'
'use strict';
// Sidecar da egg Ollama. Duas funcoes:
//
//   1. serve o chat em "/" (arquivo unico, sem CDN - a pagina funciona offline)
//   2. faz proxy de todo o resto para a API do Ollama, que escuta so em 127.0.0.1
//
// Assim uma unica allocation atende o chat e a API. Sem dependencias npm.
//
// Por que isso e nao "ligar o Ollama em 0.0.0.0": a API do Ollama nao tem
// autenticacao. Quem abrir a allocation na internet expoe o modelo pra qualquer
// um. Aqui a allocation so fala com o chat, e a API fica em localhost.

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PUBLIC_PORT = parseInt(process.env.SERVER_PORT || '11434', 10);
const UPSTREAM_HOST = '127.0.0.1';
const UPSTREAM_PORT = parseInt(process.env.OLLAMA_INTERNAL_PORT || '11434', 10);
const CHAT_HTML = path.join(__dirname, 'chat.html');
const SESSION_FILE = path.join(__dirname, '.session.json');

// 0 = Ollama decide; >0 limita as threads de inferencia (modelo pequeno sofre com thread demais)
const CPU_THREADS = String(parseInt(process.env.CPU_THREADS || '0', 10) || 0);

// Chave do token de acesso. Vazio = chat aberto (comportamento antigo).
// UI_TOKEN vem da aba Startup do servidor; veja a variavel de mesmo nome na egg.
const UI_TOKEN = (process.env.UI_TOKEN || '').trim();
const MAX_BODY = 32 * 1024 * 1024; // 32 MB: base64 de imagem + contexto grande

// ----------------------------------------------------------------- sessao
// Token por sessao, guardado no disco para sobreviver ao restart. Assim o
// navegador nao precisa reenviar ?token= a cada reload, e o admin pode trocar
// o UI_TOKEN sem derrubar quem ja esta logado.
let sessions = new Map(); // token -> { exp }
function loadSessions() {
  try {
    const raw = JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'));
    sessions = new Map(Object.entries(raw));
  } catch (e) {
    sessions = new Map();
  }
}
function saveSessions() {
  const now = Date.now();
  for (const [t, v] of sessions) if (v.exp < now) sessions.delete(t);
  try {
    fs.writeFileSync(SESSION_FILE, JSON.stringify(Object.fromEntries(sessions)), { mode: 0o600 });
  } catch (e) {
    /* disco cheio/read-only: a sessao dura ate o restart, nao e fatal */
  }
}
function newSession() {
  const token = crypto.randomBytes(24).toString('hex');
  sessions.set(token, { exp: Date.now() + 30 * 86400000 }); // 30 dias
  saveSessions();
  return token;
}
function sessionValid(token) {
  if (!token) return false;
  const s = sessions.get(token);
  if (!s) return false;
  if (s.exp < Date.now()) {
    sessions.delete(token);
    saveSessions();
    return false;
  }
  return true;
}
function sessionToken(req) {
  const auth = req.headers.authorization || '';
  if (auth.startsWith('Bearer ')) return auth.slice(7).trim();
  const cookie = (req.headers.cookie || '')
    .split(';')
    .map((c) => c.trim())
    .find((c) => c.startsWith('latam_sid='));
  return cookie ? cookie.slice('latam_sid='.length) : '';
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('payload maior que 32 MB'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}
loadSessions();

// ----------------------------------------------------------------- respostas
function json(res, code, obj, headers) {
  const body = JSON.stringify(obj);
  res.writeHead(code, Object.assign({ 'content-type': 'application/json; charset=utf-8' }, headers || {}));
  res.end(body);
}
function sendChat(res, html) {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  res.end(html);
}

function loginPage(message) {
  const err = message
    ? '<p class="err">' + String(message).replace(/[<>&"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c])) + '</p>'
    : '';
  return (
    '<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>LATAM IA - acesso</title><style>' +
    'body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0a0c10;color:#e8ebf0;' +
    'font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}' +
    '.card{background:#101319;border:1px solid #1e232d;border-radius:14px;padding:26px 24px;width:min(340px,90vw)}' +
    '.logo{width:34px;height:34px;border-radius:10px;background:linear-gradient(135deg,#2f6feb,#7b4dff);' +
    'display:grid;place-items:center;font-weight:700;margin-bottom:14px}' +
    'h1{font-size:19px;margin:0 0 4px}p.sub{color:#8b93a3;font-size:13px;margin:0 0 16px}' +
    'input{width:100%;box-sizing:border-box;background:#14181f;border:1px solid #2a313d;color:#e8ebf0;' +
    'border-radius:9px;padding:9px 11px;font:inherit;margin-bottom:10px}' +
    'input:focus{outline:none;border-color:#2f6feb}' +
    'button{width:100%;background:#2f6feb;color:#fff;border:0;border-radius:9px;padding:9px;font:inherit;' +
    'font-weight:600;cursor:pointer}button:hover{background:#4f8bff}' +
    '.err{color:#ff9a9a;font-size:13px;margin:0 0 12px}</style></head><body>' +
    '<form class="card" method="post" action="/login"><div class="logo">L</div>' +
    '<h1>LATAM IA</h1><p class="sub">Digite o token de acesso definido no painel.</p>' +
    err +
    '<input type="password" name="token" placeholder="Token de acesso" autofocus autocomplete="current-password">' +
    '<button type="submit">Entrar</button></form></body></html>'
  );
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  // ---------------------------------------------------------------- login
  if (p === '/login') {
    // GET mostra o formulario; POST confere o token.
    if (req.method !== 'POST') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(loginPage(''));
    }
    return readBody(req)
      .then((raw) => {
        const form = new URLSearchParams(raw);
        const given = (form.get('token') || '').trim();
        const expected = UI_TOKEN;
        // comparacao em tempo constante para nao vazar o token byte a byte
        const ok =
          expected.length > 0 &&
          given.length === expected.length &&
          crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected));
        if (!ok) {
          res.writeHead(401, { 'content-type': 'text/html; charset=utf-8' });
          return res.end(loginPage('Token incorreto.'));
        }
        const sid = newSession();
        res.writeHead(302, {
          'set-cookie': 'latam_sid=' + sid + '; Path=/; Max-Age=' + 30 * 86400 + '; SameSite=Lax',
          location: '/',
        });
        res.end();
      })
      .catch((e) => json(res, 400, { error: e.message }));
  }

  if (p === '/logout') {
    sessions.delete(sessionToken(req));
    saveSessions();
    res.writeHead(302, { 'set-cookie': 'latam_sid=; Path=/; Max-Age=0', location: '/login' });
    return res.end();
  }

  // ---------------------------------------------------------------- chat
  if (req.method === 'GET' && (p === '/' || p === '/index.html')) {
    if (UI_TOKEN && !sessionValid(sessionToken(req))) {
      res.writeHead(302, { location: '/login' });
      return res.end();
    }
    return fs.readFile(CHAT_HTML, (err, buf) => {
      if (err) {
        res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end('chat.html nao encontrado: ' + err.message);
      }
      // injeta a config do servidor na pagina. Nada sensivel aqui: threads e
      // apenas um aviso de performance, e auth so diz se o logout deve aparecer.
      const html = buf
        .toString('utf8')
        .replace(
          '<div id="cfg" style="display:none"></div>',
          '<div id="cfg" style="display:none" data-threads="' +
            CPU_THREADS +
            '" data-auth="' +
            (UI_TOKEN ? '1' : '0') +
            '"></div>'
        );
      sendChat(res, html);
    });
  }

  // ---------------------------------------------------------------- api
  // Tudo que nao for pagina vai pro Ollama. Se o token estiver ligado, exige
  // sessao valida - inclusive pra chamadas diretas de script.
  if (UI_TOKEN && !sessionValid(sessionToken(req))) {
    return json(res, 401, { error: 'nao autenticado - faca login em /login' });
  }

  if (p === '/favicon.ico') {
    res.writeHead(204);
    return res.end();
  }

  const headers = Object.assign({}, req.headers, {
    host: UPSTREAM_HOST + ':' + UPSTREAM_PORT,
  });

  const upstream = http.request(
    {
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      method: req.method,
      path: req.url,
      headers: headers,
    },
    (ures) => {
      res.writeHead(ures.statusCode || 502, ures.headers);
      // pipe preserva o chunked/SSE do Ollama (stream: true)
      ures.pipe(res);
    }
  );

  upstream.on('error', (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'application/json' });
    }
    res.end(JSON.stringify({ error: 'Ollama indisponivel: ' + err.message }));
  });

  req.pipe(upstream);
});

server.on('clientError', (err, socket) => {
  if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
});

server.listen(PUBLIC_PORT, '0.0.0.0', () => {
  console.log('[ui] chat em http://0.0.0.0:' + PUBLIC_PORT + '/  ->  API em 127.0.0.1:' + UPSTREAM_PORT);
  if (UI_TOKEN) {
    console.log('[ui] autenticacao LIGADA (UI_TOKEN definido). A API tambem exige login.');
  } else {
    console.log('[ui] AVISO: sem autenticacao. Qualquer um com a URL usa o chat e a API.');
    console.log('[ui]       Defina UI_TOKEN na aba Startup para exigir login.');
  }
});

const shutdown = (signal) => {
  console.log('[ui] ' + signal + ' recebido, encerrando.');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
PROXYEOF
    cat > "${SERVER_DIR}/ui/chat.html" << 'CHATEOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0a0c10">
<title>LATAM IA</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0a0c10;
    --panel: #101319;
    --panel-2: #14181f;
    --panel-3: #1a1f28;
    --line: #1e232d;
    --line-2: #2a313d;
    --text: #e8ebf0;
    --muted: #8b93a3;
    --dim: #667083;
    --accent: #2f6feb;
    --accent-2: #4f8bff;
    --user-bubble: #1a2338;
    --danger: #b3392f;
    --ok: #4bb377;
    --radius: 14px;
  }
  :root.light {
    color-scheme: light;
    --bg: #f6f7f9;
    --panel: #ffffff;
    --panel-2: #f1f3f7;
    --panel-3: #e7eaf0;
    --line: #e2e6ed;
    --line-2: #ccd3de;
    --text: #171a20;
    --muted: #5c6575;
    --dim: #78818f;
    --user-bubble: #e5edff;
    --danger: #c0392b;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0;
    display: flex;
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
    overscroll-behavior: none;
  }
  button, select, textarea, input { font: inherit; color: inherit; }
  button { cursor: pointer; background: none; border: none; }
  a { color: var(--accent-2); }
  ::-webkit-scrollbar { width: 9px; height: 9px; }
  ::-webkit-scrollbar-thumb { background: var(--line-2); border-radius: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }

  /* ---------------- sidebar ---------------- */
  #side {
    flex: 0 0 268px; width: 268px; display: flex; flex-direction: column;
    background: var(--panel); border-right: 1px solid var(--line);
    transition: transform .18s ease, opacity .18s ease;
  }
  #side.hidden { display: none; }
  .side-head { padding: 12px 12px 8px; display: flex; align-items: center; gap: 9px; }
  .side-head .logo {
    width: 26px; height: 26px; border-radius: 8px; flex: 0 0 auto;
    background: linear-gradient(135deg, var(--accent), #7b4dff);
    display: grid; place-items: center; font-size: 13px; font-weight: 700; color: #fff;
  }
  .side-head .t { font-weight: 650; font-size: 14px; }
  .side-head .spacer { flex: 1; }
  #new-chat {
    margin: 0 12px 10px; padding: 9px 11px; border-radius: 10px;
    background: var(--accent); color: #fff; font-weight: 600; font-size: 14px;
    display: flex; align-items: center; justify-content: center; gap: 7px;
  }
  #new-chat:hover { background: var(--accent-2); }
  .search { margin: 0 12px 8px; position: relative; }
  .search input {
    width: 100%; background: var(--panel-2); border: 1px solid var(--line-2);
    border-radius: 9px; padding: 7px 10px; font-size: 13px;
  }
  .search input:focus { outline: none; border-color: var(--accent); }
  #chats { flex: 1 1 auto; overflow-y: auto; padding: 0 8px 8px; }
  .grp { font-size: 11px; color: var(--dim); text-transform: uppercase; letter-spacing: .6px; padding: 10px 6px 4px; }
  .chat-item {
    position: relative; padding: 8px 28px 8px 9px; border-radius: 8px; cursor: pointer;
    font-size: 13.5px; color: var(--muted); white-space: nowrap; overflow: hidden;
    text-overflow: ellipsis; border: 1px solid transparent;
  }
  .chat-item:hover { background: var(--panel-2); color: var(--text); }
  .chat-item.active { background: var(--panel-2); color: var(--text); border-color: var(--line-2); }
  .chat-item .x {
    position: absolute; right: 5px; top: 50%; transform: translateY(-50%);
    width: 19px; height: 19px; border-radius: 5px; display: none; place-items: center;
    color: var(--dim); font-size: 13px; line-height: 1;
  }
  .chat-item:hover .x { display: grid; }
  .chat-item .x:hover { background: var(--danger); color: #fff; }
  .side-foot { border-top: 1px solid var(--line); padding: 8px; display: flex; gap: 6px; flex-wrap: wrap; }
  .side-foot button {
    flex: 1 1 auto; font-size: 12px; color: var(--muted); padding: 6px 8px;
    border-radius: 8px; border: 1px solid var(--line-2);
  }
  .side-foot button:hover { color: var(--text); background: var(--panel-2); }
  .empty-chats { padding: 22px 12px; text-align: center; color: var(--dim); font-size: 12.5px; }

  /* ---------------- coluna principal ---------------- */
  main { flex: 1 1 auto; display: flex; flex-direction: column; min-width: 0; }

  header {
    flex: 0 0 auto; display: flex; align-items: center; gap: 8px;
    padding: 9px 12px; background: var(--panel); border-bottom: 1px solid var(--line);
  }
  .brand { display: flex; align-items: center; gap: 8px; font-weight: 650; letter-spacing: .3px; font-size: 14px; }
  .brand .logo {
    width: 24px; height: 24px; border-radius: 7px; flex: 0 0 auto;
    background: linear-gradient(135deg, var(--accent), #7b4dff);
    display: grid; place-items: center; font-size: 12px; font-weight: 700; color: #fff;
  }
  .brand .sub { font-size: 11px; color: var(--muted); font-weight: 500; }
  header .spacer { flex: 1; }
  select {
    background: var(--panel-2); border: 1px solid var(--line-2); border-radius: 9px;
    padding: 6px 9px; font-size: 13px; max-width: 40vw;
  }
  .icon-btn {
    width: 33px; height: 33px; border-radius: 9px; display: grid; place-items: center;
    border: 1px solid var(--line-2); background: var(--panel-2); color: var(--muted);
    font-size: 15px; line-height: 1; flex: 0 0 auto;
  }
  .icon-btn:hover { color: var(--text); border-color: #3a4353; }
  .icon-btn.on { color: var(--accent-2); border-color: var(--accent); }

  /* ---------------- mensagens ---------------- */
  #log {
    flex: 1 1 auto; overflow-y: auto; -webkit-overflow-scrolling: touch;
    padding: 20px 14px 12px;
  }
  .wrap { max-width: 780px; margin: 0 auto; }
  .empty { text-align: center; color: var(--muted); margin: 11vh 0 0; }
  .empty h1 { font-size: 26px; margin: 0 0 6px; color: var(--text); font-weight: 650; }
  .empty p { margin: 0; font-size: 14px; }
  .empty .hint { margin-top: 16px; font-size: 13px; color: var(--dim); }

  .msg { display: flex; gap: 10px; margin: 0 0 18px; }
  .msg .avatar {
    flex: 0 0 auto; width: 28px; height: 28px; border-radius: 8px; margin-top: 2px;
    display: grid; place-items: center; font-size: 11px; font-weight: 700;
    background: var(--panel-3); color: var(--muted); border: 1px solid var(--line-2);
  }
  .msg.user .avatar { background: var(--user-bubble); color: #9db9f5; border-color: #263453; }
  :root.light .msg.user .avatar { color: #2c5cc5; }
  .msg .body { flex: 1 1 auto; min-width: 0; }
  .msg .who { font-size: 12px; color: var(--muted); margin-bottom: 3px; font-weight: 600; }
  .content { overflow-wrap: anywhere; word-break: break-word; }
  .content > *:first-child { margin-top: 0; }
  .content > *:last-child { margin-bottom: 0; }
  .content p { margin: 7px 0; }
  .content h1, .content h2, .content h3, .content h4 {
    margin: 15px 0 7px; font-weight: 650; line-height: 1.35;
  }
  .content h1 { font-size: 21px; } .content h2 { font-size: 18px; }
  .content h3 { font-size: 16px; } .content h4 { font-size: 14.5px; }
  .content ul, .content ol { margin: 7px 0; padding-left: 22px; }
  .content li { margin: 3px 0; }
  .content li > ul, .content li > ol { margin: 3px 0; }
  .content blockquote {
    margin: 9px 0; padding: 3px 12px; border-left: 3px solid var(--line-2);
    color: var(--muted);
  }
  .content hr { border: 0; border-top: 1px solid var(--line); margin: 14px 0; }
  .content a { text-decoration: none; }
  .content a:hover { text-decoration: underline; }
  .content code {
    background: var(--panel-2); border: 1px solid var(--line); border-radius: 5px;
    padding: 1px 5px; font-size: 13px;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .content pre {
    background: #0c0f14; border: 1px solid var(--line); border-radius: 10px;
    margin: 9px 0; overflow: hidden;
  }
  :root.light .content pre { background: #10131a; }
  .content pre .code-head {
    display: flex; align-items: center; gap: 8px; padding: 5px 10px;
    background: #151a22; border-bottom: 1px solid #232a35;
    font-size: 11.5px; color: #8b93a3;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  .content pre .code-head .lang { text-transform: lowercase; }
  .content pre .code-head .cbtn {
    margin-left: auto; color: #8b93a3; font-size: 11.5px; padding: 1px 6px; border-radius: 5px;
    font-family: inherit;
  }
  .content pre .code-head .cbtn:hover { color: #fff; background: #242c38; }
  .content pre code {
    display: block; padding: 11px 13px; overflow-x: auto;
    background: none; border: none; font-size: 13px; line-height: 1.5; color: #d6dbe4;
  }
  .content table { border-collapse: collapse; margin: 10px 0; font-size: 13.5px; display: block; overflow-x: auto; }
  .content th, .content td { border: 1px solid var(--line-2); padding: 5px 10px; text-align: left; }
  .content th { background: var(--panel-2); font-weight: 650; }
  .content img { max-width: 100%; border-radius: 8px; margin: 6px 0; }
  .content .katex-err { color: var(--danger); font-size: 12px; }

  /* syntax highlight (tema escuro, sempre) */
  .tok-kw { color: #c678dd; } .tok-str { color: #98c379; } .tok-num { color: #d19a66; }
  .tok-com { color: #5c6370; font-style: italic; } .tok-fn { color: #61afef; }
  .tok-type { color: #e5c07b; } .tok-op { color: #56b6c2; } .tok-var { color: #e06c75; }
  .tok-attr { color: #d19a66; } .tok-tag { color: #e06c75; }

  .think {
    color: var(--muted); font-size: 13.5px; border-left: 2px solid var(--line-2);
    padding-left: 10px; margin-bottom: 8px;
  }
  .think summary { cursor: pointer; font-size: 12.5px; color: var(--dim); }
  .think .think-body { margin-top: 5px; font-style: italic; white-space: pre-wrap; }

  .toolcall {
    border: 1px solid var(--line-2); border-radius: 10px; margin: 8px 0;
    background: var(--panel-2); font-size: 13px; overflow: hidden;
  }
  .toolcall .tc-head {
    display: flex; align-items: center; gap: 7px; padding: 6px 10px;
    border-bottom: 1px solid var(--line); font-weight: 600;
  }
  .toolcall .tc-head .badge {
    font-size: 10.5px; padding: 1px 6px; border-radius: 20px;
    background: #2a1f45; color: #b79cff; font-weight: 600;
  }
  .toolcall .tc-head .st { margin-left: auto; font-size: 11.5px; font-weight: 500; color: var(--dim); }
  .toolcall .tc-head .st.ok { color: var(--ok); }
  .toolcall .tc-head .st.bad { color: #ff9a9a; }
  .toolcall pre { margin: 0; padding: 8px 10px; background: none; border: 0; }
  .toolcall code { font-size: 12px; background: none; border: 0; padding: 0; white-space: pre-wrap; }
  .toolcall .tc-args { border-top: 1px dashed var(--line-2); }

  .foot { display: flex; align-items: center; gap: 9px; margin-top: 5px; font-size: 11.5px; color: var(--dim); flex-wrap: wrap; }
  .foot .act { color: var(--dim); font-size: 11.5px; padding: 2px 5px; border-radius: 5px; }
  .foot .act:hover { color: var(--text); background: var(--panel-2); }
  .foot .toks { color: var(--dim); }
  .err { color: #ff9a9a; }

  .caret {
    display: inline-block; width: 7px; height: 15px; margin-left: 2px;
    background: var(--accent-2); vertical-align: text-bottom;
    animation: blink 1.05s steps(1) infinite;
  }
  @keyframes blink { 50% { opacity: 0; } }
  .dots { display: inline-flex; gap: 4px; align-items: center; height: 18px; }
  .dots i { width: 6px; height: 6px; border-radius: 50%; background: var(--muted); animation: bounce 1.15s infinite; }
  .dots i:nth-child(2) { animation-delay: .16s; }
  .dots i:nth-child(3) { animation-delay: .32s; }
  @keyframes bounce { 0%, 60%, 100% { transform: translateY(0); opacity: .45; } 30% { transform: translateY(-4px); opacity: 1; } }

  /* ---------------- composer ---------------- */
  .composer-box {
    flex: 0 0 auto; background: var(--panel); border-top: 1px solid var(--line);
    padding: 10px 14px calc(10px + env(safe-area-inset-bottom));
  }
  .composer {
    max-width: 780px; margin: 0 auto; display: flex; align-items: flex-end; gap: 8px;
    background: var(--panel-2); border: 1px solid var(--line-2); border-radius: 16px; padding: 7px 7px 7px 8px;
  }
  .composer:focus-within { border-color: var(--accent); }
  textarea {
    flex: 1 1 auto; border: none; background: none; resize: none; outline: none;
    max-height: 220px; min-height: 26px; padding: 5px 6px; line-height: 1.5;
  }
  textarea::placeholder { color: #6b7484; }
  .send {
    flex: 0 0 auto; width: 34px; height: 34px; border-radius: 10px; display: grid; place-items: center;
    background: var(--accent); color: #fff; font-size: 15px; transition: background .15s, opacity .15s;
  }
  .send:hover { background: var(--accent-2); }
  .send.stop { background: var(--danger); }
  .send:disabled { opacity: .4; cursor: not-allowed; }
  .attach {
    flex: 0 0 auto; width: 32px; height: 32px; border-radius: 9px; display: grid; place-items: center;
    color: var(--muted); font-size: 17px;
  }
  .attach:hover { color: var(--text); background: var(--panel-3); }
  #files { display: none; }
  .thumbs { max-width: 780px; margin: 0 auto 7px; display: flex; gap: 7px; flex-wrap: wrap; }
  .thumb { position: relative; }
  .thumb img { width: 56px; height: 56px; object-fit: cover; border-radius: 9px; border: 1px solid var(--line-2); display: block; }
  .thumb button {
    position: absolute; top: -6px; right: -6px; width: 19px; height: 19px; border-radius: 50%;
    background: var(--danger); color: #fff; font-size: 11px; line-height: 1; display: grid; place-items: center;
  }
  .bar { max-width: 780px; margin: 7px auto 0; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .bar label { display: flex; align-items: center; gap: 5px; font-size: 12px; color: var(--muted); cursor: pointer; }
  .bar .status { font-size: 12px; color: var(--dim); margin-left: auto; }
  .bar .status.bad { color: #ff9a9a; }
  .pill { font-size: 11.5px; padding: 2px 8px; border-radius: 20px; border: 1px solid var(--line-2); color: var(--muted); }
  .pill.warn { border-color: #6a4a2a; color: #e0a86a; }

  /* ---------------- painel de config ---------------- */
  #panel {
    position: fixed; top: 0; right: 0; bottom: 0; width: min(380px, 92vw); z-index: 40;
    background: var(--panel); border-left: 1px solid var(--line);
    transform: translateX(100%); transition: transform .18s ease;
    display: flex; flex-direction: column;
  }
  #panel.open { transform: none; }
  #panel .ph { display: flex; align-items: center; padding: 12px 14px; border-bottom: 1px solid var(--line); font-weight: 650; }
  #panel .pb { flex: 1 1 auto; overflow-y: auto; padding: 6px 14px 20px; }
  .grp-t { font-size: 11px; color: var(--dim); text-transform: uppercase; letter-spacing: .6px; margin: 16px 0 6px; }
  .fld { margin-bottom: 12px; }
  .fld label { display: block; font-size: 12.5px; color: var(--muted); margin-bottom: 3px; }
  .fld label b { color: var(--text); font-weight: 600; }
  .fld .row { display: flex; align-items: center; gap: 8px; }
  .fld input[type="number"], .fld input[type="text"], .fld select, .fld textarea {
    width: 100%; background: var(--panel-2); border: 1px solid var(--line-2);
    border-radius: 8px; padding: 6px 8px; font-size: 13px;
  }
  .fld textarea { min-height: 62px; resize: vertical; font-family: inherit; }
  .fld input[type="range"] { flex: 1 1 auto; }
  .fld .val { font-size: 12px; color: var(--text); min-width: 42px; text-align: right; font-variant-numeric: tabular-nums; }
  .fld .hint { font-size: 11.5px; color: var(--dim); margin-top: 3px; }
  .switch { display: flex; align-items: center; gap: 8px; font-size: 13px; }
  .switch input { width: 15px; height: 15px; }
  .btn-row { display: flex; gap: 7px; margin-top: 8px; }
  .btn-row button {
    flex: 1 1 auto; padding: 7px; border-radius: 8px; border: 1px solid var(--line-2);
    font-size: 12.5px; color: var(--muted);
  }
  .btn-row button:hover { color: var(--text); background: var(--panel-2); }
  #overlay { position: fixed; inset: 0; background: rgba(0,0,0,.42); z-index: 30; opacity: 0; pointer-events: none; transition: opacity .18s; }
  #overlay.on { opacity: 1; pointer-events: auto; }

  /* modal generico */
  .modal {
    position: fixed; inset: 0; z-index: 50; display: none; place-items: center;
    background: rgba(0,0,0,.5); padding: 16px;
  }
  .modal.on { display: grid; }
  .modal .box {
    background: var(--panel); border: 1px solid var(--line-2); border-radius: 14px;
    padding: 18px; width: min(420px, 100%); max-height: 86vh; overflow-y: auto;
  }
  .modal h2 { margin: 0 0 4px; font-size: 17px; }
  .modal p.d { margin: 0 0 14px; font-size: 13px; color: var(--muted); }
  .modal .fld { margin-bottom: 11px; }
  .modal .acts { display: flex; gap: 8px; margin-top: 14px; }
  .modal .acts button { flex: 1 1 auto; padding: 8px; border-radius: 9px; font-size: 13.5px; font-weight: 600; }
  .modal .acts .pri { background: var(--accent); color: #fff; }
  .modal .acts .sec { border: 1px solid var(--line-2); color: var(--muted); }
  .modal .acts .dan { background: var(--danger); color: #fff; }
  .modal pre.imp { background: var(--panel-2); border: 1px solid var(--line); border-radius: 8px; padding: 9px; font-size: 11.5px; max-height: 200px; overflow: auto; }

  #toast {
    position: fixed; left: 50%; bottom: 26px; transform: translate(-50%, 12px); z-index: 60;
    background: var(--panel-3); border: 1px solid var(--line-2); color: var(--text);
    padding: 8px 14px; border-radius: 10px; font-size: 13px; opacity: 0; pointer-events: none;
    transition: opacity .18s, transform .18s;
  }
  #toast.on { opacity: 1; transform: translate(-50%, 0); }

  @media (max-width: 860px) {
    #side { position: fixed; top: 0; bottom: 0; left: 0; z-index: 35; box-shadow: 0 0 40px rgba(0,0,0,.5); }
    #side.hidden { transform: translateX(-100%); display: flex; }
  }
  @media (max-width: 640px) {
    body { font-size: 15px; }
    #log { padding: 14px 11px 8px; }
    .brand .sub { display: none; }
    select { font-size: 12px; max-width: 34vw; }
    .msg { gap: 8px; margin-bottom: 15px; }
    .msg .avatar { width: 25px; height: 25px; }
    .composer-box { padding: 8px 9px calc(8px + env(safe-area-inset-bottom)); }
  }
</style>
</head>
<body>

<aside id="side">
  <div class="side-head">
    <span class="logo">L</span>
    <span class="t">LATAM IA</span>
    <span class="spacer"></span>
    <button class="icon-btn" id="side-close" title="Fechar" aria-label="Fechar menu">&times;</button>
  </div>
  <button id="new-chat" type="button">+ Nova conversa</button>
  <div class="search"><input id="q" type="search" placeholder="Buscar conversas..." autocomplete="off"></div>
  <div id="chats"></div>
  <div class="side-foot">
    <button type="button" id="export-btn">Exportar</button>
    <button type="button" id="import-btn">Importar</button>
    <button type="button" id="logout-btn" style="display:none">Sair</button>
  </div>
</aside>

<main>
<header>
  <button class="icon-btn" id="menu" title="Conversas" aria-label="Conversas">&#9776;</button>
  <div class="brand">
    <span class="logo">L</span>
    <span>LATAM IA<span class="sub" id="sub"></span></span>
  </div>
  <span class="spacer"></span>
  <select id="model" title="Modelo"><option value="">carregando modelos...</option></select>
  <button class="icon-btn" id="cfg-btn" title="Configuracoes" aria-label="Configuracoes">&#9881;</button>
</header>

<div id="cfg" style="display:none"></div>
<div id="log"><div class="wrap" id="wrap"></div></div>

<div class="composer-box">
  <div class="thumbs" id="thumbs"></div>
  <form id="form" class="composer" style="background:none;border:0;padding:0">
    <div style="display:flex;align-items:flex-end;gap:8px;width:100%;background:var(--panel-2);border:1px solid var(--line-2);border-radius:16px;padding:7px 7px 7px 8px">
      <label class="attach" for="files" title="Anexar imagem">&#128206;</label>
      <input type="file" id="files" accept="image/*" multiple>
      <textarea id="input" rows="1" placeholder="Carregando modelos..." disabled autofocus></textarea>
      <button class="send" id="send" type="submit" title="Enviar" aria-label="Enviar" disabled>&#10148;</button>
    </div>
  </form>
  <div class="bar">
    <label><input type="checkbox" id="think"> raciocinio</label>
    <label><input type="checkbox" id="tools" checked> ferramentas</label>
    <span class="pill" id="caps"></span>
    <span class="status" id="status"></span>
  </div>
</div>
</main>

<div id="overlay"></div>
<aside id="panel">
  <div class="ph">Configuracoes <span class="spacer" style="flex:1"></span>
    <button class="icon-btn" id="panel-close" title="Fechar">&times;</button></div>
  <div class="pb">
    <div class="grp-t">Aparencia</div>
    <div class="fld"><label class="switch"><input type="checkbox" id="p-theme"> Tema claro</label></div>
    <div class="fld"><label class="switch"><input type="checkbox" id="p-math" checked> Renderizar LaTeX (KaTeX)</label>
      <div class="hint">Usa CDN. Desligue se o servidor nao tiver internet.</div></div>

    <div class="grp-t">Prompt de sistema</div>
    <div class="fld"><textarea id="p-system" placeholder="Ex.: Voce e um assistente tecnico. Responda em portugues, direto ao ponto."></textarea>
      <div class="hint">Enviado como mensagem de sistema em toda conversa.</div></div>

    <div class="grp-t">Geracao</div>
    <div class="fld"><label><b>Temperatura</b> <span style="color:var(--dim)">- criatividade</span></label>
      <div class="row"><input type="range" id="p-temp" min="0" max="2" step="0.05" value="0.8"><span class="val" id="v-temp">0.8</span></div></div>
    <div class="fld"><label><b>Top P</b> <span style="color:var(--dim)">- amostragem</span></label>
      <div class="row"><input type="range" id="p-top_p" min="0" max="1" step="0.01" value="0.95"><span class="val" id="v-top_p">0.95</span></div></div>
    <div class="fld"><label><b>Top K</b> <span style="color:var(--dim)">- 0 = desligado</span></label>
      <div class="row"><input type="range" id="p-top_k" min="0" max="200" step="1" value="40"><span class="val" id="v-top_k">40</span></div></div>
    <div class="fld"><label><b>Max tokens</b> <span style="color:var(--dim)">- tamanho da resposta</span></label>
      <div class="row"><input type="number" id="p-num_predict" min="-1" max="131072" value="-1"><span class="val"></span></div>
      <div class="hint">-1 = sem limite (o modelo decide).</div></div>
    <div class="fld"><label><b>Repeat penalty</b></label>
      <div class="row"><input type="range" id="p-repeat_penalty" min="0.5" max="2" step="0.05" value="1.1"><span class="val" id="v-repeat_penalty">1.1</span></div></div>
    <div class="fld"><label><b>Presence penalty</b></label>
      <div class="row"><input type="range" id="p-presence_penalty" min="-2" max="2" step="0.05" value="0"><span class="val" id="v-presence_penalty">0</span></div></div>
    <div class="fld"><label><b>Frequency penalty</b></label>
      <div class="row"><input type="range" id="p-frequency_penalty" min="-2" max="2" step="0.05" value="0"><span class="val" id="v-frequency_penalty">0</span></div></div>
    <div class="fld"><label><b>Seed</b> <span style="color:var(--dim)">- -1 = aleatorio</span></label>
      <div class="row"><input type="number" id="p-seed" value="-1"></div>
      <div class="hint">Fixe a seed para reproduzir a mesma resposta.</div></div>
    <div class="btn-row"><button type="button" id="reset-opts">Restaurar padrao do modelo</button></div>

    <div class="grp-t">Contexto</div>
    <div class="fld"><label><b>num_ctx</b> <span style="color:var(--dim)">- janela de contexto</span></label>
      <div class="row"><input type="number" id="p-num_ctx" min="256" max="1048576" step="256" value="2048"></div>
      <div class="hint" id="ctx-hint">Mais contexto = mais RAM. O modelo suporta ate <b id="ctx-max">?</b>.</div></div>
    <div class="fld"><label class="switch"><input type="checkbox" id="p-truncate" checked> Truncar historico longo</label>
      <div class="hint">Em vez de dar erro quando passar do contexto, corta as mensagens antigas.</div></div>
    <div class="fld"><label class="switch"><input type="checkbox" id="p-flash"> Flash attention</label>
      <div class="hint">Reduz uso de RAM da janela de contexto.</div></div>

    <div class="grp-t">Formato de saida</div>
    <div class="fld"><select id="p-format">
      <option value="">livre (texto)</option>
      <option value="json">JSON forcado</option>
      <option value="schema">JSON com schema...</option>
    </select></div>
    <div class="fld" id="schema-box" style="display:none">
      <textarea id="p-schema" placeholder='{"type":"object","properties":{...}}'></textarea>
      <div class="hint">JSON Schema. O modelo e obrigado a seguir.</div></div>

    <div class="grp-t">Dados</div>
    <div class="btn-row"><button type="button" id="clear-all">Apagar todas as conversas</button></div>
  </div>
</aside>

<div class="modal" id="m-rename"><div class="box">
  <h2>Renomear conversa</h2><p class="d">Um nome curto para achar depois.</p>
  <div class="fld"><input type="text" id="rn-name" maxlength="80"></div>
  <div class="acts"><button type="button" class="sec" data-close>Cancelar</button><button type="button" class="pri" id="rn-ok">Salvar</button></div>
</div></div>

<div class="modal" id="m-confirm"><div class="box">
  <h2 id="cf-t">Confirmar</h2><p class="d" id="cf-d"></p>
  <div class="acts"><button type="button" class="sec" data-close>Cancelar</button><button type="button" class="dan" id="cf-ok">Confirmar</button></div>
</div></div>

<div class="modal" id="m-export"><div class="box">
  <h2>Exportar</h2><p class="d">Baixe o arquivo ou copie o conteudo.</p>
  <div class="acts" style="margin-top:0"><button type="button" class="sec" id="ex-file">Baixar .json</button><button type="button" class="sec" id="ex-md">Baixar .md</button></div>
  <pre class="imp" id="ex-text" style="margin-top:12px"></pre>
  <div class="acts"><button type="button" class="sec" id="ex-copy">Copiar</button><button type="button" class="pri" data-close>Fechar</button></div>
</div></div>

<div class="modal" id="m-import"><div class="box">
  <h2>Importar</h2><p class="d">Cole o JSON exportado antes. As conversas sao somadas as atuais.</p>
  <div class="fld"><textarea id="im-text" style="min-height:120px" placeholder='[{"title":...,"messages":[...]}]'></textarea></div>
  <div class="acts"><button type="button" class="sec" data-close>Cancelar</button><button type="button" class="pri" id="im-ok">Importar</button></div>
</div></div>

<div id="toast"></div>

<script>
(function () {
  'use strict';

  /* ============================================================ estado */
  var $ = function (id) { return document.getElementById(id); };
  var log = $('log'), wrap = $('wrap'), modelSel = $('model'), form = $('form');
  var input = $('input'), sendBtn = $('send'), thinkBox = $('think'), toolsBox = $('tools');
  var statusEl = $('status'), subEl = $('sub'), capsEl = $('caps');
  var sideEl = $('side'), chatsEl = $('chats'), thumbsEl = $('thumbs');
  var panelEl = $('panel'), overlayEl = $('overlay');

  var cfgEl = $('cfg');
  var THREADS = (cfgEl && cfgEl.dataset && cfgEl.dataset.threads) || '0';
  var HAS_AUTH = (cfgEl && cfgEl.dataset && cfgEl.dataset.auth) === '1';

  var LS = {
    read: function (k, d) { try { var v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
    write: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* quota cheia */ } }
  };

  var chats = LS.read('latam.chats', []);   // [{id,title,createdAt,updatedAt,messages:[{role,content,thinking,tool_calls,images,ts}]}]
  var currentId = null;
  var settings = LS.read('latam.settings', null) || {
    theme: 'dark', math: true, system: '', format: '', schema: '', truncate: true, flash: false,
    opts: {}   // { [modelo]: { temperature, top_p, ... } }
  };
  var modelMeta = {};   // nome -> { size, capabilities, contextLength, defaults }
  var busy = false, controller = null, autoScroll = true;
  var pendingImages = [];   // [{ data: base64, url: blobUrl, name }]
  var toolDefs = [];
  var katexReady = false;

  /* ============================================================ util */
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function uid() {
    return 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }
  var toastTimer = null;
  function toast(msg) {
    var t = $('toast');
    t.textContent = msg;
    t.classList.add('on');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.classList.remove('on'); }, 1900);
  }
  function copyText(text, btn, label) {
    var done = function () { if (btn) { btn.textContent = 'copiado'; setTimeout(function () { btn.textContent = label; }, 1400); } else { toast('copiado'); } };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { toast('nao deu para copiar'); });
    } else {
      var ta = document.createElement('textarea');
      ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); done(); } catch (e) { toast('nao deu para copiar'); }
      document.body.removeChild(ta);
    }
  }
  function stickToBottom() { if (autoScroll) log.scrollTop = log.scrollHeight; }
  log.addEventListener('scroll', function () {
    autoScroll = log.scrollHeight - log.scrollTop - log.clientHeight < 60;
  });
  function status(msg, bad) {
    statusEl.textContent = msg || '';
    statusEl.className = 'status' + (bad ? ' bad' : '');
  }
  function fmtBytes(n) {
    if (!n) return '';
    if (n >= 1073741824) return (n / 1073741824).toFixed(1) + ' GB';
    return Math.round(n / 1048576) + ' MB';
  }
  function relTime(ts) {
    var s = (Date.now() - ts) / 1000;
    if (s < 60) return 'agora';
    if (s < 3600) return Math.floor(s / 60) + ' min';
    if (s < 86400) return Math.floor(s / 3600) + ' h';
    if (s < 604800) return Math.floor(s / 86400) + ' d';
    return new Date(ts).toLocaleDateString('pt-BR');
  }

  /* ============================================================ markdown */
  // Markdown completo sem dependencia externa: cabecalhos, negrito/italico,
  // listas aninhadas, tabelas, blockquote, hr, links, imagens, codigo com
  // highlight proprio. Tudo escapa o texto antes, entao nao ha XSS via modelo.
  var HL = {
    js:    ['javascript','js','jsx','ts','typescript','tsx','mjs','cjs','node','json'],
    py:    ['python','py'],
    sh:    ['bash','sh','shell','zsh','console','shell-session'],
    go:    ['go','golang'],
    c:     ['c','cpp','c++','h','hpp','cc','cs','csharp','java','rust','rs','kotlin','swift','php','scala'],
    sql:   ['sql','mysql','postgres','sqlite'],
    html:  ['html','xml','svg','vue','svelte'],
    css:   ['css','scss','less'],
    yaml:  ['yaml','yml','toml','ini','conf','dockerfile'],
    md:    ['md','markdown']
  };
  var KW = {
    js: 'const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|class|extends|super|this|typeof|instanceof|in|of|try|catch|finally|throw|async|await|yield|import|export|from|default|delete|void|null|undefined|true|false|static|get|set',
    py: 'def|class|return|if|elif|else|for|while|in|not|and|or|is|None|True|False|import|from|as|try|except|finally|raise|with|lambda|yield|pass|break|continue|global|nonlocal|assert|del|async|await|self',
    sh: 'if|then|else|elif|fi|for|while|do|done|case|esac|function|return|export|local|set|echo|exit|in|select|until',
    go: 'func|package|import|return|if|else|for|range|switch|case|default|type|struct|interface|map|chan|go|defer|var|const|nil|true|false|select|break|continue|fallthrough',
    c:  'int|char|float|double|void|long|short|unsigned|signed|struct|enum|union|typedef|return|if|else|for|while|do|switch|case|break|continue|class|public|private|protected|new|delete|this|null|nullptr|true|false|const|static|virtual|template|namespace|using|include|define|fn|let|mut|impl|pub|match|async|await|def|var|val|string|bool|func|package',
    sql:'select|from|where|insert|into|values|update|set|delete|create|table|alter|drop|join|left|right|inner|outer|on|group|by|order|having|limit|offset|as|and|or|not|null|primary|key|foreign|index|distinct|union|all|case|when|then|end|count|sum|avg|min|max',
    html:'div|span|p|a|img|ul|ol|li|h1|h2|h3|h4|h5|h6|table|tr|td|th|form|input|button|select|option|script|style|body|head|html|meta|link|section|article|header|footer|main|nav',
    css: 'color|background|margin|padding|border|display|flex|grid|position|width|height|font|text|align|justify|transform|transition|animation|z-index|opacity|overflow',
    yaml:'true|false|null|yes|no|on|off',
    md:  ''
  };
  function langOf(name) {
    var n = String(name || '').toLowerCase();
    for (var k in HL) if (HL[k].indexOf(n) !== -1) return k;
    return n ? null : null;
  }
  function highlight(code, lang) {
    var kw = lang ? (KW[lang] || '') : '';
    var out = [];
    var i = 0;
    var n = code.length;
    // tokenizador simples: comentarios, strings, numeros, palavras, resto
    var re = /(\/\/[^\n]*|#[^\n]*|\/\*[\s\S]*?\*\/|--[^\n]*)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)|\b(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b|([A-Za-z_$][\w$]*)|([\s\S])/g;
    var m;
    while ((m = re.exec(code)) !== null) {
      var t = m[0];
      if (m[1]) out.push('<span class="tok-com">' + esc(t) + '</span>');
      else if (m[2]) out.push('<span class="tok-str">' + esc(t) + '</span>');
      else if (m[3]) out.push('<span class="tok-num">' + esc(t) + '</span>');
      else if (m[4]) {
        if (kw && new RegExp('^(?:' + kw + ')$').test(t)) out.push('<span class="tok-kw">' + esc(t) + '</span>');
        else if (/^[A-Z]/.test(t)) out.push('<span class="tok-type">' + esc(t) + '</span>');
        else if (code[re.lastIndex] === '(') out.push('<span class="tok-fn">' + esc(t) + '</span>');
        else out.push(esc(t));
      } else out.push(esc(t));
      if (i++ > 200000) break; // trava de seguranca
    }
    return out.join('');
  }

  function codeBlock(raw, streaming) {
    var nl = raw.indexOf('\n');
    var lang = nl === -1 ? (streaming ? '' : raw.trim()) : raw.slice(0, nl);
    var body = nl === -1 ? '' : raw.slice(nl + 1);
    if (!streaming && nl === -1) body = raw;
    var key = langOf(lang);
    var html = '<div class="code-head"><span class="lang">' + esc(lang || 'texto') + '</span>' +
      '<button type="button" class="cbtn" data-copy-code>copiar</button></div>';
    html += '<code>' + (key ? highlight(body, key) : esc(body)) + '</code>';
    return '<pre data-lang="' + esc(lang) + '">' + html + '</pre>';
  }

  function inline(text) {
    var s = esc(text);
    // protege codigo inline
    var codes = [];
    s = s.replace(/`([^`\n]+)`/g, function (_, c) {
      codes.push(c);
      return '\u0000' + (codes.length - 1) + '\u0000';
    });
    // imagem ![alt](url) e link [txt](url)
    s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, function (_, alt, url) {
      return /^(https?:|data:image\/|\/)/i.test(url)
        ? '<img src="' + url.replace(/"/g, '%22') + '" alt="' + alt + '" loading="lazy">'
        : esc('![' + alt + '](' + url + ')');
    });
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, function (_, txt, url) {
      if (!/^(https?:|mailto:|\/|#)/i.test(url)) return txt;
      return '<a href="' + url.replace(/"/g, '%22') + '" target="_blank" rel="noopener noreferrer">' + txt + '</a>';
    });
    // URL solta
    s = s.replace(/(^|[\s(])((?:https?:\/\/)[^\s<)]+)/g, function (_, pre, url) {
      return pre + '<a href="' + url.replace(/"/g, '%22') + '" target="_blank" rel="noopener noreferrer">' + url + '</a>';
    });
    // bold / italic / strike / mark
    s = s.replace(/\*\*\*([^*\n]+)\*\*\*/g, '<strong><em>$1</em></strong>');
    s = s.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
    s = s.replace(/(^|[\s(])_([^_\n]+)_(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
    s = s.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');
    s = s.replace(/==([^=\n]+)==/g, '<mark>$1</mark>');
    // LaTeX inline $...$ (so se KaTeX carregou)
    if (katexReady && settings.math) {
      s = s.replace(/(^|[\s(])\$([^$\n]+)\$/g, function (_, pre, tex) {
        try { return pre + window.katex.renderToString(tex, { throwOnError: false, displayMode: false }); }
        catch (e) { return pre + '<span class="katex-err">' + esc('$' + tex + '$') + '</span>'; }
      });
    }
    // restaura codigo inline
    s = s.replace(/\u0000(\d+)\u0000/g, function (_, i) { return '<code>' + esc(codes[+i]) + '</code>'; });
    return s;
  }

  // split respeitando ``` (e ~~~)
  function splitFences(text) {
    var parts = [];
    var re = /^(```|~~~)[ \t]*([^\n]*)\n?/gm;
    var last = 0, m, open = null, openStart = 0, openLang = '';
    while ((m = re.exec(text)) !== null) {
      if (open === null) {
        parts.push({ t: 'text', v: text.slice(last, m.index) });
        open = m[1]; openLang = m[2]; openStart = re.lastIndex;
      } else if (m[1] === open) {
        parts.push({ t: 'code', lang: openLang, v: text.slice(openStart, m.index) });
        open = null;
      }
      last = re.lastIndex;
    }
    if (open !== null) parts.push({ t: 'code', lang: openLang, v: text.slice(openStart), open: true });
    else parts.push({ t: 'text', v: text.slice(last) });
    return parts.filter(function (p) { return p.v !== '' || p.t === 'code'; });
  }

  function mdTable(lines) {
    var rows = lines.map(function (l) {
      return l.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map(function (c) { return c.trim(); });
    });
    var aligns = (rows[1] || []).map(function (c) {
      if (/^:-+:$/.test(c)) return 'center';
      if (/^-+:$/.test(c)) return 'right';
      if (/^:-+/.test(c)) return 'left';
      return '';
    });
    var html = '<table><thead><tr>';
    rows[0].forEach(function (c, i) {
      html += '<th' + (aligns[i] ? ' style="text-align:' + aligns[i] + '"' : '') + '>' + inline(c) + '</th>';
    });
    html += '</tr></thead><tbody>';
    for (var r = 2; r < rows.length; r++) {
      html += '<tr>';
      rows[r].forEach(function (c, i) {
        html += '<td' + (aligns[i] ? ' style="text-align:' + aligns[i] + '"' : '') + '>' + inline(c) + '</td>';
      });
      html += '</tr>';
    }
    return html + '</tbody></table>';
  }

  // Parser de lista. Devolve { html, used }: 'used' e quantas linhas de
  // 'lines' ele realmente transformou em itens, para o mdBlocks saber de onde
  // continuar. Recursivo para sublistas indentadas.
  function mdList(lines, ordered) {
    var tag = ordered ? 'ol' : 'ul';
    var itemRe = ordered ? /^(\s*)(\d+)[.)]\s+(.*)$/ : /^(\s*)([-*+])\s+(.*)$/;
    var html = '<' + tag + '>';
    var i = 0;
    var used = 0;
    // Recuo do marcador dos itens desta lista. 'var' hoista, entao sem este
    // default o teste de irmao abaixo lia 'undefined' e nunca casava.
    var indent = 0;
    while (i < lines.length) {
      var line = lines[i];
      var m = line.match(itemRe);
      // Uma linha em branco NAO encerra a lista: se o proximo conteudo ainda e
      // um item no mesmo recuo, ele pertence a esta <ul>. Sem isso
      // "- a\n  - sub\n\n- b" perdia o "b" (que nao e sub-item, e irmao).
      if (!m) {
        if (!line.trim()) {
          var k = i;
          while (k < lines.length && !lines[k].trim()) k++;
          var km = k < lines.length ? lines[k].match(itemRe) : null;
          if (km && km[1].length === indent) { i = k; continue; }
          // recuo MAIOR que o do item = sub-item tardio; pertence ao item
          // anterior, nao a esta lista. Consome para o mdBlocks nao repetir.
          if (km && km[1].length > indent) { i = k + 1; used = i; continue; }
        }
        break;
      }
      indent = m[1].length;
      var text = m[3];
      i++;
      // junta o corpo do item: linhas indentadas alem do marcador, incluindo
      // sub-itens e paragrafos de continuacao
      var sub = [];
      while (i < lines.length) {
        var l2 = lines[i];
        var sm = l2.match(/^(\s*)([-*+]|\d+[.)])\s+/);
        if (sm && sm[1].length > indent) { sub.push(l2); i++; continue; }
        if (!l2.trim()) {
          // linha em branco so continua se o proximo conteudo ainda pertence ao item
          var j = i;
          while (j < lines.length && !lines[j].trim()) j++;
          if (j < lines.length) {
            var nm = lines[j].match(/^(\s*)([-*+]|\d+[.)])\s+/);
            if ((nm && nm[1].length > indent) || (!nm && /^\s{2,}\S/.test(lines[j]))) {
              while (i < j) { sub.push(lines[i]); i++; }
              continue;
            }
          }
          break;
        }
        if (/^\s{2,}\S/.test(l2)) { sub.push(l2); i++; continue; }
        break;
      }
      used = i;
      var inner = inline(text);
      if (sub.length) {
        var rest = sub.map(function (l) { return l.replace(new RegExp('^\\s{0,' + (indent + 2) + '}'), ''); });
        var child = /^\s*\d+[.)]\s/.test(rest[0]) ? mdList(rest, true) : mdList(rest, false);
        if (child && child.html) inner += child.html;
      }
      html += '<li>' + inner + '</li>';
    }
    if (!used) return null;
    return { html: html + '</' + tag + '>', used: used };
  }

  function mdBlocks(text) {
    var lines = String(text).split('\n');
    var out = '';
    var i = 0;
    while (i < lines.length) {
      var line = lines[i];

      if (!line.trim()) { i++; continue; }

      // hr
      if (/^\s*([-*_])\s*(\1\s*){2,}$/.test(line)) { out += '<hr>'; i++; continue; }

      // cabecalho
      var h = line.match(/^(#{1,6})\s+(.*)$/);
      if (h) {
        var lvl = h[1].length;
        out += '<h' + lvl + '>' + inline(h[2]) + '</h' + lvl + '>';
        i++; continue;
      }

      // tabela
      if (line.indexOf('|') !== -1 && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1]) && lines[i + 1].indexOf('-') !== -1) {
        var tbl = [line];
        var k = i + 1;
        while (k < lines.length && lines[k].indexOf('|') !== -1 && lines[k].trim()) { tbl.push(lines[k]); k++; }
        if (tbl.length >= 2) { out += mdTable(tbl); i = k; continue; }
      }

      // blockquote
      if (/^\s*>/.test(line)) {
        var q = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) { q.push(lines[i].replace(/^\s*>\s?/, '')); i++; }
        out += '<blockquote>' + mdBlocks(q.join('\n')) + '</blockquote>';
        continue;
      }

      // lista. Uma linha em branco nao encerra a lista: se a proxima linha
      // util for um item no recuo base (ou continuacao indentada), ela ainda
      // pertence a mesma <ul>. Sem isso "- a\n  - sub\n\n- b" virava
      // paragrafo no "b".
      var ulm = line.match(/^(\s*)[-*+]\s+/);
      var olm = line.match(/^(\s*)\d+[.)]\s+/);
      if (ulm || olm) {
        var baseIndent = (ulm || olm)[1].length;
        var itemRe = ulm ? new RegExp('^\\s{0,' + baseIndent + '}[-*+]\\s+')
                         : new RegExp('^\\s{0,' + baseIndent + '}\\d+[.)]\\s+');
        var contRe = new RegExp('^\\s{' + (baseIndent + 2) + ',}\\S');
        var buf = [];
        while (i < lines.length) {
          if (itemRe.test(lines[i]) || contRe.test(lines[i])) { buf.push(lines[i]); i++; continue; }
          if (!lines[i].trim()) {
            // olha adiante: se o proximo conteudo ainda e item/continuacao, engole o branco
            var j = i;
            while (j < lines.length && !lines[j].trim()) j++;
            if (j < lines.length && (itemRe.test(lines[j]) || contRe.test(lines[j]))) {
              while (i < j) { buf.push(lines[i]); i++; }
              continue;
            }
          }
          break;
        }
        var r = mdList(buf, !ulm, 0);
        // mdList para na primeira linha que nao reconhece (ex.: o branco antes
        // de "- item 3") e diz quantas consumiu em r.used. Sem ajustar o i pelo
        // que SOBROU, o restante da lista era descartado silenciosamente.
        if (r) {
          out += r.html;
          i += buf.length - r.used;
          continue;
        }
      }

      // LaTeX em bloco $$...$$
      if (katexReady && settings.math && /^\s*\$\$/.test(line)) {
        var tex = [];
        var first = line.replace(/^\s*\$\$\s?/, '');
        if (/^\s*\$\$\s*$/.test(first) || first.trim() === '') {
          i++;
          while (i < lines.length && !/\$\$/.test(lines[i])) { tex.push(lines[i]); i++; }
          if (i < lines.length) i++;
        } else {
          tex.push(first.replace(/\s*\$\$\s*$/, ''));
          i++;
        }
        try { out += window.katex.renderToString(tex.join('\n'), { throwOnError: false, displayMode: true }); }
        catch (e) { out += '<p class="katex-err">' + esc(tex.join('\n')) + '</p>'; }
        continue;
      }

      // paragrafo (junta linhas contiguas)
      var para = [line];
      i++;
      while (i < lines.length && lines[i].trim() &&
             !/^(#{1,6})\s/.test(lines[i]) && !/^\s*[-*+]\s+/.test(lines[i]) &&
             !/^\s*\d+[.)]\s+/.test(lines[i]) && !/^\s*>/.test(lines[i]) &&
             !/^(```|~~~)/.test(lines[i]) && !/^\s*([-*_])\s*(\1\s*){2,}$/.test(lines[i]) &&
             !(lines[i].indexOf('|') !== -1 && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|/.test(lines[i + 1]))) {
        para.push(lines[i]); i++;
      }
      out += '<p>' + inline(para.join('\n')).replace(/\n/g, '<br>') + '</p>';
    }
    return out;
  }

  function md(text, streaming) {
    var parts = splitFences(String(text));
    var html = '';
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (p.t === 'code') html += codeBlock(p.lang ? p.lang + '\n' + p.v : p.v, !!p.open || streaming);
      else html += mdBlocks(p.v);
    }
    return html;
  }

  /* ============================================================ KaTeX */
  function loadKatex() {
    if (katexReady || !settings.math) return Promise.resolve();
    return new Promise(function (resolve) {
      if (window.katex) { katexReady = true; return resolve(); }
      var l = document.createElement('link');
      l.rel = 'stylesheet';
      l.href = 'https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css';
      document.head.appendChild(l);
      var s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js';
      s.onload = function () { katexReady = true; resolve(); };
      s.onerror = function () {
        settings.math = false;
        $('p-math').checked = false;
        persistSettings();
        toast('KaTeX nao carregou - sem internet no navegador?');
        resolve();
      };
      document.head.appendChild(s);
      setTimeout(function () { if (!katexReady) resolve(); }, 6000);
    });
  }

  /* ============================================================ conversas */
  function persistChats() { LS.write('latam.chats', chats); }
  function persistSettings() { LS.write('latam.settings', settings); }

  function current() {
    for (var i = 0; i < chats.length; i++) if (chats[i].id === currentId) return chats[i];
    return null;
  }
  function ensureChat() {
    var c = current();
    if (c) return c;
    c = { id: uid(), title: 'Nova conversa', createdAt: Date.now(), updatedAt: Date.now(), messages: [] };
    chats.unshift(c);
    currentId = c.id;
    persistChats();
    return c;
  }
  function newChat(silent) {
    if (busy) abortNow();
    currentId = null;
    pendingImages = [];
    renderThumbs();
    wrap.innerHTML = '';
    emptyState(true);
    renderChats();
    status('');
    if (!silent) input.focus();
  }
  function deleteChat(id) {
    chats = chats.filter(function (c) { return c.id !== id; });
    if (currentId === id) { currentId = null; wrap.innerHTML = ''; emptyState(true); }
    persistChats();
    renderChats();
  }
  function titleFrom(text) {
    var t = String(text).replace(/\s+/g, ' ').trim();
    return t.length > 42 ? t.slice(0, 42) + '...' : (t || 'Nova conversa');
  }

  function renderChats() {
    var q = ($('q').value || '').toLowerCase().trim();
    var list = chats.filter(function (c) {
      if (!q) return true;
      if ((c.title || '').toLowerCase().indexOf(q) !== -1) return true;
      return c.messages.some(function (m) { return (m.content || '').toLowerCase().indexOf(q) !== -1; });
    });
    chatsEl.innerHTML = '';
    if (!list.length) {
      var e = document.createElement('div');
      e.className = 'empty-chats';
      e.textContent = q ? 'Nada encontrado.' : 'Sem conversas ainda.';
      chatsEl.appendChild(e);
      return;
    }
    var now = Date.now();
    // agrupa por faixa de data: hoje / ontem / 7 dias / mais antigas
    var buckets = { 0: [], 1: [], 2: [], 3: [] };
    list.forEach(function (c) {
      var age = now - c.updatedAt;
      var b = age < 86400000 ? 0 : age < 172800000 ? 1 : age < 604800000 ? 2 : 3;
      buckets[b].push(c);
    });
    ['Hoje', 'Ontem', 'Ultimos 7 dias', 'Mais antigas'].forEach(function (label, bi) {
      if (!buckets[bi].length) return;
      var h = document.createElement('div');
      h.className = 'grp';
      h.textContent = label;
      chatsEl.appendChild(h);
      buckets[bi].forEach(function (c) {
        var d = document.createElement('div');
        d.className = 'chat-item' + (c.id === currentId ? ' active' : '');
        d.textContent = c.title || 'Nova conversa';
        d.title = c.title + '\n' + c.messages.length + ' mensagens - ' + relTime(c.updatedAt);
        d.addEventListener('click', function () { openChat(c.id); });
        var x = document.createElement('button');
        x.className = 'x';
        x.type = 'button';
        x.title = 'Apagar';
        x.innerHTML = '&times;';
        x.addEventListener('click', function (ev) {
          ev.stopPropagation();
          confirmBox('Apagar conversa?', '"' + c.title + '" e ' + c.messages.length + ' mensagens vao sumir.', function () {
            deleteChat(c.id);
          });
        });
        d.appendChild(x);
        // duplo clique renomeia
        d.addEventListener('dblclick', function () { renameChat(c.id); });
        chatsEl.appendChild(d);
      });
    });
  }

  function openChat(id) {
    if (busy) abortNow();
    currentId = id;
    var c = current();
    pendingImages = [];
    renderThumbs();
    wrap.innerHTML = '';
    if (!c || !c.messages.length) { emptyState(true); }
    else {
      emptyState(false);
      c.messages.forEach(function (m, i) {
        if (m.role === 'tool') return;   // resultado de ferramenta: desenha junto do assistant
        if (m.role === 'assistant' && m.tool_calls && m.tool_calls.length && !m.content) {
          drawToolCalls(m, c.messages, i);
          return;
        }
        var el = addMessage(m.role);
        if (m.thinking) drawThinking(el.parentNode, m.thinking);
        if (m.images && m.images.length) drawImages(el.parentNode, m.images);
        el.innerHTML = md(m.content || '', false);
        if (m.role === 'assistant') footer(el, m);
      });
    }
    renderChats();
    stickToBottom();
    if (window.innerWidth <= 860) sideEl.classList.add('hidden');
  }

  function renameChat(id) {
    var c = null;
    for (var i = 0; i < chats.length; i++) if (chats[i].id === id) c = chats[i];
    if (!c) return;
    var modal = $('m-rename');
    $('rn-name').value = c.title || '';
    modal.classList.add('on');
    setTimeout(function () { $('rn-name').focus(); $('rn-name').select(); }, 40);
    $('rn-ok').onclick = function () {
      c.title = ($('rn-name').value || '').trim() || 'Nova conversa';
      c.updatedAt = Date.now();
      persistChats();
      renderChats();
      modal.classList.remove('on');
    };
  }

  /* ============================================================ desenho */
  function emptyState(show) {
    var el = $('empty');
    if (show) {
      if (el) return;
      var d = document.createElement('div');
      d.className = 'empty';
      d.id = 'empty';
      d.innerHTML = '<h1>LATAM IA</h1><p>Seu assistente rodando localmente neste servidor.</p>' +
        '<div class="hint">Escolha o modelo acima e mande a primeira mensagem.<br>' +
        'Atalhos: <b>Ctrl+K</b> nova conversa &nbsp; <b>Ctrl+/</b> configuracoes</div>';
      wrap.appendChild(d);
    } else if (el) {
      el.parentNode.removeChild(el);
    }
  }

  function addMessage(role) {
    emptyState(false);
    var msg = document.createElement('div');
    msg.className = 'msg ' + role;
    msg.innerHTML = '<div class="avatar">' + (role === 'user' ? 'EU' : 'IA') + '</div>' +
      '<div class="body"><div class="who">' + (role === 'user' ? 'Voce' : 'LATAM IA') + '</div>' +
      '<div class="content"></div></div>';
    wrap.appendChild(msg);
    stickToBottom();
    return msg.querySelector('.content');
  }

  function drawImages(host, images) {
    images.forEach(function (src) {
      var img = document.createElement('img');
      img.src = src.indexOf('data:') === 0 ? src : 'data:image/png;base64,' + src;
      img.style.maxWidth = '220px';
      img.alt = 'imagem anexada';
      host.insertBefore(img, host.firstChild);
    });
  }

  function drawThinking(host, text) {
    var d = document.createElement('details');
    d.className = 'think';
    d.open = thinkBox.checked;
    d.innerHTML = '<summary>Raciocinio (' + text.split(/\s+/).length + ' palavras)</summary>' +
      '<div class="think-body">' + esc(text) + '</div>';
    host.insertBefore(d, host.firstChild);
    return d;
  }

  function drawToolCalls(msg, all, idx) {
    var el = addMessage('assistant');
    var body = el.parentNode;
    (msg.tool_calls || []).forEach(function (tc, i) {
      var fn = tc.function || {};
      // procura o resultado (role:tool) logo depois
      var result = null;
      for (var j = idx + 1; j < Math.min(idx + 4, all.length); j++) {
        if (all[j].role === 'tool' && (!all[j].tool_name || all[j].tool_name === fn.name)) {
          result = all[j]; break;
        }
      }
      var box = document.createElement('div');
      box.className = 'toolcall';
      box.innerHTML =
        '<div class="tc-head"><span class="badge">TOOL</span><span>' + esc(fn.name || '?') + '</span>' +
        '<span class="st ' + (result ? 'ok' : '') + '">' + (result ? 'executada' : 'pendente') + '</span></div>' +
        '<pre><code>' + esc(JSON.stringify(fn.arguments || {}, null, 2)) + '</code></pre>' +
        (result ? '<div class="tc-args"><pre><code>' + esc(String(result.content || '').slice(0, 2000)) + '</code></pre></div>' : '');
      body.appendChild(box);
    });
    return el;
  }

  function footer(el, meta) {
    var doc = document;               // 'el' pode estar fora do DOM apos um clear
    var f = doc.createElement('div');
    f.className = 'foot';
    var parts = [];
    if (meta.model) parts.push(meta.model);
    if (meta.ms) parts.push((meta.ms / 1000).toFixed(1) + 's');
    if (meta.tps) parts.push(meta.tps.toFixed(1) + ' tok/s');
    if (meta.tokens) parts.push(meta.tokens + ' tokens');
    if (meta.interrupted) parts.push('interrompido');
    var info = document.createElement('span');
    info.className = 'toks';
    info.textContent = parts.join(' · ');
    f.appendChild(info);

    function act(label, fn) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'act';
      b.textContent = label;
      b.addEventListener('click', fn);
      f.appendChild(b);
      return b;
    }
    var copyBtn = act('copiar', function () { copyText(el.textContent, copyBtn, 'copiar'); });
    act('regenerar', function () { regenerate(el); });
    if (el.closest('.msg.assistant')) {
      act('editar', function () { editLastUser(); });
    }
    el.parentNode.appendChild(f);
  }

  /* ============================================================ stream */
  function streamer(el) {
    var buf = '';
    var raf = 0;
    function paint(withCaret) {
      el.innerHTML = md(buf, withCaret) + (withCaret ? '<span class="caret"></span>' : '');
      stickToBottom();
    }
    return {
      push: function (d) {
        buf += d;
        if (raf) return;
        raf = requestAnimationFrame(function () { raf = 0; paint(true); });
      },
      done: function () { if (raf) { cancelAnimationFrame(raf); raf = 0; } paint(false); return buf; },
      text: function () { return buf; }
    };
  }

  function thinking(el) {
    el.innerHTML = '<span class="dots"><i></i><i></i><i></i></span>';
  }

  var waitTimer = null;
  function startWaitClock() {
    var t0 = Date.now();
    stopWaitClock();
    waitTimer = setInterval(function () {
      var s = Math.round((Date.now() - t0) / 1000);
      status('aguardando o modelo... ' + s + 's' + (s > 20 ? ' (carregando na RAM)' : ''));
    }, 1000);
  }
  function stopWaitClock() { if (waitTimer) { clearInterval(waitTimer); waitTimer = null; } }

  /* ============================================================ opcoes */
  // [nome no options do Ollama, id do input no painel, padrao]
  var OPT_DEFS = [
    ['temperature', 'p-temp', 0.8],
    ['top_p', 'p-top_p', 0.95],
    ['top_k', 'p-top_k', 40],
    ['num_predict', 'p-num_predict', -1],
    ['repeat_penalty', 'p-repeat_penalty', 1.1],
    ['presence_penalty', 'p-presence_penalty', 0],
    ['frequency_penalty', 'p-frequency_penalty', 0],
    ['seed', 'p-seed', -1],
    ['num_ctx', 'p-num_ctx', 2048]
  ];
  function optEl(key) {
    for (var i = 0; i < OPT_DEFS.length; i++) if (OPT_DEFS[i][0] === key) return $(OPT_DEFS[i][1]);
    return null;
  }
  // O label tem id proprio (v-temp para temperature), entao derivo do input.
  function optLabel(key) {
    var el = optEl(key);
    if (!el) return null;
    return $(el.id.replace(/^p-/, 'v-'));
  }
  function modelOpts(model) {
    var base = {};
    OPT_DEFS.forEach(function (d) { base[d[0]] = d[2]; });
    var saved = (settings.opts && settings.opts[model]) || {};
    Object.keys(saved).forEach(function (k) { base[k] = saved[k]; });
    return base;
  }
  function buildOptions() {
    var o = {};
    var t = parseInt(THREADS, 10);
    if (t > 0) o.num_thread = t;
    var m = modelSel.value;
    var saved = (settings.opts && settings.opts[m]) || {};
    Object.keys(saved).forEach(function (k) {
      var v = saved[k];
      if (v === '' || v === null || v === undefined) return;
      o[k] = v;
    });
    if (settings.flash) o.flash_attn = true;
    if (settings.truncate === false) o.truncate = false;
    return o;
  }
  function buildFormat() {
    if (settings.format === 'json') return 'json';
    if (settings.format === 'schema' && settings.schema) {
      try { return JSON.parse(settings.schema); } catch (e) { return null; }
    }
    return null;
  }
  // Monta o array que vai pro Ollama a partir da conversa salva. O userMsg ja
  // foi gravado em c.messages antes de chamar aqui - se eu passar de novo ele
  // aparece duas vezes no contexto e o modelo repete a pergunta.
  function messagesForSend() {
    var c = ensureChat();
    var msgs = [];
    if (settings.system && settings.system.trim()) {
      msgs.push({ role: 'system', content: settings.system.trim() });
    }
    c.messages.forEach(function (m) {
      var o = { role: m.role, content: m.content || '' };
      if (m.thinking) o.thinking = m.thinking;
      if (m.tool_calls) o.tool_calls = m.tool_calls;
      if (m.tool_name) o.tool_name = m.tool_name;
      if (m.images && m.images.length) o.images = m.images;
      msgs.push(o);
    });
    return msgs;
  }

  /* ============================================================ tools */
  // Duas ferramentas que rodam no navegador - nao precisam de backend.
  // Servem de demonstracao do ciclo completo de tool calling do Ollama.
  function localTool(name, args) {
    return new Promise(function (resolve) {
      if (name === 'get_current_time') {
        var tz = (args && (args.timezone || args.tz)) || 'UTC';
        var now = new Date();
        var s;
        try {
          s = now.toLocaleString('pt-BR', { timeZone: tz, dateStyle: 'full', timeStyle: 'long' });
        } catch (e) {
          return resolve({ error: 'fuso "' + tz + '" invalido' });
        }
        return resolve({ result: s, timezone: tz, iso: now.toISOString() });
      }
      if (name === 'calculator') {
        var expr = String((args && (args.expression || args.expr)) || '');
        // so numeros e operadores - nada de eval com codigo arbitrario
        if (!/^[-+*/%().\d\s^eE]*$/.test(expr) || !/[\d]/.test(expr)) {
          return resolve({ error: 'expressao invalida: use apenas numeros e + - * / ( )' });
        }
        try {
          var val = Function('"use strict";return (' + expr.replace(/\^/g, '**') + ')')();
          if (typeof val !== 'number' || !isFinite(val)) return resolve({ error: 'resultado nao numerico' });
          return resolve({ result: val, expression: expr });
        } catch (e) {
          return resolve({ error: 'nao consegui calcular: ' + e.message });
        }
      }
      resolve({ error: 'ferramenta "' + name + '" nao implementada' });
    });
  }

  toolDefs = [
    {
      type: 'function',
      function: {
        name: 'get_current_time',
        description: 'Retorna a data e hora atuais em um fuso horario. Use quando o usuario perguntar as horas, a data de hoje ou precisar do horario local de uma cidade.',
        parameters: {
          type: 'object',
          properties: {
            timezone: { type: 'string', description: 'Nome IANA do fuso, ex.: America/Boa_Vista, America/Sao_Paulo, UTC' }
          },
          required: ['timezone']
        }
      }
    },
    {
      type: 'function',
      function: {
        name: 'calculator',
        description: 'Avalia uma expressao aritmetica com precisao. Use para qualquer conta, em vez de calcular de cabeca.',
        parameters: {
          type: 'object',
          properties: {
            expression: { type: 'string', description: 'Expressao, ex.: (12.5 * 3) + 7 / 2' }
          },
          required: ['expression']
        }
      }
    }
  ];

  /* ============================================================ envio */
  function modelReady() { return !!modelSel.value; }
  function setReady() {
    if (!modelReady()) return;
    input.disabled = false;
    sendBtn.disabled = false;
    input.placeholder = 'Pergunte qualquer coisa...';
  }
  function setBusy(v) {
    busy = v;
    input.disabled = !modelReady();
    sendBtn.disabled = !modelReady();
    sendBtn.classList.toggle('stop', v);
    sendBtn.innerHTML = v ? '&#9632;' : '&#10148;';
    sendBtn.title = v ? 'Parar' : 'Enviar';
  }

  // Todo caminho que interrompe a geracao passa por aqui. O listener de
  // 'abort' no runTurn e quem finaliza de fato (marcando como interrompido).
  function abortNow() {
    if (!controller) return;
    controller.abort();
    controller = null;
  }

  function send(overrideText, overrideImages) {
    if (busy) { abortNow(); return; }
    var text = (overrideText !== undefined ? overrideText : input.value).trim();
    var images = overrideImages || pendingImages.slice();
    var model = modelSel.value;
    if (!text && !images.length) return;
    if (!model || model.indexOf(' ') !== -1) {
      status('nenhum modelo disponivel ainda - aguarde carregar', true);
      return;
    }

    var c = ensureChat();
    emptyState(false);

    var userMsg = { role: 'user', content: text, ts: Date.now() };
    if (images.length) userMsg.images = images.map(function (i) { return i.data; });
    c.messages.push(userMsg);
    c.updatedAt = Date.now();
    if (c.messages.filter(function (m) { return m.role === 'user'; }).length === 1 && c.title === 'Nova conversa') {
      c.title = titleFrom(text || '(imagem)');
    }
    persistChats();

    var userEl = addMessage('user');
    if (images.length) drawImages(userEl.parentNode, images.map(function (i) { return i.data; }));
    userEl.innerHTML = md(text, false);

    if (overrideText === undefined) { input.value = ''; autoresize(); }
    pendingImages = [];
    renderThumbs();
    setBusy(true);
    autoScroll = true;

    runTurn(model, userMsg);
  }

  function regenerate(el) {
    if (busy) return;
    var c = current();
    if (!c) return;
    // remove a ultima resposta do assistente (e tool calls penduradas nela)
    var cut = c.messages.length;
    while (cut > 0 && c.messages[cut - 1].role !== 'user') cut--;
    if (cut === 0) { toast('nada para regenerar'); return; }
    c.messages = c.messages.slice(0, cut);
    persistChats();
    // apaga do DOM as mensagens depois do ultimo user
    var nodes = wrap.querySelectorAll('.msg');
    for (var i = nodes.length - 1; i >= 0; i--) {
      wrap.removeChild(nodes[i]);
      if (nodes[i].classList.contains('user')) break;
    }
    setBusy(true);
    autoScroll = true;
    runTurn(modelSel.value, null);
  }

  function editLastUser() {
    var c = current();
    if (!c) return;
    var idx = -1;
    for (var i = c.messages.length - 1; i >= 0; i--) if (c.messages[i].role === 'user') { idx = i; break; }
    if (idx === -1) { toast('sem mensagem sua para editar'); return; }
    input.value = c.messages[idx].content || '';
    autoresize();
    input.focus();
    c.messages = c.messages.slice(0, idx);
    persistChats();
    openChat(c.id);
    toast('edite e envie de novo');
  }

  function runTurn(model, userMsg) {
    var el = addMessage('assistant');
    thinking(el);
    status('aguardando o modelo...');
    startWaitClock();

    var c = ensureChat();
    var st = streamer(el);
    var thinkBuf = '', thinkEl = null;
    var toolCalls = [];
    var startedAt = Date.now();
    var firstToken = true;
    var metrics = null;
    var aborted = false;
    var settled = false;      // garante que finish() roda uma vez so
    var ctl = new AbortController();
    controller = ctl;

    function finish(err) {
      if (settled) return;
      settled = true;
      stopWaitClock();
      var answer = st.done();
      var ms = Date.now() - startedAt;

      if (err) {
        if (!answer) el.innerHTML = '<span class="err">' + esc(err.message) + '</span>';
        else footer(el, { model: model, ms: ms });
        status(err.message, true);
        setBusy(false);
        return;
      }

      if (aborted) {
        // Parado pelo usuario. Salvo o que ja veio para nao perder o trecho.
        if (answer || thinkBuf) {
          c.messages.push({
            role: 'assistant', content: answer, thinking: thinkBuf || undefined,
            ts: Date.now(), model: model, ms: ms, interrupted: true
          });
          c.updatedAt = Date.now();
          persistChats();
          renderChats();
        }
        footer(el, { model: model, ms: ms, interrupted: true });
        status('interrompido');
        setBusy(false);
        return;
      }

      var tps = metrics && metrics.eval_duration ? metrics.eval_count / (metrics.eval_duration / 1e9) : 0;
      var meta = {
        role: 'assistant', content: answer, ts: Date.now(), model: model, ms: ms,
        tps: tps, tokens: metrics ? metrics.eval_count : 0
      };
      if (thinkBuf) meta.thinking = thinkBuf;
      if (toolCalls.length) meta.tool_calls = toolCalls;
      c.messages.push(meta);
      c.updatedAt = Date.now();
      persistChats();
      renderChats();
      footer(el, meta);
      setBusy(false);
      status('');
      if (toolCalls.length) runTools(model, toolCalls, answer, thinkBuf);
      else input.focus();
    }

    // Alguns navegadores (e o jsdom) nao rejeitam read() com AbortError quando
    // o fetch e abortado: o stream so fica pendurado e o usuario nunca ve que
    // parou. Por isso o abort tem caminho proprio, alem do .catch().
    // O listener roda SEMPRE no abort: abortNow() ja zerou 'controller', entao
    // comparar com ele nunca ia bater. settled impede finish() duplicado.
    ctl.signal.addEventListener('abort', function () {
      aborted = true;
      finish(null);
    });

    var body = {
      model: model,
      messages: messagesForSend(),
      stream: true,
      think: thinkBox.checked,
      options: buildOptions()
    };
    if (toolsBox.checked && (modelMeta[model] || {}).hasTools) body.tools = toolDefs;
    var fmt = buildFormat();
    if (fmt) body.format = fmt;
    if (settings.truncate) body.truncate = true;

    fetch('/api/chat', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      signal: ctl.signal,
      body: JSON.stringify(body)
    }).then(function (resp) {
      if (!resp.ok) return resp.text().then(function (t) { throw new Error('HTTP ' + resp.status + ' - ' + t); });
      var reader = resp.body.getReader();
      var dec = new TextDecoder();
      var pending = '';

      function pump() {
        // Depois do abort alguns navegadores ainda entregam chunks ja
        // enfileirados. Sem este guarda o texto tardio chamava status() e
        // sobrescrevia o "interrompido" que o usuario acabou de ver.
        if (settled || aborted) return Promise.resolve();
        return reader.read().then(function (res) {
          if (res.done) return finish(null);
          if (settled || aborted) return;
          pending += dec.decode(res.value, { stream: true });
          var lines = pending.split('\n');
          pending = lines.pop();
          for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line) continue;
            var chunk;
            try { chunk = JSON.parse(line); } catch (e) { continue; }
            if (chunk.error) throw new Error(chunk.error);
            var m = chunk.message || {};
            if (m.thinking) {
              if (!thinkEl) { thinkEl = drawThinking(el.parentNode, ''); }
              thinkBuf += m.thinking;
              thinkEl.querySelector('.think-body').textContent = thinkBuf;
              stickToBottom();
            }
            if (m.tool_calls && m.tool_calls.length) {
              m.tool_calls.forEach(function (tc) { toolCalls.push(tc); });
            }
            if (m.content) {
              if (firstToken) {
                firstToken = false;
                stopWaitClock();
                if (!settled && !aborted) status('gerando...');
              }
              st.push(m.content);
            }
            if (chunk.done) metrics = chunk;
          }
          return pump();
        });
      }

      return pump();
    }).catch(function (e) { finish(e); });
  }

  function runTools(model, calls, answer, thinkBuf) {
    status('executando ' + calls.length + ' ferramenta' + (calls.length > 1 ? 's' : '') + '...');
    // 1. mostra as chamadas
    var lastUserIdx = -1;
    for (var i = ensureChat().messages.length - 1; i >= 0; i--) {
      if (ensureChat().messages[i].role === 'user') { lastUserIdx = i; break; }
    }
    var c = ensureChat();
    var hostIdx = c.messages.length - 1;   // o assistant que acabou de pedir
    // remove o assistant "vazio" e desenha os tool calls no lugar
    var nodes = wrap.querySelectorAll('.msg');
    if (nodes.length) wrap.removeChild(nodes[nodes.length - 1]);
    c.messages.pop();
    c.messages.push({ role: 'assistant', content: answer || '', thinking: thinkBuf || undefined, tool_calls: calls, ts: Date.now(), model: model });
    drawToolCalls({ tool_calls: calls }, c.messages, c.messages.length - 1);

    // 2. executa cada uma
    var pending = calls.map(function (tc) {
      var fn = tc.function || {};
      return localTool(fn.name, fn.arguments || {}).then(function (out) {
        return { name: fn.name, out: out };
      });
    });

    Promise.all(pending).then(function (results) {
      results.forEach(function (r) {
        c.messages.push({ role: 'tool', tool_name: r.name, content: JSON.stringify(r.out), ts: Date.now() });
      });
      persistChats();
      status('respondendo com o resultado...');
      setBusy(true);
      autoScroll = true;
      runTurn(model, null);
    });
  }

  /* ============================================================ anexos */
  function renderThumbs() {
    thumbsEl.innerHTML = '';
    pendingImages.forEach(function (img, i) {
      var d = document.createElement('div');
      d.className = 'thumb';
      var im = document.createElement('img');
      im.src = img.url;
      im.alt = img.name;
      var b = document.createElement('button');
      b.type = 'button';
      b.innerHTML = '&times;';
      b.title = 'Remover';
      b.addEventListener('click', function () {
        URL.revokeObjectURL(img.url);
        pendingImages.splice(i, 1);
        renderThumbs();
      });
      d.appendChild(im);
      d.appendChild(b);
      thumbsEl.appendChild(d);
    });
  }

  function addFiles(files) {
    var meta = modelMeta[modelSel.value] || {};
    if (!meta.hasVision) {
      toast('este modelo nao aceita imagem (' + (modelSel.value || 'nenhum') + ')');
      return;
    }
    Array.prototype.forEach.call(files, function (f) {
      if (!/^image\//.test(f.type)) { toast(f.name + ' nao e imagem'); return; }
      if (f.size > 8 * 1048576) { toast(f.name + ' passa de 8 MB'); return; }
      var r = new FileReader();
      r.onload = function () {
        var b64 = String(r.result).split(',')[1] || '';
        pendingImages.push({ data: b64, url: r.result, name: f.name });
        renderThumbs();
        setReady();
      };
      r.readAsDataURL(f);
    });
  }

  $('files').addEventListener('change', function (e) {
    addFiles(e.target.files);
    e.target.value = '';
  });
  ['dragover', 'drop'].forEach(function (ev) {
    document.addEventListener(ev, function (e) { e.preventDefault(); });
  });
  document.addEventListener('drop', function (e) {
    if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) addFiles(e.dataTransfer.files);
  });
  input.addEventListener('paste', function (e) {
    var items = (e.clipboardData || {}).items || [];
    for (var i = 0; i < items.length; i++) {
      if (items[i].type.indexOf('image/') === 0) {
        var f = items[i].getAsFile();
        if (f) { addFiles([f]); e.preventDefault(); }
      }
    }
  });

  /* ============================================================ modelos */
  function loadModels() {
    status('carregando modelos...');
    return fetch('/api/tags', { cache: 'no-store' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (data) {
      var models = (data && data.models) || [];
      var prev = modelSel.value;
      modelSel.innerHTML = '';
      if (!models.length) {
        modelSel.innerHTML = '<option value="">nenhum modelo</option>';
        status('nenhum modelo baixado - configure MODEL no painel', true);
        return;
      }
      models.forEach(function (m) {
        var o = document.createElement('option');
        o.value = m.name;
        o.textContent = m.name + ' (' + fmtBytes(m.size) + ')';
        modelSel.appendChild(o);
        modelMeta[m.name] = { size: m.size, capabilities: m.capabilities || [], hasTools: false, hasVision: false, contextLength: 0 };
      });
      if (prev && modelSel.querySelector('option[value="' + prev + '"]')) modelSel.value = prev;
      subEl.textContent = ' · ' + models.length + ' modelo' + (models.length > 1 ? 's' : '');
      setReady();
      status('');
      return probeModel(modelSel.value);
    }).catch(function (e) {
      modelSel.innerHTML = '<option value="">API fora do ar - tente recarregar</option>';
      status('API indisponivel: ' + e.message, true);
    });
  }

  // /api/show diz o que o modelo sabe fazer. Sem isso nao da para habilitar
  // tool calling nem anexo de imagem com seguranca.
  function probeModel(name) {
    if (!name) return Promise.resolve();
    capsEl.textContent = '';
    return fetch('/api/show', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: name })
    }).then(function (r) { return r.ok ? r.json() : null; }).then(function (d) {
      if (!d) return;
      var caps = d.capabilities || [];
      var meta = modelMeta[name] || (modelMeta[name] = {});
      meta.capabilities = caps;
      meta.hasTools = caps.indexOf('tools') !== -1;
      meta.hasVision = caps.indexOf('vision') !== -1;
      var info = d.model_info || {};
      var arch = info['general.architecture'] || '';
      meta.contextLength = info[arch + '.context_length'] || 0;
      var tags = [];
      if (meta.hasTools) tags.push('ferramentas');
      if (meta.hasVision) tags.push('visao');
      if (caps.indexOf('thinking') !== -1) tags.push('raciocinio');
      if (meta.contextLength) tags.push('ctx ' + (meta.contextLength >= 1024 ? Math.round(meta.contextLength / 1024) + 'k' : meta.contextLength));
      capsEl.textContent = tags.join(' · ');
      capsEl.className = 'pill' + (meta.contextLength && meta.contextLength < 2048 ? ' warn' : '');
      $('ctx-max').textContent = meta.contextLength ? meta.contextLength.toLocaleString('pt-BR') + ' tokens' : 'desconhecido';
      toolsBox.disabled = !meta.hasTools;
      if (!meta.hasTools) { toolsBox.checked = false; toolsBox.title = 'este modelo nao suporta ferramentas'; }
      else toolsBox.title = 'permitir que o modelo chame ferramentas';
      if (!meta.hasVision) document.querySelector('.attach').style.opacity = '.4';
      else document.querySelector('.attach').style.opacity = '';
      loadModelOpts(name, d);
    }).catch(function () { /* modelo sem /api/show: segue sem caps */ });
  }

  // Le os parametros que o proprio modelo declara e usa como base, para o
  // painel comecar nos valores do Modelfile em vez de chute meu.
  function loadModelOpts(name, show) {
    var params = (show && show.parameters) || '';
    var base = {};
    String(params).split('\n').forEach(function (line) {
      var m = line.match(/^\s*([a-z_]+)\s+(.+)$/);
      if (!m) return;
      var k = m[1], v = m[2].trim();
      if (k === 'stop') return;
      if (/^(temperature|top_p|top_k|min_p|typical_p|repeat_penalty|presence_penalty|frequency_penalty)$/.test(k)) {
        base[k] = parseFloat(v);
      } else if (/^(num_predict|num_ctx|top_k|seed|num_keep|repeat_last_n)$/.test(k)) {
        base[k] = parseInt(v, 10);
      }
    });
    var saved = (settings.opts && settings.opts[name]) || {};
    var merged = {};
    OPT_DEFS.forEach(function (d) {
      merged[d[0]] = saved[d[0]] !== undefined ? saved[d[0]] : (base[d[0]] !== undefined ? base[d[0]] : d[2]);
    });
    settings.opts[name] = merged;
    persistSettings();
    paintOpts(name);
  }

  function paintOpts(name) {
    var o = modelOpts(name);
    OPT_DEFS.forEach(function (d) {
      var key = d[0];
      var el = optEl(key);
      if (!el) return;
      el.value = o[key];
      var v = optLabel(key);
      if (v) v.textContent = String(o[key]);
    });
  }

  function saveOpt(key, val) {
    var name = modelSel.value;
    if (!name) return;
    if (!settings.opts[name]) settings.opts[name] = {};
    if (val === '' || val === null) delete settings.opts[name][key];
    else settings.opts[name][key] = val;
    persistSettings();
  }

  /* ============================================================ painel */
  function openPanel(open) {
    panelEl.classList.toggle('open', open);
    overlayEl.classList.toggle('on', open);
    $('cfg-btn').classList.toggle('on', open);
  }

  // Os campos de geracao sao ligados pelo bindSetting() abaixo, que sabe
  // distinguir parametro por-modelo de preferencia global.
  OPT_DEFS.forEach(function (d) { bindSetting(d[1], d[0], 'num'); });
  $('reset-opts').addEventListener('click', function () {
    var name = modelSel.value;
    if (name && settings.opts[name]) { delete settings.opts[name]; }
    persistSettings();
    probeModel(name);
    toast('parametros do modelo restaurados');
  });

  // settings[key] fica em settings.opts[modelo] quando a chave e um parametro
  // de geracao (per-modelo). bindSetting le/escreve pelo caminho certo.
  function isModelOpt(key) {
    return OPT_DEFS.some(function (d) { return d[0] === key; });
  }
  function bindSetting(id, key, type) {
    var el = $(id);
    if (!el) return;
    var modelScoped = isModelOpt(key);
    if (modelScoped) {
      // o valor vem de paintOpts(); aqui so ligo o listener
    } else {
      if (type === 'bool') el.checked = !!settings[key];
      else if (settings[key] !== undefined) el.value = settings[key];
    }
    el.addEventListener('input', function () {
      if (modelScoped) {
        var v = el.type === 'range' ? parseFloat(el.value) : parseInt(el.value, 10);
        var lbl = optLabel(key);
        if (lbl) lbl.textContent = el.value;
        saveOpt(key, isNaN(v) ? '' : v);
        return;
      }
      settings[key] = type === 'bool' ? el.checked : el.value;
      persistSettings();
      if (key === 'theme') applyTheme();
      if (key === 'math' && el.checked) loadKatex().then(function () { repaintAll(); });
      if (key === 'format') $('schema-box').style.display = settings.format === 'schema' ? '' : 'none';
    });
  }

  function applyTheme() {
    document.documentElement.classList.toggle('light', settings.theme === 'light');
    var m = document.querySelector('meta[name="theme-color"]');
    if (m) m.setAttribute('content', settings.theme === 'light' ? '#f6f7f9' : '#0a0c10');
  }
  function repaintAll() {
    var c = current();
    if (c) openChat(c.id);
  }

  /* ============================================================ export */
  function exportPayload() {
    return { app: 'LATAM IA', version: 1, exportedAt: new Date().toISOString(), chats: chats };
  }
  function download(name, text, mime) {
    var b = new Blob([text], { type: mime || 'application/json' });
    var u = URL.createObjectURL(b);
    var a = document.createElement('a');
    a.href = u; a.download = name;
    document.body.appendChild(a); a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(u); }, 1000);
  }
  function toMarkdown(c) {
    var out = '# ' + (c.title || 'Conversa') + '\n\n';
    c.messages.forEach(function (m) {
      if (m.role === 'tool') { out += '> resultado de `' + (m.tool_name || 'tool') + '`: `' + String(m.content).slice(0, 300) + '`\n\n'; return; }
      out += (m.role === 'user' ? '## Voce\n\n' : '## LATAM IA\n\n');
      if (m.thinking) out += '_raciocinio: ' + m.thinking.replace(/\n/g, ' ').slice(0, 400) + '_\n\n';
      out += (m.content || '') + '\n\n';
    });
    return out;
  }

  /* ============================================================ modal */
  function confirmBox(title, desc, onOk) {
    $('cf-t').textContent = title;
    $('cf-d').textContent = desc;
    $('m-confirm').classList.add('on');
    $('cf-ok').onclick = function () {
      $('m-confirm').classList.remove('on');
      onOk();
    };
  }
  document.querySelectorAll('[data-close]').forEach(function (b) {
    b.addEventListener('click', function () { b.closest('.modal').classList.remove('on'); });
  });
  document.querySelectorAll('.modal').forEach(function (m) {
    m.addEventListener('click', function (e) { if (e.target === m) m.classList.remove('on'); });
  });

  /* ============================================================ eventos */
  $('menu').addEventListener('click', function () { sideEl.classList.toggle('hidden'); });
  $('side-close').addEventListener('click', function () { sideEl.classList.add('hidden'); });
  $('new-chat').addEventListener('click', function () { newChat(); });
  $('q').addEventListener('input', renderChats);
  $('cfg-btn').addEventListener('click', function () { openPanel(!panelEl.classList.contains('open')); });
  $('panel-close').addEventListener('click', function () { openPanel(false); });
  overlayEl.addEventListener('click', function () { openPanel(false); });

  $('export-btn').addEventListener('click', function () {
    var json = JSON.stringify(exportPayload(), null, 2);
    $('ex-text').textContent = json.slice(0, 4000) + (json.length > 4000 ? '\n... (truncado na visualizacao)' : '');
    $('m-export').classList.add('on');
    $('ex-file').onclick = function () { download('latam-ia-' + Date.now() + '.json', json); };
    $('ex-md').onclick = function () {
      var c = current() || chats[0];
      if (!c) { toast('nada para exportar'); return; }
      download((c.title || 'conversa').replace(/[^\w-]+/g, '_') + '.md', toMarkdown(c), 'text/markdown');
    };
    $('ex-copy').onclick = function () { copyText(json, $('ex-copy'), 'Copiar'); };
  });
  $('import-btn').addEventListener('click', function () {
    $('im-text').value = '';
    $('m-import').classList.add('on');
    $('im-ok').onclick = function () {
      try {
        var data = JSON.parse($('im-text').value);
        var list = Array.isArray(data) ? data : (data.chats || []);
        if (!Array.isArray(list) || !list.length) throw new Error('formato desconhecido');
        var added = 0;
        list.forEach(function (c) {
          if (!c || !Array.isArray(c.messages)) return;
          chats.unshift({
            id: uid(),
            title: c.title || 'Importada',
            createdAt: c.createdAt || Date.now(),
            updatedAt: c.updatedAt || Date.now(),
            messages: c.messages.filter(function (m) { return m && m.role && typeof m.content === 'string' || (m && m.tool_calls); })
          });
          added++;
        });
        persistChats();
        renderChats();
        $('m-import').classList.remove('on');
        toast(added + ' conversa' + (added > 1 ? 's' : '') + ' importada' + (added > 1 ? 's' : ''));
      } catch (e) {
        toast('JSON invalido: ' + e.message);
      }
    };
  });
  $('clear-all').addEventListener('click', function () {
    confirmBox('Apagar tudo?', 'Todas as ' + chats.length + ' conversas salvas neste navegador vao sumir. Exporte antes se quiser guardar.', function () {
      chats = [];
      currentId = null;
      persistChats();
      wrap.innerHTML = '';
      emptyState(true);
      renderChats();
      openPanel(false);
      toast('apagado');
    });
  });
  $('logout-btn').addEventListener('click', function () { window.location.href = '/logout'; });

  function autoresize() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 220) + 'px';
  }
  input.addEventListener('input', autoresize);
  modelSel.addEventListener('change', function () {
    setReady();
    probeModel(modelSel.value);
  });
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
  });
  form.addEventListener('submit', function (e) { e.preventDefault(); send(); });

  // delegacao: botao "copiar" dentro de bloco de codigo
  wrap.addEventListener('click', function (e) {
    var b = e.target.closest('[data-copy-code]');
    if (!b) return;
    var pre = b.closest('pre');
    var code = pre ? pre.querySelector('code') : null;
    if (code) copyText(code.textContent, b, 'copiar');
  });

  document.addEventListener('keydown', function (e) {
    var mod = e.ctrlKey || e.metaKey;
    if (mod && e.key.toLowerCase() === 'k') { e.preventDefault(); newChat(); }
    else if (mod && e.key === '/') { e.preventDefault(); openPanel(!panelEl.classList.contains('open')); }
    else if (e.key === 'Escape') { openPanel(false); document.querySelectorAll('.modal.on').forEach(function (m) { m.classList.remove('on'); }); }
  });

  /* ============================================================ boot */
  if (HAS_AUTH) $('logout-btn').style.display = '';
  applyTheme();
  bindSetting('p-theme', 'theme', 'bool');
  bindSetting('p-math', 'math', 'bool');
  bindSetting('p-system', 'system', 'str');
  bindSetting('p-num_ctx', 'num_ctx', 'str');
  bindSetting('p-truncate', 'truncate', 'bool');
  bindSetting('p-flash', 'flash', 'bool');
  bindSetting('p-format', 'format', 'str');
  bindSetting('p-schema', 'schema', 'str');
  $('schema-box').style.display = settings.format === 'schema' ? '' : 'none';
  if (settings.math) loadKatex();

  if (window.innerWidth <= 860) sideEl.classList.add('hidden');
  emptyState(true);
  autoresize();
  renderChats();
  loadModels().then(function () {
    var last = LS.read('latam.lastChat', null);
    if (last && chats.some(function (c) { return c.id === last; })) openChat(last);
  });
  // guarda qual conversa estava aberta
  var origOpen = openChat;
  openChat = function (id) { LS.write('latam.lastChat', id); origOpen(id); };
})();
</script>
</body>
</html>
CHATEOF
fi
echo "[egg] interface web em /home/container/ui/ (git=${UI_FROM_GIT})"

# --------------------------------------------------------------- script de inicializacao
cat > "${SERVER_DIR}/ollama-start.sh" << 'STARTEOF'
#!/bin/bash
# Ollama egg - inicializacao. Editavel pelo File Manager do painel.
# As variaveis (MODEL, AUTO_PULL, KEEP_ALIVE...) vem da aba Startup do servidor.
# BASE_DIR so existe pra facilitar teste fora do painel; no Pterodactyl e /home/container.
BASE_DIR="${BASE_DIR:-/home/container}"
cd "${BASE_DIR}" || exit 1

OLLAMA_ROOT="${BASE_DIR}/ollama"
OLLAMA_BIN="${OLLAMA_ROOT}/bin/ollama"

export HOME="${BASE_DIR}"
export OLLAMA_MODELS="${BASE_DIR}/models"
export TMPDIR="${BASE_DIR}/temp"
export LD_LIBRARY_PATH="${OLLAMA_ROOT}/lib/ollama${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# as libs de Vulkan sao removidas na instalacao, entao desliga a sondagem
export OLLAMA_VULKAN=0

# Com a interface ligada, o Node ocupa a allocation publica e o Ollama fica so em
# 127.0.0.1 (porta interna nao precisa de allocation no Pterodactyl).
UI_ON="false"
if [ "${ENABLE_UI}" = "true" ] || [ "${ENABLE_UI}" = "1" ]; then
    if ! command -v node >/dev/null 2>&1; then
        echo "[egg] ERRO: ENABLE_UI=true mas nao existe 'node' nesta imagem."
        echo "[egg] Use ghcr.io/parkervcp/yolks:nodejs_24 ou desligue a variavel ENABLE_UI."
        exit 1
    fi
    UI_ON="true"
    INTERNAL_PORT=11434
    if [ "${INTERNAL_PORT}" = "${SERVER_PORT}" ]; then INTERNAL_PORT=11435; fi
    export OLLAMA_HOST="127.0.0.1:${INTERNAL_PORT}"
    export OLLAMA_INTERNAL_PORT="${INTERNAL_PORT}"
else
    export OLLAMA_HOST="0.0.0.0:${SERVER_PORT}"
fi

mkdir -p "${OLLAMA_MODELS}" "${TMPDIR}" "${HOME}/.ollama"

if [ -n "${ORIGINS}" ];           then export OLLAMA_ORIGINS="${ORIGINS}"; fi
if [ -n "${KEEP_ALIVE}" ];        then export OLLAMA_KEEP_ALIVE="${KEEP_ALIVE}"; fi
if [ -n "${NUM_PARALLEL}" ];      then export OLLAMA_NUM_PARALLEL="${NUM_PARALLEL}"; fi
if [ -n "${MAX_LOADED_MODELS}" ]; then export OLLAMA_MAX_LOADED_MODELS="${MAX_LOADED_MODELS}"; fi
if [ -n "${CONTEXT_LENGTH}" ];    then export OLLAMA_CONTEXT_LENGTH="${CONTEXT_LENGTH}"; fi
if [ -n "${KV_CACHE_TYPE}" ];     then export OLLAMA_KV_CACHE_TYPE="${KV_CACHE_TYPE}"; fi
if [ -n "${LLM_LIBRARY}" ];       then export OLLAMA_LLM_LIBRARY="${LLM_LIBRARY}"; fi
if [ "${FLASH_ATTENTION}" = "1" ] || [ "${FLASH_ATTENTION}" = "true" ]; then export OLLAMA_FLASH_ATTENTION=1; fi
if [ "${DEBUG}" = "1" ] || [ "${DEBUG}" = "true" ];                     then export OLLAMA_DEBUG=1; fi

if [ ! -x "${OLLAMA_BIN}" ]; then
    echo "[egg] ERRO: ${OLLAMA_BIN} nao encontrado."
    echo "[egg] Rode 'Reinstall Server' no painel (Admin > Servers > seu server > Reinstall)."
    exit 1
fi

echo "[egg] =============================================="
echo "[egg] Ollama $(cat "${OLLAMA_ROOT}/VERSION" 2>/dev/null || echo '?') | inferencia em CPU"
echo "[egg] api       : ${OLLAMA_HOST}"
if [ "${UI_ON}" = "true" ]; then
    echo "[egg] chat web  : porta publica ${SERVER_PORT} -> abra http://SEU_IP:${SERVER_PORT}/ no navegador"
fi
echo "[egg] models    : ${OLLAMA_MODELS}"
echo "[egg] memoria   : ${SERVER_MEMORY} MB (limite do container)"
echo "[egg] =============================================="

if ! grep -q -m1 -o ' avx2 ' /proc/cpuinfo 2>/dev/null; then
    echo "[egg] AVISO: esta CPU nao tem AVX2 - a inferencia vai usar o backend 'cpu' basico e ficar bem lenta."
fi

# Threads de inferencia. Em modelo pequeno (<3B), usar todas as vCPU ATRASA muito:
# medido com 2 vCPU -> 1 thread: 27.8 tok/s | 2: 45.2 tok/s | 4: 0.2 tok/s (thrashing).
# Teto de threads = vCPU que ESTE container enxerga.
#
# Por que nproc nao basta: nproc usa sched_getaffinity, que so reflete cpuset
# (pinning). Pterodactyl/Wings pode limitar CPU por CFS quota (cgroup v2 cpu.max,
# "quota period") em vez de cpuset - nesse caso nproc continua reportando todas
# as cores do host. Ex.: "200% CPU / 2 cores" no painel.
#
# Ollama usa o runtime do Go, que le NumCPU via sched_getaffinity tambem. Entao
# num cgroup limitado por quota ele cria 20 threads pra 2 cores de trabalho, e a
# sincronizacao come tudo. (Ja observado: n_threads=20, warmup de 114s.)
#
# cpu.max = "<quota> <period>"; "max" = ilimitado. threads = quota/period.
NCPU="$(nproc 2>/dev/null || echo 1)"
CG_MAX=""
for _cg in /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu/cpu.cfs_quota_us; do
    if [ -r "${_cg}" ]; then CG_MAX="${_cg}"; break; fi
done
if [ -n "${CG_MAX}" ]; then
    if [ "${CG_MAX}" = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" ]; then
        _q="$(cat "${CG_MAX}" 2>/dev/null || echo -1)"
        _p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 100000)"
    else
        read -r _q _p < "${CG_MAX}" 2>/dev/null || true
    fi
    if [ -n "${_q:-}" ] && [ "${_q}" != "max" ] && [ "${_q}" -gt 0 ] 2>/dev/null \
       && [ -n "${_p:-}" ] && [ "${_p}" -gt 0 ] 2>/dev/null; then
        # teto inteiro: 150000/100000 = 1, nao 2. Duas threads brigando por 1.5
        # core vao se throttlear no fim de cada periodo de 100ms e ficar pior
        # do que uma thread so. Melhor sobrar core do que faltar.
        _lim=$(( _q / _p ))
        [ "${_lim}" -lt 1 ] && _lim=1
        if [ "${_lim}" -lt "${NCPU}" ]; then
            echo "[egg] cgroup limita CPU a ${_lim} core(s), quota ${_q}/${_p} - nproc dizia ${NCPU}"
            NCPU="${_lim}"
        fi
    fi
fi
if [ -z "${CPU_THREADS}" ] || [ "${CPU_THREADS}" = "0" ]; then
    CPU_THREADS="${NCPU}"
fi
if [ "${CPU_THREADS}" -gt "${NCPU}" ] 2>/dev/null; then
    echo "[egg] AVISO: CPU_THREADS=${CPU_THREADS} mas o container so ve ${NCPU} vCPU."
    echo "[egg]         Mais threads que nucleos causa thrashing e derruba a velocidade."
    echo "[egg]         Ajustando para ${NCPU}. Modelos <3B costumam render melhor com 4-8."
    CPU_THREADS="${NCPU}"
fi
export CPU_THREADS
echo "[egg] threads   : ${CPU_THREADS} (vCPU visiveis: ${NCPU})"
echo "[egg] AVISO     : o limite vale para o chat. Clientes que chamam a API direto"
echo "[egg]             precisam mandar options.num_thread=${CPU_THREADS} na requisicao."

# ----------------------------------------------------------------- download automatico
if [ "${AUTO_PULL}" = "true" ] || [ "${AUTO_PULL}" = "1" ]; then
    if [ -n "${MODEL}" ]; then
        (
            READY_PORT="${OLLAMA_HOST##*:}"
            echo "[egg] Aguardando o servidor subir para baixar '${MODEL}'..."
            for _ in $(seq 1 60); do
                if curl -fsS "http://127.0.0.1:${READY_PORT}/api/tags" >/dev/null 2>&1; then break; fi
                sleep 1
            done
            echo "[egg] Baixando '${MODEL}'... (o progresso aparece no console)"
            if "${OLLAMA_BIN}" pull "${MODEL}"; then
                echo "[egg] Modelo '${MODEL}' pronto para uso."
            else
                echo "[egg] Falha ao baixar '${MODEL}'. Verifique o nome do modelo e o espaco em disco."
            fi
        ) &
    else
        echo "[egg] AUTO_PULL esta ligado mas a variavel MODEL esta vazia - nada sera baixado."
    fi
fi

if [ "${UI_ON}" = "true" ]; then
    # Ollama em background (os logs continuam indo pro console do painel, entao o
    # marcador "Listening on" segue funcionando) e o Node em primeiro plano.
    "${OLLAMA_BIN}" serve &
    exec node "${BASE_DIR}/ui/proxy.js"
fi

exec "${OLLAMA_BIN}" serve
STARTEOF
chmod +x "${SERVER_DIR}/ollama-start.sh"

# --------------------------------------------------------------- smoke test
echo "[egg] smoke test: subindo 'ollama serve' por alguns segundos..."
export OLLAMA_MODELS="${WORK}/smoke-models"
export OLLAMA_HOME="${WORK}/smoke-home"
export OLLAMA_HOST="127.0.0.1:11499"
export LD_LIBRARY_PATH="${LIB_DIR}"
mkdir -p "${OLLAMA_MODELS}" "${OLLAMA_HOME}"

"${BIN_DIR}/ollama" serve > "${WORK}/smoke.log" 2>&1 &
SMOKE_PID=$!
SMOKE_OK="no"
for _ in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:11499/api/version" >/dev/null 2>&1; then SMOKE_OK="yes"; break; fi
    sleep 0.5
done
if [ "${SMOKE_OK}" = "yes" ]; then
    echo "[egg] smoke test OK -> $(curl -fsS http://127.0.0.1:11499/api/version)"
else
    echo "[egg] AVISO: o smoke test nao respondeu. Log do ollama:"
    tail -25 "${WORK}/smoke.log" 2>/dev/null || true
fi
kill "${SMOKE_PID}" >/dev/null 2>&1
wait "${SMOKE_PID}" 2>/dev/null

# --------------------------------------------------------------- resumo
echo "=============================================="
echo "[egg] Instalacao concluida."
echo "[egg] binario  : /home/container/ollama/bin/ollama"
echo "[egg] modelos  : /home/container/models"
echo "[egg] startup  : /home/container/ollama-start.sh"
echo "[egg] Lembre de dar disco suficiente pro modelo (${MODEL:-modelo nao definido})."
echo "=============================================="
exit 0
