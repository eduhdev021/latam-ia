// Teste de ponta a ponta das features NOVAS contra o servidor REAL
// (Ollama v0.34.0 + proxy em 127.0.0.1:25565, com qwen3:0.6b e tinyllama:latest).
// Referencia: features do Open WebUI reimplementadas sem backend.
import { JSDOM, VirtualConsole } from 'jsdom';
import fs from 'fs';

const BASE = 'http://127.0.0.1:25565';
let html = fs.readFileSync('/mnt/server/ui/chat.html', 'utf8');
html = html.replace('<div id="cfg" style="display:none"></div>',
  '<div id="cfg" style="display:none" data-threads="2" data-auth="0"></div>');

let pass = 0, fail = 0;
function ok(cond, name, extra) {
  if (cond) { pass++; console.log('  PASS ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  -> ' + JSON.stringify(extra) : '')); }
}

const log = [];
const vc = new VirtualConsole();
vc.on('jsdomError', (e) => log.push('jsdomError: ' + (e.message || e)));
vc.on('error', (...a) => log.push('error: ' + a.join(' ')));

const dom = new JSDOM(html, {
  runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc, url: BASE + '/',
  beforeParse(w) {
    w.fetch = (u, o) => fetch(String(u).startsWith('http') ? String(u) : BASE + String(u), o);
    w.navigator.clipboard = { writeText: async () => {} };
  },
});
const w = dom.window, d = w.document;
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 120000, step = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (fn()) return true; await wait(step); }
  return false;
}
function send(text) {
  d.getElementById('input').value = text;
  d.getElementById('input').dispatchEvent(new w.Event('input', { bubbles: true }));
  d.getElementById('form').dispatchEvent(new w.Event('submit', { bubbles: true, cancelable: true }));
}

console.log('\n[1] modelos carregados de verdade');
ok(await until(() => d.getElementById('model').value && !/carregando/.test(d.getElementById('model').options[0].textContent)),
   'modelos vieram do /api/tags', d.getElementById('model').options.length);
const nomes = [...d.getElementById('model').options].map((o) => o.value).filter(Boolean);
console.log('   modelos: ' + nomes.join(', '));
ok(nomes.length >= 2, 'ha 2+ modelos para o multi', nomes);

// O /api/tags devolve tinyllama primeiro, e ele ignora o system prompt.
// Os testes de memoria e de ferramenta precisam do qwen3, que obedece.
const sel = d.getElementById('model');
if ([...sel.options].some((o) => o.value === 'qwen3:0.6b')) {
  sel.value = 'qwen3:0.6b';
  sel.dispatchEvent(new w.Event('change', { bubbles: true }));
  await until(() => d.getElementById('caps').textContent.length > 0, 20000);
  await until(() => /ferramentas/.test(d.getElementById('caps').textContent), 20000);
  console.log('   modelo escolhido: ' + sel.value + ' | caps: ' + d.getElementById('caps').textContent);
  ok(d.getElementById('tools').checked, 'trocar de modelo religou o tool calling');
}

console.log('\n[2] memoria persistente no system prompt');
d.getElementById('mem-new').value = 'O usuario se chama Eduardo e mora em Boa Vista.';
d.getElementById('mem-add').dispatchEvent(new w.Event('click', { bubbles: true }));
ok(d.querySelectorAll('#mem-list .mem-item').length === 1, 'fato listado');
send('Qual e o meu nome e onde eu moro? Responda em uma frase.');
ok(await until(() => !d.getElementById('send').classList.contains('stop'), 120000), 'resposta chegou');
await wait(400);
const resp = d.querySelector('.msg.assistant .content').textContent;
console.log('   resposta: ' + resp.slice(0, 160));
ok(/Eduardo|Boa Vista/.test(resp), 'o modelo usou a memoria', resp.slice(0, 120));

console.log('\n[3] web_search de ponta a ponta (Wikipedia real)');
// pergunta que o modelo nao tem como saber de memoria
send('Use a ferramenta de busca na web e me diga qual e a populacao de Boa Vista, Roraima, segundo a Wikipedia. Cite o numero.');
ok(await until(() => d.querySelectorAll('.toolcall').length >= 1, 120000), 'cartao de ferramenta apareceu',
   d.querySelectorAll('.toolcall').length);
