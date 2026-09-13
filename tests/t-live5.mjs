// Teste da API key de ponta a ponta: proxy REAL rodando com UI_TOKEN=segredo123.
// O chat configura a mesma chave no painel (grupo Conexao) e tudo funciona;
// com chave errada, a API recusa e o chat mostra erro.
// Autocontido: sobe o proprio proxy (com UI_TOKEN) numa porta livre, copia os
// arquivos do repo pra um tmp e derruba tudo no final. So precisa de node +
// um Ollama respondendo em 127.0.0.1:11434 (o proxy faz o pipe).
import { JSDOM, VirtualConsole } from 'jsdom';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { spawn } from 'child_process';
import net from 'net';

function repoFile(name) {
  return [
    new URL('../src/' + name, import.meta.url).pathname,
    '/home/user/egg-ollama/src/' + name,
  ].find((f) => fs.existsSync(f));
}
function repoAsset(name) {
  return [
    new URL('../assets/' + name, import.meta.url).pathname,
    '/home/user/latam-ia/assets/' + name,
  ].find((f) => fs.existsSync(f));
}
function freePort() {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.listen(0, '127.0.0.1', () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'latam-key-'));
for (const [src, dst] of [
  [repoFile('proxy.js'), 'proxy.js'],
  [repoFile('chat.html'), 'chat.html'],
  [repoAsset('logo-192.png'), 'logo-192.png'],
  [repoAsset('logo-512.png'), 'logo-512.png'],
]) fs.copyFileSync(src, path.join(tmp, dst));

const PORT = await freePort();
const BASE = 'http://127.0.0.1:' + PORT;
const proxy = spawn('node', ['proxy.js'], {
  cwd: tmp,
  env: { SERVER_PORT: String(PORT), UI_TOKEN: 'segredo123', CPU_THREADS: '2', PATH: process.env.PATH },
  stdio: 'ignore',
});
// espera o proxy aceitar conexao
{
  let up = false;
  for (let i = 0; i < 50 && !up; i++) {
    await new Promise((r) => setTimeout(r, 200));
    up = await fetch(BASE + '/manifest.webmanifest').then(() => true, () => false);
  }
  if (!up) { console.log('FAIL proxy nao subiu'); process.exit(1); }
}
let pass = 0, fail = 0;
function ok(cond, name, extra) {
  if (cond) { pass++; console.log('  PASS ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  -> ' + JSON.stringify(extra) : '')); }
}

let html = fs.readFileSync(path.join(tmp, 'chat.html'), 'utf8');
html = html.replace('<div id="cfg" style="display:none"></div>',
  '<div id="cfg" style="display:none" data-threads="2" data-auth="0"></div>');

function bootPage(apiKey) {
  const log = [];
  const vc = new VirtualConsole();
  vc.on('jsdomError', (e) => log.push(e.message));
  const dom = new JSDOM(html, {
    runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc, url: BASE + '/',
    beforeParse(w) {
      w.fetch = (u, o) => fetch(String(u).startsWith('http') ? String(u) : BASE + String(u), o);
      w.navigator.clipboard = { writeText: async () => {} };
      if (apiKey) w.localStorage.setItem('latam.settings', JSON.stringify({ theme: 'dark', apiKey }));
    },
  });
  return { w: dom.window, d: dom.window.document, log };
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 30000, step = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (fn()) return true; await wait(step); }
  return false;
}

console.log('\n[1] sem chave: o login bloqueia a API');
{
  const b = bootPage(null);
  ok(await until(() => /fora do ar|indisponivel/i.test(b.d.getElementById('status').textContent) ||
     /login/i.test(b.d.getElementById('model').options[0].textContent), 15000),
     'sem chave nao ve os modelos', b.d.getElementById('status').textContent);
}

console.log('\n[2] com a chave certa no painel: tudo funciona');
{
  const b = bootPage('segredo123');
  ok(await until(() => b.d.getElementById('model').value &&
     !/carregando|nenhum|fora/i.test(b.d.getElementById('model').options[0].textContent), 15000),
     'modelos carregaram com Bearer', b.d.getElementById('model').options[0].textContent);
  // qwen3 para em prompts curtos; tinyllama pode entrar em loop de geracao
  // (medido: 5996 tokens sem stop). O teste de chave nao e sobre o modelo.
  const sel = b.d.getElementById('model');
  if ([...sel.options].some((o) => o.value === 'qwen3:0.6b')) {
    sel.value = 'qwen3:0.6b';
    sel.dispatchEvent(new b.w.Event('change', { bubbles: true }));
    await until(() => b.d.getElementById('caps').textContent.length > 0, 20000);
  }
  // manda uma mensagem de verdade
  // tinyllama entra em loop de geracao com prompts curtos demais ("ok?"):
  // 5996 tokens sem stop, medido no log do llama-server. Pergunta fechada
  // ele responde e para.
  b.d.getElementById('input').value = 'Qual e a capital da Franca? Responda com uma palavra.';
  b.d.getElementById('input').dispatchEvent(new b.w.Event('input', { bubbles: true }));
  b.d.getElementById('form').dispatchEvent(new b.w.Event('submit', { bubbles: true, cancelable: true }));
  ok(await until(() => !b.d.getElementById('send').classList.contains('stop'), 120000), 'resposta chegou');
  const txt = b.d.querySelector('.msg.assistant .content').textContent;
  ok(txt.trim().length > 0, 'resposta com texto', txt.slice(0, 60));
}

console.log('\n[3] chave errada: recusa');
{
  const b = bootPage('chave-errada');
  ok(await until(() => /fora do ar|indisponivel/i.test(b.d.getElementById('status').textContent), 15000),
     'chave errada vira erro visivel', b.d.getElementById('status').textContent);
}

console.log('\n[4] logo servido pelo proxy com o arquivo do Git');
{
  for (const p of ['/logo-192.png', '/logo-512.png']) {
    const r = await fetch(BASE + p);
    ok(r.status === 200 && (r.headers.get('content-type') || '').includes('png'), p + ' -> 200 png',
       r.status + ' ' + r.headers.get('content-type'));
  }
  const m = await (await fetch(BASE + '/manifest.webmanifest')).json();
  ok(m.icons.some((i) => i.src === '/logo-192.png') && m.icons.some((i) => i.src === '/logo-512.png'),
     'manifest lista os PNGs', m.icons.map((i) => i.src));
}

console.log('\n================================');
console.log(`  ${pass} passaram, ${fail} falharam`);
console.log('================================');
proxy.kill();
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
