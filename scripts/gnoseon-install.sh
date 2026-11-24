#!/bin/bash
#
# Gnoseon - egg para Pterodactyl / Pelican (painel Open WebUI puro).
# Instalacao como ROOT em python:3.11-slim-bookworm: o Wings grava o
# install.sh em dir root/0700 e imagem nao-root morre "Permission denied".
# Runtime yolk python_3.11 (mesma base = venv portavel). Zero credenciais.
#
set -o pipefail

SERVER_DIR="/mnt/server"
VENV_DIR="${SERVER_DIR}/venv"

echo "=============================================="
echo " Instalacao da egg Gnoseon (Open WebUI puro)"
echo "=============================================="
echo "[egg] server dir : ${SERVER_DIR}"
echo "[egg] arch       : $(uname -m)"

# ---- python: Open WebUI exige 3.11/3.12; pega o caso de imagem trocada na mao
PY="$(command -v python3.11 || command -v python3)"
if [ -z "${PY}" ]; then
    echo "[egg] ERRO: python nao encontrado na imagem de instalacao."
    echo "[egg]       A egg instala em python:3.11-slim-bookworm e roda em"
    echo "[egg]       ghcr.io/parkervcp/yolks:python_3.11."
    exit 1
fi
PYVER="$("${PY}" -c 'import sys; print("%d.%d" % (sys.version_info[0], sys.version_info[1]))')"
case "${PYVER}" in
    3.11 | 3.12)
        echo "[egg] python    : ${PYVER} ($("${PY}" --version 2>&1)) - ok"
        ;;
    *)
        echo "[egg] ERRO: o Open WebUI precisa de Python 3.11 ou 3.12 (imagem atual: ${PYVER})."
        echo "[egg]       A instalacao espera a imagem python:3.11-slim-bookworm e o"
        echo "[egg]       runtime ghcr.io/parkervcp/yolks:python_3.11 - rode Reinstall."
        exit 1
        ;;
esac

# ---- disco: pico ~5 GB na instalacao; depois fica ~4 GB (venv + dados)
AVAIL_MB="$(df -BM --output=avail "${SERVER_DIR}" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${AVAIL_MB}" ] && [ "${AVAIL_MB}" -lt 3500 ]; then
    echo "[egg] ERRO: so tem ${AVAIL_MB} MB livres no disco do server e a"
    echo "[egg]       instalacao precisa de ~5 GB de pico. Aumente o limite"
    echo "[egg]       de disco do servidor no painel e rode Reinstall."
    exit 1
fi
if [ -n "${AVAIL_MB}" ] && [ "${AVAIL_MB}" -lt 5000 ]; then
    echo "[egg] AVISO: so tem ${AVAIL_MB} MB livres; a instalacao fica justa."
fi
echo "[egg] espaco livre: ${AVAIL_MB:-?} MB"

# ---- limpeza da egg antiga (Ollama/Node); data/ fica: contas sobrevivem
for OLD in ollama models .ollama owui-venv .uv .install-tmp gnoseon \
    ollama-start.sh server.js package.json package-lock.json node_modules; do
    rm -rf "${SERVER_DIR:?}/${OLD}"
done

# ---- diretorios
mkdir -p "${SERVER_DIR}/data" "${SERVER_DIR}/temp" "${SERVER_DIR}/gnoseon"

# ---- gcc/g++: a slim nao traz; best-effort (apt falhou = segue com wheels)
if ! command -v gcc >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
    echo "[egg] instalando ferramentas de compilacao (gcc/g++)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq --no-install-recommends gcc g++ make >/dev/null 2>&1 \
        || echo "[egg] AVISO: apt falhou; seguindo so com wheels pre-compilados."
fi

# ---- venv no disco do server (sobrevive ao fim do container de instalacao)
echo "[egg] criando o venv em venv/ ..."
rm -rf "${VENV_DIR}"
if ! "${PY}" -m venv "${VENV_DIR}"; then
    echo "[egg] ERRO: falhou ao criar o venv."
    exit 1
fi
PIP="${VENV_DIR}/bin/pip"
"${PIP}" install --no-cache-dir --quiet --upgrade pip

# /tmp do Wings pode ser tmpfs de 100 MB: TMPDIR vai pro disco do server
# (na instalacao e no runtime - o start script refaz).
export TMPDIR="${SERVER_DIR}/temp"
mkdir -p "${TMPDIR}"

