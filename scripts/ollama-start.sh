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

# Com o Open WebUI ligado, ele ocupa a allocation publica e o Ollama fica so em
# 127.0.0.1 (porta interna nao precisa de allocation no Pterodactyl). Sem ele, a
# propria API do Ollama e quem atende a porta publica.
OWUI_SERVE="false"
OWUI_WANTED="false"
if [ "${ENABLE_OPENWEBUI}" = "true" ] || [ "${ENABLE_OPENWEBUI}" = "1" ]; then OWUI_WANTED="true"; fi
if [ "${OWUI_WANTED}" = "true" ] && [ -x "${BASE_DIR}/owui-venv/bin/open-webui" ]; then
    OWUI_SERVE="true"
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
# Defaults de memoria NO SCRIPT, nao so na egg. Se a variavel chegar vazia o
# Ollama decide sozinho, e o que ele decide mata o processo: medido num server
# pequeno sem CONTEXT_LENGTH nem KV_CACHE_TYPE -> n_ctx 4096, flash_attn auto,
# "CPU KV buffer size = 448.00 MiB" e em seguida
#   Load failed ... llama-server process has terminated: signal: killed
# ou seja, o kernel matou por falta de RAM. O sintoma do lado do usuario e o
# chat simplesmente parar de responder, sem erro na tela.
CONTEXT_LENGTH="${CONTEXT_LENGTH:-2048}"
KV_CACHE_TYPE="${KV_CACHE_TYPE:-q8_0}"
FLASH_ATTENTION="${FLASH_ATTENTION:-1}"
export OLLAMA_CONTEXT_LENGTH="${CONTEXT_LENGTH}"
export OLLAMA_KV_CACHE_TYPE="${KV_CACHE_TYPE}"
# O cache de prompt do llama-server guarda uma copia do estado de cada conversa na
# RAM (medido: 87 MB por ~800 tokens) e o padrao dele e 8192 MiB - IGNORANDO o
# limite do container. Num server de 8 GB com Open WebUI isso e receita para OOM.
# O Ollama nao tem variavel propria, mas o llama-server le LLAMA_ARG_CACHE_RAM
# (declarado em --help como env da flag --cache-ram). Verificado no v0.34.0:
# com LLAMA_ARG_CACHE_RAM=256 o log passou a dizer "size limit: 256 MiB".
# Default no script, nao so na egg: quem atualiza so o start script pelo curl
# (sem reimportar a egg) tambem precisa sair do teto de 8192 MiB.
CACHE_RAM="${CACHE_RAM:-512}"
export LLAMA_ARG_CACHE_RAM="${CACHE_RAM}"
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
if [ "${OWUI_SERVE}" = "true" ]; then
    echo "[egg] interface : porta publica ${SERVER_PORT} -> Open WebUI em http://SEU_IP:${SERVER_PORT}/"
fi
echo "[egg] models    : ${OLLAMA_MODELS}"
echo "[egg] cache     : prompt ${CACHE_RAM:-8192 (padrao do llama-server!)} MiB | K/V ${KV_CACHE_TYPE:-f16}"

# Limite de memoria DESTE container. Nao da para usar MemTotal nem SERVER_MEMORY
# sozinho: o Ollama mede "inference compute" pelo total da MAQUINA, entao ele acha
# que cabe o que nao cabe. O cgroup e a unica fonte confiavel.
# MEM_LIMIT_MB vindo de fora (raro) tem preferencia; senao lemos o cgroup.
if [ -z "${MEM_LIMIT_MB}" ]; then
    for _f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [ -r "${_f}" ] || continue
        _v="$(head -1 "${_f}" 2>/dev/null | tr -dc '0-9')"
        [ -z "${_v}" ] && continue
        _mb=$(( _v / 1048576 ))
        # cgroup v1 sem limite devolve um numero absurdo (~9.2e18); > 1 PB = ilimitado
        [ "${_mb}" -gt 1048576 ] && continue
        MEM_LIMIT_MB="${_mb}"
        break
    done
fi
[ -z "${MEM_LIMIT_MB}" ] && MEM_LIMIT_MB="${SERVER_MEMORY}"
echo "[egg] memoria   : ${MEM_LIMIT_MB:-?} MB (limite do container)"
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
# 'auto' (padrao), vazio, 0 ou qualquer valor que nao seja numero: usa o teto do
# container. De proposito: "0" na aba Startup nao dizia nada para quem le.
case "${CPU_THREADS}" in
    ""|0|auto|AUTO|Auto) CPU_THREADS="" ;;
    *[!0-9]*)            CPU_THREADS="" ;;
