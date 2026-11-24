# Egg Gnoseon — Open WebUI puro (Pterodactyl / Pelican)

Painel web de chat com **logo e nome Gnoseon**, contas, histórico, leitura de arquivos e
execução de código. **Sem Ollama local**: os modelos vêm de uma API externa compatível com
OpenAI (`/v1`), por padrão a nuvem da Ollama.

Sem variável de senha ou chave nesta egg — de propósito:

| O quê | Onde configura |
| --- | --- |
| Conta admin | **Cria no próprio painel** — a **primeira conta criada vira Admin** |
| Chave dos modelos (Ollama /v1 etc.) | **Painel** → Admin → Configurações → **Conexões** |
| Chave da sandbox E2B | **Painel** → Admin → Configurações → **Code Execution** → Jupyter URL `e2b://CHAVE` (ou Valves da tool) |

## Arquivos

- `egg-gnoseon.json` — a egg pra importar no painel.
- `logo-gnoseon.png` / `logo-gnoseon.svg` — a marca Gnoseon (a egg já aplica tudo sozinha;
  os arquivos ficam de sobra pra usar onde quiser).
- `splash-gnoseon-claro.png` / `splash-gnoseon-escuro.png` — as telas de carregamento
  (claro: marca minimalista; escuro: a arte do robô).
- `gnoseon-tool-e2b.json` — cópia da tool E2B pra importação manual (só precisa se o
  registro automático falhar; o normal é a tool já nascer no painel).

## Instalar

1. Pterodactyl/Pelican → **Nests (Aves)** → **Importar** → `egg-gnoseon.json`.
2. Criar o servidor usando a egg **Gnoseon**, imagem **“Open WebUI (Python 3.11)”**.
3. Recursos recomendados: **6 GB+ de disco** (a instalação chega a ~5 GB no pico), **2 GB+ de RAM**
   (4 GB é confortável), 1 porta de allocation.
4. A instalação baixa ~2.5 GB (PyTorch CPU + Open WebUI): demora alguns minutos.
   Acompanhe pelo console. `Reinstall` refaz tudo e **não apaga** contas/conversas (`data/`).
5. No primeiro **Start** do servidor o painel leva 1–2 min extras pra ficar pronto
   (na primeira vez ele baixa o modelo de embeddings do RAG, ~90 MB). Quando o console
   mostrar a linha **`[gnoseon] Painel no ar em http://IP:PORTA`**, está acessível —
   é essa linha que marca o servidor como online no painel.

## Primeiro acesso (a conta Admin)

1. Abra `http://IP:PORTA` no navegador.
2. Clique em **Sign up** e crie a conta (nome, e-mail, senha).
3. **A primeira conta criada no painel vira Administrador automaticamente** —
   nada de e-mail/senha em variável.
4. Depois de criar a sua, tranca o painel: **Admin Panel → Settings → General →
   desligar “Enable New Sign Ups”** (só quem você convidar entra).

## Chave dos modelos (dentro do painel)

1. Crie a chave no provedor. Na Ollama: `ollama.com` → **Settings → API Keys**.
2. No painel: **Admin Panel → Settings → Connections** → seção **OpenAI API** → botão **+**:
   - **URL**: `https://ollama.com/v1`
   - **Key**: a sua chave
   - **Save**
3. Volte ao chat: os modelos do provedor aparecem no seletor do topo.
4. Serve pra **qualquer provedor compatível com OpenAI** (OpenRouter, Groq, Together, vLLM,
   LM Studio...): é só trocar a URL pelo `/v1` do provedor.

## Logo Gnoseon

A arte que você mandou (robô + orbe) virou a marca oficial do painel. O instalador aplica
tudo sozinho nos estáticos do Open WebUI: favicon (PNG, ICO e SVG), ícones do app PWA
(192/512), `logo.png`, splash escuro com o robô, splash claro com a marca minimalista e o
`site.webmanifest` (nome e cor do tema viram Gnoseon). Até o título da aba vira “Gnoseon”.
Nada pra fazer — se um dia quiser trocar a arte, gere uma nova `assets/master.webp` e rode
**Reinstall**.

**Nota de licença**: a licença do Open WebUI permite rebrand (nome, logo, identidade visual)
em deployments com **até 50 usuários** (cláusula (i) da licença, que a egg mira). Acima disso,
é preciso autorização por escrito da Open WebUI ou licença enterprise.

## Arquivos e código (nativo do Open WebUI)

