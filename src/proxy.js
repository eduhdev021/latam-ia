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
