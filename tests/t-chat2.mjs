// Suite de testes do chat v2 (LATAM IA completo).
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

// ------------------------------------------------------------------ 1. stream + historico
{
  console.log('\n[1] streaming e historico');
  const b = boot();
  await ready(b);
  sendMsg(b, 'oi');
  const got = await until(() => b.state.sent.length === 1);
  ok(got, 'mandou 1 requisicao');
  const body = b.state.sent[0];
  ok(body.model === 'qwen3:0.6b', 'model certo', body.model);
  ok(body.options.num_thread === 2, 'num_thread=2 injetado', body.options);
  ok(body.truncate === true, 'truncate:true');
  ok(Array.isArray(body.messages) && body.messages.length === 1 && body.messages[0].role === 'user',
     'historico tem a msg do user', body.messages);
  await until(() => b.d.querySelectorAll('.msg.assistant').length === 1);
  const txt = await until(() => /Tudo bem/.test(b.d.querySelector('.msg.assistant .content').textContent));
  ok(txt, 'resposta apareceu', b.d.querySelector('.msg.assistant .content').textContent);
  ok(/tok\/s/.test(b.d.querySelector('.msg.assistant .foot').textContent), 'footer tem tok/s', b.d.querySelector('.msg.assistant .foot').textContent);
  const acts = [...b.d.querySelectorAll('.msg.assistant .foot .act')].map((a) => a.textContent);
  ok(acts.join(',') === 'copiar,regenerar,editar,apagar', 'footer tem copiar/regenerar/editar/apagar', acts);
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 2. segunda msg manda historico
{
  console.log('\n[2] contexto da conversa');
  const b = boot();
  await ready(b);
  sendMsg(b, 'primeira');
  await until(() => /Tudo bem/.test(b.d.querySelector('.msg.assistant .content').textContent));
  sendMsg(b, 'segunda');
  await until(() => b.state.sent.length === 2);
  const roles = b.state.sent[1].messages.map(m => m.role);
  ok(roles.join(',') === 'user,assistant,user', 'historico acumula', roles);
  ok(b.state.sent[1].messages[1].content.includes('Tudo bem'), 'resposta anterior vai no contexto');
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 3. system prompt
{
  console.log('\n[3] system prompt');
  const b = boot();
  await ready(b);
  b.d.getElementById('p-system').value = 'Voce e tecnico.';
  b.d.getElementById('p-system').dispatchEvent(new b.w.Event('input', { bubbles: true }));
  sendMsg(b, 'oi');
  await until(() => b.state.sent.length === 1);
  const m0 = b.state.sent[0].messages[0];
  ok(m0.role === 'system' && m0.content === 'Voce e tecnico.', 'system vai como primeira msg', m0);
  // persistiu no localStorage?
  const saved = JSON.parse(b.w.localStorage.getItem('latam.settings'));
  ok(saved.system === 'Voce e tecnico.', 'system persistido');
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 4. opcoes (skip) do modelo
{
  console.log('\n[4] parametros de geracao');
  const b = boot();
  await ready(b);
  // o /api/show do harness retorna temperature 0.6, top_k 20, top_p 0.95
  await until(() => b.d.getElementById('p-temp').value === '0.6');
  ok(b.d.getElementById('p-temp').value === '0.6', 'herdou temperature do Modelfile', b.d.getElementById('p-temp').value);
  ok(b.d.getElementById('p-top_k').value === '20', 'herdou top_k', b.d.getElementById('p-top_k').value);
  // muda e confere que vai na requisicao
  const el = b.d.getElementById('p-temp');
  el.value = '1.4';
  el.dispatchEvent(new b.w.Event('input', { bubbles: true }));
  sendMsg(b, 'oi');
  await until(() => b.state.sent.length === 1);
  ok(b.state.sent[0].options.temperature === 1.4, 'temperature vai na requisicao', b.state.sent[0].options);
  ok(b.state.sent[0].options.num_thread === 2, 'num_thread continua junto');
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 5. tool calling
{
  console.log('\n[5] tool calling (ciclo completo)');
  const b = boot({
    onChat(body, n) {
      if (n === 1) {
        return [JSON.stringify({ message: { role: 'assistant', content: '', tool_calls: [
          { function: { name: 'get_current_time', arguments: { timezone: 'America/Boa_Vista' } } }] } }),
          JSON.stringify({ done: true, eval_count: 1, eval_duration: 100000000 })];
      }
      return [JSON.stringify({ message: { role: 'assistant', content: 'Sao 01:20 em Boa Vista.' } }),
              JSON.stringify({ done: true, eval_count: 9, eval_duration: 300000000 })];
    }
  });
  await ready(b);
  sendMsg(b, 'que horas sao?');
  await until(() => b.state.sent.length === 1);
  // 3 agora: get_current_time, calculator e web_search (a busca entrou junto)
  ok(Array.isArray(b.state.sent[0].tools) && b.state.sent[0].tools.length === 3, 'tools enviadas', (b.state.sent[0].tools || []).length);
  ok(b.state.sent[0].tools.some(t => t.function.name === 'search'), 'search na lista');
  ok(b.state.sent[0].tools[0].function.name === 'get_current_time', 'nome da tool');
  await until(() => b.state.sent.length === 2, 8000);
  ok(b.state.sent.length === 2, 'segunda requisicao apos executar a tool');
  const second = b.state.sent[1].messages;
  const asst = second.find(m => m.role === 'assistant' && m.tool_calls);
  const tool = second.find(m => m.role === 'tool');
  ok(!!asst, 'assistant com tool_calls no contexto');
  ok(!!tool && tool.tool_name === 'get_current_time', 'resultado voltou como role:tool', tool && tool.tool_name);
  ok(tool && /result/.test(tool.content), 'conteudo do tool tem result', tool && tool.content.slice(0, 80));
  ok(b.d.querySelectorAll('.toolcall').length >= 1, 'tool call desenhada na tela', b.d.querySelectorAll('.toolcall').length);
  ok(/01:20/.test(b.d.querySelector('.toolcall').textContent) || /America\/Boa_Vista/.test(b.d.querySelector('.toolcall').textContent),
     'args da tool visiveis');
  const okTxt = await until(() => /01:20/.test(b.d.body.textContent));
  ok(okTxt, 'resposta final apareceu');
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 6. tools desligado
{
  console.log('\n[6] tools desligado');
  const b = boot();
  await ready(b);
  b.d.getElementById('tools').checked = false;
  b.d.getElementById('tools').dispatchEvent(new b.w.Event('change', { bubbles: true }));
  sendMsg(b, 'oi');
  await until(() => b.state.sent.length === 1);
  ok(!b.state.sent[0].tools, 'sem tools quando desmarcado', b.state.sent[0].tools);
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 7. modelo sem tools
{
  console.log('\n[7] modelo sem capability de tools');
  const b = boot({ models: [{ name: 'tiny', size: 1000, capabilities: ['completion'] }],
                   show: { capabilities: ['completion'], parameters: '', model_info: {} } });
  await ready(b);
  ok(b.d.getElementById('tools').disabled, 'checkbox de tools fica disabled');
  ok(b.d.getElementById('caps').textContent === '', 'pill de caps vazio', b.d.getElementById('caps').textContent);
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 8. historico persistente
{
  console.log('\n[8] conversas salvas');
  const b = boot();
  await ready(b);
  sendMsg(b, 'conversa um');
  await until(() => /Tudo bem/.test(b.d.querySelector('.msg.assistant .content').textContent));
  const saved = JSON.parse(b.w.localStorage.getItem('latam.chats'));
  ok(Array.isArray(saved) && saved.length === 1, '1 conversa no localStorage', saved && saved.length);
  ok(saved[0].title === 'conversa um', 'titulo veio da 1a msg', saved[0].title);
  ok(saved[0].messages.length === 2, 'user+assistant salvos', saved[0].messages.length);
  ok(b.d.querySelectorAll('.chat-item').length === 1, 'aparece na sidebar', b.d.querySelectorAll('.chat-item').length);
  // nova conversa + voltar
  b.d.getElementById('new-chat').dispatchEvent(new b.w.MouseEvent('click', { bubbles: true }));
  ok(b.d.querySelectorAll('.msg').length === 0, 'tela limpa apos nova conversa');
  ok(b.d.querySelectorAll('.chat-item').length === 1, 'a antiga continua na lista');
  b.d.querySelector('.chat-item').dispatchEvent(new b.w.MouseEvent('click', { bubbles: true }));
  await until(() => b.d.querySelectorAll('.msg').length === 2);
  ok(b.d.querySelectorAll('.msg').length === 2, 'reabriu com as 2 mensagens');
  ok(/conversa um/.test(b.d.querySelector('.msg.user .content').textContent), 'texto certo');
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 9. apagar conversa
{
  console.log('\n[9] apagar conversa');
  const b = boot();
  await ready(b);
  sendMsg(b, 'apaga eu');
  await until(() => b.d.querySelectorAll('.chat-item').length === 1);
  b.d.querySelector('.chat-item .x').dispatchEvent(new b.w.MouseEvent('click', { bubbles: true }));
  await until(() => b.d.getElementById('m-confirm').classList.contains('on'));
  ok(b.d.getElementById('m-confirm').classList.contains('on'), 'modal de confirmacao abriu');
  b.d.getElementById('cf-ok').dispatchEvent(new b.w.MouseEvent('click', { bubbles: true }));
  await until(() => JSON.parse(b.w.localStorage.getItem('latam.chats')).length === 0);
  ok(JSON.parse(b.w.localStorage.getItem('latam.chats')).length === 0, 'conversa apagada do storage');
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 10. markdown
{
  console.log('\n[10] markdown');
  const b = boot({ onChat: () => [
    JSON.stringify({ message: { role: 'assistant', content:
      '# Titulo\n\nTexto com **negrito** e *italico* e `codigo`.\n\n' +
      '- item 1\n- item 2\n  - sub\n- item 3\n\n1. um\n2. dois\n\n' +
      '| a | b |\n|---|---|\n| 1 | 2 |\n\n' +
      '> citacao\n\n```js\nconst x = 42;\nconsole.log(x);\n```\n\n' +
      '[link](https://exemplo.com)\n\n---\n\nfim\n' } }),
    JSON.stringify({ done: true, eval_count: 30, eval_duration: 1000000000 })
  ]});
  await ready(b);
  sendMsg(b, 'md');
  const c = await until(() => {
    const el = b.d.querySelector('.msg.assistant .content');
    return el && el.querySelector('table') && el.querySelector('pre');
  }, 6000);
  const el = b.d.querySelector('.msg.assistant .content');
  ok(c, 'renderizou');
  ok(el.querySelector('h1') && el.querySelector('h1').textContent === 'Titulo', 'h1');
  ok(el.querySelector('strong') && el.querySelector('strong').textContent === 'negrito', 'negrito');
  ok(el.querySelector('em') && el.querySelector('em').textContent === 'italico', 'italico');
  ok(el.querySelector('code') && el.querySelector('code').textContent === 'codigo', 'codigo inline');
  ok(el.querySelectorAll('ul li').length === 4, 'lista com subitem (3 + 1)', el.querySelectorAll('ul li').length);
  ok(el.querySelector('ul ul li') !== null, 'sublista aninhada de verdade');
  ok(el.querySelectorAll('ol li').length === 2, 'lista ordenada', el.querySelectorAll('ol li').length);
  ok(el.querySelector('table tbody td') && el.querySelector('table tbody td').textContent === '1', 'tabela');
  ok(el.querySelector('blockquote') && /citacao/.test(el.querySelector('blockquote').textContent), 'blockquote');
  ok(el.querySelector('pre code') && /const x = 42/.test(el.querySelector('pre code').textContent), 'bloco de codigo');
  ok(el.querySelector('pre .code-head .lang').textContent === 'js', 'label de linguagem');
  ok(el.querySelector('.tok-kw') !== null, 'syntax highlight aplicado');
  ok(el.querySelector('a[href="https://exemplo.com"]') !== null, 'link virou <a>');
  ok(el.querySelector('hr') !== null, 'hr');
  ok(el.querySelector('[data-copy-code]') !== null, 'botao copiar no codigo');
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 11. XSS
{
  console.log('\n[11] seguranca: nada de HTML injetado');
  const b = boot({ onChat: () => [
    JSON.stringify({ message: { role: 'assistant', content: '<img src=x onerror=alert(1)><script>window.PWNED=1<\/script>' } }),
    JSON.stringify({ done: true, eval_count: 3, eval_duration: 100000000 })
  ]});
  await ready(b);
  sendMsg(b, 'xss');
  await until(() => /onerror/.test(b.d.querySelector('.msg.assistant .content').textContent));
  ok(b.w.PWNED === undefined, 'script nao executou');
  ok(b.d.querySelector('.msg.assistant .content img') === null, 'img nao foi criado');
  ok(/<img src=x onerror/.test(b.d.querySelector('.msg.assistant .content').textContent), 'virou texto puro');
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

// ------------------------------------------------------------------ 12. parar
{
  console.log('\n[12] interromper');
  const b = boot({ onChat: () => {
    // stream que nunca fecha: o pull enfileira 1 chunk e fica pendurado
    return null;
  }});
  await ready(b);
  b.state.sent.length = 0;
  // override: stream aberto
  b.w.fetch = async (u, o) => {
    if (String(u).startsWith('/api/chat')) {
      b.state.sent.push(JSON.parse(o.body));
      const enc = new TextEncoder();
      return { ok: true, body: new ReadableStream({ pull() { /* nunca resolve */ } }) };
    }
    return { ok: true, json: async () => ({ models: [] }) };
  };
  sendMsg(b, 'longo');
  await until(() => b.state.sent.length === 1);
  ok(b.d.getElementById('send').classList.contains('stop'), 'botao virou parar');
  b.d.getElementById('send').dispatchEvent(new b.w.MouseEvent('click', { bubbles: true }));
  const stopped = await until(() => /interrompido/.test(b.d.getElementById('status').textContent));
  ok(stopped, 'status = interrompido', b.d.getElementById('status').textContent);
  // b.w.close() removido: fechava a janela e um fetch pendurado quebrava no teste seguinte
}

console.log('\n================================');
console.log(`  ${pass} passaram, ${fail} falharam`);
console.log('================================');
process.exit(fail ? 1 : 0);
