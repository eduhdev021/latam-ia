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
const https = require('https');
const net = require('net');

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

// Painel duplo numa porta so: com ENABLE_OPENWEBUI ligado, um cookie decide quem
// a porta publica serve. Open WebUI nao funciona sob subcaminho (usa caminhos
// absolutos), entao o interruptor troca a porta inteira em vez de montar /owui.
const OWUI_ENABLED = /^(true|1)$/i.test((process.env.ENABLE_OPENWEBUI || '').trim());
const OWUI_PORT = parseInt(process.env.OPENWEBUI_PORT || '3000', 10);
function panelCookie(req) {
  const raw = req.headers.cookie || '';
  const m = raw.match(/(?:^|;\s*)latam_panel=([^;]+)/);
  return m ? m[1] : '';
}
function owuiPipe(req, res) {
  // identity: upstream sem gzip (e localhost, custo zero) - a injecao do botao
  // "voltar" precisa do HTML em texto; bytes comprimidos virariam lixo.
  const headers = Object.assign({}, req.headers, { host: '127.0.0.1:' + OWUI_PORT, 'accept-encoding': 'identity' });
  const up = http.request(
    { host: '127.0.0.1', port: OWUI_PORT, method: req.method, path: req.url, headers },
    (ures) => {
      const ct = String(ures.headers['content-type'] || '');
      // na raiz, injeta um botao fixo "voltar pro LATAM IA" (o OWUI nao conhece
      // o interruptor; sem isso o usuario ficaria preso no outro painel)
      if (req.method === 'GET' && req.url === '/' && ures.statusCode === 200 && ct.includes('text/html') && !ures.headers['content-encoding']) {
        const chunks = [];
        ures.on('data', (c) => chunks.push(c));
        ures.on('end', () => {
          let body = Buffer.concat(chunks).toString('utf8');
          const btn = '<a href="/__panel/latam" style="position:fixed;left:10px;bottom:10px;z-index:2147483647;' +
            'background:#111;color:#fff;border:1px solid #555;border-radius:8px;padding:6px 10px;' +
            'font:12px system-ui,sans-serif;text-decoration:none;opacity:.85">\u2190 LATAM IA</a>';
          body = body.includes('</body>') ? body.replace('</body>', btn + '</body>') : body + btn;
          const h = Object.assign({}, ures.headers);
          delete h['content-length'];
          delete h['content-encoding'];
          h['content-length'] = String(Buffer.byteLength(body));
          res.writeHead(ures.statusCode, h);
          res.end(body);
        });
        return;
      }
      res.writeHead(ures.statusCode || 502, ures.headers);
      ures.pipe(res);
    }
  );
  up.on('error', () => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('Open WebUI indisponivel nesta porta (ENABLE_OPENWEBUI/OPENWEBUI_PORT?)');
  });
  req.pipe(up);
}
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
// Bearer com o proprio UI_TOKEN tambem autentica - e assim que o campo
// "API key" do chat conversa com este servidor (e com APIs externas que usam
// chave no Authorization). Sessoes de login continuam valendo.
function tokenMatches(token) {
  if (!UI_TOKEN || !token) return false;
  const a = Buffer.from(token), b = Buffer.from(UI_TOKEN);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function sessionValid(token) {
  if (!token) return false;
  if (tokenMatches(token)) return true;
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

// ----------------------------------------------------------------- PWA
// Icone em SVG inline: nao precisa de binario no repo nem de CDN.
const ICON =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">' +
  '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">' +
  '<stop offset="0" stop-color="#2f6feb"/><stop offset="1" stop-color="#7b4dff"/>' +
  '</linearGradient></defs>' +
  '<rect width="64" height="64" rx="14" fill="url(#g)"/>' +
  '<text x="32" y="43" font-family="system-ui,sans-serif" font-size="32" ' +
  'font-weight="700" fill="#fff" text-anchor="middle">L</text></svg>';

const MANIFEST = JSON.stringify({
  name: 'LATAM IA',
  short_name: 'LATAM IA',
  description: 'Chat local rodando no seu servidor',
  start_url: '/',
  scope: '/',
  display: 'standalone',
  background_color: '#0a0c10',
  theme_color: '#0a0c10',
  lang: 'pt-BR',
  icons: [
    { src: '/logo-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
    { src: '/logo-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
    { src: '/logo-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    { src: '/icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' },
  ],
});

// Cacheia so o shell (a pagina). Requisicao de API NUNCA entra no cache -
// resposta de modelo nao pode ficar guardada. Se o servidor cair, o app abre
// e mostra que esta offline em vez de servir conversa velha.
const SERVICE_WORKER = `
const SHELL = '/';
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open('latam-shell').then((c) => c.add(SHELL)));
  self.skipWaiting();
});
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== 'latam-shell').map((k) => caches.delete(k))))
  );
  self.clients.claim();
});
self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  if (u.origin !== self.location.origin) return;
  // so a pagina vai pro cache; API e busca sempre vao pra rede
  if (u.pathname !== '/' && u.pathname !== '/index.html') return;
  e.respondWith(
    fetch(e.request)
      .then((r) => {
        const copy = r.clone();
        caches.open('latam-shell').then((c) => c.put(SHELL, copy));
        return r;
      })
      .catch(() => caches.match(SHELL))
  );
});
`;

// ----------------------------------------------------------------- busca
// Busca na web sem precisar de chave de API. A Wikipedia e a unica fonte que
// testei que funciona daqui sem anti-bot (DuckDuckGo devolve 202, Mojeek 403).
// Se o provedor mudar, o modelo recebe o erro e responde sem a busca.
function httpGet(target, timeoutMs) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      target,
      { headers: { 'user-agent': 'LATAM-IA/1.0 (chat local; +https://github.com/eduhdev021/latam-ia)' }, timeout: timeoutMs },
      (r) => {
        if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) {
          r.resume();
          return resolve(httpGet(new URL(r.headers.location, target).toString(), timeoutMs));
        }
        let body = '';
        r.setEncoding('utf8');
        r.on('data', (c) => {
          body += c;
          if (body.length > 2 * 1024 * 1024) r.destroy();
        });
        r.on('end', () => resolve({ status: r.statusCode || 0, body }));
      }
    );
    req.on('timeout', () => {
      req.destroy(new Error('timeout de ' + timeoutMs + 'ms'));
    });
    req.on('error', reject);
  });
}

