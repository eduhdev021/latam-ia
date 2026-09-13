#!/usr/bin/env python3
"""Gera egg-ollama.json (PTDL_v2) a partir de scripts/ollama-install.sh.

Uso: python3 build_egg.py
"""
import json
import pathlib

HERE = pathlib.Path(__file__).parent
INSTALL_SCRIPT = (HERE / "scripts" / "ollama-install.sh").read_text()

egg = {
    "meta": {"version": "PTDL_v2", "update_url": None},
    "name": "Ollama (LLM)",
    "author": "eduardo@lagoshost.com.br",
    "description": (
        "Servidor Ollama para rodar LLMs locais, com o Open WebUI como interface na mesma porta.\n"
        "Abra http://IP:PORTA/ no navegador: o primeiro acesso cria a conta admin. O Ollama fica so\n"
        "em 127.0.0.1; a API compativel com OpenAI e o /api/v1 do Open WebUI (Settings > Account >\n"
        "API Keys). Desligue ENABLE_OPENWEBUI para expor a API do Ollama direto na allocation.\n"
        "Inferencia em CPU - o Pterodactyl nao repassa GPU pro container.\n"
        "Requisitos: CPU com AVX2 (sem AVX funciona, mas cai no backend 'cpu' e fica muito lento), "
        "4 GB+ de RAM por modelo pequeno e disco suficiente pro modelo (ex.: qwen3:0.6b = 522 MB, "
        "llama3.1:8b = 4.9 GB). O binario do Ollama ocupa ~70 MB apos remover as libs de GPU.\n"
        "A instalacao baixa ~1.4 GB do GitHub: de uns minutos e precisa de ~4.5 GB livres no pico."
    ),
    "features": [],
    "docker_images": {
        "Node.js 24 (recomendado)": "ghcr.io/parkervcp/yolks:nodejs_24",
        "Node.js 22": "ghcr.io/parkervcp/yolks:nodejs_22",
    },
    "file_denylist": [],
    "startup": "bash /home/container/ollama-start.sh",
    "config": {
        "files": "{}",
        "startup": json.dumps(
            {
                # Ollama loga: msg="Listening on [::]:PORTA (version X)"
                # O match do Wings e bytes.Contains (case-sensitive) ou "regex:..."
                "done": ["Listening on", "regex:(?i)listening on"],
                "user_interaction": [],
                "strip_ansi": True,
            }
        ),
        "logs": "{}",
        "stop": "^C",
    },
    "scripts": {
        "installation": {
            "script": INSTALL_SCRIPT,
            # Mesma base do ghcr.io/parkervcp/yolks:debian (glibc 2.41)
            "container": "debian:trixie-slim",
            "entrypoint": "bash",
        }
    },
    "variables": [
        {
            "name": "Modelo",
            "description": "Modelo baixado automaticamente no start. Aceita varios separados por virgula: 'qwen3:0.6b, tinyllama'. O nome tem que ser exato - os nomes estao em ollama.com/library e o Ollama nao tem comando de busca. Vazio = nao baixa nada.",
            "env_variable": "MODEL",
            "default_value": "qwen3:0.6b",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|string|max:64",
            "field_type": "text",
        },
        {
            "name": "Baixar modelo automaticamente",
            "description": "Se true, roda 'ollama pull' do modelo acima assim que o servidor sobe (o progresso aparece no console).",
            "env_variable": "AUTO_PULL",
            "default_value": "true",
            "user_viewable": True,
            "user_editable": True,
            "rules": "required|in:true,false,1,0",
            "field_type": "text",
        },
        {
            "name": "Keep alive",
            "description": "Tempo que o modelo fica carregado na RAM apos a ultima requisicao (ex.: 5m, 1h, -1 = nunca descarrega, 0 = descarrega ja).",
            "env_variable": "KEEP_ALIVE",
            "default_value": "5m",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|string|max:16",
            "field_type": "text",
        },
        {
            "name": "Requisicoes paralelas",
            "description": "OLLAMA_NUM_PARALLEL - quantas requisicoes o modelo atende ao mesmo tempo. A RAM necessaria escala com esse valor.",
            "env_variable": "NUM_PARALLEL",
            "default_value": "1",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|numeric|between:1,16",
            "field_type": "text",
        },
        {
            "name": "Modelos carregados simultaneamente",
            "description": "OLLAMA_MAX_LOADED_MODELS - mantenha em 1 a menos que sobre muita RAM.",
            "env_variable": "MAX_LOADED_MODELS",
            "default_value": "1",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|numeric|between:0,8",
            "field_type": "text",
        },
        {
            "name": "Context length",
            "description": "OLLAMA_CONTEXT_LENGTH - janela de contexto padrao. 0 = deixar o Ollama decidir. Quanto maior, mais RAM.",
            "env_variable": "CONTEXT_LENGTH",
            "default_value": "2048",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|numeric|between:0,1048576",
            "field_type": "text",
        },
        {
            "name": "Tipo do cache K/V",
            "description": "OLLAMA_KV_CACHE_TYPE - q8_0 e q4_0 economizam RAM com leve perda de qualidade. Medido com qwen3:0.6b em CPU: f16 = runner de 632 MiB e 24.1 tok/s; q8_0 = runner de 580 MiB e 26.4 tok/s (menos RAM e mais rapido). Precisa de FLASH_ATTENTION=1.",
            "env_variable": "KV_CACHE_TYPE",
            "default_value": "q8_0",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|in:f16,q8_0,q4_0",
            "field_type": "text",
        },
        {
            "name": "Origens permitidas (CORS)",
            "description": "OLLAMA_ORIGINS - use * para aceitar qualquer origem ou liste dominios separados por virgula.",
            "env_variable": "ORIGINS",
            "default_value": "*",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|string|max:255",
            "field_type": "text",
        },
        {
            "name": "Login no ollama.com (modelos cloud)",
            "description": "1 faz o login no ollama.com pelo console: o start imprime uma URL, voce abre no celular/PC e autoriza. Necessario para os modelos que rodam na nuvem da Ollama (nomes terminados em -cloud, ex.: gpt-oss:120b-cloud). A credencial fica gravada no server; depois volte para 0. O container nao tem navegador nem terminal, por isso o login e por URL.",
            "env_variable": "SIGNIN",
            "default_value": "0",
            "user_viewable": True,
            "user_editable": True,
            "rules": "required|in:0,1,true,false",
            "field_type": "text",
        },
        {
            "name": "Cache de prompt (MiB)",
            "description": "Teto de RAM do cache de prompt do llama-server, que guarda uma copia do estado de cada conversa (medido: 87 MB por ~800 tokens) para responder mais rapido. O padrao do llama-server e 8192 MiB e ele NAO respeita o limite do container - por isso o padrao aqui e 512. 0 desliga o cache, -1 tira o teto (comportamento antigo, arriscado em server pequeno).",
            "env_variable": "CACHE_RAM",
            "default_value": "512",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|numeric|between:-1,1048576",
            "field_type": "text",
        },
        {
            "name": "Flash attention",
            "description": "1 liga OLLAMA_FLASH_ATTENTION (menos RAM com contextos grandes, e obrigatorio para KV_CACHE_TYPE q8_0/q4_0). 0 desliga.",
            "env_variable": "FLASH_ATTENTION",
            "default_value": "1",
            "user_viewable": True,
            "user_editable": True,
            "rules": "required|in:0,1,true,false",
            "field_type": "text",
        },
        {
            "name": "Debug",
            "description": "1 liga OLLAMA_DEBUG (logs verbosos no console).",
            "env_variable": "DEBUG",
            "default_value": "0",
            "user_viewable": True,
            "user_editable": True,
            "rules": "required|in:0,1,true,false",
            "field_type": "text",
        },
        {
            "name": "Forcar biblioteca de inferencia",
            "description": "OLLAMA_LLM_LIBRARY - vazio = autodeteccao. Ex.: cpu, cpu_avx, cpu_avx2. So mexa se a autodeteccao errar.",
            "env_variable": "LLM_LIBRARY",
            "default_value": "",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|string|max:32",
            "field_type": "text",
        },
        {
            "name": "Open WebUI (interface)",
            "description": "true instala e roda o Open WebUI na allocation do server (contas, RAG, historico) com o Ollama so em 127.0.0.1 - e o padrao, e o que da a interface web e a API /api/v1. false = API pura do Ollama na allocation, sem interface. Custa ~3 GB de disco e ~1 GB de RAM; deixe false se o disco for curto. Instala via Reinstall.",
            "env_variable": "ENABLE_OPENWEBUI",
            "default_value": "true",
            "user_viewable": True,
            "user_editable": True,
            "rules": "required|in:true,false,1,0",
            "field_type": "text",
        },
        {
            "name": "Threads de inferencia",
            "description": "Quantas threads o llama.cpp usa. 'auto' (padrao) = o teto de CPU que ESTE container tem direito (o cgroup, ex.: 2 num server de 200%/2 cores) - o start script mostra o numero que resolveu no console. Pode por um numero fixo (ex.: 4). O valor e gravado como 'PARAMETER num_thread' dentro de cada modelo, porque o Ollama NAO tem variavel de ambiente para threads e o Open WebUI nao manda esse parametro. NUNCA ponha acima das vCPU do server: medido com 2 vCPU, 4 threads derrubou de 45.2 para 0.2 tok/s.",
            "env_variable": "CPU_THREADS",
            "default_value": "auto",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|string|max:8",
            "field_type": "text",
        },
        {
            "name": "Repo dos scripts (Git)",
            "description": "De onde o instalador baixa scripts/ollama-start.sh - ele nao cabe embutido na egg (o painel corta o script em ~64 KiB). Precisa ser publico: credencial dentro do server nao e segura.",
            "env_variable": "UI_REPO",
            "default_value": "https://github.com/eduhdev021/latam-ia.git",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|string|max:255",
            "field_type": "text",
        },
        {
            "name": "Branch/tag dos scripts",
            "description": "Branch, tag ou commit que o git clone usa. Troque e rode Reinstall Server para atualizar o start script.",
            "env_variable": "UI_REF",
            "default_value": "main",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|string|max:64",
            "field_type": "text",
        },
        {
            "name": "Versao do Ollama",
            "description": "'latest' ou uma tag do GitHub (ex.: v0.34.0). Usada so durante a instalacao/reinstall.",
            "env_variable": "OLLAMA_VERSION",
            "default_value": "latest",
            "user_viewable": True,
            "user_editable": False,
            "rules": "nullable|string|max:20",
            "field_type": "text",
        },
        {
            "name": "Remover libs de GPU",
            "description": "true apaga CUDA/ROCm/Vulkan/MLX apos extrair (2.2 GB -> ~70 MB). So desligue se souber o que esta fazendo.",
            "env_variable": "STRIP_GPU_LIBS",
            "default_value": "true",
            "user_viewable": True,
            "user_editable": False,
            "rules": "required|in:true,false,1,0",
            "field_type": "text",
        },
    ],
}

out = HERE / "egg-ollama.json"
out.write_text(json.dumps(egg, indent=4, ensure_ascii=False) + "\n")
print(f"gerado: {out} ({out.stat().st_size} bytes)")


# A direcao inverteu: antes os arquivos eram EXTRAIDOS de heredocs dentro do
# instalador. Agora src/ e a fonte de verdade e o instalador NAO embute mais
# nada - o painel do Pterodactyl corta o script da egg em ~64 KiB, e o chat tem
# 90 KB. Tudo que o servidor precisa vem do Git na instalacao.
SRC = HERE / "src"
SCRIPTS = HERE / "scripts"
for name in ("ollama-start.sh",):
    src = SRC / name
    dest = SCRIPTS / name
    dest.write_text(src.read_text())
    print(f"  scripts/{dest.name} <- src/{name} ({dest.stat().st_size} bytes)")

total = sum((SCRIPTS / n).stat().st_size for n in ("ollama-start.sh",))
print(f"  total entregue pelo Git: {total} bytes")
print(f"  instalador embutido na egg: {len(INSTALL_SCRIPT)} bytes (limite do painel ~65536)")
assert len(INSTALL_SCRIPT) < 60000, "o script da egg estouraria o limite de ~64 KiB do painel"