esac
[ -z "${CPU_THREADS}" ] && CPU_THREADS="${NCPU}"
if [ "${CPU_THREADS}" -gt "${NCPU}" ] 2>/dev/null; then
    echo "[egg] AVISO: CPU_THREADS=${CPU_THREADS} mas o container so ve ${NCPU} vCPU."
    echo "[egg]         Mais threads que nucleos causa thrashing e derruba a velocidade."
    echo "[egg]         Ajustando para ${NCPU}. Modelos <3B costumam render melhor com 4-8."
    CPU_THREADS="${NCPU}"
fi
export CPU_THREADS
echo "[egg] threads   : ${CPU_THREADS} (vCPU visiveis: ${NCPU})"
echo "[egg]             sera gravado como 'num_thread' dentro de cada modelo, entao vale"
echo "[egg]             para qualquer cliente - inclusive o Open WebUI, que nao manda esse"
echo "[egg]             parametro (o Ollama nao tem variavel de ambiente para threads)."

# ----------------------------------------------------------------- teto de threads
# Ollama NAO tem variavel de ambiente para threads. Verificado no binario v0.34.0:
# nao existe nenhuma OLLAMA_*THREAD* e a string "CPU_THREADS" aparece 0 vezes.
# OMP_NUM_THREADS tambem e ignorado (medido: com OMP_NUM_THREADS=2 o runner seguiu
# em n_threads=1). O unico jeito de o teto valer para QUALQUER cliente e gravar
# "PARAMETER num_thread" dentro do proprio modelo.
#
# Isso importa porque o Open WebUI nao manda num_thread: sem o parametro gravado,
# o Ollama usa o que nproc diz - e num container limitado por quota CFS o nproc
# reporta TODAS as cores do host (ex.: 10 num server de "200% CPU / 2 cores").
# Muitas threads para pouca quota = thrashing + throttle a cada 100 ms, e a
# geracao fica tao lenta que parece travada.
# Conferencia de memoria: modelo no disco + interface precisam caber no cgroup.
# Sem isso o usuario so descobre no susto, quando o chat para de responder porque
# o kernel esta matando/trocando processo.
check_memory() {
    [ -z "${MEM_LIMIT_MB}" ] && return 0
    # O que carrega na RAM e UM modelo por vez (MAX_LOADED_MODELS=1), entao a
    # conta certa e o MAIOR modelo instalado - somar todos daria alarme falso
    # em quem tem varios modelos baixados.
    _model_mb="$("${OLLAMA_BIN}" list 2>/dev/null | awk '
        NR>1 && $3 ~ /^[0-9]+(\.[0-9]+)?$/ {
            m = ($4=="TB") ? 1048576 : ($4=="GB") ? 1024 : ($4=="KB") ? 1/1024 : 1
            mb = $3 * m
            if (mb > max) max = mb
        } END { printf "%d", max }')"
    [ -z "${_model_mb}" ] || [ "${_model_mb}" = "0" ] && \
        _model_mb="$(du -sm "${OLLAMA_MODELS}/blobs" 2>/dev/null | awk '{print $1}')"
    [ -z "${_model_mb}" ] && return 0
    _reserva=300
    [ "${OWUI_SERVE}" = "true" ] && _reserva=1300   # Open WebUI: ~700 MB-1 GB medido
    _precisa=$(( _model_mb + _reserva ))
    echo "[egg] memoria   : maior modelo ${_model_mb} MB + reserva ${_reserva} MB = ${_precisa} MB"
    echo "[egg]             limite do container: ${MEM_LIMIT_MB} MB"
    if [ "${_precisa}" -gt "${MEM_LIMIT_MB}" ]; then
        echo "[egg] AVISO: NAO CABE. Faltam $(( _precisa - MEM_LIMIT_MB )) MB."
        echo "[egg]         O chat vai travar ou o kernel vai matar o processo (OOM)."
        echo "[egg]         Opcoes: modelo menor (ex.: 0.6b em vez de 7b), ou"
        echo "[egg]         ENABLE_OPENWEBUI=false, ou mais RAM no painel."
    fi
}

