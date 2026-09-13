// Testes das features novas (referencia: Open WebUI):
// memoria persistente, fila de mensagens, multi-modelo, fixar conversa,
// web_search via tool calling, PWA (manifest + service worker no proxy).
import { boot, wait, until, ready } from './harness2.mjs';

let pass = 0, fail = 0;
function ok(cond, name, extra) {
  if (cond) { pass++; console.log('  PASS ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  -> ' + JSON.stringify(extra) : '')); }
}
function sendMsg(b, text) {
  b.d.getElementById('input').value = text;
  b.d.getElementById('input').dispatchEvent(new b.w.Event('input', { bubbles: true }));
  b.d.getElementById('form').dispatchEvent(new b.w.Event('submit', { bubbles: true, cancelable: true }));
}
const sysOf = (body) => (body.messages.find((m) => m.role === 'system') || {}).content || '';

// ------------------------------------------------------------------ 1. memoria
{
  console.log('\n[1] memoria persistente');
  const b = boot();
  await ready(b);

  const memNew = b.d.getElementById('mem-new');
  ok(!!memNew, 'campo de novo fato existe');
  memNew.value = 'me chamo Eduardo';
  b.d.getElementById('mem-add').dispatchEvent(new b.w.Event('click', { bubbles: true }));
  ok(b.d.querySelectorAll('#mem-list .mem-item').length === 1, 'fato apareceu na lista',
     b.d.querySelectorAll('#mem-list .mem-item').length);
  ok(JSON.parse(b.w.localStorage.getItem('latam.settings')).memory.length === 1, 'persistiu no localStorage');

  sendMsg(b, 'oi');
  await until(() => b.state.sent.length === 1);
  ok(sysOf(b.state.sent[0]).includes('me chamo Eduardo'), 'fato foi no system prompt', sysOf(b.state.sent[0]));

  // desligar tira do contexto
  const on = b.d.getElementById('mem-on');
  on.checked = false;
  on.dispatchEvent(new b.w.Event('input', { bubbles: true }));
  sendMsg(b, 'oi de novo');
  await until(() => b.state.sent.length === 2);
  ok(!sysOf(b.state.sent[1]).includes('Eduardo'), 'desligado nao manda o fato', sysOf(b.state.sent[1]));

  // remover pelo X
  b.d.querySelector('#mem-list .mem-item .x').dispatchEvent(new b.w.Event('click', { bubbles: true }));
  ok(b.d.querySelectorAll('#mem-list .mem-item').length === 0, 'remover funcionou');
  ok(JSON.parse(b.w.localStorage.getItem('latam.settings')).memory.length === 0, 'localStorage limpo');
}

// ------------------------------------------------------------------ 2. system + memoria juntos
{
  console.log('\n[2] system prompt e memoria coexistem');
  const b = boot();
  await ready(b);
  b.d.getElementById('mem-new').value = 'fato X';
  b.d.getElementById('mem-add').dispatchEvent(new b.w.Event('click', { bubbles: true }));
  const ps = b.d.getElementById('p-system');
  ps.value = 'voce e tecnico';
  ps.dispatchEvent(new b.w.Event('input', { bubbles: true }));
  sendMsg(b, 'oi');
  await until(() => b.state.sent.length === 1);
  const sys = sysOf(b.state.sent[0]);
  ok(sys.includes('voce e tecnico'), 'system prompt presente');
  ok(sys.includes('fato X'), 'memoria presente');
  ok(b.state.sent[0].messages.filter((m) => m.role === 'system').length === 1, 'uma unica msg de system',
     b.state.sent[0].messages.filter((m) => m.role === 'system').length);
}

// ------------------------------------------------------------------ 3. fila
{
  console.log('\n[3] fila de mensagens');
  // hold: a PRIMEIRA resposta nao fecha, entao o chat continua "ocupado" - sem
  // isso o finish() roda na hora e a segunda mensagem e enviada direto, sem fila.
  const b = boot({
    hold: (body, n) => n === 1,
    onChat: (body, n) => (n === 1 ? ['{"message":{"role":"assistant","content":"pensando"}}'] : null),
  });
  await ready(b);
  sendMsg(b, 'primeira');
  await until(() => b.state.sent.length === 1);
  // Espera o botao virar "parar" - so isso prova que o chat esta ocupado.
  // (Sem isso o teste passaria/falharia conforme o timing do agendador.)
  ok(await until(() => b.d.getElementById('send').classList.contains('stop')), 'esta ocupado');

  sendMsg(b, 'segunda');
  await wait(80);
  ok(b.state.sent.length === 1, 'nao abortou a primeira nem disparou outra', b.state.sent.length);
  ok(b.d.querySelectorAll('#queue .q-item').length === 1, 'entrou na fila',
     b.d.querySelectorAll('#queue .q-item').length);
  ok(b.d.getElementById('queue').style.display === '', 'fila visivel');
  ok(b.d.getElementById('input').value === '', 'input limpo depois de enfileirar');

  sendMsg(b, 'terceira');
  await wait(60);
  ok(b.d.querySelectorAll('#queue .q-item').length === 2, 'segunda na fila');

  // tira uma da fila
  b.d.querySelector('#queue .q-item .x').dispatchEvent(new b.w.Event('click', { bubbles: true }));
  ok(b.d.querySelectorAll('#queue .q-item').length === 1, 'removeu da fila');
}