const toolName = d.querySelector('.toolcall') ? d.querySelector('.toolcall').textContent : '';
console.log('   tool: ' + toolName.slice(0, 90).replace(/\s+/g, ' '));
ok(/search/.test(toolName), 'a ferramenta usada foi search', toolName.slice(0, 80));
ok(await until(() => {
  const t = d.querySelector('.toolcall');
  return t && /executada|concluida|ok/i.test(t.className + ' ' + t.textContent);
}, 90000), 'ferramenta executou');
// O ciclo de ferramenta tem duas geracoes: pede a tool, executa, responde.
ok(await until(() => !d.getElementById('send').classList.contains('stop'), 120000), 'geracao terminou');
await wait(400);
ok(await until(() => !d.getElementById('send').classList.contains('stop'), 120000), 'resposta apos a tool terminou');
await until(() => {
  const last = [...d.querySelectorAll('.msg.assistant')].pop();
  return last && last.querySelector('.content') && last.querySelector('.content').textContent.trim().length > 3;
}, 120000);
const resp2 = [...d.querySelectorAll('.msg.assistant .content')].pop().textContent;
console.log('   resposta final: ' + resp2.slice(0, 200).replace(/\s+/g, ' '));
ok(/\d/.test(resp2), 'a resposta tem um numero', resp2.slice(0, 120));

console.log('\n[4] multi-modelo com modelos reais');
const chk = d.getElementById('multi-on');
ok(chk.parentNode.style.display === '', 'checkbox multi visivel');
chk.checked = true;
chk.dispatchEvent(new w.Event('change', { bubbles: true }));
ok(d.getElementById('multi').style.display === '', 'seletor abriu');
const labels = [...d.querySelectorAll('#multi label')];
ok(labels.length === nomes.length, 'todos os modelos listados', labels.length);
// garante que os dois estao marcados
labels.forEach((l) => { const cb = l.querySelector('input'); if (!cb.checked) { cb.checked = true; cb.dispatchEvent(new w.Event('change', { bubbles: true })); } });
const antes = d.querySelectorAll('.msg.assistant').length;
send('Responda so com uma palavra: qual e a capital da Franca?');
ok(await until(() => d.querySelectorAll('.msg.assistant').length >= antes + 2, 180000),
   'duas respostas apareceram', d.querySelectorAll('.msg.assistant').length - antes);
// espera as duas terminarem (2 footers) antes de inspecionar
// Cada bolha termina sozinha; esperar as duas terem footer antes de inspecionar.
ok(await until(() => [...d.querySelectorAll('.msg.assistant')].slice(-2)
     .every((m) => m.querySelector('.foot')), 180000),
   'as duas terminaram', [...d.querySelectorAll('.msg.assistant')].slice(-2)
     .map((m) => !!m.querySelector('.foot')));
const whos = [...d.querySelectorAll('.msg.assistant .who')].slice(-2).map((x) => x.textContent.trim());
console.log('   bolhas: ' + JSON.stringify(whos));
// A bolha do modelo principal nao leva rotulo (o modelo ja esta no seletor);
// a secundaria leva o nome para dar para distinguir.
ok(whos.some((x) => /tinyllama/.test(x)) && whos.some((x) => x === 'LATAM IA'),
   'uma bolha por modelo (secundaria rotulada)', whos);
const lastTwo = [...d.querySelectorAll('.msg.assistant')].slice(-2);
console.log('   ' + whos[0] + ': ' + lastTwo[0].querySelector('.content').textContent.slice(0, 60).replace(/\s+/g, ' '));
console.log('   ' + whos[1] + ': ' + lastTwo[1].querySelector('.content').textContent.slice(0, 60).replace(/\s+/g, ' '));
// O footer fica DENTRO da bolha; pegar .foot do documento pega os antigos.
const foots = lastTwo.map((m) => (m.querySelector('.foot') || { textContent: '(sem foot)' }).textContent);
ok(foots.some((f) => /comparacao/.test(f)), 'uma marcada como comparacao', foots);

console.log('\n[5] historico so tem a resposta do modelo principal');
const chats = JSON.parse(w.localStorage.getItem('latam.chats'));
const msgs = chats[0].messages;
const assts = msgs.filter((m) => m.role === 'assistant');
console.log('   msgs no historico: ' + msgs.length + ' (assistant: ' + assts.length + ')');
console.log('   modelos gravados: ' + JSON.stringify(assts.map((m) => m.model)));
ok(assts.every((m) => m.model === d.getElementById('model').value),
   'nenhuma resposta secundaria entrou no historico', assts.map((m) => m.model));

console.log('\n[6] PWA servido pelo proxy real');
for (const [p, ct] of [['/sw.js', 'javascript'], ['/manifest.webmanifest', 'manifest'], ['/icon.svg', 'svg']]) {
  const r = await fetch(BASE + p);
  ok(r.status === 200 && (r.headers.get('content-type') || '').includes(ct), p + ' -> ' + r.status,
     r.headers.get('content-type'));
}
const mani = await (await fetch(BASE + '/manifest.webmanifest')).json();
ok(mani.name === 'LATAM IA' && mani.start_url === '/', 'manifest valido', mani.name);
ok(mani.icons.length === 2, 'icones declarados', mani.icons.length);

if (log.length) console.log('\n   logs jsdom: ' + JSON.stringify(log.slice(0, 4)));

console.log('\n================================');
console.log(`  ${pass} passaram, ${fail} falharam`);
console.log('================================');
process.exit(fail ? 1 : 0);
