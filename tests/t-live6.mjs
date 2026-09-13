// Ao vivo: gerenciar modelos pela interface contra um Ollama real.
// Baixa all-minilm:latest (27 MB, rapido) pelo botao "Baixar" do painel,
// confirma que chegou no servidor, e apaga pelo X com confirmacao inline.
import { JSDOM, VirtualConsole } from 'jsdom';

const BASE = process.env.BASE || 'http://127.0.0.1:25565';
const TARGET = 'all-minilm:latest';

let pass = 0, fail = 0;
const ok = (c, n, x) => c ? (pass++, console.log('  PASS ' + n)) : (fail++, console.log('  FAIL ' + n + (x !== undefined ? '  -> ' + JSON.stringify(x) : '')));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 60000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (e) {} await wait(200); }
  return false;
}
const tags = async () => (await fetch(BASE + '/api/tags')).json().then((d) => (d.models || []).map((m) => m.name));

console.log('\n[1] estado inicial');
const before = await tags();
ok(Array.isArray(before), 'API responde /api/tags', before);
ok(!before.includes(TARGET), TARGET + ' nao esta instalado (pre-condicao)', before);

// garante limpo caso o teste anterior tenha caido no meio
await fetch(BASE + '/api/delete', { method: 'DELETE', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: TARGET }) });

console.log('\n[2] baixar pela interface');
const html = await (await fetch(BASE + '/')).text();
const vc = new VirtualConsole();
const dom = new JSDOM(html.replace('<div id="cfg" style="display:none"></div>', '<div id="cfg" style="display:none" data-threads="2" data-auth="0"></div>'), {
  runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc, url: BASE + '/',
  beforeParse(w) {
    w.fetch = (u, o) => fetch(String(u).startsWith('http') ? String(u) : BASE + String(u), o);
    w.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  },
});
const b = dom.window, d = dom.window.document;
ok(await until(() => d.getElementById('model') && d.getElementById('model').options.length > 0), 'chat carregou modelos');
ok(await until(() => d.querySelectorAll('#mdl-list .mdl-row').length > 0), 'lista de modelos do painel renderizou');

d.getElementById('mdl-new').value = TARGET;
d.getElementById('mdl-pull').dispatchEvent(new b.Event('click', { bubbles: true }));
ok(await until(() => d.getElementById('mdl-msg').textContent.includes('concluido'), 120000),
   'download terminou', d.getElementById('mdl-msg').textContent);
ok(d.getElementById('mdl-bar').style.width === '100%', 'barra em 100%');

const after = await tags();
ok(after.includes(TARGET), TARGET + ' esta no servidor', after);
ok(await until(() => [...d.querySelectorAll('#mdl-list .mdl-row')].some((r) => r.dataset.name === TARGET)),
   TARGET + ' apareceu na lista do painel');

console.log('\n[3] apagar pela interface (confirmacao inline)');
const row = [...d.querySelectorAll('#mdl-list .mdl-row')].find((r) => r.dataset.name === TARGET);
const del = row.querySelector('.mdl-del');
del.dispatchEvent(new b.Event('click', { bubbles: true }));
ok((await tags()).includes(TARGET), '1o clique so arma: modelo continua instalado');
const del2 = [...d.querySelectorAll('#mdl-list .mdl-row')].find((r) => r.dataset.name === TARGET).querySelector('.mdl-del');
del2.dispatchEvent(new b.Event('click', { bubbles: true }));
ok(await until(async () => !(await tags()).includes(TARGET), 30000), TARGET + ' sumiu do servidor');
ok(await until(() => ![...d.querySelectorAll('#mdl-list .mdl-row')].some((r) => r.dataset.name === TARGET)),
   TARGET + ' sumiu da lista do painel');

console.log('\n================================');
console.log(`  ${pass} passaram, ${fail} falharam`);
console.log('================================');
dom.window.close();
process.exit(fail ? 1 : 0);