# ---- PyTorch CPU: o wheel do PyPI traz ~4 GB de libs CUDA inutil sem GPU
echo "[egg] instalando PyTorch CPU (economiza ~4 GB de libs CUDA)..."
if ! "${PIP}" install --no-cache-dir --progress-bar off \
        torch --index-url https://download.pytorch.org/whl/cpu; then
    echo "[egg] ERRO: falha ao instalar o PyTorch CPU (rede? disco?)."
    exit 1
fi

# ---- Open WebUI
echo "[egg] instalando o Open WebUI (baixa ~2 GB, pode demorar varios minutos)..."
if ! "${PIP}" install --no-cache-dir --progress-bar off \
        open-webui e2b e2b-code-interpreter; then
    echo "[egg] ERRO: falha ao instalar o Open WebUI (rede? disco?)."
    echo "[egg]       Rode Reinstall Server pra tentar de novo."
    exit 1
fi

# ---- smoke test
SITE_PKG="$("${VENV_DIR}/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
echo "[egg] smoke test..."
"${VENV_DIR}/bin/python" -m uvicorn --version || { echo "[egg] ERRO: uvicorn nao respondeu."; exit 1; }
"${VENV_DIR}/bin/python" -c "import e2b_code_interpreter; print('[egg] SDK e2b ok')" \
    || echo "[egg] AVISO: SDK e2b nao importou (sandbox fica de fora; o chat funciona)."
if [ ! -f "${SITE_PKG}/open_webui/main.py" ]; then
    echo "[egg] ERRO: open_webui/main.py nao encontrado (instalacao incompleta)."
    exit 1
fi
echo "[egg] Open WebUI instalado -> $(du -sh "${VENV_DIR}" 2>/dev/null | cut -f1) em venv/"

# ---- branding: patch tira o sufixo ' (Open WebUI)' do nome (best-effort)
"${VENV_DIR}/bin/python" - <<'GNOS_PATCH_PY'
import glob
import re

hits = glob.glob("/mnt/server/venv/lib/python*/site-packages/open_webui/env.py")
pat = re.compile(
    r"if WEBUI_NAME != ['\"]Open WebUI['\"]:\s*\n\s*WEBUI_NAME \+= ['\"] \(Open WebUI\)['\"]"
)
new = (
    "# Gnoseon: mantem o nome customizado sem sufixo\n"
    "if False:\n"
    '    WEBUI_NAME += " (Open WebUI)"'
)
if not hits:
    print("[egg] branding: env.py do Open WebUI nao encontrado; segue como esta")
for h in hits:
    s = open(h, encoding="utf-8").read()
    s2, n = pat.subn(new, s, count=1)
    if n:
        open(h, "w", encoding="utf-8").write(s2)
        print("[egg] branding: painel vai mostrar so 'Gnoseon'")
    else:
        print("[egg] branding: padrao do sufixo nao encontrado; segue como esta")
GNOS_PATCH_PY

# ---- logo/splash/favicon Gnoseon nos estaticos (rebrand OK ate 50 usuarios)
STATIC_DIR="$(${VENV_DIR}/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')/open_webui/static"
if [ -d "${STATIC_DIR}" ]; then
    cat > "${SERVER_DIR}/gnoseon/favicon.svg" <<'GNOS_FAVICON_SVG'
__GNOS_FAVICON_SVG__
GNOS_FAVICON_SVG
    cat > "${SERVER_DIR}/gnoseon/logo-master.b64" <<'GNOS_LOGO_B64'
__GNOS_LOGO_B64__
GNOS_LOGO_B64
    cat > "${SERVER_DIR}/gnoseon/splash-light.b64" <<'GNOS_SPLASH_B64'
__GNOS_SPLASH_B64__
GNOS_SPLASH_B64
    cat > "${SERVER_DIR}/gnoseon/apply-logo.py" <<'GNOS_LOGO_PY'
import base64
import io
import os
import sys

from PIL import Image

static_dir, gnoseon_dir = sys.argv[1], sys.argv[2]
done = []


def load_image(name):
    raw = "".join(open(os.path.join(gnoseon_dir, name)).read().split())
    return Image.open(io.BytesIO(base64.b64decode(raw)))


art = load_image("logo-master.b64").convert("RGB")
light = load_image("splash-light.b64").convert("RGBA")

