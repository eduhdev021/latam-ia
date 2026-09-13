import { JSDOM, VirtualConsole } from 'jsdom';
import fs from 'fs';
// Resolve o chat relativo ao repo (tests/ fica dentro dele); o caminho absoluto
// do sandbox de desenvolvimento fica so como fallback.
export const CHAT_HTML = [
  new URL('../src/chat.html', import.meta.url).pathname,
  '/home/user/egg-ollama/src/chat.html',
].find((f) => fs.existsSync(f));
let HTML = fs.readFileSync(CHAT_HTML, 'utf8');
HTML = HTML.replace('<div id="cfg" style="display:none"></div>',
  '<div id="cfg" style="display:none" data-threads="2" data-auth="0"></div>');
export function boot(overrides = {}) {
  const hold = overrides.hold || null;   // funcao(body, n) -> true mantem aberto
  const log = [];
  const vc = new VirtualConsole();
  vc.on('jsdomError', e => log.push('jsdomError: ' + (e.message || e)));
  vc.on('error', (...a) => log.push('console.error: ' + a.join(' ')));
  const state = { sent: [], calls: [], search: [], reqs: [], models: overrides.models || [{ name: 'qwen3:0.6b', size: 522653767, capabilities: ['completion','tools','thinking'] }], show: overrides.show };
  const enc = new TextEncoder();
  function streamResponse(chunks, body, n) {
    return {
      ok: true, status: 200,
      text: async () => JSON.stringify({ error: 'nao' }),
      json: async () => JSON.parse(chunks[0] || '{}'),
      body: new ReadableStream({
        // hold(body, n) -> true mantem o stream aberto, para testar o estado
        // "ocupado". Fechar o stream dispara o finish() na hora.
        start(c) {
          chunks.forEach((x) => c.enqueue(enc.encode(x.endsWith('\n') ? x : x + '\n')));
          if (!(hold && hold(body, n))) c.close();
        }
      })
    };
  }
  const PAGE = overrides.owui
    ? HTML.replace('data-auth="0"', 'data-auth="0" data-owui="1"')
    : HTML;
  const dom = new JSDOM(PAGE, {
    runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc, url: 'http://localhost/',
    beforeParse(w) {
      w.fetch = async (u, o) => {
        const url = String(u);
        const body = o && o.body ? JSON.parse(o.body) : null;
        state.reqs.push({ url, opts: o || {} });
        if (url.startsWith('/search')) {
          state.search.push(url);
          return {
            ok: true,
            json: async () => ({
              query: 'capital do brasil', source: 'wikipedia:pt',
              results: [{ title: 'Brasilia', url: 'https://pt.wikipedia.org/wiki/Brasilia', snippet: 'capital federal do Brasil' }]
            })
          };
        }
        if (url.startsWith('/api/tags')) return { ok: true, json: async () => ({ models: state.models }) };
        if (url.startsWith('/api/pull')) {
          state.calls.push({ url, body });
          // stream NDJSON de progresso, como o Ollama devolve
          return streamResponse([
            JSON.stringify({ status: 'pulling manifest' }),
            JSON.stringify({ status: 'downloading', completed: 500, total: 1000 }),
            JSON.stringify({ status: 'success' }),
          ], body, 0);
        }
        if (url.startsWith('/api/delete')) {
          state.calls.push({ url, body });
          // imita o efeito real: some da lista do /api/tags seguinte
          state.models = state.models.filter((m) => m.name !== (body && body.name));
          return { ok: true, json: async () => ({}) };
        }
        if (url.startsWith('/api/show')) {
          state.calls.push({ url, body });
          return state.show
            ? { ok: true, json: async () => state.show }
            : { ok: true, json: async () => ({ capabilities: ['completion','tools','thinking'], parameters: 'temperature 0.6\ntop_k 20\ntop_p 0.95\nrepeat_penalty 1\nstop "<|im_start|>"', model_info: { 'general.architecture': 'qwen3', 'qwen3.context_length': 40960 }, modelfile: '' }) };
        }
        if (url.startsWith('/api/chat')) {
          state.sent.push(body);
          const n = state.sent.length;
          const handler = overrides.onChat;
          const chunks = handler ? handler(body, n) : null;
          return streamResponse(chunks || [
            JSON.stringify({ message: { role: 'assistant', content: 'Ola! ' } }),
            JSON.stringify({ message: { role: 'assistant', content: 'Tudo bem?' } }),
            JSON.stringify({ done: true, eval_count: 6, eval_duration: 240000000, model: 'qwen3:0.6b' })
          ], body, n);
        }
        return { ok: false, status: 404, text: async () => 'nf' };
      };
      w.navigator.clipboard = { writeText: async () => {} };
      w.URL.createObjectURL = () => 'blob:fake';
      w.URL.revokeObjectURL = () => {};
      w.HTMLCanvasElement && (w.HTMLCanvasElement.prototype.getContext = () => null);
    }
  });
  return { dom, w: dom.window, d: dom.window.document, state, log };
}
export const wait = ms => new Promise(r => setTimeout(r, ms));
export async function until(fn, ms = 4000, step = 20) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (fn()) return true; await wait(step); }
  return false;
}
export function ready(booted) {
  return until(() => {
    const sel = booted.d.getElementById('model');
    return sel && sel.value && !sel.options[0].textContent.includes('carregando');
  });
}