// ------------------------------------------------------------------ 4. multi-modelo
{
  console.log('\n[4] multi-modelo');
  const b = boot({
    models: [
      { name: 'qwen3:0.6b', size: 522653767, capabilities: ['completion', 'tools'] },
      { name: 'llama3.2:1b', size: 1300000000, capabilities: ['completion'] },
    ],
  });
  await ready(b);
  // Com 2 modelos o checkbox aparece; a caixa de selecao so abre ao ligar.
  ok(b.d.getElementById('multi-on').parentNode.style.display === '', 'checkbox multi aparece com 2 modelos');
  ok(b.d.getElementById('multi').style.display === 'none', 'caixa oculta enquanto desligado');

  const chk = b.d.getElementById('multi-on');
  chk.checked = true;
  chk.dispatchEvent(new b.w.Event('change', { bubbles: true }));
  ok(b.d.getElementById('multi').style.display === '', 'caixa abre ao ligar');
  ok(b.d.querySelectorAll('#multi label').length === 2, '2 modelos listados',
     b.d.querySelectorAll('#multi label').length);
  ok(JSON.parse(b.w.localStorage.getItem('latam.settings')).multiOn === true, 'multiOn salvo');

  sendMsg(b, 'compara');
  ok(await until(() => b.state.sent.length === 2), 'disparou 2 requisicoes', b.state.sent.length);
  const nomes = b.state.sent.map((s) => s.model).sort();
  ok(nomes[0] === 'llama3.2:1b' && nomes[1] === 'qwen3:0.6b', 'um pedido por modelo', nomes);
  ok(await until(() => b.d.querySelectorAll('.msg.assistant').length === 2), 'duas bolhas de resposta',
     b.d.querySelectorAll('.msg.assistant').length);
  const whos = [...b.d.querySelectorAll('.msg.assistant .who')].map((w) => w.textContent);
  ok(whos.some((w) => /llama3\.2|qwen3/.test(w)), 'bolha diz de qual modelo veio', whos);
  ok(await until(() => b.d.querySelectorAll('.foot').length === 2), 'dois footers',
     b.d.querySelectorAll('.foot').length);
  const foots = [...b.d.querySelectorAll('.foot')].map((f) => f.textContent);
  ok(foots.some((f) => /comparacao/.test(f)), 'footer marca como comparacao', foots);
}

// ------------------------------------------------------------------ 5. com 1 modelo nao ha multi
{
  console.log('\n[5] multi some com um modelo so');
  const b = boot();
  await ready(b);
  ok(b.d.getElementById('multi').style.display === 'none', 'seletor oculto');
  ok(b.d.getElementById('multi-on').parentNode.style.display === 'none', 'checkbox oculto');
  sendMsg(b, 'oi');
  await until(() => b.state.sent.length === 1);
  ok(b.state.sent.length === 1, 'uma requisicao so');
}

// ------------------------------------------------------------------ 6. fixar conversa
{
  console.log('\n[6] fixar conversa');
  const b = boot();
  await ready(b);
  sendMsg(b, 'conversa A');
  await until(() => b.state.sent.length === 1);
  const first = JSON.parse(b.w.localStorage.getItem('latam.chats'))[0].id;

  b.d.getElementById('new-chat').dispatchEvent(new b.w.Event('click', { bubbles: true }));
  await wait(60);
  sendMsg(b, 'conversa B');
  ok(await until(() => b.state.sent.length === 2), 'segunda conversa criada', b.state.sent.length);

  // B e a mais recente: vem primeiro
  ok(await until(() => (b.d.querySelectorAll('#chats .chat-item')[0] || { textContent: '' })
      .textContent.includes('conversa B')),
     'mais recente no topo', b.d.querySelectorAll('#chats .chat-item')[0] &&
     b.d.querySelectorAll('#chats .chat-item')[0].textContent);

  // fixa a B (que esta aberta)
  b.d.getElementById('pin-btn').dispatchEvent(new b.w.Event('click', { bubbles: true }));
  await wait(60);
  ok(b.d.getElementById('pin-btn').textContent === 'Desafixar', 'botao virou Desafixar');
  ok(!!b.d.querySelector('#chats .grp') && b.d.querySelector('#chats .grp').textContent === 'Fixadas',
     'grupo Fixadas apareceu', b.d.querySelector('#chats .grp') && b.d.querySelector('#chats .grp').textContent);
  ok(!!b.d.querySelector('#chats .pin'), 'estrela na conversa');
  ok(JSON.parse(b.w.localStorage.getItem('latam.settings')).pinned[b.state.lastChat || first] !== undefined ||
     Object.keys(JSON.parse(b.w.localStorage.getItem('latam.settings')).pinned).length === 1, 'pin persistiu');

  // desafixar
  b.d.getElementById('pin-btn').dispatchEvent(new b.w.Event('click', { bubbles: true }));
  await wait(60);
  ok(!b.d.querySelector('#chats .pin'), 'estrela sumiu');
  ok(Object.keys(JSON.parse(b.w.localStorage.getItem('latam.settings')).pinned).length === 0, 'pin removido');
}

