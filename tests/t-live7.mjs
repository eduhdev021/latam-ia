// Ao vivo: os dois paineis numa porta so (interruptor por cookie).
// Precisa do start script com ENABLE_UI=true + ENABLE_OPENWEBUI=true.
const BASE = process.env.BASE || 'http://127.0.0.1:25565';
let pass = 0, fail = 0;
const ok = (c, n, x) => c ? (pass++, console.log('  PASS ' + n)) : (fail++, console.log('  FAIL ' + n + (x !== undefined ? '  -> ' + String(x).slice(0, 100) : '')));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

console.log('\n[1] padrao: a porta serve o LATAM IA');
let r = await fetch(BASE + '/');
let html = await r.text();
ok(r.status === 200 && html.includes('LATAM IA'), 'sem cookie: LATAM IA', r.status);
ok(/data-owui="1"/.test(html), 'cfg anuncia data-owui=1 (botao aparece no painel)');
r = await fetch(BASE + '/api/version');
ok(r.ok && (await r.json()).version === '0.34.0', 'API do Ollama segue na mesma porta');

console.log('\n[2] interruptor -> Open WebUI');
r = await fetch(BASE + '/__panel/owui', { redirect: 'manual' });
const setCookie = r.headers.get('set-cookie') || '';
ok(r.status === 302 && r.headers.get('location') === '/', 'troca redireciona pra /', r.status);
ok(setCookie.includes('latam_panel=owui'), 'cookie latam_panel=owui setado', setCookie);

const JAR = 'latam_panel=owui';
// da tempo do OWUI responder
let up = false;
for (let i = 0; i < 30 && !up; i++) {
  up = await fetch(BASE + '/health', { headers: { cookie: JAR } }).then((x) => x.ok, () => false);
  if (!up) await wait(2000);
}
ok(up, 'com cookie: /health responde (rota vai pro Open WebUI)');
r = await fetch(BASE + '/', { headers: { cookie: JAR } });
html = await r.text();
ok(html.includes('<title>Open WebUI</title>'), 'com cookie: / serve o Open WebUI', html.slice(0, 80));
ok(html.includes('/__panel/latam'), 'botao "voltar pro LATAM IA" injetado na pagina');
r = await fetch(BASE + '/socket.io/?EIO=4&transport=polling', { headers: { cookie: JAR } });
ok(r.status === 200, 'socket.io do OWUI passa pelo proxy', r.status);

console.log('\n[3] interruptor -> volta pro LATAM IA');
r = await fetch(BASE + '/__panel/latam', { redirect: 'manual' });
ok(r.status === 302 && (r.headers.get('set-cookie') || '').includes('Max-Age=0'), 'volta limpa o cookie', r.headers.get('set-cookie'));
r = await fetch(BASE + '/');
html = await r.text();
ok(html.includes('LATAM IA') && !html.includes('<title>Open WebUI</title>'), 'sem cookie de novo: LATAM IA');

console.log('\n================================');
console.log(`  ${pass} passaram, ${fail} falharam`);
console.log('================================');
process.exit(fail ? 1 : 0);