const stripTags = (s) =>
  String(s)
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#\d+;|&[a-z]+;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

async function webSearch(query, lang) {
  const base = 'https://' + lang + '.wikipedia.org';
  // 1. procura os artigos
  const s = await httpGet(
    base + '/w/api.php?action=query&list=search&format=json&srlimit=5&srsearch=' + encodeURIComponent(query),
    8000
  );
  if (s.status !== 200) throw new Error('wikipedia respondeu ' + s.status);
  let data;
  try {
    data = JSON.parse(s.body);
  } catch (e) {
    throw new Error('resposta da wikipedia nao e JSON');
  }
  const hits = ((data.query || {}).search || []).slice(0, 3);
  if (!hits.length) return { query: query, results: [], note: 'nada encontrado' };

  // 2. busca o resumo de cada um em paralelo
  const results = await Promise.all(
    hits.map((h) =>
      httpGet(base + '/api/rest_v1/page/summary/' + encodeURIComponent(h.title), 8000)
        .then((r) => {
          try {
            const d = JSON.parse(r.body);
            return {
              title: d.title || h.title,
              url: (d.content_urls || {}).desktop ? d.content_urls.desktop.page : base + '/wiki/' + encodeURIComponent(h.title),
              snippet: d.extract || stripTags(h.snippet || ''),
            };
          } catch (e) {
            return { title: h.title, url: base + '/wiki/' + encodeURIComponent(h.title), snippet: stripTags(h.snippet || '') };
          }
        })
        .catch(() => ({ title: h.title, url: base + '/wiki/' + encodeURIComponent(h.title), snippet: stripTags(h.snippet || '') }))
    )
  );
  return { query: query, source: 'wikipedia:' + lang, results: results };
}


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

  // ------------------------------------------------- interruptor de paineis
  if (p === '/__panel/owui' || p === '/__panel/latam') {
    const on = p === '/__panel/owui';
    res.writeHead(302, {
      'set-cookie': on
        ? 'latam_panel=owui; Path=/; Max-Age=2592000; SameSite=Lax'
        : 'latam_panel=; Path=/; Max-Age=0',
      location: '/',
    });
    return res.end();
  }
  // cookie diz "owui": a porta inteira vira o Open WebUI (ele tem login proprio,
  // entao passa na frente do UI_TOKEN do chat)
  if (OWUI_ENABLED && panelCookie(req) === 'owui') return owuiPipe(req, res);

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
            '" data-owui="' +
            (OWUI_ENABLED ? '1' : '0') +
            '"></div>'
        );
      sendChat(res, html);
    });
  }

  // ---------------------------------------------------------------- PWA/logo
  // Shell do app e icones sao publicos mesmo com UI_TOKEN ligado: nao contem
  // dado algum (so o casco do app), e o service worker precisa existir antes do
  // login para o PWA instalar. A API e a pagina continuam atras do login.
  // ---------------------------------------------------------------- PWA
  // Service worker e manifest tem que ser arquivos reais na raiz: data URI nao
  // funciona pra service worker (o navegador exige same-origin + escopo).
  if (p === '/sw.js') {
    res.writeHead(200, {
      'content-type': 'application/javascript; charset=utf-8',
      'cache-control': 'no-store',
      'service-worker-allowed': '/',
    });
    return res.end(SERVICE_WORKER);
  }
  if (p === '/manifest.webmanifest') {
    res.writeHead(200, { 'content-type': 'application/manifest+json; charset=utf-8' });
    return res.end(MANIFEST);
  }
  if (p === '/favicon.ico' || p === '/icon.svg') {
    res.writeHead(200, { 'content-type': 'image/svg+xml', 'cache-control': 'max-age=86400' });
    return res.end(ICON);
  }
  if (p === '/logo-192.png' || p === '/logo-512.png' || p === '/logo.png') {
    // O logo vem do Git (assets/), copiado pela instalacao para ui/. Cache longo:
    // o arquivo so muda quando o usuario reinstala.
    var file = path.join(__dirname, p === '/logo.png' ? 'logo-512.png' : p.slice(1));
    return fs.promises.readFile(file).then(
      (buf) => {
        res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'public, max-age=604800' });
        res.end(buf);
      },
      () => {
        res.writeHead(404, { 'content-type': 'text/plain' });
        res.end('logo nao instalado - rode Reinstall para buscar do Git');
      }
    );
  }

  // ---------------------------------------------------------------- api
  // Tudo que nao for pagina vai pro Ollama. Se o token estiver ligado, exige
  // sessao valida - inclusive pra chamadas diretas de script.
  if (UI_TOKEN && !sessionValid(sessionToken(req))) {
    return json(res, 401, { error: 'nao autenticado - faca login em /login' });
  }

  // ---------------------------------------------------------------- busca
  // /search?q=... faz a busca no servidor, nao no navegador. Motivo: CORS.
  // A Wikipedia ate permite cross-origin, mas a maioria dos provedores nao,
  // e o navegador bloquearia. Aqui o proxy pede e devolve JSON limpo.
  if (p === '/search') {
    return readBody(req)
      .then(() => {
        const q = (url.searchParams.get('q') || '').trim().slice(0, 400);
        if (!q) return json(res, 400, { error: 'faltou q' });
        const lang = (url.searchParams.get('lang') || 'pt').slice(0, 8);
        return webSearch(q, lang).then(
          (r) => json(res, 200, r),
          (e) => json(res, 502, { error: e.message })
        );
      })
      .catch((e) => json(res, 500, { error: e.message }));
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

// WebSocket (socket.io do Open WebUI) segue o cookie do interruptor
server.on('upgrade', (req, socket, head) => {
  if (!(OWUI_ENABLED && panelCookie(req) === 'owui')) {
    socket.destroy();
    return;
  }
  const up = net.connect(OWUI_PORT, '127.0.0.1', () => {
    const lines = Object.keys(req.headers).map((k) => k + ': ' + req.headers[k]);
    up.write(req.method + ' ' + req.url + ' HTTP/1.1\r\n' + lines.join('\r\n') + '\r\n\r\n');
    if (head && head.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
  up.on('error', () => socket.destroy());
  socket.on('error', () => up.destroy());
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