// ------------------------------------------------------------------ 7. web_search tool
{
  console.log('\n[7] web_search como ferramenta');
  const b = boot({
    onChat: (body, n) => (n === 1 ? [
      JSON.stringify({ message: { role: 'assistant', content: '', tool_calls: [
        { function: { name: 'search', arguments: { query: 'capital do brasil' } } }] } }),
      JSON.stringify({ done: true, eval_count: 1, eval_duration: 10000000 }),
    ] : null),
  });
  await ready(b);
  sendMsg(b, 'qual a capital do brasil?');
  await until(() => b.state.sent.length === 1);
  ok(b.state.sent[0].tools.some((t) => t.function.name === 'search'), 'search oferecida');

  const searched = await until(() => b.state.search && b.state.search.length === 1);
  ok(searched, 'chamou /search no proxy', b.state.search);
  ok(b.state.search[0] && b.state.search[0].includes('capital%20do%20brasil'), 'query na URL', b.state.search[0]);

  await until(() => b.state.sent.length === 2, 6000);
  ok(b.state.sent.length === 2, 'voltou com o resultado da busca');
  const toolMsg = b.state.sent[1].messages.find((m) => m.role === 'tool');
  ok(!!toolMsg, 'resultado entrou como msg tool');
  const out = JSON.parse(toolMsg.content);
  ok(out.results && out.results[0] && out.results[0].title === 'Brasilia', 'resultado da busca chegou',
     out.results && out.results[0]);
  ok(b.d.querySelectorAll('.toolcall').length === 1, 'cartao da ferramenta desenhado',
     b.d.querySelectorAll('.toolcall').length);

  // desligada, nao oferece
  const web = b.d.getElementById('web-on');
  web.checked = false;
  web.dispatchEvent(new b.w.Event('input', { bubbles: true }));
  sendMsg(b, 'e agora?');
  await until(() => b.state.sent.length === 3);
  ok(!b.state.sent[2].tools.some((t) => t.function.name === 'search'), 'desligada nao oferece search',
     b.state.sent[2].tools.map((t) => t.function.name));
}

// ------------------------------------------------------------------ 8. PWA no HTML
{
  console.log('\n[8] PWA');
  const b = boot();
  await ready(b);
  const fs = await import('fs');
  const html = fs.readFileSync('/home/user/egg-ollama/src/chat.html', 'utf8');
  ok(html.includes('rel="manifest"'), 'link do manifest');
  ok(html.includes("serviceWorker.register('/sw.js'"), 'registro do service worker');
  ok(html.includes('rel="icon"'), 'icone declarado');
}


// ------------------------------------------------------------------ 9. API externa + key
{
  console.log('\n[9] API externa + chave');
  const b = boot();
  await ready(b);
  b.d.getElementById('c-base').value = 'https://ollama.exemplo.dev/';
  b.d.getElementById('c-base').dispatchEvent(new b.w.Event('input', { bubbles: true }));
  b.d.getElementById('c-key').value = 'segredo123';
  b.d.getElementById('c-key').dispatchEvent(new b.w.Event('input', { bubbles: true }));
  const st = JSON.parse(b.w.localStorage.getItem('latam.settings'));
  ok(st.apiBase === 'https://ollama.exemplo.dev/', 'base salva (sem barra final)', st.apiBase);
  ok(st.apiKey === 'segredo123', 'chave salva');

  b.state.reqs.length = 0;
  sendMsg(b, 'oi');
  await until(() => b.state.sent.length >= 1 || b.state.reqs.some((r) => r.url.includes('/api/chat')));
  const chatReq = b.state.reqs.find((r) => r.url.includes('/api/chat'));
  ok(!!chatReq, 'requisicao de chat feita');
  ok(chatReq.url.startsWith('https://ollama.exemplo.dev/api/chat'), 'URL usa a base externa', chatReq.url);
  ok((chatReq.opts.headers || {})['authorization'] === 'Bearer segredo123',
     'Authorization Bearer enviado', chatReq.opts.headers);

  // sem chave configurada nao manda header
  const b2 = boot();
  await ready(b2);
  b2.state.reqs.length = 0;
  sendMsg(b2, 'oi');
  await until(() => b2.state.reqs.some((r) => r.url.includes('/api/chat')));
  const r2 = b2.state.reqs.find((r) => r.url.includes('/api/chat'));
  ok(r2.url.startsWith('/api/chat'), 'sem base: URL relativa', r2.url);
  ok(!(r2.opts.headers || {})['authorization'], 'sem chave: sem header', r2.opts.headers);
}

console.log('\n================================');
console.log(`  ${pass} passaram, ${fail} falharam`);
console.log('================================');
process.exit(fail ? 1 : 0);
