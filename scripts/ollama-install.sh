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
// Sidecar da egg Ollama: serve o chat em "/" e faz proxy de todo o resto para a
// API do Ollama, que escuta so em 127.0.0.1. Assim uma allocation atende os dois.
// Sem dependencias npm - usa apenas o modulo http do Node.

const http = require('http');
const fs = require('fs');
const path = require('path');

const PUBLIC_PORT = parseInt(process.env.SERVER_PORT || '11434', 10);
const UPSTREAM_HOST = '127.0.0.1';
const UPSTREAM_PORT = parseInt(process.env.OLLAMA_INTERNAL_PORT || '11434', 10);
const CHAT_HTML = path.join(__dirname, 'chat.html');
// 0 = Ollama decide; >0 limita as threads de inferencia (bom pra modelo pequeno)
const CPU_THREADS = String(parseInt(process.env.CPU_THREADS || '0', 10) || 0);

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
    return fs.readFile(CHAT_HTML, (err, buf) => {
      if (err) {
        res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end('chat.html nao encontrado: ' + err.message);
      }
      // injeta a config do servidor na pagina (nada sensivel aqui)
      const html = buf
        .toString('utf8')
        .replace(
          '<div id="cfg" style="display:none"></div>',
          '<div id="cfg" style="display:none" data-threads="' + CPU_THREADS + '"></div>'
        );
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(html);
    });
  }

  if (req.url === '/favicon.ico') {
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
    --line: #1e232d;
    --line-2: #2a313d;
    --text: #e8ebf0;
    --muted: #8b93a3;
    --accent: #2f6feb;
    --accent-2: #4f8bff;
    --user-bubble: #1a2338;
    --radius: 14px;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0;
    display: flex;
    flex-direction: column;
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
    overscroll-behavior: none;
  }
  button, select, textarea, input { font: inherit; color: inherit; }
  button { cursor: pointer; background: none; border: none; }

  /* ---------------- topo ---------------- */
  header {
    flex: 0 0 auto;
    display: flex; align-items: center; gap: 10px;
    padding: 10px 14px;
    background: var(--panel);
    border-bottom: 1px solid var(--line);
  }
  .brand { display: flex; align-items: center; gap: 9px; font-weight: 650; letter-spacing: .3px; }
  .brand .logo {
    width: 26px; height: 26px; border-radius: 8px; flex: 0 0 auto;
    background: linear-gradient(135deg, var(--accent), #7b4dff);
    display: grid; place-items: center; font-size: 13px; font-weight: 700; color: #fff;
  }
  .brand .sub { font-size: 11px; color: var(--muted); font-weight: 500; }
  header .spacer { flex: 1; }
  select {
    background: var(--panel-2); border: 1px solid var(--line-2); border-radius: 9px;
    padding: 6px 9px; font-size: 13px; max-width: 44vw;
  }
  .icon-btn {
    width: 34px; height: 34px; border-radius: 9px; display: grid; place-items: center;
    border: 1px solid var(--line-2); background: var(--panel-2); color: var(--muted);
    font-size: 15px; line-height: 1;
  }
  .icon-btn:hover { color: var(--text); border-color: #3a4353; }

  /* ---------------- mensagens ---------------- */
  #log {
    flex: 1 1 auto; overflow-y: auto; -webkit-overflow-scrolling: touch;
    padding: 20px 14px 12px; scroll-behavior: smooth;
  }
  .wrap { max-width: 780px; margin: 0 auto; }
  .empty { text-align: center; color: var(--muted); margin: 12vh 0 0; }
  .empty h1 { font-size: 26px; margin: 0 0 6px; color: var(--text); font-weight: 650; }
  .empty p { margin: 0; font-size: 14px; }
  .empty .hint { margin-top: 18px; font-size: 13px; color: #6d7686; }

  .msg { display: flex; gap: 10px; margin: 0 0 18px; }
  .msg .avatar {
    flex: 0 0 auto; width: 28px; height: 28px; border-radius: 8px; margin-top: 2px;
    display: grid; place-items: center; font-size: 11px; font-weight: 700;
    background: #1c212b; color: var(--muted); border: 1px solid var(--line-2);
  }
  .msg.user .avatar { background: var(--user-bubble); color: #9db9f5; border-color: #263453; }
  .msg .body { flex: 1 1 auto; min-width: 0; }
  .msg .who { font-size: 12px; color: var(--muted); margin-bottom: 3px; font-weight: 600; }
  .content {
    white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word;
  }
  .msg.user .content {
    background: var(--user-bubble); border: 1px solid #263453;
    border-radius: var(--radius); padding: 9px 13px;
  }
  .content code {
    background: #0c0f14; border: 1px solid var(--line); border-radius: 5px;
    padding: 1px 5px; font-size: 13px;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .content pre {
    background: #0c0f14; border: 1px solid var(--line); border-radius: 10px;
    padding: 11px 13px; overflow-x: auto; margin: 9px 0;
  }
  .content pre code { background: none; border: none; padding: 0; font-size: 13px; }
  .think {
    color: #788193; font-size: 13.5px; border-left: 2px solid var(--line-2);
    padding-left: 10px; margin-bottom: 8px; font-style: italic;
  }
  .foot { display: flex; align-items: center; gap: 10px; margin-top: 5px; font-size: 11.5px; color: #667083; }
  .foot button { color: #667083; font-size: 11.5px; padding: 2px 4px; border-radius: 5px; }
  .foot button:hover { color: var(--text); background: var(--panel-2); }
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
  form {
    flex: 0 0 auto; background: var(--panel); border-top: 1px solid var(--line);
    padding: 10px 14px calc(10px + env(safe-area-inset-bottom));
  }
  .composer {
    max-width: 780px; margin: 0 auto; display: flex; align-items: flex-end; gap: 8px;
    background: var(--panel-2); border: 1px solid var(--line-2); border-radius: 16px; padding: 7px 7px 7px 13px;
  }
  .composer:focus-within { border-color: var(--accent); }
  textarea {
    flex: 1 1 auto; border: none; background: none; resize: none; outline: none;
    max-height: 190px; min-height: 26px; padding: 5px 0; line-height: 1.5;
  }
  textarea::placeholder { color: #6b7484; }
  .send {
    flex: 0 0 auto; width: 34px; height: 34px; border-radius: 10px; display: grid; place-items: center;
    background: var(--accent); color: #fff; font-size: 15px; transition: background .15s, opacity .15s;
  }
  .send:hover { background: var(--accent-2); }
  .send.stop { background: #b3392f; }
  .send:disabled { opacity: .4; cursor: not-allowed; }
  .bar { max-width: 780px; margin: 7px auto 0; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .bar label { display: flex; align-items: center; gap: 5px; font-size: 12px; color: var(--muted); }
  .bar .status { font-size: 12px; color: #667083; margin-left: auto; }
  .bar .status.bad { color: #ff9a9a; }

  @media (max-width: 640px) {
    body { font-size: 15px; }
    #log { padding: 14px 11px 8px; }
    .brand .sub { display: none; }
    select { font-size: 12px; max-width: 38vw; }
    .msg { gap: 8px; margin-bottom: 15px; }
    .msg .avatar { width: 25px; height: 25px; }
  }
</style>
</head>
<body>

<header>
  <div class="brand">
    <span class="logo">L</span>
    <span>LATAM IA<span class="sub" id="sub"></span></span>
  </div>
  <span class="spacer"></span>
  <select id="model" title="Modelo"><option value="">carregando modelos...</option></select>
  <button class="icon-btn" id="new" title="Nova conversa" aria-label="Nova conversa">+</button>
</header>

<div id="cfg" style="display:none"></div>
<div id="log"><div class="wrap" id="wrap"></div></div>

<form id="form">
  <div class="composer">
    <textarea id="input" rows="1" placeholder="Carregando modelos..." disabled autofocus></textarea>
    <button class="send" id="send" type="submit" title="Enviar" aria-label="Enviar" disabled>&#10148;</button>
  </div>
  <div class="bar">
    <label><input type="checkbox" id="think"> mostrar raciocinio</label>
    <button type="button" id="reload" class="status" style="border:1px solid var(--line-2);border-radius:6px;padding:2px 7px">recarregar modelos</button>
    <span class="status" id="status"></span>
  </div>
</form>

<script>
(function () {
  'use strict';

  var log = document.getElementById('log');
  var wrap = document.getElementById('wrap');
  var modelSel = document.getElementById('model');
  var form = document.getElementById('form');
  var input = document.getElementById('input');
  var sendBtn = document.getElementById('send');
  var thinkBox = document.getElementById('think');
  var statusEl = document.getElementById('status');
  var subEl = document.getElementById('sub');

  var history = [];
  var controller = null;
  var busy = false;
  var autoScroll = true;
  var cfgEl = document.getElementById('cfg');
  var THREADS = (cfgEl && cfgEl.dataset && cfgEl.dataset.threads) || '0';

  /* ---------------------------------------------------------- util */
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  // markdown minimo, sem CDN: ``` blocos e `inline`
  function md(text) {
    var parts = String(text).split('```');
    var out = '';
    for (var i = 0; i < parts.length; i++) {
      if (i % 2 === 1) {
        out += '<pre><code>' + esc(parts[i].replace(/^[a-zA-Z0-9_+#-]*\n/, '')) + '</code></pre>';
      } else {
        out += esc(parts[i]).replace(/`([^`\n]+)`/g, '<code>$1</code>');
      }
    }
    return out;
  }

  function stickToBottom() {
    if (autoScroll) log.scrollTop = log.scrollHeight;
  }
  log.addEventListener('scroll', function () {
    autoScroll = log.scrollHeight - log.scrollTop - log.clientHeight < 60;
  });

  function status(msg, bad) {
    statusEl.textContent = msg || '';
    statusEl.className = 'status' + (bad ? ' bad' : '');
  }

  /* ---------------------------------------------------------- mensagens */
  function emptyState(show) {
    var el = document.getElementById('empty');
    if (show) {
      if (el) return;
      var d = document.createElement('div');
      d.className = 'empty';
      d.id = 'empty';
      d.innerHTML = '<h1>LATAM IA</h1><p>Seu assistente rodando localmente neste servidor.</p>' +
                    '<div class="hint">Escolha o modelo acima e mande a primeira mensagem.</div>';
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

  /* Renderizador incremental: guarda o texto acumulado e re-renderiza so o ultimo
     bloco aberto, entao o custo por chunk e constante e a resposta aparece token a token. */
  function streamer(el) {
    var buf = '';
    var raf = 0;
    var lastBlocks = -1;

    function paint(withCaret) {
      var parts = buf.split('```');
      var open = parts.length % 2 === 0; // fence nao fechada
      var closed = open ? parts.length - 1 : parts.length;
      var html = '';
      for (var i = 0; i < closed; i++) {
        html += (i % 2 === 1)
          ? '<pre><code>' + esc(parts[i].replace(/^[a-zA-Z0-9_+#-]*\n/, '')) + '</code></pre>'
          : md(parts[i]);
      }
      if (open) html += '<pre><code>' + esc(parts[closed].replace(/^[a-zA-Z0-9_+#-]*\n/, ''));
      if (withCaret) html += '<span class="caret"></span>';
      el.innerHTML = html;
      lastBlocks = parts.length;
      stickToBottom();
    }

    return {
      push: function (delta) {
        buf += delta;
        if (raf) return;
        raf = requestAnimationFrame(function () { raf = 0; paint(true); });
      },
      done: function () {
        if (raf) { cancelAnimationFrame(raf); raf = 0; }
        paint(false);
        return buf;
      },
      text: function () { return buf; },
      blocks: function () { return lastBlocks; }
    };
  }

  function thinking(el) {
    el.innerHTML = '<span class="dots"><i></i><i></i><i></i></span>';
  }

  function footer(el, model, ms, interrupted) {
    var f = document.createElement('div');
    f.className = 'foot';
    var info = document.createElement('span');
    info.textContent = model + ' · ' + (ms / 1000).toFixed(1) + 's' + (interrupted ? ' · interrompido' : '');
    var copy = document.createElement('button');
    copy.type = 'button';
    copy.textContent = 'copiar';
    copy.addEventListener('click', function () {
      var text = el.textContent;
      if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(function () { copy.textContent = 'copiado'; });
      } else {
        copy.textContent = 'indisponivel';
      }
      setTimeout(function () { copy.textContent = 'copiar'; }, 1400);
    });
    f.appendChild(info);
    f.appendChild(copy);
    el.parentNode.appendChild(f);
  }

  /* ---------------------------------------------------------- modelos */
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
        o.textContent = m.name + ' (' + Math.round((m.size || 0) / 1048576) + ' MB)';
        modelSel.appendChild(o);
      });
      if (prev && modelSel.querySelector('option[value="' + prev + '"]')) modelSel.value = prev;
      subEl.textContent = ' · ' + models.length + ' modelo' + (models.length > 1 ? 's' : '');
      input.placeholder = 'Pergunte qualquer coisa...';
      setReady();
      status('');
    }).catch(function (e) {
      modelSel.innerHTML = '<option value="">API fora do ar - tente recarregar</option>';
      status('API indisponivel: ' + e.message, true);
    });
  }

  /* ---------------------------------------------------------- envio */
  function modelReady() { return !!modelSel.value; }

  function setReady() {
    if (!modelReady()) return;
    input.disabled = false;
    sendBtn.disabled = false;
    input.placeholder = 'Pergunte qualquer coisa...';
    input.focus();
  }

  // Limita as threads de inferencia. Em modelo pequeno (<3B) thread demais ATRASA:
  // o overhead de sincronizacao entre as threads come o ganho. 0 = Ollama decide.
  function buildOptions() {
    var o = {};
    var t = parseInt(THREADS, 10);
    if (t > 0) o.num_thread = t;
    return o;
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
  function stopWaitClock() {
    if (waitTimer) { clearInterval(waitTimer); waitTimer = null; }
  }

  function setBusy(v) {
    busy = v;
    input.disabled = !modelReady();
    sendBtn.disabled = !modelReady();
    sendBtn.classList.toggle('stop', v);
    sendBtn.innerHTML = v ? '&#9632;' : '&#10148;';
    sendBtn.title = v ? 'Parar' : 'Enviar';
  }

  function send() {
    if (busy) { if (controller) controller.abort(); return; }
    var text = input.value.trim();
    var model = modelSel.value;
    if (!text) return;
    if (!model || model.indexOf(' ') !== -1) {
      status('nenhum modelo disponivel ainda - aguarde carregar', true);
      return;
    }

    emptyState(false);
    history.push({ role: 'user', content: text });
    var userEl = addMessage('user');
    userEl.innerHTML = md(text);
    input.value = '';
    autoresize();
    setBusy(true);
    autoScroll = true;

    var el = addMessage('assistant');
    thinking(el);
    status('aguardando o modelo...');
    startWaitClock();

    var st = streamer(el);
    var thinkBuf = '';
    var thinkEl = null;
    var startedAt = Date.now();
    var firstToken = true;
    controller = new AbortController();

    fetch('/api/chat', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      signal: controller.signal,
      body: JSON.stringify({
        model: model,
        messages: history,
        stream: true,
        think: thinkBox.checked,
        options: buildOptions()
      })
    }).then(function (resp) {
      if (!resp.ok) return resp.text().then(function (t) { throw new Error('HTTP ' + resp.status + ' - ' + t); });
      var reader = resp.body.getReader();
      var dec = new TextDecoder();
      var pending = '';

      function pump() {
        return reader.read().then(function (res) {
          if (res.done) return close();
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
              if (!thinkEl) { thinkEl = document.createElement('div'); thinkEl.className = 'think'; el.parentNode.insertBefore(thinkEl, el); }
              thinkBuf += m.thinking;
              thinkEl.textContent = thinkBuf;
              stickToBottom();
            }
            if (m.content) {
              if (firstToken) { firstToken = false; stopWaitClock(); status('gerando...'); }
              st.push(m.content);
            }
          }
          return pump();
        });
      }

      function close() {
        stopWaitClock();
        var answer = st.done();
        var ms = Date.now() - startedAt;
        if (answer) history.push({ role: 'assistant', content: answer });
        footer(el, model, ms, false);
        setBusy(false);
        status('');
      }

      return pump();
    }).catch(function (e) {
      stopWaitClock();
      var answer = st.done();
      if (e.name === 'AbortError') {
        if (answer) history.push({ role: 'assistant', content: answer });
        footer(el, model, Date.now() - startedAt, true);
        status('interrompido');
      } else {
        if (!answer) el.innerHTML = '<span class="err">' + esc(e.message) + '</span>';
        else footer(el, model, Date.now() - startedAt, true);
        status(e.message, true);
      }
      setBusy(false);
    });
  }

  /* ---------------------------------------------------------- composer */
  function autoresize() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 190) + 'px';
  }
  input.addEventListener('input', autoresize);
  modelSel.addEventListener('change', setReady);
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
  });
  form.addEventListener('submit', function (e) { e.preventDefault(); send(); });
  document.getElementById('reload').addEventListener('click', loadModels);
  document.getElementById('new').addEventListener('click', function () {
    history = [];
    wrap.innerHTML = '';
    emptyState(true);
    status('');
    input.focus();
  });

  emptyState(true);
  autoresize();
  loadModels();
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
