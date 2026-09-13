# Egg Ollama (Pterodactyl / Pelican)

Egg para rodar **Ollama** (LLM local, inferência em CPU) com o **Open WebUI** como
interface web — tudo numa porta só, a allocation do server.

```
ENABLE_OPENWEBUI=true  (padrão)

  navegador ──> http://SEU_IP:SERVER_PORT/  ──>  Open WebUI  ──>  Ollama (127.0.0.1:11434)
```

O Open WebUI é o processo que segura a allocation. O Ollama escuta **só em
localhost**, então não precisa de allocation extra nem de expor a API crua na
internet. A API compatível com OpenAI é o `/api/v1` do próprio Open WebUI.

Com `ENABLE_OPENWEBUI=false` o server vira API pura: o Ollama assume a
`SERVER_PORT` e o `/api/*` + `/v1/*` ficam abertos na allocation.

## Arquivos

| arquivo | o que é |
| --- | --- |
| `egg-ollama.json` | a egg (PTDL_v2). É o que você importa no painel. |
| `build_egg.py` | gera `egg-ollama.json` embutindo `scripts/ollama-install.sh`. |
| `scripts/ollama-install.sh` | instalador: baixa o Ollama, remove libs de GPU, instala o Open WebUI. |
| `src/ollama-start.sh` | start script (editável pelo File Manager do painel). |
| `scripts/ollama-start.sh` | cópia gerada pelo build — é a que o Git entrega ao servidor. |
| `tests/t-egg.mjs` | valida a egg, as variáveis, a sincronia e resíduos de código morto. |
| `tests/t-start.mjs` | **executa** o start script contra binários-stub (7 cenários). |
| `tests/t-api-live.mjs` | valida a API do Ollama; se auto-pula quando não há Ollama no ar. |

`scripts/` é o que o instalador clona deste repositório. Se você editar
`src/ollama-start.sh`, rode `python3 build_egg.py` (sincroniza a cópia e a egg) e
faça commit — a CI reclama se os dois divergirem.

## Como instalar

1. Painel → **Admin → Nests → Import Egg** → suba `egg-ollama.json`.
2. Crie o server com essa egg. Imagem: `ghcr.io/parkervcp/yolks:nodejs_24`.
3. **Allocation**: uma porta só. É nela que o Open WebUI vai atender.
4. **Startup**: confira `MODEL` (ex.: `qwen3:0.6b`) e deixe `ENABLE_OPENWEBUI=true`.
5. Instale. O download do Ollama tem ~1,4 GB e o Open WebUI mais ~3 GB de disco.
6. **Start** → abra `http://SEU_IP:PORTA/` → o primeiro acesso cria a conta admin.

> O Node da imagem yolks não é usado por nada: o Open WebUI roda em Python 3.11
> standalone (via `uv`, em `owui-venv/`) e o Ollama é um binário Go. A imagem
> nodejs_24 entra só porque traz `curl`, `git` e um userland Debian recente.

## Requisitos do server

**Disco é a primeira parede, RAM é a segunda.**

| item | quanto |
| --- | --- |
| binário do Ollama | ~70 MB depois de remover CUDA/ROCm/Vulkan (~2,2 GB sem remover) |
| Open WebUI (`owui-venv/`) | ~3 GB |
| pico da instalação | ~4,5 GB livres |
| modelo | `qwen3:0.6b` = 522 MB · `llama3.1:8b` = 4,9 GB |
| RAM do Open WebUI | ~800 MB–1 GB, quase fixo |
| RAM por modelo | ~4 GB para modelos pequenos |

CPU precisa ter **AVX2**. Sem AVX o Ollama cai no backend `cpu` básico e fica
muito lento (o start script avisa no console).

## Variáveis (aba Startup)

18 variáveis. As que importam no dia a dia:

| variável | padrão | o que faz |
| --- | --- | --- |
| `MODEL` | `qwen3:0.6b` | baixado automaticamente na instalação/start. |
| `ENABLE_OPENWEBUI` | `true` | interface web na allocation + Ollama em localhost. `false` = API pura. |
| `AUTO_PULL` | `true` | baixa `MODEL` ao subir. |
| `CPU_THREADS` | `auto` | `auto` = o teto de CPU que este container tem direito (lê o cgroup). Aceita número fixo. |
| `CONTEXT_LENGTH` | `2048` | contexto padrão. É o que mais come RAM: corte para 1024 se apertar. |
| `CACHE_RAM` | `512` | teto de RAM do cache de prompt. O padrão do llama-server é **8192** e ignora o container. |
| `KV_CACHE_TYPE` | `q8_0` | metade da RAM do KV, sem perda de velocidade (medido abaixo). |
| `KEEP_ALIVE` | `5m` | quanto tempo o modelo fica carregado. Menos = mais RAM livre. |
| `NUM_PARALLEL` / `MAX_LOADED_MODELS` | `1` / `1` | suba só se sobrar RAM. |
| `OLLAMA_VERSION` | `latest` | usada na instalação/reinstall. |
| `UI_REPO` / `UI_REF` | este repo / `main` | de onde vem o start script. |