bake_threads() {
    _mf="${TMPDIR}/Modelfile.threads"
    for _m in $("${OLLAMA_BIN}" list 2>/dev/null | awk 'NR>1 && $1 ~ /:/ {print $1}'); do
        if "${OLLAMA_BIN}" show "${_m}" 2>/dev/null \
             | grep -qE "^[[:space:]]*num_thread[[:space:]]+${CPU_THREADS}([^0-9]|$)"; then
            continue
        fi
        printf 'FROM %s\nPARAMETER num_thread %s\n' "${_m}" "${CPU_THREADS}" > "${_mf}"
        if "${OLLAMA_BIN}" create "${_m}" -f "${_mf}" >/dev/null 2>&1; then
            echo "[egg] ${_m}: num_thread=${CPU_THREADS} gravado no modelo"
        else
            echo "[egg] AVISO: nao consegui gravar num_thread em ${_m}."
        fi
    done
    rm -f "${_mf}"
}

# Em background: espera o Ollama responder, baixa o modelo pedido e grava o teto
# de threads em todos os modelos presentes.
(
    READY_PORT="${OLLAMA_HOST##*:}"
    for _ in $(seq 1 60); do
        if curl -fsS "http://127.0.0.1:${READY_PORT}/api/tags" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    if [ "${AUTO_PULL}" = "true" ] || [ "${AUTO_PULL}" = "1" ]; then
        if [ -n "${MODEL}" ]; then
            echo "[egg] Baixando '${MODEL}'... (o progresso aparece no console)"
            if "${OLLAMA_BIN}" pull "${MODEL}"; then
                echo "[egg] Modelo '${MODEL}' pronto para uso."
            else
                echo "[egg] Falha ao baixar '${MODEL}'. Verifique o nome e o espaco em disco."
            fi
        else
            echo "[egg] AUTO_PULL ligado mas MODEL esta vazio - nada sera baixado."
        fi
    fi
    bake_threads
    check_memory
) &

# ----------------------------------------------------------------- Open WebUI (opcional)
# A interface web: contas, RAG, historico. Ocupa a allocation do server e fala com
# o Ollama em localhost. Os dados (SQLite) ficam em open-webui/ e sobrevivem a
# restart e a reinstall.
#
# O venv do Open WebUI e criado na INSTALACAO, onde o diretorio do server e
# /mnt/server. Em runtime o MESMO diretorio e montado em /home/container, e o uv
# grava caminhos absolutos em tres lugares: o shebang dos executaveis de bin/, o
# symlink bin/python e o "home" do pyvenv.cfg. Sem corrigir, o shebang aponta para
# um interpretador que nao existe e o kernel responde "cannot execute: required
# file not found" - o server cai na hora. A funcao abaixo reescreve o prefixo para
# o BASE_DIR real. Roda em todo start, e idempotente (na segunda vez o prefixo ja
# bate e ela nao faz nada) e conserta instalacoes antigas sem baixar nada de novo.
owui_fix_paths() {
    _venv="${BASE_DIR}/owui-venv"
    _cfg="${_venv}/pyvenv.cfg"
    [ -f "${_cfg}" ] || return 0
    _old_home="$(sed -n 's/^home = //p' "${_cfg}" | head -1)"
    # prefixo gravado na instalacao, deduzido do "home" do pyvenv.cfg
    _old_prefix=""
    case "${_old_home}" in
        */.uv/*)             _old_prefix="${_old_home%%/.uv/*}" ;;
        */.local/share/uv/*) _old_prefix="${_old_home%%/.local/share/uv/*}" ;;
    esac
    [ -n "${_old_prefix}" ] || return 0
    if [ "${_old_prefix}" = "${BASE_DIR}" ]; then return 0; fi
    _new_home="${BASE_DIR}${_old_home#"${_old_prefix}"}"
    echo "[egg] Open WebUI: ajustando caminhos do venv (${_old_prefix} -> ${BASE_DIR})"

    # 1) SYMLINKS ABSOLUTOS - o passo que faltava. O uv cria um atalho
    #    .uv/python/cpython-3.11-linux-x86_64-gnu -> <prefixo>/.uv/python/cpython-3.11.X-...
    #    e ele e ABSOLUTO. Sem repointar, o caminho novo resolve de volta pro
    #    prefixo antigo e o start morre com "required file not found".
    _sym=0
    for _dir in "${BASE_DIR}/.uv" "${_venv}"; do
        [ -d "${_dir}" ] || continue
        while IFS= read -r _s; do
            _t="$(readlink "${_s}" 2>/dev/null)" || continue
            case "${_t}" in
                "${_old_prefix}"/*)
                    ln -sfn "${BASE_DIR}${_t#"${_old_prefix}"}" "${_s}"
                    _sym=$(( _sym + 1 ))
                    ;;
            esac
        done < <(find "${_dir}" -type l 2>/dev/null)
    done

    # 2) pyvenv.cfg
    sed -i "s#^home = .*#home = ${_new_home}#" "${_cfg}"

    # 3) shebangs dos executaveis (delimitador @ porque o padrao contem "#!")
    _she=0
    for _f in "${_venv}"/bin/*; do
        [ -f "${_f}" ] && [ ! -L "${_f}" ] || continue
        case "$(head -1 "${_f}" 2>/dev/null)" in
            "#!${_old_prefix}/"*)
                sed -i "1s@^#!${_old_prefix}/@#!${BASE_DIR}/@" "${_f}"
                _she=$(( _she + 1 ))
                ;;
        esac
    done

    # 4) scripts de activate (nao usamos, mas deixa consistente)
    for _a in "${_venv}/bin/activate" "${_venv}/bin/activate.csh" \
              "${_venv}/bin/activate.fish" "${_venv}/bin/activate.nu" \
              "${_venv}/bin/activate.bat"; do
        [ -f "${_a}" ] && sed -i "s#${_old_prefix}/#${BASE_DIR}/#g" "${_a}"
    done

    # 5) confere que o interpretador resolve; senao procura outro 3.11 no server
    if [ ! -x "${_new_home}/python3.11" ]; then
        _found=""
        for _c in "${BASE_DIR}"/.uv/python/cpython-3.11*/bin/python3.11 \
                  "${BASE_DIR}"/.local/share/uv/python/cpython-3.11*/bin/python3.11; do
            [ -x "${_c}" ] && { _found="${_c}"; break; }
        done
        if [ -n "${_found}" ]; then
            _new_home="$(dirname "${_found}")"
            sed -i "s#^home = .*#home = ${_new_home}#" "${_cfg}"
            ln -sfn "${_found}" "${_venv}/bin/python"
        fi
    fi
    if [ ! -x "${_new_home}/python3.11" ]; then
        echo "[egg] AVISO: nao achei Python 3.11 dentro de ${BASE_DIR}."
        echo "[egg]         Provavelmente foi instalado fora do diretorio do server e"
        echo "[egg]         nao sobreviveu. Apague owui-venv/ e .uv/ e rode Reinstall."
        return 0
    fi
    echo "[egg]             ${_sym} symlink(s) + ${_she} shebang(s) + pyvenv.cfg"
}

