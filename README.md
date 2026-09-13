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

17 variáveis. As que importam no dia a dia:

| variável | padrão | o que faz |
| --- | --- | --- |
| `MODEL` | `qwen3:0.6b` | baixado automaticamente na instalação/start. |
| `ENABLE_OPENWEBUI` | `true` | interface web na allocation + Ollama em localhost. `false` = API pura. |
| `AUTO_PULL` | `true` | baixa `MODEL` ao subir. |
| `CPU_THREADS` | `0` | `0` = usa as vCPU que o container enxerga (já é o teto seguro). |
| `CONTEXT_LENGTH` | `2048` | contexto padrão. É o que mais come RAM: corte para 1024 se apertar. |
| `KEEP_ALIVE` | `5m` | quanto tempo o modelo fica carregado. Menos = mais RAM livre. |
| `NUM_PARALLEL` / `MAX_LOADED_MODELS` | `1` / `1` | suba só se sobrar RAM. |
| `OLLAMA_VERSION` | `latest` | usada na instalação/reinstall. |
| `UI_REPO` / `UI_REF` | este repo / `main` | de onde vem o start script. |

O resto (`KV_CACHE_TYPE`, `ORIGINS`, `FLASH_ATTENTION`, `DEBUG`, `LLM_LIBRARY`,
`STRIP_GPU_LIBS`) está documentado na própria egg.

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

O limite vale para o que o start script sobe. Cliente que chama a API direto
precisa mandar `options.num_thread` na requisição.

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

## O que foi testado de verdade

Três suítes, **78 asserts**:

```
node tests/t-egg.mjs        # 45 asserts
node tests/t-start.mjs      # 23 asserts
node tests/t-api-live.mjs   # 10 asserts (pula sem Ollama no ar)
```

`t-start.mjs` executa `src/ollama-start.sh` de verdade contra `ollama` e
`open-webui` falsos que imprimem o que receberam. Cobre: Open WebUI na
`SERVER_PORT` com Ollama em `127.0.0.1:11434`; API pura quando desligado;
fallback quando o `owui-venv/` não existe; `ENABLE_OPENWEBUI=1`; colisão
`SERVER_PORT=11434` → interna em 11435; teto de threads via cgroup;
`WEBUI_NAME`; `ENABLE_API_KEYS=true`; e a ausência de qualquer `node` no caminho.

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
- O Open WebUI custa ~1 GB de RAM parado. Se o server for pequeno, rode com
  `ENABLE_OPENWEBUI=false` e use a API.
- O primeiro boot do Open WebUI baixa o modelo de embeddings (~90 MB).

## Histórico

Este repositório já teve um chat próprio em HTML/JS ("LATAM IA") com proxy Node
para dividir uma porta entre duas interfaces. Ele foi removido: o Open WebUI
cobre o caso com muito mais recursos e dispensa o proxy — com uma interface só, ela
binda a allocation direto. Está preservado no histórico do Git
(último commit com o chat: `a2754a5`).
