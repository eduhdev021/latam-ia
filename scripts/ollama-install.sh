#!/bin/bash
#
# Ollama egg - script de instalacao (Pterodactyl / Pelican)
# Roda como root num container descartavel; os arquivos do server estao em /mnt/server.
# As variaveis da egg chegam aqui como variaveis de ambiente (o Wings faz isso).
#
set -o pipefail

SERVER_DIR="/mnt/server"
OLLAMA_DIR="${SERVER_DIR}/ollama"
BIN_DIR="${OLLAMA_DIR}/bin"
LIB_DIR="${OLLAMA_DIR}/lib/ollama"

echo "=============================================="
echo " Instalacao da egg Ollama"
echo "=============================================="
echo "[egg] server dir : ${SERVER_DIR}"
echo "[egg] arch       : $(uname -m)"

# --------------------------------------------------------------- dependencias
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
    curl ca-certificates zstd tar xz-utils jq >/dev/null 2>&1 || true

for DEP in curl zstd tar; do
    if ! command -v "${DEP}" >/dev/null 2>&1; then
        echo "[egg] ERRO: '${DEP}' nao esta disponivel no container de instalacao."
        exit 1
    fi
done

case "$(uname -m)" in
    x86_64)          ASSET_ARCH="amd64" ;;
    aarch64 | arm64) ASSET_ARCH="arm64" ;;
    *)
        echo "[egg] ERRO: arquitetura '$(uname -m)' nao tem build oficial do Ollama."
        exit 1
        ;;
esac

# --------------------------------------------------------------- versao
VERSION="${OLLAMA_VERSION:-latest}"
if [ "${VERSION}" = "latest" ] || [ -z "${VERSION}" ]; then
    VERSION="$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d '"' -f 4)"
fi
if [ -z "${VERSION}" ]; then
    echo "[egg] ERRO: nao foi possivel resolver a versao do Ollama (GitHub fora do ar?)."
    exit 1
fi
echo "[egg] versao     : ${VERSION}"

# --------------------------------------------------------------- download
# ATENCAO: o Wings monta /tmp do container de instalacao como tmpfs de 100 MB
# (config.yml: docker.tmpfs_size), entao NAO da pra baixar o tarball la.
# Trabalhamos dentro do proprio diretorio do server e limpamos no final.
BASE_URL="https://github.com/ollama/ollama/releases/download/${VERSION}"
WORK="${SERVER_DIR}/.install-tmp"
rm -rf "${WORK}"
mkdir -p "${WORK}" || exit 1
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1

AVAIL_MB="$(df -BM --output=avail "${SERVER_DIR}" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${AVAIL_MB}" ] && [ "${AVAIL_MB}" -lt 4500 ]; then
    echo "[egg] AVISO: so tem ${AVAIL_MB} MB livres no disco do server."
    echo "[egg]        a instalacao precisa de ~4.5 GB de pico (download + extracao)"
    echo "[egg]        e depois fica em ~300 MB. Aumente o limite de disco no painel."
fi
echo "[egg] espaco livre: ${AVAIL_MB:-?} MB"

ASSET=""
for CANDIDATE in "ollama-linux-${ASSET_ARCH}.tar.zst" "ollama-linux-${ASSET_ARCH}.tgz"; do
    if curl -fsSLI -o /dev/null "${BASE_URL}/${CANDIDATE}"; then
        ASSET="${CANDIDATE}"
        break
    fi
done
if [ -z "${ASSET}" ]; then
    echo "[egg] ERRO: nenhum asset encontrado em ${BASE_URL}"
    echo "[egg]       confira se a variavel OLLAMA_VERSION esta certa (ex.: v0.34.0)."
    exit 1
fi

echo "[egg] baixando ${ASSET} (1.3 GB+ no amd64, aguarde)..."
if ! curl -fL --retry 3 --retry-delay 5 -o "${ASSET}" "${BASE_URL}/${ASSET}"; then
    echo "[egg] ERRO: falha no download de ${ASSET}"
    exit 1
fi
echo "[egg] download concluido: $(du -h "${ASSET}" | cut -f1)"

# --------------------------------------------------------------- checksum (melhor esforco)
if curl -fsSL -o sha256sum.txt "${BASE_URL}/sha256sum.txt" 2>/dev/null; then
    EXPECTED="$(grep -m1 " ${ASSET}\$" sha256sum.txt | awk '{print $1}')"
    if [ -n "${EXPECTED}" ]; then
        ACTUAL="$(sha256sum "${ASSET}" | awk '{print $1}')"
        if [ "${EXPECTED}" = "${ACTUAL}" ]; then
            echo "[egg] checksum OK (${ACTUAL:0:16}...)"
        else
            echo "[egg] ERRO: checksum confere nao."
            echo "[egg]   esperado: ${EXPECTED}"
            echo "[egg]   obtido  : ${ACTUAL}"
            exit 1
        fi
    fi
