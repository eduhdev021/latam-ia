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
| `scripts/ui-proxy.js` | sidecar Node que serve o chat e faz proxy da API |
| `scripts/ui-chat.html` | o chat LATAM IA (arquivo único, sem CDN) |
| `build_egg.py` | regenera `egg-ollama.json` e extrai as cópias legíveis |

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

Testes em `test/domtest/` (fora deste repo) rodam a página de verdade no jsdom, com `fetch` mockado devolvendo
stream NDJSON e relógio dentro da página (`performance.now`) medindo cada paint.

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
