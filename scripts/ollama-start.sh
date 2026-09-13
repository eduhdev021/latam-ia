#!/bin/bash
# Ollama egg - inicializacao. Editavel pelo File Manager do painel.
# As variaveis (MODEL, AUTO_PULL, KEEP_ALIVE...) vem da aba Startup do servidor.
# BASE_DIR so existe pra facilitar teste fora do painel; no Pterodactyl e /home/container.
BASE_DIR="${BASE_DIR:-/home/container}"
cd "${BASE_DIR}" || exit 1

OLLAMA_ROOT="${BASE_DIR}/ollama"
OLLAMA_BIN="${OLLAMA_ROOT}/bin/ollama"

export HOME="${BASE_DIR}"
export OLLAMA_MODELS="${BASE_DIR}/models"
export TMPDIR="${BASE_DIR}/temp"
export LD_LIBRARY_PATH="${OLLAMA_ROOT}/lib/ollama${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# as libs de Vulkan sao removidas na instalacao, entao desliga a sondagem
export OLLAMA_VULKAN=0

# Com a interface ligada, o Node ocupa a allocation publica e o Ollama fica so em
# 127.0.0.1 (porta interna nao precisa de allocation no Pterodactyl).
UI_ON="false"
OWUI_ONLY="false"
OWUI_WANTED="false"
if [ "${ENABLE_OPENWEBUI}" = "true" ] || [ "${ENABLE_OPENWEBUI}" = "1" ]; then OWUI_WANTED="true"; fi
if [ "${ENABLE_UI}" = "true" ] || [ "${ENABLE_UI}" = "1" ]; then
    if ! command -v node >/dev/null 2>&1; then
        echo "[egg] ERRO: ENABLE_UI=true mas nao existe 'node' nesta imagem."
        echo "[egg] Use ghcr.io/parkervcp/yolks:nodejs_24 ou desligue a variavel ENABLE_UI."
        exit 1
    fi
    # o instalador so grava ui/.enabled quando o chat veio do Git
    if [ ! -f "${BASE_DIR}/ui/.enabled" ] || [ ! -f "${BASE_DIR}/ui/proxy.js" ]; then
        echo "[egg] AVISO: ENABLE_UI=true mas o chat nao esta instalado."
        echo "[egg]         Subindo so a API. Rode Reinstall Server para trazer o chat."
        export OLLAMA_HOST="0.0.0.0:${SERVER_PORT}"
    else
    UI_ON="true"
    INTERNAL_PORT=11434
    if [ "${INTERNAL_PORT}" = "${SERVER_PORT}" ]; then INTERNAL_PORT=11435; fi
    export OLLAMA_HOST="127.0.0.1:${INTERNAL_PORT}"
    export OLLAMA_INTERNAL_PORT="${INTERNAL_PORT}"
    fi
elif [ "${OWUI_WANTED}" = "true" ] && [ -x "${BASE_DIR}/owui-venv/bin/open-webui" ]; then
    # Sem o chat Node: o Open WebUI vira A interface publica na allocation,
    # e o Ollama fica so em localhost falando com ele.
    OWUI_ONLY="true"
    INTERNAL_PORT=11434
    if [ "${INTERNAL_PORT}" = "${SERVER_PORT}" ]; then INTERNAL_PORT=11435; fi
    export OLLAMA_HOST="127.0.0.1:${INTERNAL_PORT}"
    export OLLAMA_INTERNAL_PORT="${INTERNAL_PORT}"
else
    export OLLAMA_HOST="0.0.0.0:${SERVER_PORT}"
fi

mkdir -p "${OLLAMA_MODELS}" "${TMPDIR}" "${HOME}/.ollama"

if [ -n "${ORIGINS}" ];           then export OLLAMA_ORIGINS="${ORIGINS}"; fi
if [ -n "${KEEP_ALIVE}" ];        then export OLLAMA_KEEP_ALIVE="${KEEP_ALIVE}"; fi
if [ -n "${NUM_PARALLEL}" ];      then export OLLAMA_NUM_PARALLEL="${NUM_PARALLEL}"; fi
if [ -n "${MAX_LOADED_MODELS}" ]; then export OLLAMA_MAX_LOADED_MODELS="${MAX_LOADED_MODELS}"; fi
if [ -n "${CONTEXT_LENGTH}" ];    then export OLLAMA_CONTEXT_LENGTH="${CONTEXT_LENGTH}"; fi
if [ -n "${KV_CACHE_TYPE}" ];     then export OLLAMA_KV_CACHE_TYPE="${KV_CACHE_TYPE}"; fi
if [ -n "${LLM_LIBRARY}" ];       then export OLLAMA_LLM_LIBRARY="${LLM_LIBRARY}"; fi
if [ "${FLASH_ATTENTION}" = "1" ] || [ "${FLASH_ATTENTION}" = "true" ]; then export OLLAMA_FLASH_ATTENTION=1; fi
if [ "${DEBUG}" = "1" ] || [ "${DEBUG}" = "true" ];                     then export OLLAMA_DEBUG=1; fi