fi

# --------------------------------------------------------------- extracao
echo "[egg] extraindo em ${OLLAMA_DIR} ..."
rm -rf "${BIN_DIR}" "${LIB_DIR}"
mkdir -p "${BIN_DIR}" "${LIB_DIR}"

case "${ASSET}" in
    *.tar.zst) zstd -dc "${ASSET}" | tar -xf - -C "${OLLAMA_DIR}" ;;
    *.tgz)     tar -xzf "${ASSET}" -C "${OLLAMA_DIR}" ;;
esac
if [ ! -f "${BIN_DIR}/ollama" ]; then
    echo "[egg] ERRO: extracao nao produziu ${BIN_DIR}/ollama"
    echo "[egg] conteudo encontrado:"
    find "${OLLAMA_DIR}" -maxdepth 2 | head -20
    exit 1
fi
chmod +x "${BIN_DIR}/ollama"
echo "${VERSION}" > "${OLLAMA_DIR}/VERSION"
rm -f "${ASSET}"

# --------------------------------------------------------------- remover libs de GPU
# O Pterodactyl nao repassa GPU pro container, entao CUDA/ROCm/Vulkan/MLX so ocupam disco.
if [ "${STRIP_GPU_LIBS:-true}" = "true" ]; then
    BEFORE="$(du -sh "${OLLAMA_DIR}" 2>/dev/null | cut -f1)"
    find "${OLLAMA_DIR}/lib" -mindepth 1 -maxdepth 2 -type d \
        \( -iname '*cuda*' -o -iname '*rocm*' -o -iname '*vulkan*' -o -iname '*mlx*' -o -iname '*jetpack*' \) \
        -exec rm -rf {} + 2>/dev/null
    find "${OLLAMA_DIR}/lib" -mindepth 1 -maxdepth 2 -type f \
        \( -iname '*cuda*' -o -iname '*rocm*' -o -iname '*vulkan*' -o -iname '*mlx*' -o -iname '*jetpack*' -o -iname '*rocblas*' \) \
        -delete 2>/dev/null
    echo "[egg] libs de GPU removidas: ${BEFORE} -> $(du -sh "${OLLAMA_DIR}" | cut -f1)"
fi

# --------------------------------------------------------------- bibliotecas externas
# Nao e preciso copiar nada de sistema: as .so do Ollama usam RUNPATH=$ORIGIN e so
# dependem de libc/libstdc++/libgomp (a libgomp ja vem dentro de lib/ollama).
# Verificado no v0.34.0: nenhum arquivo do build CPU referencia OpenBLAS.
MISSING="$(ldd "${LIB_DIR}"/libggml-cpu-*.so 2>/dev/null | grep 'not found' | sort -u)"
if [ -n "${MISSING}" ]; then
    echo "[egg] AVISO: bibliotecas ausentes detectadas:"
    echo "${MISSING}"
else
    echo "[egg] bibliotecas do build CPU resolvidas (nada faltando)."
fi

# --------------------------------------------------------------- diretorios de runtime
mkdir -p "${SERVER_DIR}/models" "${SERVER_DIR}/.ollama" "${SERVER_DIR}/temp" "${SERVER_DIR}/ui"

# --------------------------------------------------------------- interface web (sidecar)
# O chat vem do Git, entao da pra atualizar sem reinstalar a egg inteira.
# Repo publico: nao precisa de credencial dentro do servidor.
UI_REPO="${UI_REPO:-https://github.com/eduhdev021/latam-ia.git}"
UI_REF="${UI_REF:-main}"
UI_FROM_GIT="false"

command -v git >/dev/null 2>&1 || apt-get install -y --no-install-recommends git >/dev/null 2>&1 || true
if command -v git >/dev/null 2>&1; then
    echo "[egg] buscando o chat em ${UI_REPO} (${UI_REF})..."
    rm -rf "${WORK}/ui-repo"
    if git clone --depth 1 --branch "${UI_REF}" "${UI_REPO}" "${WORK}/ui-repo" >/dev/null 2>&1; then
        if [ -f "${WORK}/ui-repo/scripts/ui-chat.html" ] && [ -f "${WORK}/ui-repo/scripts/ui-proxy.js" ]; then
            cp "${WORK}/ui-repo/scripts/ui-chat.html" "${SERVER_DIR}/ui/chat.html"
            cp "${WORK}/ui-repo/scripts/ui-proxy.js"  "${SERVER_DIR}/ui/proxy.js"
            # Logo opcional: sem ele o chat cai no "L" de sempre.
            cp "${WORK}/ui-repo/assets/logo-192.png" "${SERVER_DIR}/ui/logo-192.png" 2>/dev/null || true
            cp "${WORK}/ui-repo/assets/logo-512.png" "${SERVER_DIR}/ui/logo-512.png" 2>/dev/null || true
            git -C "${WORK}/ui-repo" rev-parse --short HEAD > "${SERVER_DIR}/ui/.git-ref" 2>/dev/null || true
            UI_FROM_GIT="true"
            echo "[egg] chat instalado do Git (commit $(cat "${SERVER_DIR}/ui/.git-ref" 2>/dev/null || echo '?'))"
        else
            echo "[egg] AVISO: o repo nao tem scripts/ui-chat.html e scripts/ui-proxy.js."
        fi
    else
        echo "[egg] AVISO: git clone falhou (repo fora do ar? branch '${UI_REF}' existe?)."
    fi
