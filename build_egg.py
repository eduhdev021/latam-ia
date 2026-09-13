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
        "Servidor Ollama para rodar LLMs locais, com painel de chat web incluso na mesma porta.\n"
        "Abra http://IP:PORTA/ no navegador para conversar; /api/* e /v1/* seguem disponiveis\n"
        "(o /v1 e compativel com OpenAI). Desligue ENABLE_UI para expor somente a API.\n"
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
            "description": "Modelo baixado automaticamente no start (ex.: llama3.2:1b, qwen3:0.6b, phi3:mini). Vazio = nao baixa nada.",
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
            "rules": "required|in:true,false",
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
            "description": "OLLAMA_KV_CACHE_TYPE - q8_0 e q4_0 economizam RAM com leve perda de qualidade.",
            "env_variable": "KV_CACHE_TYPE",
            "default_value": "f16",
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
            "name": "Flash attention",
            "description": "1 liga OLLAMA_FLASH_ATTENTION (menos RAM com contextos grandes). 0 desliga.",
            "env_variable": "FLASH_ATTENTION",
            "default_value": "1",
            "user_viewable": True,
            "user_editable": True,
            "rules": "required|in:0,1",
            "field_type": "text",
        },
        {
            "name": "Debug",
            "description": "1 liga OLLAMA_DEBUG (logs verbosos no console).",
            "env_variable": "DEBUG",
            "default_value": "0",
            "user_viewable": True,
            "user_editable": True,
            "rules": "required|in:0,1",
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
            "name": "Painel de chat web",
            "description": "true serve uma interface de chat em http://IP:PORTA/ e deixa o Ollama em 127.0.0.1. false expoe a API direto na allocation.",
            "env_variable": "ENABLE_UI",
            "default_value": "true",
            "user_viewable": True,
            "user_editable": True,
            "rules": "required|in:true,false",
            "field_type": "text",
        },
        {
            "name": "Threads de inferencia",
            "description": "Limita as threads do llama.cpp. IMPORTANTE: em modelo pequeno (<3B) usar todas as vCPU ATRASA - o overhead de sincronizacao come o ganho. Use 4 a 8, ou o numero de nucleos FISICOS. 0 = deixar o Ollama decidir (usa tudo, ruim pra modelo pequeno).",
            "env_variable": "CPU_THREADS",
            "default_value": "6",
            "user_viewable": True,
            "user_editable": True,
            "rules": "nullable|numeric|between:0,256",
            "field_type": "text",
        },
        {
            "name": "Repo do chat (Git)",
            "description": "De onde o instalador baixa scripts/ui-chat.html e scripts/ui-proxy.js. Precisa ser publico - credencial dentro do server nao e segura.",
            "env_variable": "UI_REPO",
            "default_value": "https://github.com/eduhdev021/latam-ia.git",
            "user_viewable": True,
            "user_editable": False,
            "rules": "nullable|string|max:255",
            "field_type": "text",
        },
        {
            "name": "Branch/tag do chat",
            "description": "Branch, tag ou commit que o git clone usa. Troque e reinstale pra atualizar o chat.",
            "env_variable": "UI_REF",
            "default_value": "main",
            "user_viewable": True,
            "user_editable": False,
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
            "rules": "required|in:true,false",
            "field_type": "text",
        },
    ],
}

out = HERE / "egg-ollama.json"
out.write_text(json.dumps(egg, indent=4, ensure_ascii=False) + "\n")
print(f"gerado: {out} ({out.stat().st_size} bytes)")


def extract(marker: str, dest: pathlib.Path) -> None:
    """Tira um heredoc do install script e grava como copia legivel."""
    head = f"<< '{marker}'\n"
    start = INSTALL_SCRIPT.index(head) + len(head)
    end = INSTALL_SCRIPT.index(f"\n{marker}\n", start)
    dest.write_text(INSTALL_SCRIPT[start : end + 1])
    print(f"  referencia: {dest.name} ({dest.stat().st_size} bytes)")


extract("STARTEOF", HERE / "scripts" / "ollama-start.sh")
extract("PROXYEOF", HERE / "scripts" / "ui-proxy.js")
extract("CHATEOF", HERE / "scripts" / "ui-chat.html")