if [ ! -x "${OLLAMA_BIN}" ]; then
    echo "[egg] ERRO: ${OLLAMA_BIN} nao encontrado."
    echo "[egg] Rode 'Reinstall Server' no painel (Admin > Servers > seu server > Reinstall)."
    exit 1
fi

echo "[egg] =============================================="
echo "[egg] Ollama $(cat "${OLLAMA_ROOT}/VERSION" 2>/dev/null || echo '?') | inferencia em CPU"
echo "[egg] api       : ${OLLAMA_HOST}"
if [ "${UI_ON}" = "true" ]; then
    echo "[egg] chat web  : porta publica ${SERVER_PORT} -> abra http://SEU_IP:${SERVER_PORT}/ no navegador"
elif [ "${OWUI_ONLY}" = "true" ]; then
    echo "[egg] interface : porta publica ${SERVER_PORT} -> Open WebUI em http://SEU_IP:${SERVER_PORT}/"
fi
echo "[egg] models    : ${OLLAMA_MODELS}"
echo "[egg] memoria   : ${SERVER_MEMORY} MB (limite do container)"
echo "[egg] =============================================="

if ! grep -q -m1 -o ' avx2 ' /proc/cpuinfo 2>/dev/null; then
    echo "[egg] AVISO: esta CPU nao tem AVX2 - a inferencia vai usar o backend 'cpu' basico e ficar bem lenta."
fi

# Threads de inferencia. Em modelo pequeno (<3B), usar todas as vCPU ATRASA muito:
# medido com 2 vCPU -> 1 thread: 27.8 tok/s | 2: 45.2 tok/s | 4: 0.2 tok/s (thrashing).
# Teto de threads = vCPU que ESTE container enxerga.
#
# Por que nproc nao basta: nproc usa sched_getaffinity, que so reflete cpuset
# (pinning). Pterodactyl/Wings pode limitar CPU por CFS quota (cgroup v2 cpu.max,
# "quota period") em vez de cpuset - nesse caso nproc continua reportando todas
# as cores do host. Ex.: "200% CPU / 2 cores" no painel.
#
# Ollama usa o runtime do Go, que le NumCPU via sched_getaffinity tambem. Entao
# num cgroup limitado por quota ele cria 20 threads pra 2 cores de trabalho, e a
# sincronizacao come tudo. (Ja observado: n_threads=20, warmup de 114s.)
#
# cpu.max = "<quota> <period>"; "max" = ilimitado. threads = quota/period.
NCPU="$(nproc 2>/dev/null || echo 1)"
CG_MAX=""
for _cg in /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu/cpu.cfs_quota_us; do
    if [ -r "${_cg}" ]; then CG_MAX="${_cg}"; break; fi
done
if [ -n "${CG_MAX}" ]; then
    if [ "${CG_MAX}" = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" ]; then
        _q="$(cat "${CG_MAX}" 2>/dev/null || echo -1)"
        _p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 100000)"
    else
        read -r _q _p < "${CG_MAX}" 2>/dev/null || true
    fi
    if [ -n "${_q:-}" ] && [ "${_q}" != "max" ] && [ "${_q}" -gt 0 ] 2>/dev/null \
       && [ -n "${_p:-}" ] && [ "${_p}" -gt 0 ] 2>/dev/null; then
        # teto inteiro: 150000/100000 = 1, nao 2. Duas threads brigando por 1.5
        # core vao se throttlear no fim de cada periodo de 100ms e ficar pior
        # do que uma thread so. Melhor sobrar core do que faltar.
        _lim=$(( _q / _p ))
        [ "${_lim}" -lt 1 ] && _lim=1
        if [ "${_lim}" -lt "${NCPU}" ]; then
            echo "[egg] cgroup limita CPU a ${_lim} core(s), quota ${_q}/${_p} - nproc dizia ${NCPU}"
            NCPU="${_lim}"
        fi
    fi
