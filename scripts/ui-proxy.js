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