art_targets = {
    "logo.png": 500,
    "splash-dark.png": 512,
    "web-app-manifest-512x512.png": 512,
    "web-app-manifest-192x192.png": 192,
    "apple-touch-icon.png": 180,
    "favicon.png": 256,
    "favicon-96x96.png": 96,
}
for name, size in art_targets.items():
    path = os.path.join(static_dir, name)
    if os.path.exists(path):
        art.resize((size, size), Image.LANCZOS).save(path, optimize=True)
        done.append(name)

ico = os.path.join(static_dir, "favicon.ico")
if os.path.exists(ico):
    art.resize((64, 64), Image.LANCZOS).save(ico, sizes=[(16, 16), (32, 32), (48, 48)])
    done.append("favicon.ico")

splash = os.path.join(static_dir, "splash.png")
if os.path.exists(splash):
    light.save(splash, optimize=True)
    done.append("splash.png")

svg_src = os.path.join(gnoseon_dir, "favicon.svg")
svg_dst = os.path.join(static_dir, "favicon.svg")
if os.path.exists(svg_dst) and os.path.exists(svg_src):
    with open(svg_src, encoding="utf-8") as f:
        content = f.read()
    with open(svg_dst, "w", encoding="utf-8") as f:
        f.write(content)
    done.append("favicon.svg")

wm = os.path.join(static_dir, "site.webmanifest")
if os.path.exists(wm):
    with open(wm, encoding="utf-8") as f:
        s = f.read()
    s = s.replace('"name": "Open WebUI"', '"name": "Gnoseon"')
    s = s.replace('"short_name": "WebUI"', '"short_name": "Gnoseon"')
    s = s.replace('"theme_color": "#ffffff"', '"theme_color": "#0a0a12"')
    s = s.replace('"background_color": "#ffffff"', '"background_color": "#0a0a12"')
    with open(wm, "w", encoding="utf-8") as f:
        f.write(s)
    done.append("site.webmanifest")

print("[egg] marca Gnoseon aplicada em: " + (", ".join(done) if done else "nada encontrado"))
GNOS_LOGO_PY
    "${VENV_DIR}/bin/python" "${SERVER_DIR}/gnoseon/apply-logo.py" "${STATIC_DIR}" "${SERVER_DIR}/gnoseon"
    FRONTEND_DIR="$(${VENV_DIR}/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')/open_webui/frontend"
    if [ -f "${FRONTEND_DIR}/index.html" ]; then
        sed -i 's|<title>Open WebUI</title>|<title>Gnoseon</title>|' "${FRONTEND_DIR}/index.html" \
            && echo "[egg] titulo da aba: Gnoseon"
    fi
else
    echo "[egg] AVISO: static do Open WebUI nao encontrado; logo nao aplicada"
fi

# ---- E2B nativo no Code Execution: Jupyter URL "e2b://KEY" roda na nuvem
# (patch best-effort: compila em temp antes; versao nova = patch ignorado)
"${VENV_DIR}/bin/python" - <<'GNOS_E2B_NATIVE'
import glob
import os
import py_compile
import tempfile

PATCH = r'''
# ==== Gnoseon: engine E2B no Code Execution (patch install) ====
_gnoseon_orig_execute_code_jupyter = execute_code_jupyter


async def execute_code_jupyter(base_url, code, token="", password="", timeout=60):
    """Override Gnoseon: URL 'e2b://API_KEY' executa o codigo na sandbox E2B."""
    try:
        if not base_url or not str(base_url).startswith("e2b://"):
            return await _gnoseon_orig_execute_code_jupyter(base_url, code, token, password, timeout)
        api_key = str(base_url)[6:].strip()
        t = max(30, int(timeout or 60))
        from e2b_code_interpreter import AsyncSandbox

        sbx = await AsyncSandbox.create(api_key=api_key, timeout=t + 30)
        try:
            execution = await sbx.run_code(code, timeout=t)
        finally:
            try:
                await sbx.kill()
            except Exception:
                pass
        out = {"stdout": "", "stderr": "", "result": ""}
        if execution is None:
            out["stderr"] = "E2B: execucao sem resultado"
            return out
        out["stdout"] = "\n".join(execution.logs.stdout or []).strip()
        err = "\n".join(execution.logs.stderr or []).strip()
        if execution.error:
            err = (err + "\n" + str(execution.error)).strip()
        out["stderr"] = err
        parts = []
        for res in (execution.results or []):
            for mime, attr in (
                ("image/png", "png"),
                ("image/jpeg", "jpeg"),
                ("image/svg+xml", "svg"),
            ):
                b64data = getattr(res, attr, None)
                if b64data:
                    parts.append("data:" + mime + ";base64," + b64data)
                    break
            else:
                txt = getattr(res, "text", None) or getattr(res, "markdown", None)
                if txt:
                    parts.append(str(txt))
        out["result"] = "\n".join(parts).strip()
        return out
    except Exception as e:
        logger.exception("Gnoseon: execucao E2B falhou")
        return {"stdout": "", "stderr": "E2B error: " + str(e), "result": ""}
'''