if [ "${OWUI_WANTED}" = "true" ]; then
    OWUI_BIN="${BASE_DIR}/owui-venv/bin/open-webui"
    if [ -x "${OWUI_BIN}" ]; then
        owui_fix_paths
        export DATA_DIR="${BASE_DIR}/open-webui"
        export OLLAMA_BASE_URL="http://127.0.0.1:${OLLAMA_HOST##*:}"
        export WEBUI_NAME="${WEBUI_NAME:-LATAM IA}"
        # O Open WebUI vem com criacao de API key DESLIGADA (config.py:
        # ENABLE_API_KEYS default False) e responde 403 "API key creation is not
        # allowed in the environment". Como o Ollama agora so escuta em localhost,
        # o /api/v1 do Open WebUI e a unica API compativel com OpenAI exposta na
        # allocation - entao liga por padrao. Ponto de entrada: Settings > Account
        # > API Keys, e a URL fica http://SEU_IP:${SERVER_PORT}/api/v1.
        export ENABLE_API_KEYS="${ENABLE_API_KEYS:-true}"
        mkdir -p "${DATA_DIR}"
        echo "[egg] Open WebUI: http://SEU_IP:${SERVER_PORT} (primeiro acesso cria a conta admin)"
        # Ollama em background (os logs continuam indo pro console do painel, entao
        # o marcador "Listening on" segue funcionando) e o Open WebUI em primeiro
        # plano segurando a allocation.
        "${OLLAMA_BIN}" serve &
        exec "${OWUI_BIN}" serve --host 0.0.0.0 --port "${SERVER_PORT}"
    else
        echo "[egg] AVISO: ENABLE_OPENWEBUI=true mas owui-venv/ nao existe."
        echo "[egg]         Rode Reinstall Server com ENABLE_OPENWEBUI=true para instalar."
    fi
fi

exec "${OLLAMA_BIN}" serve