O resto (`ORIGINS`, `FLASH_ATTENTION`, `DEBUG`, `LLM_LIBRARY`, `STRIP_GPU_LIBS`)
está documentado na própria egg.

Todas as variáveis de liga/desliga aceitam `true`/`false` **e** `1`/`0`. Motivo:
o painel transforma regra `in:` em dropdown, e um valor fora da lista faz ele
recusar o salvamento da aba Startup inteira com *"The selected value is
invalid."* — sem dizer qual campo. Um server criado com uma versão antiga da egg
podia ficar travado assim.

## Usando a API

O Open WebUI expõe uma API compatível com OpenAI na **mesma porta** da interface.
A criação de chave vem **ligada** (`ENABLE_API_KEYS=true`, exportado pelo start
script — o Open WebUI traz isso desligado por padrão).

Pegue a chave em **Settings → Account → API Keys** e:

```bash
curl http://SEU_IP:PORTA/api/v1/chat/completions \
  -H "Authorization: Bearer sk-XXXX" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3:0.6b","messages":[{"role":"user","content":"oi"}]}'
```

> **Pegadinha medida na prática:** o Open WebUI guarda esse flag no SQLite
> (`config.auth.enable_api_keys`) e o valor do banco **vence** o da variável de
> ambiente depois do primeiro boot — `Config.get()` em `models/config.py` só usa
> o default do env quando a linha não existe. Ou seja: o `ENABLE_API_KEYS=true`
> do start script vale para instalação nova; se o banco já existia com o flag
> desligado, ligue em **Admin → Settings → Interface**. Sem isso a criação de
> chave responde `403 API key creation is not allowed in the environment`.

Com `ENABLE_OPENWEBUI=false` a API é a do próprio Ollama na allocation:
`/api/tags`, `/api/generate`, `/api/chat` e `/v1/*` (compatível com OpenAI), sem
autenticação — nesse caso proteja com firewall ou não exponha a allocation.

## Threads de inferência (importante)

Em modelo pequeno (<3B) usar **todas** as vCPU **atrasa**: o overhead de
sincronização come o ganho. Medido com 2 vCPU:

| threads | tok/s |
| --- | --- |
| 1 | 27,8 |
| 2 | 45,2 |
| 4 | **0,2** (thrashing) |