hits = glob.glob("/mnt/server/venv/lib/python*/site-packages/open_webui/utils/code_interpreter.py")
if not hits:
    print("[egg] e2b nativo: code_interpreter.py nao encontrado; segue sem patch")
for h in hits:
    src = open(h, encoding="utf-8").read()
    if "Gnoseon: engine E2B no Code Execution" in src:
        print("[egg] e2b nativo: patch ja presente")
        continue
    if "async def execute_code_jupyter" not in src:
        print("[egg] e2b nativo: execute_code_jupyter mudou nesta versao; segue sem patch")
        continue
    tmp = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, encoding="utf-8")
    try:
        tmp.write(src + PATCH)
        tmp.close()
        py_compile.compile(tmp.name, doraise=True)
    except Exception as e:
        print("[egg] e2b nativo: patch nao compila nesta versao; ignorado (" + str(e)[:120] + ")")
        continue
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
    with open(h, "a", encoding="utf-8") as f:
        f.write(PATCH)
    print("[egg] e2b nativo: patch aplicado - Admin > Configuracoes > Code Execution > URL e2b://KEY")
GNOS_E2B_NATIVE

# ---- tool 'Sandbox E2B' (function calling): chave nas Valves ou e2b://KEY
cat > "${SERVER_DIR}/gnoseon/e2b-tool.json" <<'GNOS_TOOL_JSON'
__GNOS_TOOL_JSON__
GNOS_TOOL_JSON
if ! "${VENV_DIR}/bin/python" -c "import json; json.load(open('${SERVER_DIR}/gnoseon/e2b-tool.json'))" >/dev/null 2>&1; then
    echo "[egg] AVISO: o JSON da tool E2B chegou invalido; importe a tool manualmente depois."
else
    echo "[egg] tool 'Sandbox E2B' pronta em gnoseon/e2b-tool.json"
fi

# Bootstrap: registra a tool no banco quando a 1a conta (admin) existir
cat > "${SERVER_DIR}/gnoseon/install-e2b-tool.py" <<'GNOS_E2B_BOOT'
#!/usr/bin/env python3
"""Gnoseon: registra a tool 'Sandbox E2B' no banco do Open WebUI assim que a
primeira conta (admin) existir - sem variavel de credencial. Best-effort: se
o schema mudar, o aviso cai no console e resta o import manual (Workspace >
Ferramentas > Importar > gnoseon/e2b-tool.json)."""
import json
import os
import sqlite3
import sys
import time

HC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.environ.get("DATA_DIR") or os.path.join(HC, "data")
DB_PATH = os.path.join(DATA_DIR, "webui.db")
TOOL_JSON = os.path.join(HC, "gnoseon", "e2b-tool.json")
TOOL_ID = "e2b_sandbox"
TOOL_NAME = "Sandbox E2B"

FALLBACK_SPEC = [{
    "type": "function",
    "function": {
        "name": "e2b_run_python",
        "description": "Executa codigo Python em uma sandbox isolada na nuvem (E2B) e devolve a saida real.",
        "parameters": {
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "Codigo Python completo para executar na sandbox.",
                }
            },
            "required": ["code"],
        },
    },
}]

FALLBACK_MANIFEST = {
    "title": TOOL_NAME,
    "description": "Executa código Python numa sandbox segura na nuvem (E2B).",
    "version": "1.2.0",
}


def log(msg):
    print("[gnoseon][e2b] " + msg, flush=True)