else
    echo "[egg] AVISO: git indisponivel no container de instalacao."
fi

# Sem Git nao da para trazer o chat: ele tem ~90 KB e o painel do Pterodactyl
# corta o script da egg em ~64 KiB (medido: 65614 bytes), entao embutir o chat
# aqui quebra o instalador com "here-document ... wanted CHATEOF".
# O caminho do Git e o unico suportado. Sem ele o server sobe como API pura.
# Sem o Git a instalacao nao pode continuar: o script de inicializacao tambem
# vem de la (nao cabe embutido na egg, veja o comentario mais abaixo).
if [ "${UI_FROM_GIT}" != "true" ]; then
    echo "[egg] ERRO: nao foi possivel baixar os arquivos do Git."
    echo "[egg]       Repo : ${UI_REPO}"
    echo "[egg]       Branch: ${UI_REF}"
    echo "[egg]       Causa provavel: git indisponivel no container de instalacao,"
    echo "[egg]       repo fora do ar, ou a branch nao existe."
    echo "[egg]       Confira UI_REPO e UI_REF na aba Startup e rode Reinstall Server."
    exit 1
fi

if [ "${UI_FROM_GIT}" = "true" ]; then
    echo "true" > "${SERVER_DIR}/ui/.enabled"
    echo "[egg] interface web em /home/container/ui/ (git=true)"
else
    rm -f "${SERVER_DIR}/ui/.enabled"
fi

# --------------------------------------------------------------- script de inicializacao
# Nao e mais um heredoc dentro do instalador: o script vem do Git, igual ao chat.
# Motivo: o painel do Pterodactyl corta o script da egg em ~64 KiB, e com o chat
# e o start script embutidos o instalador passava de 117 KB e chegava truncado
# no container (erro "here-document ... wanted CHATEOF").
if [ ! -f "${WORK}/ui-repo/scripts/ollama-start.sh" ]; then
    echo "[egg] ERRO: o repo nao tem scripts/ollama-start.sh."
    echo "[egg]       Esse arquivo e obrigatorio - e ele que sobe o Ollama."
    exit 1
fi
cp "${WORK}/ui-repo/scripts/ollama-start.sh" "${SERVER_DIR}/ollama-start.sh"
echo "[egg] start script instalado do Git"
chmod +x "${SERVER_DIR}/ollama-start.sh"

# --------------------------------------------------------------- smoke test
echo "[egg] smoke test: subindo 'ollama serve' por alguns segundos..."
export OLLAMA_MODELS="${WORK}/smoke-models"
export OLLAMA_HOME="${WORK}/smoke-home"
export OLLAMA_HOST="127.0.0.1:11499"
export LD_LIBRARY_PATH="${LIB_DIR}"
mkdir -p "${OLLAMA_MODELS}" "${OLLAMA_HOME}"

"${BIN_DIR}/ollama" serve > "${WORK}/smoke.log" 2>&1 &
SMOKE_PID=$!
SMOKE_OK="no"
for _ in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:11499/api/version" >/dev/null 2>&1; then SMOKE_OK="yes"; break; fi
    sleep 0.5
done
if [ "${SMOKE_OK}" = "yes" ]; then
    echo "[egg] smoke test OK -> $(curl -fsS http://127.0.0.1:11499/api/version)"
else
    echo "[egg] AVISO: o smoke test nao respondeu. Log do ollama:"
    tail -25 "${WORK}/smoke.log" 2>/dev/null || true
fi
kill "${SMOKE_PID}" >/dev/null 2>&1
wait "${SMOKE_PID}" 2>/dev/null

# --------------------------------------------------------------- resumo
echo "=============================================="
echo "[egg] Instalacao concluida."
echo "[egg] binario  : /home/container/ollama/bin/ollama"
echo "[egg] modelos  : /home/container/models"
echo "[egg] startup  : /home/container/ollama-start.sh"
echo "[egg] Lembre de dar disco suficiente pro modelo (${MODEL:-modelo nao definido})."
echo "=============================================="
exit 0
