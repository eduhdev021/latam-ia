// Teste de ponta a ponta contra o servidor REAL (Ollama + proxy rodando).
// Usa jsdom so para executar o JS do chat; o fetch vai pra 127.0.0.1:25565.
import { JSDOM, VirtualConsole } from 'jsdom';
import fs from 'fs';

const BASE = 'http://127.0.0.1:25565';
let html = fs.readFileSync('/mnt/server/ui/chat.html', 'utf8');
html = html.replace('<div id="cfg" style="display:none"></div>',
  '<div id="cfg" style="display:none" data-threads="2" data-auth="0"></div>');

const log = [];
const vc = new VirtualConsole();
vc.on('jsdomError', e => log.push('jsdomError: ' + (e.message || e)));
vc.on('error', (...a) => log.push('error: ' + a.join(' ')));

const dom = new JSDOM(html, {
  runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc,
  url: BASE + '/', resources: undefined,
  beforeParse(w) {
    // jsdom nao tem fetch; ponte para o Node
    w.fetch = (u, o) => {
      const url = String(u).startsWith('http') ? String(u) : BASE + String(u);
      return fetch(url, o);
    };
    w.navigator.clipboard = { writeText: async () => {} };
  }
});
const w = dom.window, d = w.document;
const wait = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, ms = 60000, step = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (fn()) return true; await wait(step); }
  return false;
}
let pass = 0, fail = 0;
function ok(c, name, extra) {
  if (c) { pass++; console.log('  PASS ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? ' -> ' + JSON.stringify(extra) : '')); }
}

console.log('[live] carregando modelos do servidor real...');
const loaded = await until(() => d.getElementById('model').value && !/carregando/.test(d.options === undefined ? d.getElementById('model').options[0].textContent : d.getElementById('model').options[0].textContent), 20000);
ok(loaded, 'modelo carregado', d.getElementById('model').value);
// O servidor agora tem 2 modelos (tinyllama + qwen3) e o /api/tags devolve o
// tinyllama primeiro. Este teste e sobre o qwen3, entao escolho ele.
const selEl = d.getElementById('model');
if ([...selEl.options].some((o) => o.value === 'qwen3:0.6b')) {
  selEl.value = 'qwen3:0.6b';
  selEl.dispatchEvent(new w.Event('change', { bubbles: true }));
  await until(() => /ferramentas/.test(d.getElementById('caps').textContent), 20000);
}
ok(d.getElementById('model').value === 'qwen3:0.6b', 'modelo e qwen3:0.6b', d.getElementById('model').value);

await until(() => d.getElementById('caps').textContent.length > 0, 15000);
console.log('  caps detectadas:', JSON.stringify(d.getElementById('caps').textContent));
ok(/ferramentas/.test(d.getElementById('caps').textContent), 'detectou capability de tools');
ok(d.getElementById('ctx-max').textContent !== '?', 'leu o context length do modelo', d.getElementById('ctx-max').textContent);

// o painel deve ter herdado temperature 0.6 do Modelfile do qwen3
await until(() => d.getElementById('p-temp').value !== '0.8', 15000);
ok(d.getElementById('p-temp').value === '0.6', 'painel herdou temperature do Modelfile', d.getElementById('p-temp').value);

console.log('\n[live] mandando mensagem real...');
d.getElementById('input').value = 'Explique em 2 bullets o que e um array em JavaScript.';
d.getElementById('input').dispatchEvent(new w.Event('input', { bubbles: true }));
const t0 = Date.now();
d.getElementById('form').dispatchEvent(new w.Event('submit', { bubbles: true, cancelable: true }));
const streamed = await until(() => {
  const el = d.querySelector('.msg.assistant .content');
  return el && el.textContent.length > 20;
}, 60000);
const tStream = Date.now() - t0;
ok(streamed, 'texto apareceu durante o stream', tStream + 'ms');
console.log(`  primeiro texto em ${(tStream / 1000).toFixed(1)}s`);

const done = await until(() => d.querySelector('.msg.assistant .foot') !== null, 60000);
ok(done, 'geracao terminou (footer criado)');
const content = d.querySelector('.msg.assistant .content');
const foot = d.querySelector('.msg.assistant .foot');
console.log('  resposta:', JSON.stringify(content.textContent.slice(0, 160)));
console.log('  footer  :', JSON.stringify(foot.textContent.slice(0, 90)));
ok(/tok\/s/.test(foot.textContent), 'footer tem tok/s real');
ok(content.querySelectorAll('li').length >= 1 || content.textContent.length > 40, 'resposta tem conteudo');
// markdown: o modelo pode responder em prosa (sem <ul>) - o que importa e que
// o renderizador produziu HTML de bloco e nao deixou texto cru com ** nem \n
ok(content.querySelector('ul, p, ol, pre, h1, h2, h3, blockquote, table') !== null,
   'markdown renderizado como HTML', content.innerHTML.slice(0, 120));
ok(!/\*\*/.test(content.textContent), 'sem ** cru na tela');
ok(!/<[a-z]/.test(content.textContent), 'sem tag crua na tela');

// historico persistido no localStorage
const saved = JSON.parse(w.localStorage.getItem('latam.chats'));
ok(saved && saved.length === 1 && saved[0].messages.length === 2, 'conversa salva no localStorage', saved && saved[0].messages.length);

// tool calling real: pede a hora
console.log('\n[live] tool calling contra o modelo real...');
d.getElementById('new-chat').dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
d.getElementById('input').value = 'Use the get_current_time tool with timezone America/Boa_Vista. You must call the tool.';
d.getElementById('input').dispatchEvent(new w.Event('input', { bubbles: true }));
d.getElementById('form').dispatchEvent(new w.Event('submit', { bubbles: true, cancelable: true }));
const toolShown = await until(() => d.querySelectorAll('.toolcall').length > 0, 90000);
if (toolShown) {
  ok(true, 'modelo pediu a ferramenta e o chat desenhou o cartao');
  console.log('  toolcall:', JSON.stringify(d.querySelector('.toolcall').textContent.slice(0, 140)));
  const executed = await until(() => /executada/.test(d.querySelector('.toolcall').textContent), 30000);
  ok(executed, 'chat executou a ferramenta no navegador');
  const finalAns = await until(() => {
    const msgs = d.querySelectorAll('.msg.assistant .content');
    return msgs.length >= 2 && msgs[msgs.length - 1].textContent.trim().length > 3;
  }, 90000);
  ok(finalAns, 'modelo respondeu com o resultado da ferramenta');
  const last = d.querySelectorAll('.msg.assistant .content');
  console.log('  resposta final:', JSON.stringify(last[last.length - 1].textContent.slice(0, 160)));
} else {
  ok(false, 'modelo nao pediu a ferramenta (qwen3:0.6b e pequeno, pode variar)');
  const c = d.querySelector('.msg.assistant .content');
  console.log('  o que veio:', JSON.stringify(c ? c.textContent.slice(0, 200) : 'nada'));
}

console.log('\nerros jsdom:', log.length ? log : 'nenhum');
console.log('\n================================');
console.log(`  ${pass} passaram, ${fail} falharam`);
console.log('================================');
process.exit(fail ? 1 : 0);