O teto é calculado pelo start script a partir do cgroup, e não do `nproc`.
Motivo: o Pterodactyl pode limitar CPU por **quota CFS** (`cpu.max`, o "200% CPU
/ 2 cores" do painel) em vez de `cpuset` — nesse caso `nproc` continua
reportando todas as cores do host, e o runtime do Go cria 20 threads para 2
cores de trabalho (já observado: `n_threads=20`, warmup de 114 s). O script lê
`cpu.max` / `cpu.cfs_quota_us` e usa `quota/period` como teto, arredondando para
baixo.

**Como o limite é aplicado de verdade:** o Ollama não tem variável de ambiente
para threads — verificado no binário v0.34.0, não existe nenhuma `OLLAMA_*THREAD*`
e a string `CPU_THREADS` aparece 0 vezes nele. `OMP_NUM_THREADS` também é
ignorado (medido: com `OMP_NUM_THREADS=2` o runner seguiu em `n_threads = 1`). O
único caminho que vale para **qualquer** cliente é gravar o parâmetro dentro do
modelo, e é o que o start script faz em todo boot:

```
FROM qwen3:0.6b
PARAMETER num_thread 2        # gravado via `ollama create` na mesma tag
```

Isso é necessário porque o Open WebUI não manda `num_thread`. Sem o parâmetro
gravado, o Ollama usa o que o `nproc` reporta — todas as cores do host — e num
container limitado por quota isso vira thrashing com throttle a cada 100 ms: a
geração fica tão lenta que parece travada. Medido com o parâmetro gravado, via
Open WebUI: `llama threadpool init, n_threads = 2` e 27,9 tok/s com `qwen3:0.6b`.

## Memória (importante)

O que come RAM aqui, medido no server de teste com `qwen3:0.6b` em CPU:

| onde | quanto | dá para controlar? |
| --- | --- | --- |
| pesos do modelo + buffers (`runner.size`) | 640 MiB | só trocando de modelo |
| Open WebUI (uvicorn + SQLite) | 630 MiB parado | `ENABLE_OPENWEBUI=false` |
| cache K/V (ctx 2048) | 59 MiB em `f16` | `KV_CACHE_TYPE=q8_0` |
| **cache de prompt** | **87 MiB por ~800 tokens, teto de 8192 MiB** | `CACHE_RAM` |

O cache de prompt era o buraco: o `llama-server` guarda uma cópia do estado de
cada conversa na RAM para responder mais rápido, com **teto padrão de 8192 MiB
que não olha o limite do container**. Num server de 8 GB com o Open WebUI isso é
OOM ou swap — e o sintoma é o chat simplesmente parar de responder.

O Ollama não tem variável própria para isso, mas o `llama-server` declara
`(env: LLAMA_ARG_CACHE_RAM)` na flag `--cache-ram`, e o Ollama repassa o ambiente
para o processo filho. Verificado:

```
$ CACHE_RAM=512  ->  srv load_model: prompt cache is enabled, size limit: 512 MiB
$ CACHE_RAM=256  ->  srv load_model: prompt cache is enabled, size limit: 256 MiB
padrao           ->  srv load_model: prompt cache is enabled, size limit: 8192 MiB
```

O start script também confere a conta no boot e avisa antes de você descobrir no
susto, comparando com o **cgroup** (`/sys/fs/cgroup/memory.max`), não com a RAM
da máquina — o Ollama mede `inference compute` pelo total do host e acha que cabe
o que não cabe:

```
[egg] memoria   : maior modelo 637 MB + reserva 1300 MB = 1937 MB
[egg]             limite do container: 8094 MB
```

A conta usa o maior modelo instalado, não a soma: com `MAX_LOADED_MODELS=1` só um
carrega por vez.

Os defaults de memória ficam **no start script**, não só na egg. Se a variável
chegar vazia o Ollama decide sozinho, e o que ele decide mata o processo — medido
num server pequeno sem `CONTEXT_LENGTH`/`KV_CACHE_TYPE`:

```
llama_context: n_ctx = 4096          flash_attn = auto
llama_kv_cache: CPU KV buffer size = 448.00 MiB
Load failed ... error="llama-server process has terminated: signal: killed"
```

`signal: killed` é o kernel matando por falta de RAM; o Ollama devolve 500 e o
chat fica girando sem erro na tela. Com os defaults do script o mesmo boot dá
`n_ctx 2048`, KV de 119 MiB, cache de prompt em 512 MiB e `HTTP 200`.

**`KV_CACHE_TYPE=q8_0` é grátis.** Mesmo prompt, mesmo contexto:

| KV cache | `runner.size` | velocidade |
| --- | --- | --- |
| `f16` (padrão antigo) | 632,3 MiB | 24,1 tok/s |
| `q8_0` (padrão agora) | 579,9 MiB | 26,4 tok/s |

Menos RAM **e** mais rápido. Precisa de `FLASH_ATTENTION=1`, que já é o padrão.

## Por que o start script vem do Git

O painel corta o script da egg em ~64 KiB (medido: 65.614 bytes). Com o
instalador e o start script embutidos, o instalador passava de 117 KB e chegava
truncado no container (`here-document ... wanted CHATEOF`). Por isso a egg
carrega só o instalador (13 KB hoje) e o instalador clona este repositório para
pegar `scripts/ollama-start.sh`. Sem Git a instalação aborta de propósito, com o
motivo na tela — melhor falhar cedo do que subir um server sem o que executar.

## Open WebUI: detalhes que custaram tempo

- Só roda em **Python 3.11/3.12**; a imagem yolks (Debian 13) traz 3.13. O
  instalador baixa um CPython 3.11 standalone via `uv` — sem compilar, sem PPA.
- `torch` é instalado com `--index-url https://download.pytorch.org/whl/cpu`: o
  wheel padrão do PyPI puxa ~5 GB de libs CUDA inúteis em server sem GPU.
- O instalador do `uv` grava recibo em `$XDG_CONFIG_HOME/uv` e pode falhar nisso
  dentro do container; por isso tudo é escopado sob o diretório do server e o que
  vale é o teste `[ -x uv ]`, não o exit code.
- `/tmp` do container pode ser tmpfs pequeno: `TMPDIR` aponta para o disco do
  server, senão a extração de wheels grandes (scipy) estoura.
- `HOME` fica no diretório do server: o Open WebUI baixa o modelo de embeddings
  (`all-MiniLM-L6-v2`) em `$HOME/.cache/huggingface` no primeiro boot.
- Os dados ficam em `open-webui/` (SQLite) e sobrevivem a restart e a reinstall.
- Não dá para servir o Open WebUI sob subpath: o SvelteKit usa caminhos absolutos
  (`/assets`, `/api`, `/socket.io`). Por isso ele precisa da porta inteira.
- **O venv não é relocável e o Pterodactyl muda o caminho entre as fases.** O
  instalador roda com o server em `/mnt/server`; em runtime o mesmo diretório é
  montado em `/home/container`. O `uv` grava caminhos absolutos no shebang dos
  executáveis de `bin/`, no symlink `bin/python` e no `home` do `pyvenv.cfg`. Sem
  corrigir, o start morre com
  `owui-venv/bin/open-webui: cannot execute: required file not found` — o kernel
  não acha o interpretador do shebang. São **quatro** lugares, e o quarto é o que
  pega: além do `pyvenv.cfg`, do symlink `bin/python` e dos shebangs de `bin/`, o
  uv cria `.uv/python/cpython-3.11-linux-x86_64-gnu` como **symlink absoluto**
  para o prefixo da instalação — reescrever só o venv não resolve, o caminho novo
  volta pelo atalho para o prefixo antigo. O start script varre os symlinks de
  `.uv/` e do venv e reescreve o prefixo para o `BASE_DIR` real em todo boot
  (idempotente), então instalações antigas se consertam sozinhas no primeiro
  start, sem baixar nada de novo.

## O que foi testado de verdade

Três suítes, **134 asserts**:

```
node tests/t-egg.mjs        # 82 asserts
node tests/t-start.mjs      # 42 asserts
node tests/t-api-live.mjs   # 10 asserts (pula sem Ollama no ar)
```

`t-start.mjs` executa `src/ollama-start.sh` de verdade contra `ollama` e
`open-webui` falsos que imprimem o que receberam. Cobre: Open WebUI na
`SERVER_PORT` com Ollama em `127.0.0.1:11434`; API pura quando desligado;
fallback quando o `owui-venv/` não existe; `ENABLE_OPENWEBUI=1`; colisão
`SERVER_PORT=11434` → interna em 11435; teto de threads via cgroup;
`WEBUI_NAME`; `ENABLE_API_KEYS=true`; a ausência de qualquer `node` no caminho;
e a reescrita dos caminhos do venv quando ele foi gravado com o prefixo da
instalação (o bug do `required file not found`), inclusive a idempotência dela.

Além disso, validado com a stack real no ar (Ollama 0.34.0 + Open WebUI):

- porta pública respondendo `<title>Open WebUI</title>` e `/health` `{"status":true}`;
- Ollama só em `127.0.0.1:11434`, sem allocation própria;
- signup do admin, criação de API key, `GET /api/v1/models`, chave errada → 401;
- `POST /api/v1/chat/completions` → 200 (12 tok/s com `tinyllama`);
- `api/version`, `api/tags`, `api/generate`, `api/chat` e streaming NDJSON.

## Limitações

- **Sem GPU.** O Pterodactyl não repassa GPU para o container; a inferência é em
  CPU. O instalador remove as libs de CUDA/ROCm/Vulkan/MLX (2,2 GB → ~70 MB).
- Modelos grandes ficam lentos em CPU. Prefira `qwen3:0.6b`, `qwen2.5:0.5b`,
  `tinyllama` — ou aceite a velocidade.
- O Open WebUI custa ~630 MB de RAM parado. Se o server for pequeno, rode com
  `ENABLE_OPENWEBUI=false` e use a API.
- O primeiro boot do Open WebUI baixa o modelo de embeddings (~90 MB).

## Histórico

Este repositório já teve um chat próprio em HTML/JS ("LATAM IA") com proxy Node
para dividir uma porta entre duas interfaces. Ele foi removido: o Open WebUI
cobre o caso com muito mais recursos e dispensa o proxy — com uma interface só, ela
binda a allocation direto. Está preservado no histórico do Git
(último commit com o chat: `a2754a5`).