- **Ler arquivos**: anexe com o **+** no chat (PDF, DOCX, TXT, CSV, código, imagens) —
  o Open WebUI lê e indexa (RAG). Pra coleções maiores: **Workspace → Knowledge** e
  referencie com `#` no chat.
- **Code Interpreter**: botão **Run** no bloco de código (roda no navegador via Pyodide,
  sem configuração). Com a E2B nativa ligada (abaixo), o **Run** passa a rodar na nuvem.
  Pra habilitar o modo automático por modelo: **Admin → Settings → Code Execution**.

## Sandbox E2B (nativa)

O Open WebUI só tem duas engines de código de fábrica: **Pyodide** (no navegador) e
**Jupyter** (servidor próprio). A egg injeta um patch no instalador que adiciona a **E2B**
ao executor de código: quando a “Jupyter URL” começa com `e2b://`, o código roda numa
sandbox na nuvem do e2b.dev — sem servidor Jupyter nenhum. O patch foi testado contra o
Open WebUI 0.13.4 e cobre os três caminhos que executam código (Code Interpreter do chat,
botão **Run** e tool nativa de código). Pra ligar:

1. Crie a chave em `e2b.dev` → **Dashboard → API Keys** (a chave começa com `e2b_`).
2. No painel: **Admin Panel → Settings → Code Execution**:
   - **Code Interpreter Engine**: `Jupyter`
   - **Jupyter URL**: `e2b://SUA_CHAVE_E2B` (a chave inteira, junto do prefixo)
   - **Jupyter Timeout**: segundos por execução (60 por padrão)
   - **Save**
3. No chat, peça “rode esse código” — o modelo gera o bloco `<code_interpreter>` e ele
   executa na nuvem E2B; stdout, erros e gráficos (PNG/SVG) voltam pro chat.

Observações:

- Cada execução cria uma **sandbox nova** (ambiente isolado, com internet) e destrói no
  fim — ~1-2s de overhead por execução e ninguém acessa o código de outra execução.
- Bibliotecas pesadas (`matplotlib`, `pandas`, `numpy`...) já vêm na sandbox padrão da E2B.
- O patch é best-effort **e seguro**: ele compila numa cópia temporária antes de aplicar;
  se a versão do Open WebUI mudar a função, o instalador pula o patch, nada quebra e o
  plano B continua valendo.

**Plano B — tool “Sandbox E2B” (function calling)**: além do motor nativo, a tool nasce
registrada direto no banco do painel assim que a primeira conta (admin) existir — aparece
sozinha em **Workspace → Ferramentas**, sem importar arquivo nenhum. Configure a chave nas
**Valves** dela (`E2B_API_KEY`) e ative no modelo. Se o registro automático não rolar, o
console avisa e o import manual resolve: **Workspace → Ferramentas → Importar** o arquivo
`gnoseon/e2b-tool.json` (aba **Files** do servidor).

## Variáveis

- Nenhuma. Porta é interna (`SERVER_PORT`). Nada de senha/chave em variável — tudo pelo painel.

## Problemas comuns

- **`WEBUI_SECRET_KEY is not set`** → egg antiga (o Open WebUI 0.13+ exige essa variável
  quando o backend sobe direto pelo uvicorn). Baixa o `egg-gnoseon.json` atual e roda
  **Reinstall**: o segredo nasce sozinho em `data/webui-secret-key` e sobrevive a restarts.
- **`bash: /mnt/install/install.sh: Permission denied`** → a egg em uso é antiga: ela instalava
  numa imagem não-root, que não consegue ler o script que o painel monta. Reimporte o
  `egg-gnoseon.json` **novo** (a instalação agora roda na imagem oficial
  `python:3.11-slim-bookworm`, que é root) e rode **Reinstall**.
- **Instalação falhou por disco** → aumente o limite do servidor e rode **Reinstall**.
- **Primeiro start demorando** → o Open WebUI baixa o modelo de embeddings do RAG (~80 MB) — normal.
- **Sem modelos no seletor** → revise em **Admin → Conexões**: a URL precisa terminar em `/v1`
  e a chave tem que estar válida.
- **Tool E2B não apareceu** → veja o console (mensagens `[gnoseon][e2b]`); o import manual
  resolve sempre.
- **Código não rodou na E2B** → confere em **Admin → Settings → Code Execution**: engine
  `Jupyter` e URL `e2b://e2b_...` (a chave inteira começa com `e2b_`). Se o console da
  instalação disse que o patch foi pulado (versão nova do Open WebUI), usa a tool nas
  Valves — os dois caminhos usam a mesma chave.
- **Painel não sobe** → veja o console; `Reinstall` recria o `venv/` sem perder os dados.
