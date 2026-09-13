# Egg Ollama (Pterodactyl / Pelican)

Egg PTDL_v2 para rodar um servidor [Ollama](https://ollama.com) dentro de um server do Pterodactyl,
com o painel de chat **LATAM IA** incluso na mesma porta. Abra `http://IP:PORTA/` no navegador e
converse; `/api/*` e `/v1/*` continuam disponíveis na mesma URL (o `/v1` é compatível com OpenAI).

Inferencia em **CPU** — o Pterodactyl não repassa GPU pro container, então as libs CUDA/ROCm/Vulkan/MLX
são removidas na instalação.

## Arquivos

| arquivo | o que é |
|---|---|
| `egg-ollama.json` | a egg — é só importar no painel |
| `scripts/ollama-install.sh` | script de instalação embutido na egg (fonte legível) |
| `scripts/ollama-start.sh` | startup que a instalação gera em `/home/container/ollama-start.sh` |
| `scripts/ui-proxy.js` | sidecar Node: serve o chat, o PWA e a rota `/search`, e faz proxy da API |
| `scripts/ui-chat.html` | o chat LATAM IA (arquivo único, sem CDN) |
| `src/` | **fonte de verdade** dos três arquivos acima |
| `assets/` | logo com fundo transparente + derivações 192/512 pro PWA |
| `tests/` | suíte jsdom + testes de ponta a ponta contra Ollama real |
| `build_egg.py` | regenera `egg-ollama.json` copiando de `src/` para `scripts/` |

## O chat vem deste repositório

Durante a instalação o script faz `git clone --depth 1` de `UI_REPO` (padrão
`https://github.com/eduhdev021/latam-ia.git`) na ref `UI_REF` (padrão `main`) e copia
`scripts/ui-chat.html` → `/home/container/ui/chat.html` e `scripts/ui-proxy.js` →
`/home/container/ui/proxy.js`. O commit usado fica registrado em `ui/.git-ref`.

**Pra atualizar o chat:** edite os arquivos aqui, dê push, e rode *Reinstall Server* no painel.
Não precisa mexer na egg.

Se o clone falhar (repo fora do ar, branch errada, sem `git` no container), o instalador avisa no
console e usa a cópia embutida na egg — o server sobe do mesmo jeito. Testado dos dois jeitos.

O repo é **público de propósito**: um repo privado exigiria credencial dentro do server, e
qualquer subadmin com acesso a eggs conseguiria ler. Se precisar fechar, use uma deploy key
read-only por node, nunca um PAT.

## Como funciona a porta única

O Ollama não tem interface web — `GET /` devolve só o texto `"Ollama is running"`
(`server/routes.go:1878`). Então a egg coloca um sidecar Node na frente:

```
navegador ──► allocation SERVER_PORT ──► ui/proxy.js
                                          ├─ GET /        → ui/chat.html
                                          └─ todo o resto → 127.0.0.1:11434 (ollama serve)
```

O Ollama passa a escutar só em `127.0.0.1` numa porta interna, que não precisa de allocation no
painel. O proxy usa `pipe()`, então o streaming SSE do `stream: true` passa intacto. A página chama
`/api/chat` com URL relativa — mesma origem, zero problema de CORS.

Com `ENABLE_UI=false` o sidecar não sobe e o Ollama volta a escutar direto em `0.0.0.0:${SERVER_PORT}`.

### Sobre portas

**A porta pública é sempre a do Wings** (`SERVER_PORT`, a allocation primária do server —
`server/server.go:158`). Não existe porta fixa exposta. Testado trocando a allocation:

| `SERVER_PORT` | proxy escuta | ollama escuta | `GET /` |
|---|---|---|---|
| 25565 | `0.0.0.0:25565` | `127.0.0.1:11434` | 200 `text/html` |
| 42069 | `0.0.0.0:42069` | `127.0.0.1:11434` | 200 `text/html` |
| 11434 | `0.0.0.0:11434` | `127.0.0.1:11435` (desviou) | 200 `text/html` |
| 43000 com `ENABLE_UI=false` | — | `0.0.0.0:43000` | 200 `text/plain` ("Ollama is running") |

O único número fixo do projeto é o `11434` **interno**, em loopback: não é allocation, não é
publicado pelo Docker e ninguém de fora alcança. Se a allocation do server for justamente 11434, o
script desvia o interno pra 11435 (terceira linha da tabela).

Se o server tiver uma **allocation secundária** em 11434, aí sim dá confusão — o Docker publicaria
essa porta direto pro Ollama, contornando o sidecar. Evitem alocar 11434 e 11435.

## O que foi testado de verdade

Testado no sandbox (Debian 13 / glibc 2.41 — mesma base da `yolks:nodejs_24`), com Ollama **v0.34.0**:

- instalação completa: download de 1.4 GB → extração → strip de GPU (**2.2 GB → 69 MB**) → smoke test respondeu `{"version":"0.34.0"}`
- `shellcheck` limpo (nível warning) no install e no start; `node --check` limpo no proxy
- boot pelo **entrypoint real do yolks nodejs** com `STARTUP=bash /home/container/ollama-start.sh`
- `[ui] chat em http://0.0.0.0:25565/ -> API em 127.0.0.1:11434`
- `GET /` pela porta pública → **200, `text/html; charset=utf-8`, 9450 bytes**
- `GET /api/tags` atravessando o proxy → **200** com o JSON dos modelos
- `POST /api/chat` com `stream:true` atravessando o proxy → **200, 5 chunks NDJSON**, `done_reason: stop`
- `POST /api/chat` sem stream → resposta completa, 18.5 tok/s em 2 vCPUs
- auto-pull baixou `qwen3:0.6b` sozinho; `Listening on 127.0.0.1:11434` continuou chegando no console
  (o marcador de "done" da egg não quebrou com o sidecar na frente)
- `SIGINT` no grupo de processos derrubou proxy e Ollama em 2 s (`[ui] SIGINT recebido, encerrando.`)

### Chat (testado com jsdom + Ollama real)

Testes em `tests/` rodam a página de verdade no jsdom, com `fetch` mockado devolvendo
stream NDJSON e relógio dentro da página (`performance.now`) medindo cada paint.

Suíte atual (roda com `node tests/t-*.mjs`, precisa de `npm i jsdom`). As duas
suítes de mock rodam sozinhas em CI (`.github/workflows/tests.yml`) — os testes
acham o chat por caminho relativo ao repo, sem depender de sandbox. As ao vivo
(`t-live*`) precisam de um Ollama em `127.0.0.1:11434` (o `t-live5` sobe o
proprio proxy com `UI_TOKEN` e se limpa no final):

| Arquivo | O que cobre | Resultado |
| --- | --- | --- |
| `t-chat2.mjs` | markdown, highlight, tool calling, parâmetros, export, interrupção | **60/60** |
| `t-features.mjs` | memória, fila, multi-modelo, fixar, `search`, PWA | **50/50** |
| `t-live.mjs` | ponta a ponta contra Ollama real (não mock) | **16/16** |
| `t-live4.mjs` | as features novas contra Ollama real, com Wikipedia de verdade | **25/25** |
| `t-live5.mjs` | API key de ponta a ponta contra proxy com `UI_TOKEN` | **8/8** |

Dois bugs que a suíte ao vivo pegou e o jsdom sozinho não pegaria:

- **Trocar de modelo matava o tool calling.** O modelo inicial não suportava
  ferramentas, o checkbox `ferramentas` era desligado, e ao trocar para um
  modelo compatível ele **continuava desligado** — o usuário ficava sem tool
  calling sem ver porquê. Agora a preferência é guardada e restaurada.
- **`web_search` nunca era chamado** pelo `qwen3:0.6b` (0/15). Renomear para
  `search` resolveu (5/5) — detalhe na seção *O que veio do Open WebUI*.

- **stream-test** — o texto aparece na tela **antes** do stream terminar, chunk a chunk
  (`t=60ms "Ola!"` → `t=90ms "Ola! Tudo"` → ...), e o texto final é igual ao stream. 5/5 asserções.
- **paint-cost** — 400 chunks com 8 ms de intervalo: **199 paints medidos, 0.561 ms de custo médio,
  pior paint 4.6 ms**, e o texto cresceu em 57 de 58 amostras.
- **render-cost** — isolando o renderizador com 4000 chunks: re-renderizar o markdown inteiro por
  chunk custa **1.384 ms/paint** (pior 7.6 ms); o renderizador incremental do LATAM IA, que cacheia
  os blocos já fechados e re-renderiza só o último, custa **0.094 ms/paint** (pior 0.78 ms) — 14,7x.
- **contra o Ollama real** (não mock): 94 chunks em 7.36 s, um a cada ~55 ms, primeiro token em
  2.11 s. `<title>LATAM IA</title>` servido com 200.

Um bug que esses testes pegaram: o `<select>` tinha um `<option value="">carregando modelos...</option>`
de placeholder, então `modelSel.value` era vazio durante o load — enviar nesse estado não fazia nada
e a tela ficava muda, parecendo travada. Agora o composer começa desabilitado e libera sozinho
quando a lista chega.

## Como instalar

1. Painel → **Admin → Nests → Create Egg** (ou importar o JSON).
2. Cole o conteúdo de `egg-ollama.json` no importador de egg.
3. Crie o server apontando pra essa egg e **dê disco e RAM suficientes** (veja abaixo).
4. Espere a instalação terminar — ela baixa ~1.4 GB do GitHub.

## Requisitos do server

| recurso | mínimo | recomendado |
|---|---|---|
| RAM | 2 GB (modelo 0.6B) | 8 GB (modelo 7-8B) |
| Disco | 5 GB livres no pico da instalação | 20 GB+ com modelo 7-8B |
| CPU | 2 vCPU | 4+ vCPU |
| CPU flags | AVX2 (sem AVX cai no backend `cpu` e fica muito lento) | AVX-512 |

O pico de disco durante a instalação é ~4.5 GB (tarball de 1.4 GB + 2.2 GB extraído); depois de
remover as libs de GPU fica em ~70 MB. O script avisa no log se o disco for insuficiente.

## Variáveis

| env | padrão | o que faz |
|---|---|---|
| `ENABLE_UI` | `true` | serve o chat em `http://IP:PORTA/`; `false` = só API na allocation |
| `CPU_THREADS` | `0` | threads de inferência; `0` = número de vCPU do container |
| `MODEL` | `qwen3:0.6b` | modelo baixado no start; vazio = não baixa nada |
| `AUTO_PULL` | `true` | roda `ollama pull` assim que o servidor sobe |
| `KEEP_ALIVE` | `5m` | quanto tempo o modelo fica na RAM (`-1` = nunca descarrega) |
| `NUM_PARALLEL` | `1` | `OLLAMA_NUM_PARALLEL` — a RAM escala com esse valor |
| `MAX_LOADED_MODELS` | `1` | `OLLAMA_MAX_LOADED_MODELS` |
| `CONTEXT_LENGTH` | `2048` | `OLLAMA_CONTEXT_LENGTH` (`0` = Ollama decide) |
| `KV_CACHE_TYPE` | `f16` | `q8_0`/`q4_0` economizam RAM com perda leve de qualidade |
| `ORIGINS` | `*` | `OLLAMA_ORIGINS` (CORS) |
| `FLASH_ATTENTION` | `1` | `OLLAMA_FLASH_ATTENTION` |
| `DEBUG` | `0` | `OLLAMA_DEBUG` (logs verbosos) |
| `LLM_LIBRARY` | *(vazio)* | força `cpu`, `cpu_avx`, `cpu_avx2` |
| `OLLAMA_VERSION` | `latest` | só admin — tag do GitHub usada na instalação |
| `STRIP_GPU_LIBS` | `true` | só admin — apaga CUDA/ROCm/Vulkan/MLX |

## Usando a API

O Ollama escuta em `0.0.0.0:${SERVER_PORT}` — use o IP e a porta da allocation do server.

```bash
# chat
curl http://IP:PORTA/api/chat -d '{
  "model": "qwen3:0.6b",
  "messages": [{"role": "user", "content": "oi"}],
  "stream": false
}'

# endpoint compatível com OpenAI
curl http://IP:PORTA/v1/chat/completions \
  -H "Authorization: Bearer ollama" \
  -d '{"model": "qwen3:0.6b", "messages": [{"role": "user", "content": "oi"}]}'
```

**Não existe shell no Pterodactyl**, então pra baixar modelos você tem dois caminhos:

1. mudar `MODEL` + `AUTO_PULL=true` e reiniciar o server (o progresso aparece no console), ou
2. chamar a API direto: `curl http://IP:PORTA/api/pull -d '{"model":"llama3.2:1b"}'`

Os modelos ficam em `/home/container/models` e contam no limite de disco do server.

## Detalhes técnicos que valem saber

- **A imagem tem que ser yolks.** O Wings não sobrescreve o `ENTRYPOINT` do container de runtime —
  ele só passa `STARTUP` como env var (`server/server.go:155`), e quem faz o eval é o
  `entrypoint.sh` da imagem. Uma imagem que não seja yolks nem chegaria a rodar o comando.
  `ghcr.io/parkervcp/yolks:nodejs_24` é `node:24-trixie-slim` (Debian 13, glibc 2.41), com
  `tini -g --` + `/entrypoint.sh` e `STOPSIGNAL SIGINT` — verificado direto no config da imagem
  via registry API. O `entrypoint.sh` do nodejs faz a mesma substituição `{{VAR}}` → `${VAR}`.
- **`/tmp` do container de instalação é tmpfs de 100 MB** (Wings: `docker.tmpfs_size`,
  `server/install.go:445`). Por isso o script baixa o tarball dentro de `/mnt/server/.install-tmp`
  e apaga no final — baixar em `/tmp` estouraria sempre.
- **Nada de OpenBLAS.** Checado no v0.34.0 com `readelf`/`strings`: nenhuma `.so` do build CPU
  referencia OpenBLAS, e o `RUNPATH` delas é `$ORIGIN`. O `libopenblas0` da imagem oficial serve
  pros backends de GPU/MLX.
- **Permissões.** A instalação roda como root em `/mnt/server`; o Wings faz `chown` recursivo no
  boot (`CheckPermissionsOnBoot`, padrão `true`), então os arquivos ficam acessíveis.
- **Detecção de "pronto".** O match do Wings é `bytes.Contains` case-sensitive
  (`remote/types.go:103`, aplicado em `server/listeners.go:169`), ou `regex:` pra regex. Por isso
  a egg usa `"Listening on"` **e** `"regex:(?i)listening on"`.
- **`strip_ansi: true`** porque o `ollama pull` imprime barra de progresso com códigos ANSI, que
  poluem o console do painel.

## Por que o chat vem do Git (e não de dentro da egg)

O painel do Pterodactyl **corta o script de instalação da egg em ~64 KiB**.
Medido no erro real:

```
/mnt/install/install.sh: line 1414: warning: here-document at line 457
    delimited by end-of-file (wanted `CHATEOF')
/mnt/install/install.sh: line 1415: syntax error: unexpected end of file
```

O chat tem 90 KB. Embutido na egg, o instalador ia a 117 KB e chegava truncado
no container — cortado no meio do heredoc, daí o `wanted CHATEOF`.

Por isso a egg só carrega **11 KB** de instalador, e tudo que o servidor precisa
(`ui-chat.html`, `ui-proxy.js`, `ollama-start.sh`) vem do `git clone` na
instalação. Consequência: **sem acesso ao Git a instalação falha de propósito**,
com mensagem dizendo o repo e a branch que tentou. Não há fallback embutido —
não cabe.

Atualizar o chat = `git push` + *Reinstall Server*. Não precisa mexer na egg.

## O que o chat tem

Arquivo único (`scripts/ui-chat.html`, ~107 KB), sem build e sem dependência npm.
Tudo roda no navegador; o `proxy.js` só serve a página, faz a busca na web e
repassa o resto pra API.

Várias das features abaixo foram implementadas a partir do que o
[Open WebUI](https://github.com/open-webui/open-webui) faz — só as que rodam
**sem backend**, porque aqui o chat é um arquivo estático servido por um proxy
de ~17 KB. O que exige servidor (RBAC, LDAP/SSO, banco vetorial, canais) não
entra e não é prometido.

**Conversas** — múltiplas conversas com sidebar, busca, agrupamento por data
(hoje / ontem / 7 dias / antigas), renomear (duplo clique), apagar com
confirmação. Tudo em `localStorage`, sobrevive ao reload.

**Markdown completo** — cabeçalhos, negrito/itálico/riscado, listas aninhadas,
listas ordenadas, tabelas com alinhamento, blockquote, `hr`, links, imagens,
código inline e blocos com **syntax highlight próprio** (JS/TS, Python, Go,
shell, C/C++/Rust, SQL, HTML, CSS, YAML), label de linguagem e botão copiar.
LaTeX via KaTeX (CDN, desligável no painel).

**Tool calling** — o chat detecta `capabilities` via `/api/show` e só habilita
ferramentas se o modelo suportar. Vem com duas que rodam no navegador:
`get_current_time` (fuso IANA) e `calculator`. A chamada e o resultado aparecem
na conversa como cartão. Verificado de ponta a ponta com `qwen3:0.6b`: o modelo
pede a ferramenta, o chat executa, devolve como `role:tool`, e o modelo responde
com o resultado.

**Parâmetros** — temperature, top_p, top_k, num_predict, repeat/presence/
frequency penalty, seed, num_ctx. Por modelo, persistidos. O painel **começa nos
valores que o próprio Modelfile declara** (lidos de `/api/show`), não em chute.

**System prompt**, formato de saída (livre / JSON forçado / JSON Schema),
truncar histórico, flash attention.

**Ações** — copiar, regenerar, editar a última mensagem sua, parar a geração
(salva o trecho que já veio). Métricas no rodapé: modelo, tempo, tok/s, tokens.

**Anexos de imagem** — colar (Ctrl+V), arrastar ou selecionar. Só habilita se o
modelo tiver `vision` nas capabilities; senão avisa e não manda.

**Exportar / importar** — JSON de todas as conversas, ou Markdown da conversa
atual.

**Tema** claro/escuro. **Atalhos**: `Ctrl+K` nova conversa, `Ctrl+/` painel de
config, `Esc` fecha.

**Autenticação** — veja a seção abaixo.

## O que veio do Open WebUI

| Feature | Como está aqui |
| --- | --- |
| **Memória persistente** | Painel → *Memória*. Fatos salvos em `localStorage` são injetados como mensagem de `system` em **todas** as conversas. Até 40 fatos, liga/desliga sem apagar. |
| **Multi-modelo** | Checkbox *multi* na barra. A mesma pergunta vai em paralelo para até 4 modelos, cada resposta na sua bolha com o nome do modelo. Só a resposta do modelo principal entra no histórico — as outras são comparacão e não poluem o contexto. |
| **Fila de mensagens** | Enviar durante uma resposta **não corta mais a geração**: a mensagem entra na fila (até 10), visível acima do composer, e sai quando a resposta atual terminar. Interromper de propósito continua parando tudo. |
| **Web search** | Ferramenta `search` (Wikipedia, **sem chave de API**). A busca roda no `proxy.js`, não no navegador, porque provedor de busca normalmente não libera CORS. |
| **PWA** | `manifest.webmanifest`, `sw.js` e `icon.svg` servidos pelo proxy. Dá pra instalar como app e o shell abre offline. Requisição de API **nunca** entra no cache. |
| **Conversas fixadas** | Botão *Fixar* na sidebar: grupo "Fixadas" no topo, com estrela. |

Duas coisas que medi antes de implementar:

- **Multi-modelo é viável no navegador.** Duas `POST /api/chat` simultâneas ao
  mesmo Ollama voltaram `200` em 1,65 s e 2,05 s — o servidor aceita concorrência.
- **O nome da ferramenta importa.** Com o nome `web_search`, o `qwen3:0.6b`
  *pensava* em chamar a ferramenta e não emitia o tool call: **0 acertos em 15
  tentativas**, com a resposta saindo vazia. Renomeei para `search` e foram
  **5 de 5**. O sublinhado parece confundir o template de ferramentas do modelo
  pequeno. Se você trocar o nome, meça de novo.

**Não implementado** (exige backend de verdade): RAG com banco vetorial, notas,
canais, voz (STT/TTS), analytics/ELO, RBAC, LDAP/SSO/SCIM, plugins e MCP.

## Logo, ícone e PWA

O logo (`assets/logo.png`) teve o fundo preto removido por corte de cor medido
no próprio arquivo (o halo escuro era RGB quase preto com alpha alto; `rembg`
tratou o halo como parte do logo e falhou). A instalação copia
`assets/logo-192.png` e `logo-512.png` do Git para `ui/`, e o proxy serve em
`/logo-192.png`, `/logo-512.png` e `/logo.png` com cache de 7 dias.

- **Favicon e header**: o chat testa `/logo-192.png`; se existir, troca o "L"
  pelo logo e vira o favicon. Instalação antiga sem o arquivo continua no "L".
- **PWA**: o manifest lista os PNGs 192/512 (any + maskable).
- **Auth**: esses arquivos são públicos mesmo com `UI_TOKEN` ligado — é só o
  casco do app, sem dado. A API e a página continuam atrás do login.

## API externa e chave (painel → Conexao)

Dois campos novos: **API externa** (URL base de outra instância Ollama ou
compatível) e **API key** (enviada como `Authorization: Bearer`). Sem
configurar, o chat fala com o próprio servidor. A chave fica só no
`localStorage` do navegador, e a API de destino precisa aceitar CORS.

Contra o próprio servidor com `UI_TOKEN`, a mesma chave vale como Bearer
(comparação em tempo constante) — testado de ponta a ponta: chave certa
carrega modelos e responde, chave errada vira erro visível, sem chave a API
recusa (`t-live5.mjs`, 8/8).

## Tem painel oficial do Ollama?

**Não.** Testado em setembro/2026:

- ao vivo: `GET /` na API v0.34.0 devolve só `Ollama is running` em
  `text/plain`; não há `/index.html` nem assets;
- `github.com/ollama/webui`, `ollama/ui` e `ollama/web` → **404**;
- guias atuais ([1](https://markaicode.com/integrate/ollama-with-open-webui/),
  [2](https://localaimaster.com/blog/open-webui-setup-guide)) seguem tratando o
  **Open WebUI** (terceiros) como a interface padrão.

O Open WebUI em si não cabe no seu server: é Python/FastAPI + SvelteKit, imagem
Docker de ~1,5 GB — e server Pterodactyl não roda Docker. Alternativas leves
existem (ex.: `ollama-gui`, que exige build Vite/React), mas nenhuma é oficial.
O LATAM IA continua sendo a interface: arquivo único servido pelo proxy, sem
build.

**Autenticação** — veja a seção acima.

## Autenticação

A API do Ollama **não tem autenticação nenhuma**. Quem expõe a allocation na
internet deixa o modelo aberto pra qualquer um. Por isso:

| `UI_TOKEN` | comportamento |
|---|---|
| vazio (padrão) | chat e API abertos. O console avisa no boot. |
| definido | `/login` exige o token; a API também passa a exigir a sessão. |

Como funciona: o proxy compara o token em **tempo constante**
(`crypto.timingSafeEqual`, pra não vazar byte a byte), emite um cookie de sessão
aleatório de 24 bytes com 30 dias de validade, e grava as sessões em
`ui/.session.json` (modo 0600) pra sobreviver ao restart. `Authorization: Bearer`
também vale, então script continua funcionando:

```bash
# pega a sessao
curl -c c.txt -X POST -d 'token=SEU_TOKEN' https://SEU_SERVIDOR/login
# usa
curl -b c.txt https://SEU_SERVIDOR/api/tags
```

Trocar o `UI_TOKEN` invalida as sessões no próximo restart.

**Limitação honesta:** isso é um portão, não é segurança de produção. O token vai
em texto puro se não houver TLS na frente, não tem rate limit nem lockout, e é
compartilhado (não há usuários separados). Pra expor na internet de verdade,
ponha um reverse proxy com TLS e basic auth na frente.

## Threads de inferência (importante)

Modelo pequeno em CPU com thread demais fica **mais lento**, não mais rápido — o overhead de
sincronização entre threads come o ganho. Medido neste projeto, num container de 2 vCPU com
`qwen3:0.6b` (550 MB):

| `num_thread` | 1º byte | velocidade | `prompt_eval` |
|---|---|---|---|
| 1 | 1.38 s | 27.8 tok/s | 0.22 s |
| 2 | 1.27 s | 45.2 tok/s | 0.12 s |
| **4** | **33.9 s** | **0.2 tok/s** | **6.74 s** |

Quatro threads em dois núcleos derrubou a velocidade 200x. É oversubscription pura.

Um relato real que motivou isso: server com 20 vCPU, `n_threads = 20`, e
`llama-server started in 114.14 seconds` pra carregar o mesmo modelo de 550 MB que aqui carrega
em 1.5 s. Não é o modelo, é thread.

Por isso:

- `CPU_THREADS=0` (padrão) usa o número de vCPU que o container enxerga — teto seguro.
- O teto respeita o **limite de CPU do painel**, não só o que `nproc` diz. Se o servidor tem
  `200% CPU / 2 cores` num node de 20 vCPU, o script detecta pelo cgroup
  (`cpu.max` = `200000 100000`) e usa 2, não 20. Sem isso o `nproc` continua reportando as 20
  cores do host e o Ollama cria 20 threads pra 2 cores de trabalho.
- O start script nunca deixa passar disso, e avisa no console se você tentar.
- Modelos < 3B costumam render melhor com 4-8. Teste no seu hardware.
- **O limite só vale pro chat.** Cliente que chama a API direto precisa mandar
  `options.num_thread` na requisição. O console avisa isso no boot.
- O Ollama não tem `OLLAMA_NUM_THREADS` (verificado no `envconfig`), e `taskset` não existe na
  imagem yolks — por isso o caminho é `num_thread` por requisição.

Se o seu log mostrar `warming up the model with an empty run` e demorar minutos, é isso.

## Limitações

- **Sem GPU.** O Pterodactyl não aloca GPU; `discover` sempre vai achar só `cpu`.
- **Nem o chat nem a API têm autenticação.** Quem souber o `IP:PORTA` usa. O Ollama tem uma flag
  `OLLAMA_AUTH` no `envconfig`, mas eu **não testei** ela — não coloque em produção exposto na
  internet sem um proxy com auth na frente.
- **O chat é de propósito mínimo.** Arquivo único, sem histórico persistido, sem múltiplas
  conversas, sem upload de imagem. É um quebra-galho pra testar o modelo, não um Open WebUI. Se
  quiserem algo completo, o caminho é um server separado com Open WebUI.
- **RAM é o teto.** O Ollama não vê o limite de cgroup do container de forma confiável — se você
  pedir um modelo maior que a RAM do server, o kernel mata o processo com
  `llama-server process has terminated: signal: killed`. Mantenha `MAX_LOADED_MODELS=1` e um
  `CONTEXT_LENGTH` coerente.
- **Instalação lenta.** São 1.4 GB do GitHub por server. Vários servers instalando ao mesmo tempo
  competem pela banda do node.
- **Reinstall não apaga modelos.** `/home/container/models` sobrevive; apague manualmente se quiser
  trocar de modelo e recuperar disco.