fi
if [ -z "${CPU_THREADS}" ] || [ "${CPU_THREADS}" = "0" ]; then
    CPU_THREADS="${NCPU}"
fi
if [ "${CPU_THREADS}" -gt "${NCPU}" ] 2>/dev/null; then
    echo "[egg] AVISO: CPU_THREADS=${CPU_THREADS} mas o container so ve ${NCPU} vCPU."
    echo "[egg]         Mais threads que nucleos causa thrashing e derruba a velocidade."
    echo "[egg]         Ajustando para ${NCPU}. Modelos <3B costumam render melhor com 4-8."
    CPU_THREADS="${NCPU}"
fi
export CPU_THREADS
echo "[egg] threads   : ${CPU_THREADS} (vCPU visiveis: ${NCPU})"
echo "[egg] AVISO     : o limite vale para o chat. Clientes que chamam a API direto"
echo "[egg]             precisam mandar options.num_thread=${CPU_THREADS} na requisicao."

# ----------------------------------------------------------------- download automatico
if [ "${AUTO_PULL}" = "true" ] || [ "${AUTO_PULL}" = "1" ]; then
    if [ -n "${MODEL}" ]; then
        (
            READY_PORT="${OLLAMA_HOST##*:}"
            echo "[egg] Aguardando o servidor subir para baixar '${MODEL}'..."
            for _ in $(seq 1 60); do
                if curl -fsS "http://127.0.0.1:${READY_PORT}/api/tags" >/dev/null 2>&1; then break; fi
                sleep 1
            done
            echo "[egg] Baixando '${MODEL}'... (o progresso aparece no console)"
            if "${OLLAMA_BIN}" pull "${MODEL}"; then
                echo "[egg] Modelo '${MODEL}' pronto para uso."
            else
                echo "[egg] Falha ao baixar '${MODEL}'. Verifique o nome do modelo e o espaco em disco."
            fi
        ) &
    else
        echo "[egg] AUTO_PULL esta ligado mas a variavel MODEL esta vazia - nada sera baixado."
    fi
fi

# ----------------------------------------------------------------- Open WebUI (opcional)
# Segundo painel junto do chat LATAM IA: contas, RAG, RBAC. Precisa de allocation
# propria no painel (OPENWEBUI_PORT). Fala com o MESMO Ollama deste server.
# Os dados (SQLite) ficam em open-webui/ e sobrevivem a restart.
if [ "${OWUI_WANTED}" = "true" ]; then
    OWUI_BIN="${BASE_DIR}/owui-venv/bin/open-webui"
    if [ -x "${OWUI_BIN}" ]; then
        if [ "${OWUI_ONLY}" = "true" ]; then OWUI_PORT="${SERVER_PORT}"; else OWUI_PORT="${OPENWEBUI_PORT:-3000}"; fi
        export DATA_DIR="${BASE_DIR}/open-webui"
        export OLLAMA_BASE_URL="http://127.0.0.1:${OLLAMA_HOST##*:}"
        export WEBUI_NAME="${WEBUI_NAME:-LATAM IA}"
        mkdir -p "${DATA_DIR}"
        echo "[egg] Open WebUI: http://SEU_IP:${OWUI_PORT} (primeiro acesso cria a conta admin)"
        if [ "${OWUI_ONLY}" = "true" ]; then
            echo "[egg]             modo exclusivo: Open WebUI na allocation, Ollama em localhost"
            "${OLLAMA_BIN}" serve &
            exec "${OWUI_BIN}" serve --host 0.0.0.0 --port "${OWUI_PORT}"
        fi
        "${OWUI_BIN}" serve --host 0.0.0.0 --port "${OWUI_PORT}" &
    else
        echo "[egg] AVISO: ENABLE_OPENWEBUI=true mas owui-venv/ nao existe."
        echo "[egg]         Rode Reinstall Server com ENABLE_OPENWEBUI=true para instalar."
    fi
fi

if [ "${UI_ON}" = "true" ]; then
    # Ollama em background (os logs continuam indo pro console do painel, entao o
    # marcador "Listening on" segue funcionando) e o Node em primeiro plano.
    "${OLLAMA_BIN}" serve &
    exec node "${BASE_DIR}/ui/proxy.js"
fi

exec "${OLLAMA_BIN}" serve