def wait_for_first_user(timeout_s):
    """Espera a primeira conta do painel (a primeira criada vira admin)."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if os.path.exists(DB_PATH):
            try:
                con = sqlite3.connect(DB_PATH, timeout=10)
                try:
                    row = con.execute(
                        "select id from user order by created_at asc limit 1"
                    ).fetchone()
                    if row:
                        return row[0]
                finally:
                    con.close()
            except sqlite3.Error:
                pass  # migracoes ainda rodando ou db ocupada: tenta de novo
        time.sleep(5)
    return None


def compute_specs(content):
    """Gera as specs pelo proprio open-webui (mesmo caminho da criacao pela UI)."""
    import asyncio

    from open_webui.utils.plugin import load_tool_module_by_id
    from open_webui.utils.tools import get_tool_specs

    module, frontmatter, _src = asyncio.run(load_tool_module_by_id(TOOL_ID, content=content))
    return get_tool_specs(module), frontmatter


def insert_tool(user_id, content, specs, meta):
    con = sqlite3.connect(DB_PATH, timeout=20)
    try:
        cols = {r[1] for r in con.execute("PRAGMA table_info(tool)")}
        required = {"id", "user_id", "name", "content", "specs", "meta", "updated_at", "created_at"}
        missing = required - cols
        if missing:
            raise RuntimeError("colunas ausentes na tabela tool: " + ", ".join(sorted(missing)))
        if con.execute("select 1 from tool where id = ?", (TOOL_ID,)).fetchone():
            return "existe"
        now = int(time.time())
        row = {
            "id": TOOL_ID,
            "version_id": None,
            "user_id": user_id,
            "name": TOOL_NAME,
            "content": content,
            "specs": json.dumps(specs),
            "meta": json.dumps(meta),
            "valves": None,
            "is_active": 1,
            "updated_at": now,
            "created_at": now,
        }
        data = {k: v for k, v in row.items() if k in cols}
        con.execute(
            "INSERT INTO tool (" + ", ".join(data) + ") VALUES (" + ", ".join(["?"] * len(data)) + ")",
            list(data.values()),
        )
        con.commit()
        return "ok"
    finally:
        con.close()


def main():
    try:
        if not os.path.exists(TOOL_JSON):
            log("e2b-tool.json nao encontrado; pulando registro automatico")
            return 1
        with open(TOOL_JSON, encoding="utf-8") as f:
            tool = json.load(f)
        content = tool["content"]
        log("aguardando a primeira conta do painel (a primeira criada vira admin)...")
        user_id = wait_for_first_user(7200)
        if not user_id:
            log("nenhuma conta criada; importe manual: Workspace > Ferramentas > Importar > gnoseon/e2b-tool.json")
            return 1
        try:
            specs, frontmatter = compute_specs(content)
        except Exception as e:
            log("specs via open-webui falhou (" + str(e) + "); usando fallback")
            specs, frontmatter = None, None
        if not specs:
            specs = FALLBACK_SPEC
        meta = {
            "description": FALLBACK_MANIFEST["description"],
            "manifest": frontmatter if isinstance(frontmatter, dict) and frontmatter else FALLBACK_MANIFEST,
            "has_user_valves": True,
        }
        result = insert_tool(user_id, content, specs, meta)
        if result == "ok":
            log("tool '" + TOOL_NAME + "' registrada no painel (Workspace > Ferramentas).")
            log("E2B nativo: Admin > Configuracoes > Code Execution -> engine Jupyter + URL e2b://KEY")
            log("ou ponha a chave e2b.dev nas Valves da tool e ative ela no modelo.")
        else:
            log("tool '" + TOOL_NAME + "' ja registrada no painel")
        return 0
    except Exception as e:
        log("registro automatico falhou (" + str(e) + "); importe manual: Workspace > Ferramentas > Importar > gnoseon/e2b-tool.json")
        return 1


if __name__ == "__main__":
    sys.exit(main())
GNOS_E2B_BOOT

# ---- script de inicializacao
cat > "${SERVER_DIR}/gnoseon-start.sh" <<'GNOS_START_EOF'
#!/bin/bash
# =====================================================================
#  Gnoseon - painel de chat (Open WebUI puro, sem Ollama local)
#  Os modelos vem de uma API externa /v1 configurada no PROPRIO PAINEL:
#  - a PRIMEIRA conta criada no painel (http://IP:PORTA) vira Admin;
#  - a chave dos modelos: Admin > Configuracoes > Conexoes (URL /v1 + key);
#  - sandbox E2B nativa: Admin > Configuracoes > Code Execution ->
#    engine Jupyter + Jupyter URL = e2b://SUA_KEY (roda no Code Interpreter);
#  - ou a tool 'Sandbox E2B' (function calling): Valves em Workspace > Ferramentas.
# =====================================================================
set -u
HC="/home/container"
cd "$HC" || exit 1
mkdir -p "$HC/data" "$HC/temp" || exit 1

PORT="${SERVER_PORT:-8080}"
VENV_PY="$HC/venv/bin/python"

if [ ! -x "$VENV_PY" ]; then
    echo "[gnoseon] ERRO: venv nao encontrado em $HC/venv."
    echo "[gnoseon]          Rode Reinstall Server pra reinstalar."
    exit 1
fi

# ------------------------------------------------ ambiente do painel
export DATA_DIR="$HC/data"
export TMPDIR="$HC/temp"
export ENV="prod"
export WEBUI_NAME="Gnoseon"
export DO_NOT_TRACK="true"
# banco travado no disco do server: algumas hospedagens injetam DATABASE_URL
# no container e isso quebra o painel - aqui vale sempre o SQLite local
export DATABASE_URL="sqlite:///${HC}/data/webui.db"

# FROM_INIT_PY: so o 'open-webui serve' seta isso (modo wheel). Com uvicorn
# direto fica False e morre com "Static asset source directory not found"
# (procura assets de DEV). True = assets do wheel; nao move o DATA_DIR.
export FROM_INIT_PY="true"

# WEBUI_SECRET_KEY: exigida pelo open-webui 0.13+ quando o backend sobe
# via uvicorn. Gerado na 1a rodada e persistido em data/ (trocar desloga).
SK_FILE="$HC/data/webui-secret-key"
if [ ! -s "$SK_FILE" ]; then
    "$VENV_PY" -c 'import secrets; print(secrets.token_hex(32))' > "$SK_FILE"
    chmod 600 "$SK_FILE" 2>/dev/null || true
fi
export WEBUI_SECRET_KEY="$(cat "$SK_FILE")"

echo "=============================================="
echo " Gnoseon - painel de chat"
echo " http://IP:${PORT}  (a primeira conta criada vira Admin)"
echo " Modelos: Admin > Configuracoes > Conexoes (URL /v1 + key)"
echo " Sandbox E2B nativa: Admin > Configuracoes > Code Execution"
echo "   -> engine Jupyter + Jupyter URL = e2b://SUA_KEY_E2B"
echo "=============================================="

# registra a tool Sandbox E2B no banco assim que a 1a conta (admin) existir
if [ -f "$HC/gnoseon/install-e2b-tool.py" ]; then
    "$VENV_PY" "$HC/gnoseon/install-e2b-tool.py" &
fi

# O open-webui 0.13+ engole o banner do uvicorn no meio do boot (e sem a
# linha "Uvicorn running" o Wings deixaria o server preso em 'Starting').
# Este vigia consulta o /health local e imprime a linha do done marker.
(
    i=0
    while [ "$i" -lt 300 ]; do
        if "$VENV_PY" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${PORT}/health', timeout=5)" >/dev/null 2>&1; then
            echo "[gnoseon] Painel no ar em http://IP:${PORT} (a primeira conta criada vira Admin)"
            exit 0
        fi
        i=$((i + 1))
        sleep 2
    done
    echo "[gnoseon] AVISO: o painel nao respondeu ao /health em 10 min - veja os erros acima."
) &

# Direto pelo python do venv: os console-scripts apontam pro caminho do
# container de instalacao. python -m uvicorn ignora isso.
exec "$VENV_PY" -m uvicorn open_webui.main:app \
    --host 0.0.0.0 \
    --port "$PORT" \
    --forwarded-allow-ips "*" \
    --no-access-log
GNOS_START_EOF
chmod +x "${SERVER_DIR}/gnoseon-start.sh"

# ---- permissoes: instalacao ROOT, runtime 'container'; sem isso nao grava
echo "[egg] ajustando permissoes p/ o runtime..."
chmod -R a+rwX "${SERVER_DIR}" 2>/dev/null || true

# ---- resumo
echo "=============================================="
echo "[egg] Instalacao concluida."
echo "[egg] painel   : http://IP:PORTA - a PRIMEIRA conta criada vira Admin"
echo "[egg] marca    : logo, splash e favicon Gnoseon aplicados no painel"
echo "[egg] modelos  : chave e URL /v1 dentro do painel (Admin > Configuracoes > Conexoes)"
echo "[egg] sandbox  : E2B nativa no Code Execution (engine Jupyter + URL e2b://KEY)"
echo "[egg]           ou tool 'Sandbox E2B' (Workspace > Ferramentas > Valves)"
echo "[egg] dados    : /home/container/data (contas e conversas sobrevivem ao Reinstall)"
echo "[egg] startup  : /home/container/gnoseon-start.sh"
echo "=============================================="
exit 0
