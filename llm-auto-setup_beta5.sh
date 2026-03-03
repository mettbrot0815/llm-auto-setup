#!/usr/bin/env bash
# =============================================================================
#
#   ██╗      ███████╗  ███████╗ ██████╗ ██╗         ██╗     ██╗     ███╗   ██╗
#   ██║     ██╔═══██╗██╔════╝██╔═══██╗██║        ██╔╝     ██║     ████╗  ██║
#   ██║     ██║   ██║██║     ██║   ██║██║       ██╔╝      ██║     ██╔██╗ ██║
#   ██║     ██║   ██║██║     ██║   ██║██║      ██╔╝       ██║     ██║╚██╗██║
#   ███████╗╚██████╔╝╚██████╗╚██████╔╝███████╗██╔╝        ███████╗██║ ╚████║
#   ╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝╚═╝         ╚══════╝╚═╝  ╚═══╝
#
#   AUTO-SETUP  v6.0.0  ·  Universal Edition
#   ────────────────────────────────────────────────────────────────────────────
#   Scans hardware → picks best model → installs the full stack.
#   No HuggingFace token required. All models from public bartowski repos.
#
#   Supports: Ubuntu 22.04/24.04 · Debian 12 · Linux Mint 21+ · Pop!_OS
#             WSL2 · CPU-only · NVIDIA CUDA · AMD ROCm · Intel Arc
#   ────────────────────────────────────────────────────────────────────────────
#   Core stack:  Ollama v0.12.3 (LOCKED) · llama-cpp-python
#                Open WebUI (port 8080)  · Neural Terminal (port 8090)
#                cowork (Open Interpreter) · aider
#   Optional:    Claude Code · OpenAI Codex · PentestAgent
#                tmux · CLI tools · GPU monitor
#   ────────────────────────────────────────────────────────────────────────────
#   ⚠  Ollama is locked to v0.12.3 — v0.12.4+ breaks GPU offload on RTX 30xx
# =============================================================================

set -uo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
readonly SCRIPT_VERSION="6.0.0"
readonly SCRIPT_INSTALL_PATH="$HOME/.config/local-llm/llm-auto-setup.sh"
readonly LOG_FILE="$HOME/llm-auto-setup-$(date +%Y%m%d-%H%M%S).log"

# Paths
readonly VENV_DIR="$HOME/.local/share/llm-venv"
readonly OWUI_VENV="$HOME/.local/share/open-webui-venv"
readonly OI_VENV="$HOME/.local/share/open-interpreter-venv"
readonly AI_VENV="$HOME/.local/share/aider-venv"
readonly MODEL_BASE="$HOME/local-llm-models"
readonly OLLAMA_MODELS="$MODEL_BASE/ollama"
readonly GGUF_MODELS="$MODEL_BASE/gguf"
readonly TEMP_DIR="$MODEL_BASE/temp"
readonly BIN_DIR="$HOME/.local/bin"
readonly CONFIG_DIR="$HOME/.config/local-llm"
readonly GUI_DIR="$HOME/.local/share/llm-webui"
readonly MODEL_CONFIG="$CONFIG_DIR/selected_model.conf"
readonly ALIAS_FILE="$HOME/.local_llm_aliases"
readonly WORK_DIR="$HOME/work"
readonly PKG_CACHE_DIR="$HOME/.cache/llm-setup"

# Ollama locked to 0.12.3 — RTX 3060 / Ampere GPU offload regression in 0.12.4+
readonly OLLAMA_LOCKED_VER="0.12.3"
readonly OLLAMA_LOCKED_URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_LOCKED_VER}/ollama-linux-amd64"

# Environment
export DEBIAN_FRONTEND=noninteractive
export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1
export PIP_CACHE_DIR="$PKG_CACHE_DIR/pip"
export npm_config_cache="$PKG_CACHE_DIR/npm"

mkdir -p "$PKG_CACHE_DIR/pip" "$PKG_CACHE_DIR/npm" "$HOME"
mkdir -p "$(dirname "$LOG_FILE")"

# =============================================================================
# COLORS  (auto-disabled when stdout is not a tty)
# =============================================================================
if [[ -t 1 ]]; then
    BOLD='\033[1m';     DIM='\033[2m';      NC='\033[0m'
    RED='\033[0;31m';   GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    ACCENT='\033[38;5;39m'    # sky-blue    — primary highlight
    ACCENT2='\033[38;5;82m'   # lime-green  — success
    MUTED='\033[38;5;240m'    # mid-grey    — secondary text
    WARN_COL='\033[38;5;214m' # amber       — warnings
    ERR_COL='\033[38;5;196m'  # red         — errors
    STEP_COL='\033[38;5;105m' # purple      — step headers
else
    BOLD=''; DIM=''; NC=''
    RED=''; GREEN=''; YELLOW=''; CYAN=''
    ACCENT=''; ACCENT2=''; MUTED=''; WARN_COL=''; ERR_COL=''; STEP_COL=''
fi

_TW=$(( $(tput cols 2>/dev/null || echo 80) ))
(( _TW < 60  )) && _TW=60
(( _TW > 120 )) && _TW=120
_rule() { local ch="${1:--}" col="${2:-$MUTED}"; printf "${col}"; printf '%*s' "$_TW" '' | tr ' ' "${ch}"; printf "${NC}\n"; }

# =============================================================================
# LOGGING
# =============================================================================
exec > >(tee -a "$LOG_FILE") 2>&1

_STEP_N=0
_STEP_TOTAL=19

log()   { printf '%s %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2 || true; }
info()  { printf "  ${ACCENT2}✓${NC}  %b\n" "$*"; }
warn()  { printf "  ${WARN_COL}⚠${NC}  ${WARN_COL}%b${NC}\n" "$*"; log "[WARN]  $*"; }
error() {
    printf "\n"
    _rule "═" "${ERR_COL}"
    printf "  ${ERR_COL}${BOLD}✗  FATAL ERROR${NC}  %b\n" "$*"
    printf "  ${MUTED}Log: %s${NC}\n" "$LOG_FILE"
    _rule "═" "${ERR_COL}"
    log "[ERROR] $*"
    exit 1
}

step() {
    (( _STEP_N++ )) || true
    printf "\n"
    _rule "─" "${STEP_COL}"
    printf "${STEP_COL}${BOLD}  STEP %d/%d  │  %b${NC}\n" "$_STEP_N" "$_STEP_TOTAL" "$*"
    _rule "─" "${STEP_COL}"
}

highlight() { printf "\n${BOLD}${ACCENT}  ◇  %b${NC}\n" "$*"; }

# =============================================================================
# PROGRESS BAR
# =============================================================================
_pbar() {
    [[ ! -t 1 ]] && return
    local pct="${1:-0}" label="${2:-}" filled empty bar emp
    (( pct > 100 )) && pct=100
    (( pct < 0   )) && pct=0
    filled=$(( pct * 40 / 100 ))
    empty=$(( 40 - filled ))
    bar="$(printf '%*s' "$filled" '' | tr ' ' '█')"
    emp="$(printf '%*s' "$empty"  '' | tr ' ' '░')"
    printf "\r  ${ACCENT}[${ACCENT2}%s%s${ACCENT}]${NC} ${BOLD}%3d%%${NC}  %-30s" \
           "$bar" "$emp" "$pct" "${label:0:30}"
}
_pbar_done() { [[ -t 1 ]] && printf "\n"; }

# Long-running pip install: background progress ticker (0→95 % over duration)
_pip_with_ticker() {
    local label="$1"; shift
    local pip_cmd=("$@")
    (
        local p=2
        while kill -0 "$$" 2>/dev/null; do
            _pbar "$p" "$label"
            p=$(( p >= 95 ? 95 : p + 1 ))
            sleep 6
        done
    ) &
    local _tick=$!
    "${pip_cmd[@]}" >> "$LOG_FILE" 2>&1
    local _rc=$?
    kill "$_tick" 2>/dev/null; wait "$_tick" 2>/dev/null || true
    _pbar 100 "$label"; _pbar_done
    return $_rc
}

# Download with live percentage (aria2c preferred, curl fallback, wget last)
_download() {
    local url="$1" dest="$2" label="${3:-Downloading}"
    info "$label → $(basename "$dest")"

    # skip if already downloaded and non-empty
    if [[ -f "$dest" ]] && [[ $(stat -c%s "$dest" 2>/dev/null || echo 0) -gt 1048576 ]]; then
        info "Already on disk ($(du -sh "$dest" | cut -f1)) — skipping download."
        return 0
    fi

    if command -v aria2c &>/dev/null; then
        aria2c --split=8 --max-connection-per-server=8 \
               --min-split-size=20M --continue=true \
               --file-allocation=none \
               --console-log-level=warn \
               -o "$(basename "$dest")" -d "$(dirname "$dest")" "$url" 2>&1 | \
            grep -E '^Download|^\[#|%' | while IFS= read -r _l; do
                local _p; _p=$(printf '%s' "$_l" | grep -oP '\d+%' | tr -d '%' | tail -1 || true)
                [[ -n "$_p" ]] && _pbar "$_p" "$label"
            done
        local _rc="${PIPESTATUS[0]:-0}"
        _pbar_done
        (( _rc == 0 )) && return 0
        warn "aria2c failed (rc=$_rc) — trying curl."
    fi

    if command -v curl &>/dev/null; then
        curl -L -C - --fail --progress-bar -o "$dest" "$url" 2>&1 | \
            while IFS= read -r _l; do
                local _p; _p=$(printf '%s' "$_l" | grep -oP '^\s*\K\d+(?=\.\d+%)' | head -1 || true)
                [[ -n "$_p" ]] && _pbar "$_p" "$label"
            done
        local _rc="${PIPESTATUS[0]:-1}"
        _pbar_done
        (( _rc == 0 )) && return 0
        warn "curl failed (rc=$_rc) — trying wget."
    fi

    if command -v wget &>/dev/null; then
        wget -c --progress=dot:mega -O "$dest" "$url" 2>&1 | \
            while IFS= read -r _l; do
                local _p; _p=$(printf '%s' "$_l" | grep -oP '\d+%' | tr -d '%' | tail -1 || true)
                [[ -n "$_p" ]] && _pbar "$_p" "$label"
            done
        local _rc="${PIPESTATUS[0]:-1}"
        _pbar_done
        (( _rc == 0 )) && return 0
    fi

    error "All download methods failed for: $url"
}

# retry <attempts> <delay> <cmd...>
retry() {
    local n="$1" d="$2"; shift 2
    local i=1
    while true; do
        "$@" && return 0
        (( i >= n )) && { warn "Failed after $n attempts: $*"; return 1; }
        warn "Attempt $i/$n failed — retrying in ${d}s…"
        sleep "$d"; (( i++ ))
    done
}

# apt install list with per-package progress bar (sudo-aware)
_apt_install() {
    local pkgs=("$@") total=${#@} idx=0 pkg
    (( total == 0 )) && return 0
    for pkg in "${pkgs[@]}"; do
        (( idx++ ))
        _pbar $(( idx * 100 / total )) "apt: $pkg"
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends "$pkg" \
            >> "$LOG_FILE" 2>&1 \
            || { _pbar_done; warn "apt: $pkg failed (non-fatal)"; }
    done
    _pbar_done
}

# ask_yes_no <prompt> → 0=yes 1=no
ask_yes_no() {
    local ans=""
    if [[ ! -t 0 ]]; then warn "Non-interactive — answering No for: $1"; return 1; fi
    printf "  ${ACCENT}?${NC}  ${BOLD}%s${NC} ${MUTED}[y/N]${NC} " "$1"
    read -r -n1 ans; printf "\n"
    [[ "$ans" =~ ^[Yy]$ ]]
}

is_wsl2()        { grep -qi microsoft /proc/version 2>/dev/null; }
get_distro_id()  { grep -m1 '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo unknown; }
get_codename()   { grep -m1 '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || lsb_release -sc 2>/dev/null || echo unknown; }

ollama_running() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
wait_ollama() {
    local max="${1:-20}" i=0
    while (( i < max )); do
        ollama_running && return 0
        sleep 1; (( i++ ))
    done
    return 1
}
start_ollama_if_needed() {
    ollama_running && return 0
    info "Starting Ollama…"
    if is_wsl2; then
        nohup ollama serve > "$HOME/.ollama.log" 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null || nohup ollama serve > "$HOME/.ollama.log" 2>&1 &
    fi
    wait_ollama 25 || warn "Ollama didn't respond in 25s."
}

# ensure a venv exists; creates/heals it if missing or broken
_ensure_venv() {
    local venv="$1"
    if [[ ! -x "$venv/bin/python3" ]]; then
        info "Creating venv: $(basename "$venv")"
        "${PYTHON_BIN:-python3}" -m venv --clear "$venv" >> "$LOG_FILE" 2>&1 \
            || error "Failed to create venv: $venv"
        "$venv/bin/python3" -m ensurepip --upgrade >> "$LOG_FILE" 2>&1 || true
        "$venv/bin/pip" install --quiet --upgrade pip "setuptools>=70" wheel >> "$LOG_FILE" 2>&1 || true
    fi
}

# =============================================================================
# WELCOME BANNER
# =============================================================================
_print_banner() {
    clear 2>/dev/null || true
    printf "\n${ACCENT}${BOLD}"
    echo "  ██╗      ███████╗  ███████╗ ██████╗ ██╗         ██╗     ██╗     ███╗   ██╗"
    echo "  ██║     ██╔═══██╗██╔════╝██╔═══██╗██║        ██╔╝     ██║     ████╗  ██║"
    echo "  ██║     ██║   ██║██║     ██║   ██║██║       ██╔╝      ██║     ██╔██╗ ██║"
    echo "  ██║     ██║   ██║██║     ██║   ██║██║      ██╔╝       ██║     ██║╚██╗██║"
    echo "  ███████╗╚██████╔╝╚██████╗╚██████╔╝███████╗██╔╝        ███████╗██║ ╚████║"
    echo "  ╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝╚═╝         ╚══════╝╚═╝  ╚═══╝"
    printf "${NC}\n"
    _rule "─" "$MUTED"
    printf "  ${BOLD}%-28s${NC}  ${MUTED}v%s  ·  Universal Edition${NC}\n" "Local LLM Auto-Setup" "$SCRIPT_VERSION"
    printf "  ${MUTED}Ubuntu/Debian/WSL2  ·  NVIDIA CUDA · AMD ROCm · CPU-only · Intel Arc${NC}\n"
    _rule "─" "$MUTED"
    printf "\n"
    printf "  ${MUTED}Core:${NC}  Ollama v%s (locked) · Open WebUI · Neural Terminal\n" "$OLLAMA_LOCKED_VER"
    printf "  ${MUTED}      ${NC}  cowork (Open Interpreter) · aider\n"
    printf "  ${MUTED}Opt: ${NC}  Claude Code · OpenAI Codex · PentestAgent · CLI tools\n"
    printf "\n"
    printf "  ${WARN_COL}⚠  Ollama locked to v%s — v0.12.4+ breaks GPU offload on RTX 30xx${NC}\n" "$OLLAMA_LOCKED_VER"
    printf "\n"
    _rule "─" "$MUTED"
    printf "  ${MUTED}Log:  %s${NC}\n" "$LOG_FILE"
    _rule "─" "$MUTED"
    printf "\n"
}
_print_banner

# =============================================================================
# STEP 1 — PRE-FLIGHT
# =============================================================================
step "Pre-flight checks"

[[ "${EUID:-0}" -eq 0 ]] && error "Do not run as root. Use a normal user with sudo."
command -v sudo &>/dev/null || error "sudo not found. Install it first."

# Architecture
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64)  info "Architecture: x86_64 ✓" ;;
    aarch64) warn "ARM64 detected — CUDA pre-built wheels unavailable; source build will be used." ;;
    *)       warn "Untested architecture: $HOST_ARCH — proceeding anyway." ;;
esac

# Distro detection
DISTRO_ID=$(get_distro_id)
DISTRO_CODENAME=$(get_codename)
UBUNTU_VER=$(lsb_release -rs 2>/dev/null \
    || grep -oP '(?<=^VERSION_ID=")[0-9.]+' /etc/os-release 2>/dev/null \
    || echo "unknown")
info "Distro: $DISTRO_ID $UBUNTU_VER ($DISTRO_CODENAME) on $HOST_ARCH"
case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|neon|elementary|zorin|kali|parrot) ;;
    *) warn "Distro '$DISTRO_ID' not officially tested — apt paths assumed." ;;
esac

# Single sudo prompt + keepalive
printf "\n  ${ACCENT}❯${NC}  ${BOLD}Administrator access required${NC} (apt · systemd · GPU drivers)\n\n"
sudo -v || error "sudo authentication failed."
( while true; do sleep 50; sudo -v 2>/dev/null; done ) &
readonly SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; trap - EXIT INT TERM' EXIT INT TERM
info "sudo keepalive active."

# Internet check
if curl -fsSL --max-time 5 https://huggingface.co >/dev/null 2>&1 \
    || curl -fsSL --max-time 5 https://pypi.org >/dev/null 2>&1; then
    info "Internet: reachable"
else
    warn "Internet appears unreachable — downloads may fail."
fi

info "Pre-flight complete."

# =============================================================================
# STEP 2 — HARDWARE DETECTION
# =============================================================================
step "Hardware detection"

# CPU
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown CPU")
CPU_THREADS=$(nproc 2>/dev/null || echo 4)
HW_THREADS=$(( CPU_THREADS > 16 ? 16 : CPU_THREADS ))

CPU_FLAGS=$(grep -m1 '^flags\|^Features' /proc/cpuinfo 2>/dev/null || echo "")
HAS_AVX512=0; [[ "$CPU_FLAGS" =~ (^| )avx512f($| ) ]] && HAS_AVX512=1
HAS_AVX2=0;   [[ "$CPU_FLAGS" =~ (^| )avx2($| )   ]] && HAS_AVX2=1
HAS_AVX=0;    [[ "$CPU_FLAGS" =~ (^| )avx($| )    ]] && HAS_AVX=1
HAS_NEON=0;   [[ "$HOST_ARCH" == "aarch64"         ]] && HAS_NEON=1

# RAM
TOTAL_RAM_KB=$(grep MemTotal     /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 4194304)
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 2097152)
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
AVAIL_RAM_GB=$(( AVAIL_RAM_KB / 1024 / 1024 ))
(( TOTAL_RAM_GB < 1 )) && TOTAL_RAM_GB=4
(( AVAIL_RAM_GB < 1 )) && AVAIL_RAM_GB=2

# GPU — NVIDIA
HAS_NVIDIA=0; HAS_AMD=0; HAS_INTEL=0; HAS_GPU=0
GPU_NAME="None"; GPU_VRAM_MIB=0; GPU_VRAM_GB=0
DRIVER_VER="N/A"; CUDA_VER_SMI=""

if command -v nvidia-smi &>/dev/null; then
    _best=0
    while IFS= read -r _mib; do
        _mib="${_mib// /}"
        [[ "$_mib" =~ ^[0-9]+$ ]] && (( _mib > _best )) && _best=$_mib
    done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true)
    _cnt=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo 1)
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
    (( _cnt > 1 )) && GPU_NAME="${_cnt}x ${GPU_NAME}"
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "N/A")
    CUDA_VER_SMI=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -1 || echo "")
    if (( _best > 500 )); then
        HAS_NVIDIA=1; HAS_GPU=1
        GPU_VRAM_MIB=$_best
        GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
    fi
    unset _best _cnt
fi

# GPU — AMD
if (( !HAS_NVIDIA )); then
    _best_amd=0
    for _sf in /sys/class/drm/card*/device/mem_info_vram_total; do
        [[ -f "$_sf" ]] || continue
        _b=$(< "$_sf" 2>/dev/null || echo 0)
        _m=$(( _b / 1024 / 1024 ))
        (( _m > _best_amd && _m > 512 )) && _best_amd=$_m
    done
    if (( _best_amd > 512 )); then
        GPU_VRAM_MIB=$_best_amd; GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
        HAS_AMD=1; HAS_GPU=1
        GPU_NAME=$(lspci 2>/dev/null | grep -iE "VGA|Display|3D" | grep -iE "AMD|ATI|Radeon|gfx" \
                   | head -1 | sed 's/.*: //' | xargs || echo "AMD GPU")
        DRIVER_VER=$(< /sys/class/drm/card0/device/driver/module/version 2>/dev/null || echo "N/A")
    fi
    unset _best_amd _sf _b _m
fi

# GPU — Intel Arc
if (( !HAS_NVIDIA && !HAS_AMD )); then
    if lspci 2>/dev/null | grep -qiE "Intel.*Arc|Intel.*Xe"; then
        HAS_INTEL=1
        GPU_NAME=$(lspci 2>/dev/null | grep -iE "Intel.*Arc|Intel.*Xe" | head -1 | sed 's/.*: //' | xargs || echo "Intel Arc")
    fi
fi

# Disk
DISK_FREE_GB=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo 20)

# SIMD string
_simd="baseline"
(( HAS_AVX512 )) && _simd="AVX-512 / AVX2 / AVX"
[[ "$_simd" == "baseline" ]] && (( HAS_AVX2 )) && _simd="AVX2 / AVX"
[[ "$_simd" == "baseline" ]] && (( HAS_AVX  )) && _simd="AVX"
[[ "$_simd" == "baseline" ]] && (( HAS_NEON )) && _simd="NEON (ARM64)"

# Hardware summary box
printf "\n"
printf "  ${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}\n"
printf "  ${CYAN}║          HARDWARE SCAN RESULTS                    ║${NC}\n"
printf "  ${CYAN}╠════════════════════════════════════════════════════════════════╣${NC}\n"
printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "CPU"      "${CPU_MODEL:0:35}"
printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "Threads"  "${CPU_THREADS} logical  (build: ${HW_THREADS})"
printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "SIMD"     "$_simd"
printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "RAM"      "${TOTAL_RAM_GB} GB total / ${AVAIL_RAM_GB} GB free"
printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "GPU"      "${GPU_NAME:0:35}"
if (( HAS_NVIDIA )); then
    printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "VRAM"   "${GPU_VRAM_GB} GB (${GPU_VRAM_MIB} MiB)"
    printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "Driver" "${DRIVER_VER}"
    [[ -n "$CUDA_VER_SMI" ]] && \
        printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "CUDA SMI" "$CUDA_VER_SMI"
elif (( HAS_AMD )); then
    printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "VRAM"   "${GPU_VRAM_GB} GB (${GPU_VRAM_MIB} MiB)"
    printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "Driver" "${DRIVER_VER}"
elif (( HAS_INTEL )); then
    printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "Note"   "Intel Arc — CPU tiers used"
fi
printf "  ${CYAN}║${NC}  %-12s  %-35s${CYAN}║${NC}\n" "Disk free" "${DISK_FREE_GB} GB"
printf "  ${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
printf "\n"
unset _simd

# =============================================================================
# COMPATIBILITY CHECKS
# =============================================================================
printf "  ${BOLD}${ACCENT}Compatibility checks${NC}\n\n"
_COMPAT_WARN=0

# NVIDIA driver age
if (( HAS_NVIDIA )); then
    _dmaj=$(echo "$DRIVER_VER" | cut -d. -f1 2>/dev/null || echo 0)
    if (( _dmaj > 0 && _dmaj < 450 )); then
        printf "  ${ERR_COL}✗${NC}  NVIDIA driver %s too old (need ≥450) — run: sudo ubuntu-drivers autoinstall\n" "$DRIVER_VER"
        (( _COMPAT_WARN++ ))
    else
        printf "  ${ACCENT2}✓${NC}  NVIDIA driver %s\n" "$DRIVER_VER"
    fi
    unset _dmaj
fi

# Ollama version lock warning
if command -v ollama &>/dev/null; then
    _ov=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
    if [[ "$_ov" != "$OLLAMA_LOCKED_VER" ]]; then
        printf "  ${WARN_COL}⚠${NC}  Ollama %s detected — will downgrade to %s (RTX 30xx fix)\n" "$_ov" "$OLLAMA_LOCKED_VER"
        (( _COMPAT_WARN++ ))
    else
        printf "  ${ACCENT2}✓${NC}  Ollama %s (locked version)\n" "$_ov"
    fi
    unset _ov
fi

# zstd
command -v zstd &>/dev/null \
    && printf "  ${ACCENT2}✓${NC}  zstd present\n" \
    || { printf "  ${WARN_COL}⚠${NC}  zstd missing — will be installed before Ollama\n"; (( _COMPAT_WARN++ )); }

# Disk
(( DISK_FREE_GB < 15 )) \
    && { printf "  ${WARN_COL}⚠${NC}  Only %d GB free — large model downloads may fail\n" "$DISK_FREE_GB"; (( _COMPAT_WARN++ )); } \
    || printf "  ${ACCENT2}✓${NC}  Disk: %d GB free\n" "$DISK_FREE_GB"

# WSL2 GPU
is_wsl2 && printf "  ${WARN_COL}⚠${NC}  WSL2: GPU passthrough requires driver ≥525 and WSL2 kernel ≥5.15\n"

printf "\n"
(( _COMPAT_WARN == 0 )) \
    && printf "  ${ACCENT2}✓${NC}  All compatibility checks passed\n\n" \
    || printf "  ${WARN_COL}⚠${NC}  %d compatibility warning(s) — see above\n\n" "$_COMPAT_WARN"
unset _COMPAT_WARN

# =============================================================================
# STEP 3 — MODEL SELECTION
# =============================================================================
step "Model selection"

VRAM_HEADROOM_MIB=1400
VRAM_USABLE_MIB=$(( GPU_VRAM_MIB - VRAM_HEADROOM_MIB ))
(( VRAM_USABLE_MIB < 0 )) && VRAM_USABLE_MIB=0

gpu_layers_for() {
    local size_gb="$1" num_layers="$2"
    local model_mib=$(( size_gb * 1024 ))
    if (( model_mib <= VRAM_USABLE_MIB )); then
        echo "-1"; return
    fi
    local mib_per=$(( model_mib / num_layers ))
    (( mib_per < 1 )) && mib_per=1
    local layers=$(( VRAM_USABLE_MIB / mib_per ))
    (( layers > num_layers )) && layers=$num_layers
    (( layers < 0 ))          && layers=0
    echo "$layers"
}

declare -A M  # chosen model fields

select_model() {
    local vram=$GPU_VRAM_GB ram=$TOTAL_RAM_GB
    # GPU tiers
    if (( HAS_GPU && vram >= 48 )); then
        highlight "≥48 GB VRAM → Llama-3.3-70B Q4_K_M [TOOLS] ★"
        M[name]="Llama-3.3-70B-Instruct Q4_K_M";      M[caps]="TOOLS"
        M[file]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M[size_gb]=40; M[layers]=80; M[tier]="70B"
    elif (( HAS_GPU && vram >= 24 )); then
        highlight "≥24 GB VRAM → Qwen3-32B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-32B Q4_K_M";                    M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
        M[size_gb]=19; M[layers]=64; M[tier]="32B"
    elif (( HAS_GPU && vram >= 16 )); then
        highlight "≥16 GB VRAM → Mistral-Small-3.2-24B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Mistral-Small-3.2-24B Q4_K_M";        M[caps]="TOOLS + THINK"
        M[file]="mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
        M[size_gb]=14; M[layers]=40; M[tier]="24B"
    elif (( HAS_GPU && vram >= 12 )); then
        highlight "≥12 GB VRAM → Qwen3-14B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-14B Q4_K_M";                    M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[size_gb]=9;  M[layers]=40; M[tier]="14B"
    elif (( HAS_GPU && vram >= 10 )); then
        highlight "≥10 GB VRAM → Phi-4-14B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Phi-4-14B Q4_K_M";                    M[caps]="TOOLS + THINK"
        M[file]="phi-4-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf"
        M[size_gb]=9;  M[layers]=40; M[tier]="14B"
    elif (( HAS_GPU && vram >= 8 )); then
        highlight "≥8 GB VRAM → Qwen3-8B Q6_K [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q6_K";                       M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q6_K.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
        M[size_gb]=6;  M[layers]=36; M[tier]="8B"
    elif (( HAS_GPU && vram >= 6 )); then
        highlight "≥6 GB VRAM → Qwen3-8B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q4_K_M";                     M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[size_gb]=5;  M[layers]=36; M[tier]="8B"
    elif (( HAS_GPU && vram >= 4 )); then
        highlight "≥4 GB VRAM → Qwen3-4B Q4_K_M [TOOLS+THINK]"
        M[name]="Qwen3-4B Q4_K_M";                     M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[size_gb]=3;  M[layers]=36; M[tier]="4B"
    # CPU tiers
    elif (( ram >= 32 )); then
        highlight "CPU ≥32 GB RAM → Qwen3-14B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-14B Q4_K_M";                    M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[size_gb]=9;  M[layers]=40; M[tier]="14B"
    elif (( ram >= 16 )); then
        highlight "CPU ≥16 GB RAM → Qwen3-8B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q4_K_M";                     M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[size_gb]=5;  M[layers]=36; M[tier]="8B"
    elif (( ram >= 8 )); then
        highlight "CPU ≥8 GB RAM → Qwen3-4B Q4_K_M [TOOLS+THINK]"
        M[name]="Qwen3-4B Q4_K_M";                     M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[size_gb]=3;  M[layers]=36; M[tier]="4B"
    else
        highlight "CPU <8 GB RAM → Qwen3-1.7B Q8_0 [TOOLS+THINK]"
        M[name]="Qwen3-1.7B Q8_0";                     M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
        M[size_gb]=2;  M[layers]=28; M[tier]="1.7B"
    fi
}
select_model

# Layer/batch tuning
if (( HAS_GPU )); then
    GPU_LAYERS=$(gpu_layers_for "${M[size_gb]}" "${M[layers]}")
    if [[ "$GPU_LAYERS" == "-1" ]]; then CPU_LAYERS=0
    else CPU_LAYERS=$(( M[layers] - GPU_LAYERS )); (( CPU_LAYERS < 0 )) && CPU_LAYERS=0; fi
else
    GPU_LAYERS=0; CPU_LAYERS="${M[layers]}"
fi
if   (( GPU_VRAM_GB >= 24 )); then BATCH=2048
elif (( GPU_VRAM_GB >= 16 )); then BATCH=1024
elif (( GPU_VRAM_GB >= 8  )); then BATCH=512
elif (( GPU_VRAM_GB >= 4  )); then BATCH=256
else                               BATCH=128; fi

_is_cached() { [[ -f "$GGUF_MODELS/$1" ]] && printf " ${ACCENT2}✓ cached${NC}" || printf ""; }

info "Auto-selected: ${M[name]}  (${M[tier]})  GPU:${GPU_LAYERS} CPU:${CPU_LAYERS} batch:${BATCH}"
printf "\n"

# Manual override picker
if ask_yes_no "Override with manual model selection?"; then
    printf "\n"
    printf "  ${CYAN}╔══════════════════════════════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "  ${CYAN}║  MODEL PICKER  ·  type a number and press Enter  ·  ✓=already cached    ║${NC}\n"
    printf "  ${CYAN}╚══════════════════════════════════════════════════════════════════════════════════════════╝${NC}\n\n"
    printf "  ${CYAN}%-4s  %-32s  %-5s  %-7s  %-5s  %s${NC}\n" "#" "Model" "Quant" "VRAM" "★" "Capabilities"
    printf "  ${CYAN}────  ────────────────────────────────  ─────  ───────  ─────  ──────────────────────────${NC}\n"

    printf "\n  ${YELLOW}  ›  CPU / No GPU needed${NC}\n"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "1"  "Qwen3-1.7B"              "Q8"  "CPU"    "$(_is_cached Qwen_Qwen3-1.7B-Q8_0.gguf)"                                                       "★ TOOLS · THINK · tiny"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "2"  "Qwen3-4B"                "Q4"  "~3 GB"  "$(_is_cached Qwen_Qwen3-4B-Q4_K_M.gguf)"                                                       "★ TOOLS · THINK"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "3"  "Phi-4-mini 3.8B"         "Q4"  "CPU"    "$(_is_cached microsoft_Phi-4-mini-instruct-Q4_K_M.gguf)"                                        "★ TOOLS · THINK · Microsoft"

    printf "\n  ${YELLOW}  ›  6–8 GB VRAM${NC}\n"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "4"  "Qwen3-8B"                "Q4"  "~5 GB"  "$(_is_cached Qwen_Qwen3-8B-Q4_K_M.gguf)"                                                       "★ TOOLS · THINK"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "5"  "Qwen3-8B"                "Q6"  "~6 GB"  "$(_is_cached Qwen_Qwen3-8B-Q6_K.gguf)"                                                         "★ TOOLS · THINK · higher quality"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "6"  "DeepSeek-R1-Distill-8B"  "Q4"  "~5 GB"  "$(_is_cached DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf)"                                         "  THINK · deep reasoning"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "7"  "Gemma-3-9B"              "Q4"  "~6 GB"  "$(_is_cached google_gemma-3-9b-it-Q4_K_M.gguf)"                                                 "  TOOLS · Google"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "8"  "Gemma-3-12B"             "Q4"  "~8 GB"  "$(_is_cached google_gemma-3-12b-it-Q4_K_M.gguf)"                                                "  TOOLS · Google"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "9"  "Dolphin3-8B"             "Q4"  "~5 GB"  "$(_is_cached Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf)"                                              "  UNCENSORED"

    printf "\n  ${YELLOW}  ›  10–12 GB VRAM${NC}\n"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "10" "Phi-4-14B"               "Q4"  "~9 GB"  "$(_is_cached phi-4-Q4_K_M.gguf)"                                                               "★ TOOLS · top coding+math"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "11" "Qwen3-14B"               "Q4"  "~9 GB"  "$(_is_cached Qwen_Qwen3-14B-Q4_K_M.gguf)"                                                      "★ TOOLS · THINK"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "12" "DeepSeek-R1-Distill-14B" "Q4"  "~9 GB"  "$(_is_cached DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf)"                                        "  THINK · deep reasoning"

    printf "\n  ${YELLOW}  ›  16 GB VRAM${NC}\n"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "13" "Gemma-3-27B"             "Q4"  "~16 GB" "$(_is_cached google_gemma-3-27b-it-Q4_K_M.gguf)"                                                "  TOOLS · Google"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "14" "Mistral-Small-3.1-24B"   "Q4"  "~14 GB" "$(_is_cached mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf)"                        "  TOOLS · THINK · 128K ctx"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "15" "Mistral-Small-3.2-24B"   "Q4"  "~14 GB" "$(_is_cached mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf)"                        "★ TOOLS · THINK · newest"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "16" "Qwen3-30B-A3B (MoE)"     "Q4"  "~16 GB" "$(_is_cached Qwen_Qwen3-30B-A3B-Q4_K_M.gguf)"                                                  "★ TOOLS · THINK · 30B @ 8B speed"

    printf "\n  ${YELLOW}  ›  24+ GB VRAM${NC}\n"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "17" "Qwen3-32B"               "Q4"  "~19 GB" "$(_is_cached Qwen_Qwen3-32B-Q4_K_M.gguf)"                                                      "★ TOOLS · THINK"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "18" "DeepSeek-R1-32B"         "Q4"  "~19 GB" "$(_is_cached DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf)"                                        "  THINK · deep reasoning"
    printf "  %-4s  %-32s  %-5s  %-7s  %b  %s\n" "19" "Llama-3.3-70B"           "Q4"  "~40 GB" "$(_is_cached Llama-3.3-70B-Instruct-Q4_K_M.gguf)"                                              "★ TOOLS · flagship"
    printf "\n"

    printf "  ${ACCENT}?${NC}  ${BOLD}Choice (or Enter to keep auto-selected):${NC} "
    read -r _mc || _mc=""

    case "${_mc:-}" in
        1)  M[name]="Qwen3-1.7B Q8_0";                     M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[size_gb]=2;  M[layers]=28; M[tier]="1.7B" ;;
        2)  M[name]="Qwen3-4B Q4_K_M";                     M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[size_gb]=3;  M[layers]=36; M[tier]="4B" ;;
        3)  M[name]="Phi-4-mini-instruct Q4_K_M";          M[caps]="TOOLS + THINK"
            M[file]="microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
            M[size_gb]=3;  M[layers]=32; M[tier]="3.8B" ;;
        4)  M[name]="Qwen3-8B Q4_K_M";                     M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=36; M[tier]="8B" ;;
        5)  M[name]="Qwen3-8B Q6_K";                       M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q6_K.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
            M[size_gb]=6;  M[layers]=36; M[tier]="8B" ;;
        6)  M[name]="DeepSeek-R1-Distill-Qwen-8B Q4_K_M";  M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-8B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=36; M[tier]="8B" ;;
        7)  M[name]="Gemma-3-9B Q4_K_M";                   M[caps]="TOOLS"
            M[file]="google_gemma-3-9b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-9b-it-GGUF/resolve/main/google_gemma-3-9b-it-Q4_K_M.gguf"
            M[size_gb]=6;  M[layers]=42; M[tier]="9B" ;;
        8)  M[name]="Gemma-3-12B Q4_K_M";                  M[caps]="TOOLS"
            M[file]="google_gemma-3-12b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-12b-it-GGUF/resolve/main/google_gemma-3-12b-it-Q4_K_M.gguf"
            M[size_gb]=8;  M[layers]=46; M[tier]="12B" ;;
        9)  M[name]="Dolphin3.0-Llama3.1-8B Q4_K_M";       M[caps]="UNCENSORED"
            M[file]="Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=32; M[tier]="8B" ;;
        10) M[name]="Phi-4-14B Q4_K_M";                    M[caps]="TOOLS + THINK"
            M[file]="phi-4-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        11) M[name]="Qwen3-14B Q4_K_M";                    M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        12) M[name]="DeepSeek-R1-Distill-Qwen-14B Q4_K_M"; M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        13) M[name]="Gemma-3-27B Q4_K_M";                  M[caps]="TOOLS"
            M[file]="google_gemma-3-27b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-27b-it-GGUF/resolve/main/google_gemma-3-27b-it-Q4_K_M.gguf"
            M[size_gb]=16; M[layers]=62; M[tier]="27B" ;;
        14) M[name]="Mistral-Small-3.1-24B Q4_K_M";        M[caps]="TOOLS + THINK"
            M[file]="mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.1-24B-Instruct-2503-GGUF/resolve/main/mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"
            M[size_gb]=14; M[layers]=40; M[tier]="24B" ;;
        15) M[name]="Mistral-Small-3.2-24B Q4_K_M";        M[caps]="TOOLS + THINK"
            M[file]="mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
            M[size_gb]=14; M[layers]=40; M[tier]="24B" ;;
        16) M[name]="Qwen3-30B-A3B Q4_K_M (MoE)";          M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
            M[size_gb]=18; M[layers]=48; M[tier]="30B-A3B" ;;
        17) M[name]="Qwen3-32B Q4_K_M";                    M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        18) M[name]="DeepSeek-R1-Distill-Qwen-32B Q4_K_M"; M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        19) M[name]="Llama-3.3-70B-Instruct Q4_K_M";       M[caps]="TOOLS"
            M[file]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
            M[size_gb]=40; M[layers]=80; M[tier]="70B" ;;
        "")  info "Keeping auto-selected model." ;;
        *)   warn "Invalid choice '$_mc' — keeping auto-selected model." ;;
    esac
    unset _mc

    # Recalculate layers and batch for manual selection
    if (( HAS_GPU )); then
        GPU_LAYERS=$(gpu_layers_for "${M[size_gb]}" "${M[layers]}")
        if [[ "$GPU_LAYERS" == "-1" ]]; then CPU_LAYERS=0
        else CPU_LAYERS=$(( M[layers] - GPU_LAYERS )); (( CPU_LAYERS < 0 )) && CPU_LAYERS=0; fi
    else
        GPU_LAYERS=0; CPU_LAYERS="${M[layers]}"
    fi
    if   (( GPU_VRAM_GB >= 24 )); then BATCH=2048
    elif (( GPU_VRAM_GB >= 16 )); then BATCH=1024
    elif (( GPU_VRAM_GB >= 8  )); then BATCH=512
    elif (( GPU_VRAM_GB >= 4  )); then BATCH=256
    else                               BATCH=128; fi
fi

info "Final selection: ${M[name]}  [${M[caps]}]  GPU:${GPU_LAYERS} CPU:${CPU_LAYERS} batch:${BATCH}"

# Disk space check
if (( DISK_FREE_GB < M[size_gb] + 3 )); then
    warn "Low disk: ${DISK_FREE_GB} GB free, model needs ~${M[size_gb]} GB."
    ask_yes_no "Continue anyway?" || error "Aborting — free up disk space and re-run."
fi

# =============================================================================
# STEP 4 — SYSTEM PACKAGES + NODE.JS
# zstd MUST be installed here, before Ollama (Ollama needs it for extraction)
# =============================================================================
step "System packages (zstd · build tools · Node.js)"

info "Running apt-get update…"
sudo apt-get update -qq >> "$LOG_FILE" 2>&1 || warn "apt update returned non-zero."

BASE_PKGS=(
    # Ollama extraction requirement — MUST be first
    zstd libzstd-dev
    # Core build tools
    curl wget git ca-certificates gnupg lsb-release
    build-essential g++ clang cmake ninja-build pkg-config
    libssl-dev libffi-dev libncurses-dev zlib1g-dev libbz2-dev
    libreadline-dev libsqlite3-dev liblzma-dev
    # Python base
    python3 python3-pip python3-venv python3-dev python3-full
    software-properties-common
    # Download accelerator + media
    aria2 ffmpeg pciutils
    # Terminal quality-of-life
    bat grc source-highlight jq unzip
)
(( HAS_AVX2 )) && BASE_PKGS+=(libopenblas-dev liblapack-dev)

info "Installing ${#BASE_PKGS[@]} system packages…"
_apt_install "${BASE_PKGS[@]}"

# Verify critical commands
for _cmd in curl wget git python3; do
    command -v "$_cmd" &>/dev/null || error "Critical dependency missing after install: $_cmd"
done

# Node.js 20 LTS via NodeSource
_node_ok=0
if command -v node &>/dev/null; then
    _nver=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo 0)
    (( _nver >= 18 )) && _node_ok=1
fi
if (( !_node_ok )); then
    info "Installing Node.js 20 LTS via NodeSource…"
    _pbar 10 "NodeSource setup script"
    curl -fsSL https://deb.nodesource.com/setup_20.x 2>>"$LOG_FILE" | sudo bash - >> "$LOG_FILE" 2>&1
    _pbar 60 "apt: nodejs"
    sudo apt-get install -y nodejs >> "$LOG_FILE" 2>&1 && _node_ok=1 || warn "Node.js install failed."
    _pbar_done
fi
command -v node &>/dev/null \
    && info "Node.js $(node --version)  /  npm $(npm --version)" \
    || warn "Node.js not available — Claude Code/Codex will not install."
unset _cmd _node_ok _nver

# =============================================================================
# STEP 5 — PYTHON ENVIRONMENT
# =============================================================================
step "Python environment"

mkdir -p "$TEMP_DIR"

PYVER_RAW=$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "0.0")
PYVER_MAJOR=$(echo "$PYVER_RAW" | cut -d. -f1)
PYVER_MINOR=$(echo "$PYVER_RAW" | cut -d. -f2)
PYTHON_BIN="python3"
info "System Python: $PYVER_RAW"

# Upgrade via deadsnakes if < 3.10
if (( PYVER_MAJOR < 3 || (PYVER_MAJOR == 3 && PYVER_MINOR < 10) )); then
    warn "Python $PYVER_RAW too old (need 3.10+) — installing 3.11 via deadsnakes…"
    sudo apt-get install -y software-properties-common >> "$LOG_FILE" 2>&1 || true
    if ! grep -rq "deadsnakes" /etc/apt/sources.list.d/ 2>/dev/null; then
        sudo add-apt-repository -y ppa:deadsnakes/ppa >> "$LOG_FILE" 2>&1 || warn "deadsnakes PPA failed."
        sudo apt-get update -qq >> "$LOG_FILE" 2>&1 || true
    fi
    sudo apt-get install -y python3.11 python3.11-venv python3.11-dev >> "$LOG_FILE" 2>&1 || true
    command -v python3.11 &>/dev/null && { PYTHON_BIN="python3.11"; info "Using Python 3.11."; }
fi

# Refresh version vars
_pv=$("$PYTHON_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "$PYVER_RAW")
PYVER_MAJOR=$(echo "$_pv" | cut -d. -f1)
PYVER_MINOR=$(echo "$_pv" | cut -d. -f2)
unset _pv

# Install version-specific venv packages
info "Installing python${PYVER_MAJOR}.${PYVER_MINOR}-venv…"
sudo apt-get install -y \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-venv" \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-dev" \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-full" \
    >> "$LOG_FILE" 2>&1 || warn "Some Python venv packages failed (non-fatal)."

# Bootstrap pip
if ! "$PYTHON_BIN" -m pip --version &>/dev/null 2>&1; then
    info "Bootstrapping pip via get-pip.py…"
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$TEMP_DIR/get-pip.py" \
        && "$PYTHON_BIN" "$TEMP_DIR/get-pip.py" --quiet \
        && rm -f "$TEMP_DIR/get-pip.py" \
        || warn "get-pip.py bootstrap failed."
fi
"$PYTHON_BIN" -m pip install --upgrade pip --quiet >> "$LOG_FILE" 2>&1 || true
info "pip $("$PYTHON_BIN" -m pip --version 2>/dev/null | awk '{print $2}') ✓"

# venv smoke test
_tv="$TEMP_DIR/.test_venv_$$"
if "$PYTHON_BIN" -m venv "$_tv" >> "$LOG_FILE" 2>&1; then
    rm -rf "$_tv"; info "Python venv: OK"
else
    sudo apt-get install -y "python${PYVER_MAJOR}.${PYVER_MINOR}-venv" >> "$LOG_FILE" 2>&1 || true
    "$PYTHON_BIN" -m venv "$_tv" >> "$LOG_FILE" 2>&1 \
        || error "Python venv still failing. Run: sudo apt-get install python${PYVER_MAJOR}.${PYVER_MINOR}-venv"
    rm -rf "$_tv"; info "Python venv: OK (after reinstall)"
fi
unset _tv
export PYTHON_BIN

# =============================================================================
# STEP 6 — DIRECTORIES & PATH
# =============================================================================
step "Directories & PATH"

mkdir -p "$OLLAMA_MODELS" "$GGUF_MODELS" "$TEMP_DIR" \
         "$BIN_DIR" "$CONFIG_DIR" "$GUI_DIR" "$WORK_DIR"
info "Directories created."

# Add BIN_DIR to PATH (idempotent)
export PATH="$BIN_DIR:$PATH"
if ! grep -q "# llm-auto-setup PATH" "$HOME/.bashrc" 2>/dev/null; then
    {   printf '\n# llm-auto-setup PATH\n'
        printf '[[ ":$PATH:" != *":%s:"* ]] && export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR"
    } >> "$HOME/.bashrc"
    info "Added $BIN_DIR to PATH in ~/.bashrc"
fi

# Terminal syntax highlighting (bat + grc)
if ! grep -q "# llm-bat-grc" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'BATGRC'

# ── Terminal syntax highlighting — llm-auto-setup ─────────────────────────────────
# llm-bat-grc
if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then alias bat='batcat'; fi
if command -v bat &>/dev/null; then
    alias cat='bat --paging=never --style=plain'
    alias less='bat --paging=always'
    export MANPAGER='sh -c "col -bx | bat --language=man --style=plain --paging=always"'
fi
if command -v grc &>/dev/null; then
    alias diff='grc diff'; alias make='grc make'
    alias gcc='grc gcc';   alias g++='grc g++'
    alias ping='grc ping'; alias ps='grc ps'
fi
# end llm-bat-grc
BATGRC
    info "Terminal syntax highlighting configured."
fi

# =============================================================================
# STEP 7 — SAVE MODEL CONFIG
# =============================================================================
step "Saving model config"

OLLAMA_TAG=$(basename "${M[file]}" .gguf \
    | sed -E 's/-([Qq][0-9].*)$/:\1/' \
    | tr '[:upper:]' '[:lower:]')

cat > "$MODEL_CONFIG" <<CONF
MODEL_NAME="${M[name]}"
MODEL_URL="${M[url]}"
MODEL_FILENAME="${M[file]}"
MODEL_SIZE="${M[tier]}"
MODEL_CAPS="${M[caps]}"
MODEL_LAYERS="${M[layers]}"
GPU_LAYERS="$GPU_LAYERS"
CPU_LAYERS="$CPU_LAYERS"
HW_THREADS="$HW_THREADS"
BATCH="$BATCH"
OLLAMA_TAG="$OLLAMA_TAG"
CONF
info "Config saved: $MODEL_CONFIG"

# =============================================================================
# STEP 8 — OLLAMA  (installed BEFORE Python venv — needs zstd already present)
# Locked to v0.12.3 — v0.12.4+ has RTX 30xx / Ampere GPU offload regression
# =============================================================================
step "Ollama v${OLLAMA_LOCKED_VER} (locked — RTX 30xx fix)"

_ollama_ver_ok() {
    local _cv; _cv=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
    [[ "$_cv" == "$OLLAMA_LOCKED_VER" ]]
}

if command -v ollama &>/dev/null && _ollama_ver_ok; then
    info "Ollama $OLLAMA_LOCKED_VER already installed ✓"
else
    if command -v ollama &>/dev/null; then
        _cv=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
        warn "Ollama $_cv detected — downgrading to $OLLAMA_LOCKED_VER (RTX 30xx GPU offload fix)"
        # Stop any running instance
        pkill -f "ollama serve" 2>/dev/null || true
        sudo systemctl stop ollama 2>/dev/null || true
        sleep 1
    else
        info "Installing Ollama $OLLAMA_LOCKED_VER…"
    fi

    # Download exact locked binary directly (bypasses install.sh which always fetches latest)
    _pbar 5 "Downloading ollama binary"
    if sudo curl -fsSL --progress-bar -o /usr/local/bin/ollama "$OLLAMA_LOCKED_URL" 2>>"$LOG_FILE"; then
        sudo chmod +x /usr/local/bin/ollama
        _pbar 100 "Ollama $OLLAMA_LOCKED_VER installed"; _pbar_done
    else
        _pbar_done
        warn "Direct download failed — trying OLLAMA_VERSION env with install.sh…"
        retry 3 10 bash -c "OLLAMA_VERSION=${OLLAMA_LOCKED_VER} curl -fsSL https://ollama.com/install.sh | sh" </dev/null \
            || error "Ollama install failed."
    fi

    # Create ollama user/group if missing (install.sh normally does this)
    id -u ollama &>/dev/null || \
        sudo useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama >> "$LOG_FILE" 2>&1 || true
    sudo usermod -aG ollama "$USER" >> "$LOG_FILE" 2>&1 || true
    unset _cv
fi

# Verify locked version
_vcheck=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
if [[ "$_vcheck" == "$OLLAMA_LOCKED_VER" ]]; then
    info "Ollama version: $_vcheck ✓ (locked)"
else
    warn "Ollama version: $_vcheck (expected $OLLAMA_LOCKED_VER — may have issues on RTX 30xx)"
fi
unset _vcheck

# Configure Ollama environment
OLLAMA_PARALLEL=1
(( TOTAL_RAM_GB >= 32 )) && OLLAMA_PARALLEL=2

if is_wsl2; then
    # WSL2: write ollama-start launcher
    cat > "$BIN_DIR/ollama-start" <<OLWSL
#!/usr/bin/env bash
# ollama-start — start Ollama in WSL2 background
export OLLAMA_MODELS="$OLLAMA_MODELS"
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_NUM_PARALLEL=$OLLAMA_PARALLEL
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_NUM_THREAD=$HW_THREADS
export OLLAMA_ORIGINS="*"
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
export CUDA_VISIBLE_DEVICES=\${CUDA_VISIBLE_DEVICES:-0}
pgrep -f "ollama serve" >/dev/null 2>&1 && { echo "Ollama already running."; exit 0; }
echo "Starting Ollama $OLLAMA_LOCKED_VER…"
nohup ollama serve >"\$HOME/.ollama.log" 2>&1 &
sleep 3
pgrep -f "ollama serve" >/dev/null && echo "Ollama started ✓" \
    || { echo "ERROR — check: cat ~/.ollama.log"; exit 1; }
OLWSL
    chmod +x "$BIN_DIR/ollama-start"
    "$BIN_DIR/ollama-start" || warn "ollama-start returned non-zero."
else
    # Native Linux: configure systemd service
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<OLOV
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS"
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_NUM_PARALLEL=$OLLAMA_PARALLEL"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_THREAD=$HW_THREADS"
Environment="OLLAMA_ORIGINS=*"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
OLOV
    sudo systemctl daemon-reload >> "$LOG_FILE" 2>&1
    sudo systemctl enable ollama  >> "$LOG_FILE" 2>&1 || warn "systemctl enable ollama failed."
    sudo systemctl restart ollama >> "$LOG_FILE" 2>&1 || warn "systemctl restart ollama failed."

    cat > "$BIN_DIR/ollama-start" <<'OLNAT'
#!/usr/bin/env bash
# ollama-start — start/check Ollama systemd service
systemctl is-active --quiet ollama 2>/dev/null \
    && echo "Ollama already running." \
    || { echo "Starting Ollama service…"
         sudo systemctl start ollama \
             && echo "Ollama started ✓" \
             || echo "ERROR: check: sudo journalctl -u ollama -n 30"; }
OLNAT
    chmod +x "$BIN_DIR/ollama-start"
fi

sleep 3
if is_wsl2; then
    pgrep -f "ollama serve" >/dev/null && info "Ollama running ✓" || warn "Ollama not running — try: ollama-start"
else
    sudo systemctl is-active --quiet ollama && info "Ollama service active ✓" || warn "Ollama not active — try: ollama-start"
fi

# =============================================================================
# STEP 9 — CUDA / ROCm TOOLKIT
# =============================================================================
if (( HAS_NVIDIA )); then
    step "CUDA toolkit (NVIDIA)"

    setup_cuda_env() {
        local cb=""
        for _p in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
            [[ -d "$_p" ]] && { cb="$_p"; break; }
        done
        if [[ -n "$cb" ]] && [[ ":$PATH:" != *":$cb:"* ]]; then
            export PATH="$cb:$PATH"
            ! grep -q "# CUDA — llm-auto-setup" "$HOME/.bashrc" 2>/dev/null && {
                printf '\n# CUDA — llm-auto-setup\nexport PATH="%s:$PATH"\n' "$cb" >> "$HOME/.bashrc"
            }
            info "CUDA bin: $cb"
        fi
        local nvcc_p; nvcc_p=$(command -v nvcc 2>/dev/null \
            || find /usr/local/cuda* /usr/bin -name nvcc 2>/dev/null | head -1 || true)
        [[ -n "$nvcc_p" ]] && export PATH="$(dirname "$nvcc_p"):$PATH"
    }

    CUDA_PRESENT=0
    command -v nvcc &>/dev/null && CUDA_PRESENT=1
    for _p in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
        [[ -d "$_p" ]] && { CUDA_PRESENT=1; break; }
    done
    ldconfig -p 2>/dev/null | grep -q 'libcudart\.so\.12' && CUDA_PRESENT=1
    dpkg -l 'cuda-toolkit-*' 2>/dev/null | grep -q '^ii' && CUDA_PRESENT=1

    if (( CUDA_PRESENT )); then
        info "CUDA already installed ✓"
        setup_cuda_env
    else
        info "Installing CUDA toolkit…"
        _uv="${UBUNTU_VER//./}"
        [[ "$_uv" != "2204" && "$_uv" != "2404" ]] && warn "Ubuntu $UBUNTU_VER not tested — attempting anyway."
        _kr="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${_uv}/x86_64/cuda-keyring_1.1-1_all.deb"
        _pbar 5 "CUDA keyring download"
        if _download "$_kr" "$TEMP_DIR/cuda-keyring.deb" "CUDA keyring"; then
            sudo dpkg -i "$TEMP_DIR/cuda-keyring.deb" >> "$LOG_FILE" 2>&1 || true
            rm -f "$TEMP_DIR/cuda-keyring.deb"
            _pbar 30 "apt update for CUDA repo"
            sudo apt-get update -qq >> "$LOG_FILE" 2>&1 || true
            _cuda_pkg=$(apt-cache search --names-only '^cuda-toolkit-12-' 2>/dev/null \
                | awk '{print $1}' | sort -V | tail -1 || true)
            [[ -z "$_cuda_pkg" ]] && _cuda_pkg="cuda-toolkit"
            _pbar 50 "apt: $_cuda_pkg"
            sudo apt-get install -y "$_cuda_pkg" >> "$LOG_FILE" 2>&1 \
                || warn "CUDA install returned non-zero — may still work."
            _pbar_done
        else
            warn "CUDA keyring download failed — trying nvidia-cuda-toolkit fallback."
            sudo apt-get install -y nvidia-cuda-toolkit >> "$LOG_FILE" 2>&1 || warn "Fallback CUDA install failed."
        fi
        sudo ldconfig 2>/dev/null || true
        setup_cuda_env
        unset _uv _kr _cuda_pkg
    fi

    # libcudart resolution — Ollama bundles CUDA libs; register them if system doesn't have them
    if ! ldconfig -p 2>/dev/null | grep -q "libcudart\.so\.12"; then
        for _d in \
            /usr/local/lib/ollama/cuda_v12 \
            /usr/local/lib/ollama/cuda_v11 \
            /usr/local/cuda/lib64 \
            /usr/local/cuda-1[23]/lib64 \
            /usr/lib/x86_64-linux-gnu; do
            if [[ -f "$_d/libcudart.so.12" || -f "$_d/libcudart.so" ]]; then
                info "Registering libcudart from: $_d"
                echo "$_d" | sudo tee /etc/ld.so.conf.d/ollama-cuda.conf > /dev/null
                sudo ldconfig
                ! grep -q "# ollama-cuda-ld" "$HOME/.bashrc" 2>/dev/null && \
                    printf '\n# ollama-cuda-ld\nexport LD_LIBRARY_PATH="%s:${LD_LIBRARY_PATH:-}"\n' "$_d" >> "$HOME/.bashrc"
                export LD_LIBRARY_PATH="$_d:${LD_LIBRARY_PATH:-}"
                break
            fi
        done
        unset _d
    fi
    ldconfig -p 2>/dev/null | grep -q "libcudart" && info "libcudart.so found in ldconfig ✓" \
        || warn "libcudart not found — GPU inference may fail. Try: sudo apt install cuda-libraries-12-0"
fi

if (( HAS_AMD && !HAS_NVIDIA )); then
    step "ROCm toolkit (AMD)"

    setup_rocm_env() {
        local rl=""
        for _r in /opt/rocm/lib /opt/rocm-*/lib /usr/lib/x86_64-linux-gnu; do
            [[ -f "$_r/libhipblas.so" || -f "$_r/librocblas.so" ]] && { rl="$_r"; break; }
        done
        [[ -z "$rl" ]] && rl="/opt/rocm/lib"
        export LD_LIBRARY_PATH="$rl:${LD_LIBRARY_PATH:-}"
        export PATH="/opt/rocm/bin:$PATH"
        ! grep -q "# ROCm — llm-auto-setup" "$HOME/.bashrc" 2>/dev/null && {
            printf '\n# ROCm — llm-auto-setup\nexport PATH="/opt/rocm/bin:$PATH"\n' >> "$HOME/.bashrc"
            printf 'export LD_LIBRARY_PATH="%s:${LD_LIBRARY_PATH:-}"\n' "$rl" >> "$HOME/.bashrc"
        }
        info "ROCm env: $rl"
    }

    ROCM_PRESENT=0
    { command -v rocminfo &>/dev/null || [[ -d /opt/rocm ]]; } && ROCM_PRESENT=1

    if (( ROCM_PRESENT )); then
        info "ROCm already installed ✓"
        setup_rocm_env
    else
        info "Installing ROCm via amdgpu-install…"
        _uv=$(lsb_release -rs 2>/dev/null || echo "unknown")
        _base="https://repo.radeon.com/amdgpu-install/latest/ubuntu/${_uv}/"
        _deb=$(wget -qO- "$_base" 2>/dev/null | grep -oP 'amdgpu-install_[^"]+_all\.deb' | tail -1 \
            || echo "amdgpu-install_6.3.60300-1_all.deb")
        if _download "${_base}${_deb}" "$TEMP_DIR/amdgpu-install.deb" "ROCm installer"; then
            sudo dpkg -i "$TEMP_DIR/amdgpu-install.deb" >> "$LOG_FILE" 2>&1 || true
            sudo apt-get update -qq >> "$LOG_FILE" 2>&1 || true
            rm -f "$TEMP_DIR/amdgpu-install.deb"
            sudo amdgpu-install --usecase=rocm --no-dkms -y >> "$LOG_FILE" 2>&1 \
                || warn "amdgpu-install returned non-zero."
        else
            warn "amdgpu-install download failed — trying fallback apt path…"
            wget -qO- https://repo.radeon.com/rocm/rocm.gpg.key 2>/dev/null \
                | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/rocm.gpg || true
            echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/6.3 ${_uv} main" \
                | sudo tee /etc/apt/sources.list.d/rocm.list > /dev/null
            sudo apt-get update -qq >> "$LOG_FILE" 2>&1 || true
            sudo apt-get install -y rocm-hip-sdk rocm-opencl-sdk >> "$LOG_FILE" 2>&1 \
                || warn "ROCm apt install failed — see rocm.docs.amd.com"
        fi
        sudo usermod -aG render,video "$USER" >> "$LOG_FILE" 2>&1 || true
        setup_rocm_env
        unset _uv _base _deb
    fi
fi

# =============================================================================
# STEP 10 — MAIN PYTHON VENV + llama-cpp-python
# =============================================================================
step "Python venv + llama-cpp-python"

_ensure_venv "$VENV_DIR"
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate" || error "Failed to activate venv: $VENV_DIR"
[[ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]] && error "Venv activation sanity check failed."
info "Venv: $VIRTUAL_ENV"

# Shared cmake args
CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release"
(( HAS_NVIDIA  )) && CMAKE_ARGS+=" -DGGML_CUDA=ON -DLLAMA_CUBLAS=ON"
(( HAS_AVX512  )) && CMAKE_ARGS+=" -DGGML_AVX512=ON -DGGML_AVX2=ON -DGGML_FMA=ON"
(( !HAS_AVX512 && HAS_AVX2 )) && CMAKE_ARGS+=" -DGGML_AVX2=ON -DGGML_FMA=ON"
(( !HAS_AVX2   && HAS_AVX  )) && CMAKE_ARGS+=" -DGGML_AVX=ON"
(( HAS_NEON    )) && CMAKE_ARGS+=" -DGGML_NEON=ON"
export SOURCE_BUILD_CMAKE_ARGS="$CMAKE_ARGS"

LLAMA_INSTALLED=0
check_llama() { "$VENV_DIR/bin/python3" -c "import llama_cpp" 2>/dev/null; }

# Try pre-built CUDA wheels (fast — no compilation)
if (( HAS_NVIDIA )); then
    CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1 || true)
    [[ -z "$CUDA_VER" ]] && CUDA_VER="${CUDA_VER_SMI:-12.1}"
    CUDA_TAG="cu$(echo "$CUDA_VER" | tr -d '.')"
    info "CUDA $CUDA_VER → wheel tag $CUDA_TAG"

    _WTAGS=("$CUDA_TAG" "cu124" "cu122" "cu121" "cu120")
    _widx=0
    for _wt in "${_WTAGS[@]}"; do
        (( _widx++ ))
        _pbar $(( _widx * 100 / ${#_WTAGS[@]} )) "CUDA wheel: $_wt"
        pip install llama-cpp-python \
            --index-url "https://abetlen.github.io/llama-cpp-python/whl/${_wt}" \
            --extra-index-url https://pypi.org/simple \
            --quiet >> "$LOG_FILE" 2>&1 \
            && { _pbar_done; info "CUDA wheel OK: $_wt"; LLAMA_INSTALLED=1; break; }
    done
    _pbar_done
    unset _WTAGS _widx _wt
fi

# Try pre-built ROCm wheels
if (( HAS_AMD && !HAS_NVIDIA && LLAMA_INSTALLED == 0 )); then
    for _wt in "rocm600" "rocm550"; do
        _pbar 50 "ROCm wheel: $_wt"
        pip install llama-cpp-python \
            --index-url "https://abetlen.github.io/llama-cpp-python/whl/${_wt}" \
            --extra-index-url https://pypi.org/simple \
            --quiet >> "$LOG_FILE" 2>&1 \
            && { _pbar_done; info "ROCm wheel OK: $_wt"; LLAMA_INSTALLED=1; break; }
    done
    _pbar_done
    unset _wt
fi

# Source build fallback
if (( LLAMA_INSTALLED == 0 )); then
    if (( HAS_NVIDIA )); then
        warn "No pre-built CUDA wheel — source build (~5 min)…"
        _pip_with_ticker "Building llama-cpp-python (CUDA)" \
            pip install llama-cpp-python --no-cache-dir
    elif (( HAS_AMD )); then
        warn "No pre-built ROCm wheel — source build (~8 min)…"
        _pip_with_ticker "Building llama-cpp-python (ROCm)" \
            env MAKE_JOBS="$HW_THREADS" CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DGGML_HIPBLAS=ON" \
            pip install llama-cpp-python --no-cache-dir
    else
        info "CPU-only build (~3 min)…"
        _pip_with_ticker "Building llama-cpp-python (CPU)" \
            env MAKE_JOBS="$HW_THREADS" CMAKE_ARGS="$SOURCE_BUILD_CMAKE_ARGS" \
            pip install llama-cpp-python --no-cache-dir
    fi
fi

check_llama && info "llama-cpp-python ✓" \
    || warn "llama-cpp-python import failed — check CUDA/ROCm paths and re-run."

deactivate 2>/dev/null || true

# =============================================================================
# STEP 11 — MODEL DOWNLOAD
# =============================================================================
step "Model download"

if ask_yes_no "Download ${M[name]} (~${M[size_gb]} GB) now?"; then
    mkdir -p "$GGUF_MODELS"

    # Check for existing file first (resume-safe)
    _existing=$(find "$GGUF_MODELS" -maxdepth 1 -name "${M[file]}" -size +1M 2>/dev/null | head -1 || true)
    if [[ -n "$_existing" ]]; then
        info "Model already on disk: $_existing ($(du -sh "$_existing" | cut -f1)) — skipping download."
    else
        _download "${M[url]}" "$GGUF_MODELS/${M[file]}" "Model: ${M[name]}"
    fi
    unset _existing

    if [[ -f "$GGUF_MODELS/${M[file]}" ]]; then
        info "Model ready: $(du -sh "$GGUF_MODELS/${M[file]}" | cut -f1)"

        # Register with Ollama
        if command -v ollama &>/dev/null; then
            info "Registering with Ollama as: $OLLAMA_TAG"
            _mf="$TEMP_DIR/Modelfile.$$"

            # Build system prompt based on capabilities
            _sys="You are a helpful AI assistant."
            [[ "${M[caps]}" == *"TOOLS"* ]] && \
                _sys="You are a helpful AI assistant with tool-calling capabilities. When tools are provided respond in the exact JSON schema specified."
            [[ "${M[caps]}" == *"THINK"* ]] && \
                _sys="${_sys} You can reason step by step before giving your final answer."

            cat > "$_mf" <<MFILE
FROM $GGUF_MODELS/${M[file]}
SYSTEM ${_sys}
PARAMETER num_thread $HW_THREADS
PARAMETER num_ctx 8192
PARAMETER num_gpu 999
MFILE
            unset _sys

            start_ollama_if_needed
            if ollama create "$OLLAMA_TAG" -f "$_mf" >> "$LOG_FILE" 2>&1; then
                info "Registered: $OLLAMA_TAG ✓"
            else
                warn "ollama create failed — model won't appear in WebUI until registered."
                warn "  Retry: ollama create $OLLAMA_TAG -f $GGUF_MODELS/${M[file]}"
            fi
            rm -f "$_mf"; unset _mf
        fi
    else
        warn "Model download failed. Resume manually:"
        warn "  curl -L -C - -o '$GGUF_MODELS/${M[file]}' '${M[url]}'"
    fi
fi

# =============================================================================
# STEP 12 — HELPER SCRIPTS
# =============================================================================
step "Helper scripts"

# ── run-gguf ─────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/run-gguf" <<'PYEOF'
#!/usr/bin/env python3
"""Run a GGUF model directly via llama-cpp-python."""
import sys, os, glob, argparse

MODEL_DIR  = os.path.expanduser("~/local-llm-models/gguf")
CONFIG_DIR = os.path.expanduser("~/.config/local-llm")
VENV_SITE  = os.path.expanduser("~/.local/share/llm-venv/lib")

for _sp in glob.glob(os.path.join(VENV_SITE, "python3*/site-packages")):
    if _sp not in sys.path:
        sys.path.insert(0, _sp)

def load_cfg():
    p = os.path.join(CONFIG_DIR, "selected_model.conf")
    cfg = {}
    if os.path.exists(p):
        with open(p) as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    k, _, v = line.partition('=')
                    cfg[k] = v.strip('"')
    return cfg

def list_models():
    models = sorted(glob.glob(os.path.join(MODEL_DIR, "*.gguf")))
    if not models:
        print("No GGUF models in", MODEL_DIR); return
    print("Available models:")
    for m in models:
        print(f"  {os.path.basename(m):<55} {os.path.getsize(m)/1024**3:.1f} GB")

def main():
    cfg = load_cfg()
    p   = argparse.ArgumentParser(description="Run a GGUF model")
    p.add_argument("model",  nargs="?")
    p.add_argument("prompt", nargs="*")
    p.add_argument("--gpu-layers", type=int, default=None)
    p.add_argument("--ctx",        type=int, default=8192)
    p.add_argument("--max-tokens", type=int, default=512)
    p.add_argument("--threads",    type=int, default=int(cfg.get("HW_THREADS", 4)))
    p.add_argument("--batch",      type=int, default=int(cfg.get("BATCH", 256)))
    args = p.parse_args()

    if not args.model:
        list_models(); sys.exit(0)

    path = args.model if os.path.isabs(args.model) else os.path.join(MODEL_DIR, args.model)
    if not os.path.exists(path):
        print(f"Not found: {path}"); list_models(); sys.exit(1)

    prompt     = " ".join(args.prompt) if args.prompt else "Hello!"
    gpu_layers = args.gpu_layers if args.gpu_layers is not None else int(cfg.get("GPU_LAYERS", 0))

    try:
        from llama_cpp import Llama
        print(f"Loading {os.path.basename(path)} | GPU:{gpu_layers} threads:{args.threads} batch:{args.batch}")
        llm = Llama(model_path=path, n_gpu_layers=gpu_layers,
                    n_threads=args.threads, n_batch=args.batch,
                    verbose=False, n_ctx=args.ctx)
        out = llm(prompt, max_tokens=args.max_tokens, echo=True, temperature=0.7, top_p=0.95)
        print(out["choices"][0]["text"])
    except ImportError:
        print("ERROR: llama_cpp not found — activate venv: source ~/.local/share/llm-venv/bin/activate")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)

if __name__ == "__main__":
    main()
PYEOF
chmod +x "$BIN_DIR/run-gguf"

# ── llm-stop ─────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-stop" <<'STOP'
#!/usr/bin/env bash
# llm-stop — stop Ollama, Open WebUI, and Neural Terminal
_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }
echo "Stopping local LLM services…"

if _wsl2 || ! systemctl is-active --quiet ollama 2>/dev/null; then
    pgrep -f "ollama serve" >/dev/null && { pkill -f "ollama serve" && echo "✓ Ollama stopped."; } \
        || echo "  Ollama: not running."
else
    sudo systemctl stop ollama && echo "✓ Ollama service stopped." || echo "Could not stop Ollama."
fi

pgrep -f "open-webui" >/dev/null && { pkill -f "open-webui" && echo "✓ Open WebUI stopped."; } \
    || echo "  Open WebUI: not running."

pgrep -f "http.server.*8090" >/dev/null && { pkill -f "http.server.*8090" && echo "✓ Neural Terminal stopped."; } \
    || echo "  Neural Terminal: not running."

echo "Done."
STOP
chmod +x "$BIN_DIR/llm-stop"

# ── llm-update ───────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-update" <<UPDEOF
#!/usr/bin/env bash
# llm-update — update Open WebUI and pip packages; Ollama is NEVER upgraded
set -uo pipefail

OLLAMA_LOCKED="${OLLAMA_LOCKED_VER}"
OWUI_VENV="\$HOME/.local/share/open-webui-venv"
CONFIG="\$HOME/.config/local-llm/selected_model.conf"

echo ""
echo "═══════════════════════════════════  LLM Stack Updater  ═══════════════════════════════════"
echo ""

# ── Ollama: enforce locked version, never upgrade ──────────────────────────────────────────────
echo "[ 1/3 ] Checking Ollama version…"
_cur=\$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
echo "  Installed: \$_cur  |  Locked: \$OLLAMA_LOCKED (RTX 30xx GPU fix — NEVER upgrade)"
if [[ "\$_cur" != "\$OLLAMA_LOCKED" ]]; then
    echo "  WARNING: version drifted — reinstalling locked v\${OLLAMA_LOCKED}…"
    _url="https://github.com/ollama/ollama/releases/download/v\${OLLAMA_LOCKED}/ollama-linux-amd64"
    if sudo curl -fsSL -o /usr/local/bin/ollama "\$_url"; then
        sudo chmod +x /usr/local/bin/ollama
        echo "  ✓ Locked to v\$OLLAMA_LOCKED"
    else
        echo "  ✗ Could not download locked binary — leaving as-is."
    fi
else
    echo "  ✓ Ollama v\$OLLAMA_LOCKED is correct — NOT upgrading."
fi
unset _cur _url

# ── Open WebUI ─────────────────────────────────────────────────────────────────────────────────
echo ""
echo "[ 2/3 ] Updating Open WebUI…"
if [[ -d "\$OWUI_VENV" ]]; then
    OLD=\$("\$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print \$2}' || echo "?")
    "\$OWUI_VENV/bin/pip" install --upgrade open-webui --quiet \
        && NEW=\$("\$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print \$2}' || echo "?") \
        && echo "  ✓ Open WebUI: \$OLD → \$NEW" \
        || echo "  ✗ Open WebUI update failed."
else
    echo "  Open WebUI venv not found — run: llm-setup to reinstall."
fi

# ── Pip packages across all venvs ───────────────────────────────────────────────────────────────
echo ""
echo "[ 3/3 ] Upgrading pip packages in all venvs…"
for _v in llm-venv aider-venv open-interpreter-venv; do
    _vp="\$HOME/.local/share/\$_v"
    if [[ -x "\$_vp/bin/pip" ]]; then
        echo "  Updating \$_v…"
        "\$_vp/bin/pip" install --upgrade pip setuptools wheel --quiet 2>/dev/null || true
    fi
done
unset _v _vp

echo ""
echo "  ✓ Update complete. Run: exec bash"
echo ""
UPDEOF
chmod +x "$BIN_DIR/llm-update"

# ── llm-switch ─────────────────────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-switch" <<'SWITCH'
#!/usr/bin/env bash
# llm-switch — change active model (updates config, no reinstall needed)
CONFIG="$HOME/.config/local-llm/selected_model.conf"
GGUF_DIR="$HOME/local-llm-models/gguf"

[[ ! -f "$CONFIG" ]] && { echo "No config found — run: llm-setup"; exit 1; }

echo ""
echo "═══════════════════════════════════  MODEL SWITCHER  ═══════════════════════════════════"
echo ""

shopt -s nullglob
_files=("$GGUF_DIR"/*.gguf)
if [[ ${#_files[@]} -eq 0 ]]; then
    echo "  No GGUF models in $GGUF_DIR"
    echo "  Download more: llm-add"
    exit 0
fi

echo "  Available GGUF models:"
_idx=0
declare -a _map
for _f in "${_files[@]}"; do
    (( _idx++ ))
    printf "  %-4s %s  (%s)\n" "$_idx" "$(basename "$_f")" "$(du -sh "$_f" | cut -f1)"
    _map[$_idx]="$_f"
done

echo ""
read -r -p "  Select model number (Enter to cancel): " _ch

[[ -z "$_ch" ]] && { echo "Cancelled."; exit 0; }
_sel="${_map[$_ch]:-}"
if [[ -z "$_sel" ]]; then echo "Invalid choice."; exit 1; fi

_base=$(basename "$_sel")
_new_tag=$(basename "$_sel" .gguf | sed -E 's/-([Qq][0-9].*)$/:\1/' | tr '[:upper:]' '[:lower:]')

sed -i "s|^MODEL_FILENAME=.*|MODEL_FILENAME=\"$_base\"|"       "$CONFIG"
sed -i "s|^OLLAMA_TAG=.*|OLLAMA_TAG=\"$_new_tag\"|"            "$CONFIG"

echo ""
echo "  ✓ Active model set to: $_base"
echo "  ✓ Ollama tag: $_new_tag"
echo ""
echo "  Register with Ollama:"
echo "    ollama create $_new_tag -f $_sel"
echo ""
SWITCH
chmod +x "$BIN_DIR/llm-switch"

# ── llm-add ────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-add" <<ADDEOF
#!/usr/bin/env bash
# llm-add — download additional GGUF models and register with Ollama
set -uo pipefail

GGUF_DIR="\$HOME/local-llm-models/gguf"
TEMP_DIR="\$HOME/local-llm-models/temp"
CONFIG="\$HOME/.config/local-llm/selected_model.conf"
HW_THREADS=\$(nproc 2>/dev/null || echo 4)

mkdir -p "\$GGUF_DIR" "\$TEMP_DIR"

echo ""
echo "══════════════════════════════════════  LLM ADD  ═══════════════════════════════════════"
echo ""

# ── Model catalog ──────────────────────────────────────────────────────────────────────────────
echo "  Catalog (bartowski HuggingFace GGUF collection):"
echo ""
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "#" "Model" "Quant" "VRAM" "Capabilities"
printf "  ────  ────────────────────────────────  ─────  ───────  ──────────────────────────\n"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "1"  "Qwen3-1.7B"               "Q8"  "CPU"    "TOOLS · THINK · tiny"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "2"  "Qwen3-4B"                 "Q4"  "~3 GB"  "TOOLS · THINK"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "3"  "Qwen3-8B"                 "Q4"  "~5 GB"  "TOOLS · THINK"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "4"  "Qwen3-8B"                 "Q6"  "~6 GB"  "TOOLS · THINK · higher quality"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "5"  "Qwen3-14B"                "Q4"  "~9 GB"  "TOOLS · THINK"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "6"  "Phi-4-14B"                "Q4"  "~9 GB"  "TOOLS · THINK · coding"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "7"  "Mistral-Small-3.2-24B"    "Q4"  "~14 GB" "TOOLS · THINK"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "8"  "Qwen3-32B"                "Q4"  "~19 GB" "TOOLS · THINK"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "9"  "Llama-3.3-70B"            "Q4"  "~40 GB" "TOOLS · flagship"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "10" "DeepSeek-R1-Distill-8B"   "Q4"  "~5 GB"  "THINK · deep reasoning"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "11" "DeepSeek-R1-Distill-14B"  "Q4"  "~9 GB"  "THINK · deep reasoning"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "12" "Gemma-3-9B"               "Q4"  "~6 GB"  "TOOLS · Google"
printf "  %-4s  %-32s  %-5s  %-7s  %s\n" "u"  "[enter URL]"              ""    ""       "Custom HuggingFace GGUF URL"
echo ""
read -r -p "  Choice: " _ch

case "\${_ch:-}" in
    1)  M_NAME="Qwen3-1.7B Q8_0"
        M_FILE="Qwen_Qwen3-1.7B-Q8_0.gguf"
        M_URL="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf" ;;
    2)  M_NAME="Qwen3-4B Q4_K_M"
        M_FILE="Qwen_Qwen3-4B-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf" ;;
    3)  M_NAME="Qwen3-8B Q4_K_M"
        M_FILE="Qwen_Qwen3-8B-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf" ;;
    4)  M_NAME="Qwen3-8B Q6_K"
        M_FILE="Qwen_Qwen3-8B-Q6_K.gguf"
        M_URL="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf" ;;
    5)  M_NAME="Qwen3-14B Q4_K_M"
        M_FILE="Qwen_Qwen3-14B-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf" ;;
    6)  M_NAME="Phi-4-14B Q4_K_M"
        M_FILE="phi-4-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf" ;;
    7)  M_NAME="Mistral-Small-3.2-24B Q4_K_M"
        M_FILE="mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf" ;;
    8)  M_NAME="Qwen3-32B Q4_K_M"
        M_FILE="Qwen_Qwen3-32B-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf" ;;
    9)  M_NAME="Llama-3.3-70B Q4_K_M"
        M_FILE="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf" ;;
    10) M_NAME="DeepSeek-R1-Distill-Qwen-8B Q4_K_M"
        M_FILE="DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-8B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf" ;;
    11) M_NAME="DeepSeek-R1-Distill-Qwen-14B Q4_K_M"
        M_FILE="DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf" ;;
    12) M_NAME="Gemma-3-9B Q4_K_M"
        M_FILE="google_gemma-3-9b-it-Q4_K_M.gguf"
        M_URL="https://huggingface.co/bartowski/google_gemma-3-9b-it-GGUF/resolve/main/google_gemma-3-9b-it-Q4_K_M.gguf" ;;
    u|U)
        read -r -p "  HuggingFace GGUF URL: " M_URL
        [[ -z "\${M_URL:-}" ]] && { echo "Cancelled."; exit 0; }
        M_FILE=\$(basename "\$M_URL" | sed 's/?.*//') 
        M_NAME="\$M_FILE" ;;
    *)  echo "Invalid choice — exiting."; exit 0 ;;
esac

# Skip if already on disk
if [[ -f "\$GGUF_DIR/\$M_FILE" ]] && [[ \$(stat -c%s "\$GGUF_DIR/\$M_FILE" 2>/dev/null || echo 0) -gt 1048576 ]]; then
    echo "  ✓ Already on disk: \$(du -sh "\$GGUF_DIR/\$M_FILE" | cut -f1)"
else
    pushd "\$GGUF_DIR" >/dev/null
    DL_OK=0
    command -v aria2c &>/dev/null && \
        aria2c --split=8 --max-connection-per-server=8 --continue=true --file-allocation=none \
               -o "\$M_FILE" "\$M_URL" && DL_OK=1
    (( DL_OK == 0 )) && curl -L -C - --progress-bar -o "\$M_FILE" "\$M_URL" && DL_OK=1
    (( DL_OK == 0 )) && wget -c --show-progress -O "\$M_FILE" "\$M_URL" && DL_OK=1
    (( DL_OK == 0 )) && { echo "✗ Download failed."; popd >/dev/null; exit 1; }
    echo "  ✓ Downloaded: \$(du -sh "\$M_FILE" | cut -f1)"
    popd >/dev/null
fi

# Register with Ollama
if command -v ollama &>/dev/null; then
    _tag=\$(basename "\$M_FILE" .gguf | sed -E 's/-([Qq][0-9].*)$/:\1/' | tr '[:upper:]' '[:lower:]')
    echo "  Registering with Ollama as: \$_tag"
    _mf="\$TEMP_DIR/Modelfile.add.\$\$"
    printf 'FROM %s\nPARAMETER num_gpu 999\nPARAMETER num_thread %s\nPARAMETER num_ctx 8192\n' \
        "\$GGUF_DIR/\$M_FILE" "\$HW_THREADS" > "\$_mf"
    if ! curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        nohup ollama serve >"\$HOME/.ollama.log" 2>&1 &
        sleep 4
    fi
    ollama create "\$_tag" -f "\$_mf" && echo "  ✓ Registered: \$_tag" || echo "  ✗ ollama create failed."
    rm -f "\$_mf"
fi

echo ""
read -r -p "  Set as active default? [y/N] " _sw
[[ "\${_sw:-}" =~ ^[Yy]\$ && -f "\$CONFIG" ]] && {
    _tag=\$(basename "\$M_FILE" .gguf | sed -E 's/-([Qq][0-9].*)$/:\1/' | tr '[:upper:]' '[:lower:]')
    sed -i "s|^MODEL_NAME=.*|MODEL_NAME=\"\$M_NAME\"|"       "\$CONFIG"
    sed -i "s|^MODEL_FILENAME=.*|MODEL_FILENAME=\"\$M_FILE\"|" "\$CONFIG"
    sed -i "s|^OLLAMA_TAG=.*|OLLAMA_TAG=\"\$_tag\"|"          "\$CONFIG"
    echo "  ✓ Active model updated."
}
echo ""
ADDEOF
chmod +x "$BIN_DIR/llm-add"

# ── local-models-info ──────────────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/local-models-info" <<'INFOEOF'
#!/usr/bin/env bash
_cfg="$HOME/.config/local-llm/selected_model.conf"
_r() { grep "^${1}=" "$_cfg" 2>/dev/null | head -1 | cut -d'"' -f2; }
echo ""
echo "═══════════════════════════════════  INSTALLED MODELS  ═══════════════════════════════════"
echo ""
echo "  Ollama models:"
ollama list 2>/dev/null || echo "  (Ollama not running — run: ollama-start)"
echo ""
echo "  GGUF files ($HOME/local-llm-models/gguf):"
shopt -s nullglob
_fs=(~/local-llm-models/gguf/*.gguf)
if [[ ${#_fs[@]} -eq 0 ]]; then echo "  (none)"; else
    for _f in "${_fs[@]}"; do printf "  %-55s %s\n" "$(basename "$_f")" "$(du -sh "$_f" | cut -f1)"; done
fi
echo ""
echo "  Disk usage: $(du -sh ~/local-llm-models 2>/dev/null | cut -f1 || echo '?')"
echo ""
if [[ -f "$_cfg" ]]; then
    echo "  Active config:"
    printf "  %-20s  %s\n" "Model"       "$(_r MODEL_NAME)  [$(_r MODEL_SIZE)]"
    printf "  %-20s  %s\n" "Capabilities" "$(_r MODEL_CAPS)"
    printf "  %-20s  %s\n" "Ollama tag"  "$(_r OLLAMA_TAG)"
    printf "  %-20s  GPU:%s / CPU:%s  Threads:%s  Batch:%s\n" \
        "Layers" "$(_r GPU_LAYERS)" "$(_r MODEL_LAYERS)" "$(_r HW_THREADS)" "$(_r BATCH)"
fi
echo ""
INFOEOF
chmod +x "$BIN_DIR/local-models-info"

# ── llm-show-config ────────────────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-show-config" <<'SHOWCFG'
#!/usr/bin/env bash
_G='\033[0;32m' _Y='\033[1;33m' _C='\033[0;36m' _N='\033[0m'
_cfg="$HOME/.config/local-llm/selected_model.conf"
_r() { grep "^${1}=" "$_cfg" 2>/dev/null | head -1 | cut -d'"' -f2; }
_sp() {
    local lbl="$1" path="$2"
    [[ -e "$path" ]] && printf "  ${_G}✓${_N}  %-26s  %s\n" "$lbl" "$path" \
                     || printf "  ${_Y}✗${_N}  %-26s  ${_Y}%s  (not found)${_N}\n" "$lbl" "$path"
}

echo ""
echo -e "${_C}╔══════════════════════════════════════════════════════════════════════════════════╗${_N}"
echo -e "${_C}║               LOCAL LLM  —  PATHS & CONFIG                                     ║${_N}"
echo -e "${_C}╚══════════════════════════════════════════════════════════════════════════════════╝${_N}"
echo ""
echo -e "${_C}  ── Install Paths ────────────────────────────────────────────────────────────────${_N}"
_sp "Config dir"      "$HOME/.config/local-llm"
_sp "GGUF models"     "$HOME/local-llm-models/gguf"
_sp "Ollama models"   "$HOME/local-llm-models/ollama"
_sp "Neural Terminal" "$HOME/.local/share/llm-webui/llm-chat.html"
_sp "Open WebUI venv" "$HOME/.local/share/open-webui-venv"
_sp "Main venv"       "$HOME/.local/share/llm-venv"
_sp "OI venv"         "$HOME/.local/share/open-interpreter-venv"
_sp "Aider venv"      "$HOME/.local/share/aider-venv"
_sp "bin dir"         "$HOME/.local/bin"
_sp "Alias file"      "$HOME/.local_llm_aliases"
echo ""
echo -e "${_C}  ── Model Config ──────────────────────────────────────────────────────────────────${_N}"
if [[ -f "$_cfg" ]]; then
    printf "  %-22s  ${_G}%s${_N}\n"  "Model"       "$(_r MODEL_NAME)"
    printf "  %-22s  %s\n"             "Size tier"   "$(_r MODEL_SIZE)"
    printf "  %-22s  %s\n"             "Capabilities" "$(_r MODEL_CAPS)"
    printf "  %-22s  ${_Y}%s${_N}\n"  "Ollama tag"  "$(_r OLLAMA_TAG)"
    printf "  %-22s  %s / %s total\n" "GPU layers"  "$(_r GPU_LAYERS)" "$(_r MODEL_LAYERS)"
    printf "  %-22s  %s\n"             "CPU layers"  "$(_r CPU_LAYERS)"
    printf "  %-22s  %s\n"             "Threads"     "$(_r HW_THREADS)"
    printf "  %-22s  %s\n"             "Batch"       "$(_r BATCH)"
    _gguf="$HOME/local-llm-models/gguf/$(_r MODEL_FILENAME)"
    [[ -f "$_gguf" ]] \
        && printf "\n  ${_G}✓${_N}  GGUF on disk: %s  (%s)\n" "$_gguf" "$(du -sh "$_gguf" | cut -f1)" \
        || printf "\n  ${_Y}✗${_N}  GGUF not downloaded: %s\n" "$_gguf"
else
    echo "  (no config — run: llm-setup)"
fi
echo ""
echo -e "${_C}  ── Services ──────────────────────────────────────────────────────────────────────${_N}"
curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 \
    && echo -e "  ${_G}✓${_N}  Ollama  running @ http://127.0.0.1:11434" \
    || echo -e "  ${_Y}✗${_N}  Ollama  not running  (run: ollama-start)"
curl -sf --max-time 2 http://127.0.0.1:8080 >/dev/null 2>&1 \
    && echo -e "  ${_G}✓${_N}  Open WebUI  running @ http://localhost:8080" \
    || echo -e "  ${_Y}–${_N}  Open WebUI  not running  (run: webui)"
curl -sf --max-time 2 http://127.0.0.1:8090 >/dev/null 2>&1 \
    && echo -e "  ${_G}✓${_N}  Neural Terminal  running @ http://localhost:8090" \
    || echo -e "  ${_Y}–${_N}  Neural Terminal  not running  (run: chat)"
echo ""
SHOWCFG
chmod +x "$BIN_DIR/llm-show-config"

# ── llm-checker ─────────────────────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-checker" <<'CHECKER'
#!/usr/bin/env bash
# llm-checker — hardware + model status dashboard
[[ -t 1 ]] && { G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' R='\033[0;31m' N='\033[0m'; } \
            || { G=''; Y=''; C=''; R=''; N=''; }

VRAM=0; GPU_NAME="None"
command -v nvidia-smi &>/dev/null && {
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA")
    VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
           | head -1 | awk '{print int($1/1024)}')
}
RAM=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 0)
THREADS=$(nproc 2>/dev/null || echo 4)

CFG="$HOME/.config/local-llm/selected_model.conf"
MODEL=$(grep "^MODEL_NAME=" "$CFG" 2>/dev/null | cut -d'"' -f2 || echo "(none)")
TAG=$(  grep "^OLLAMA_TAG=" "$CFG" 2>/dev/null | cut -d'"' -f2 || echo "(none)")
CAPS=$( grep "^MODEL_CAPS=" "$CFG" 2>/dev/null | cut -d'"' -f2 || echo "")

echo ""
echo -e "${C}╔══════════════════════════════════════════════════════════════════════════════════╗${N}"
echo -e "${C}║          🔍  LLM CHECKER  —  System & Model Status                               ║${N}"
echo -e "${C}╚══════════════════════════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "${C}  Hardware${N}"
printf "  %-18s %s\n" "CPU threads"  "$THREADS"
printf "  %-18s %s\n" "RAM"          "${RAM} GB"
printf "  %-18s %s\n" "GPU"          "$GPU_NAME"
(( VRAM > 0 )) && printf "  %-18s %s\n" "VRAM" "${VRAM} GB"
echo ""
echo -e "${C}  Ollama${N}"
if command -v ollama &>/dev/null; then
    OV=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
    printf "  %-18s ${G}%s${N}\n" "Version" "$OV"
    [[ "$OV" != "0.12.3" ]] && printf "  ${Y}⚠  Expected 0.12.3 — wrong version may break RTX 30xx GPU!${N}\n"
    curl -s --max-time 2 http://localhost:11434/api/tags &>/dev/null \
        && printf "  %-18s ${G}%s${N}\n" "Status" "running ✓" \
        || printf "  %-18s ${R}%s${N}\n" "Status" "not running  →  ollama-start"
else
    printf "  ${R}Ollama not installed — run: llm-setup${N}\n"
fi
echo ""
echo -e "${C}  Active model${N}"
printf "  %-18s %s\n" "Name"         "$MODEL"
printf "  %-18s %s\n" "Ollama tag"   "$TAG"
printf "  %-18s %s\n" "Capabilities" "${CAPS:-unknown}"
echo ""
echo -e "${C}  Tool integration${N}"
printf "  %-18s %s\n" "API endpoint" "http://127.0.0.1:11434/v1  (OpenAI-compatible)"
printf "  %-18s %s\n" "cowork"       "OI → openai/\$OLLAMA_TAG via Ollama /v1"
printf "  %-18s %s\n" "aider"        "ollama_chat/\$OLLAMA_TAG"
printf "  %-18s %s\n" "Open WebUI"   "OLLAMA_BASE_URL=http://127.0.0.1:11434"
echo ""
echo -e "${C}  Recommended models by VRAM${N}"
(( VRAM >= 24 )) && M_REC="Qwen3-32B Q4_K_M (24 GB+)"  \
    || (( VRAM >= 12 )) && M_REC="Qwen3-14B Q4_K_M" \
    || (( VRAM >= 8  )) && M_REC="Qwen3-8B Q6_K"    \
    || (( VRAM >= 6  )) && M_REC="Qwen3-8B Q4_K_M"  \
    || (( RAM  >= 16 )) && M_REC="Qwen3-8B Q4_K_M (CPU)" \
    || M_REC="Qwen3-4B Q4_K_M (CPU)"
printf "  %-18s ${G}%s${N}\n" "Best fit" "$M_REC"
echo ""
CHECKER
chmod +x "$BIN_DIR/llm-checker"

# =============================================================================
# STEP 13 — OPEN WEBUI
# =============================================================================
step "Open WebUI (primary UI — port 8080)"

info "Setting up Open WebUI venv…"
_ensure_venv "$OWUI_VENV"
"$OWUI_VENV/bin/pip" install --upgrade pip --quiet >> "$LOG_FILE" 2>&1 || true

if is_wsl2; then _OWUI_HOST="0.0.0.0"; else _OWUI_HOST="127.0.0.1"; fi
mkdir -p "$GUI_DIR/open-webui-data"

if "$OWUI_VENV/bin/pip" show open-webui &>/dev/null 2>&1; then
    _old=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}')
    info "Open WebUI $_old already installed — upgrading…"
    _pip_with_ticker "Upgrading open-webui" \
        "$OWUI_VENV/bin/pip" install --upgrade open-webui || warn "Open WebUI upgrade failed."
else
    info "Installing Open WebUI (first install — may take 5–10 min)…"
    _pip_with_ticker "Installing open-webui (5-10 min)" \
        "$OWUI_VENV/bin/pip" install open-webui \
        || warn "Open WebUI install failed — check $LOG_FILE"
fi

_owui_ver=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?")
[[ "$_owui_ver" != "?" ]] && info "Open WebUI $_owui_ver ✓" || warn "Open WebUI may not have installed correctly."
unset _owui_ver _old

# Launcher
cat > "$BIN_DIR/llm-webui" <<OWUI_L
#!/usr/bin/env bash
# llm-webui / webui — Open WebUI (primary chat interface)
set -uo pipefail
OWUI_VENV="\$HOME/.local/share/open-webui-venv"
OWUI_DATA="\$HOME/.local/share/llm-webui/open-webui-data"
BIN_DIR="\$HOME/.local/bin"

# Auto-reinstall if missing
if [[ ! -x "\$OWUI_VENV/bin/open-webui" ]]; then
    echo "  Open WebUI not found — reinstalling (may take 5 min)…"
    "\${PYTHON_BIN:-python3}" -m venv "\$OWUI_VENV" 2>/dev/null || python3 -m venv "\$OWUI_VENV"
    "\$OWUI_VENV/bin/pip" install --quiet --upgrade pip open-webui \
        || { echo "  ERROR: reinstall failed. Run: llm-setup"; exit 1; }
    echo "  ✓ Reinstalled."
fi

# Start Ollama if needed
_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
if ! _up; then
    echo "→ Starting Ollama…"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        [[ -x "\$BIN_DIR/ollama-start" ]] && "\$BIN_DIR/ollama-start" \
            || nohup ollama serve >"\$HOME/.ollama.log" 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null || nohup ollama serve >"\$HOME/.ollama.log" 2>&1 &
    fi
    for _i in {1..20}; do _up && break; sleep 1; done
    _up || echo "  WARNING: Ollama not responding — WebUI may show no models."
fi

# Kill stale process on port 8080
_st=\$(ss -lptn 'sport = :8080' 2>/dev/null \
    | awk 'NR>1{match(\$NF,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1 || \
    fuser 8080/tcp 2>/dev/null || true)
[[ -n "\$_st" ]] && { kill "\$_st" 2>/dev/null || true; sleep 1; }
mkdir -p "\$OWUI_DATA"

# Environment — tool calling + Ollama integration
export OLLAMA_BASE_URL="http://127.0.0.1:11434"
export OLLAMA_API_BASE_URL="http://127.0.0.1:11434"
export ENABLE_OLLAMA_API="true"
export ENABLE_TOOLS="true"
export ENABLE_CODE_EXECUTION="true"
export WEBUI_AUTH="false"
export ENABLE_LOGIN_FORM="false"
export ENABLE_SIGNUP="false"
export DEFAULT_USER_ROLE="admin"
export CORS_ALLOW_ORIGIN="*"
export AIOHTTP_CLIENT_TIMEOUT=900
export AIOHTTP_CLIENT_TIMEOUT_TOTAL=900
export OLLAMA_REQUEST_TIMEOUT=900
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_FLASH_ATTENTION=1
export DATA_DIR="\$OWUI_DATA"
export PYTHONWARNINGS="ignore::RuntimeWarning"

echo ""
echo "  ╔══════════════════════════════════════════════════════════════════════╗"
echo "  ║        🌐  OPEN WEBUI  —  LOCAL LLM                                  ║"
echo "  ║  URL:  http://localhost:8080                                         ║"
echo "  ║  Ollama API: http://127.0.0.1:11434                                  ║"
echo "  ║  Tools / function calling: enabled                                   ║"
echo "  ║  Press Ctrl+C to stop                                                ║"
echo "  ╚══════════════════════════════════════════════════════════════════════╝"
echo ""

exec "\$OWUI_VENV/bin/open-webui" serve --host ${_OWUI_HOST} --port 8080
OWUI_L
chmod +x "$BIN_DIR/llm-webui"
# 'webui' should be a direct copy / symlink
cp "$BIN_DIR/llm-webui" "$BIN_DIR/webui" 2>/dev/null || ln -sf "$BIN_DIR/llm-webui" "$BIN_DIR/webui" || true
chmod +x "$BIN_DIR/webui" 2>/dev/null || true
info "Open WebUI launcher: llm-webui / webui → http://localhost:8080"

# =============================================================================
# STEP 14 — NEURAL TERMINAL (HTML fallback UI)
# =============================================================================
step "Neural Terminal (fallback UI — port 8090)"

python3 - <<'PYHTML'
import os
html = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NEURAL TERMINAL</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;600;700&family=Orbitron:wght@400;700;900&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<style>
:root{--bg:#0a0e1a;--bg2:#0f1525;--bg3:#141b2d;--border:#1e2d4a;--accent:#00d4ff;--accent2:#00ff88;--accent3:#7b2fff;--text:#c8d8f0;--text2:#7a9cc0;--user-bg:#0d1f35;--ai-bg:#081520;--code-bg:#050c18;--danger:#ff4466;--warn:#ffaa00;}
*{margin:0;padding:0;box-sizing:border-box;}
html,body{height:100%;font-family:'JetBrains Mono',monospace;background:var(--bg);color:var(--text);overflow:hidden;}
#app{display:flex;height:100vh;}
#sidebar{width:260px;min-width:200px;background:var(--bg2);border-right:1px solid var(--border);display:flex;flex-direction:column;transition:width .2s;}
#sidebar.collapsed{width:48px;min-width:48px;}
#main{flex:1;display:flex;flex-direction:column;overflow:hidden;}
#sidebar-header{padding:14px 12px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;}
#logo{font-family:'Orbitron',monospace;font-weight:900;font-size:13px;color:var(--accent);letter-spacing:2px;white-space:nowrap;overflow:hidden;}
#toggle-sidebar{background:none;border:none;color:var(--text2);cursor:pointer;font-size:18px;padding:2px 4px;flex-shrink:0;}
#toggle-sidebar:hover{color:var(--accent);}
#new-chat-btn{margin:10px;padding:9px;background:linear-gradient(135deg,var(--accent3),var(--accent));border:none;border-radius:8px;color:#fff;font-family:'JetBrains Mono',monospace;font-size:12px;cursor:pointer;white-space:nowrap;overflow:hidden;}
#new-chat-btn:hover{opacity:.85;}
#sessions-list{flex:1;overflow-y:auto;padding:6px 0;}
.session-item{padding:9px 14px;cursor:pointer;border-left:3px solid transparent;font-size:11px;color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:all .15s;}
.session-item:hover{background:var(--bg3);color:var(--text);}
.session-item.active{border-left-color:var(--accent);background:var(--bg3);color:var(--accent);}
#topbar{padding:10px 16px;border-bottom:1px solid var(--border);background:var(--bg2);display:flex;align-items:center;gap:10px;}
#model-select{flex:1;background:var(--bg3);border:1px solid var(--border);color:var(--text);padding:6px 10px;border-radius:6px;font-family:'JetBrains Mono',monospace;font-size:12px;cursor:pointer;}
#model-select:focus{outline:1px solid var(--accent);}
#status-dot{width:8px;height:8px;border-radius:50%;background:var(--danger);flex-shrink:0;}
#status-dot.online{background:var(--accent2);}
#status-text{font-size:11px;color:var(--text2);white-space:nowrap;}
#export-btn{background:none;border:1px solid var(--border);color:var(--text2);padding:5px 10px;border-radius:6px;font-size:11px;cursor:pointer;white-space:nowrap;}
#export-btn:hover{border-color:var(--accent);color:var(--accent);}
#messages{flex:1;overflow-y:auto;padding:20px;display:flex;flex-direction:column;gap:16px;}
#messages::-webkit-scrollbar{width:4px;}
#messages::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px;}
.msg{display:flex;gap:12px;max-width:820px;}
.msg.user{align-self:flex-end;flex-direction:row-reverse;max-width:75%;}
.msg.assistant{align-self:flex-start;}
.avatar{width:30px;height:30px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:14px;flex-shrink:0;}
.msg.user .avatar{background:linear-gradient(135deg,var(--accent3),var(--accent));color:#fff;}
.msg.assistant .avatar{background:linear-gradient(135deg,var(--accent2)33,var(--bg3));border:1px solid var(--accent2)44;color:var(--accent2);}
.bubble{padding:12px 16px;border-radius:10px;font-size:13px;line-height:1.65;white-space:pre-wrap;word-break:break-word;}
.msg.user .bubble{background:var(--user-bg);border:1px solid var(--border);}
.msg.assistant .bubble{background:var(--ai-bg);border:1px solid var(--border);}
.bubble code{font-family:'JetBrains Mono',monospace;font-size:12px;}
.bubble pre{background:var(--code-bg)!important;border:1px solid var(--border);border-radius:6px;padding:12px;overflow-x:auto;margin:8px 0;}
.bubble pre code{background:transparent!important;padding:0;font-size:12px;}
.thinking-block{background:var(--bg3);border:1px solid var(--accent3)44;border-radius:8px;padding:10px 14px;margin:4px 0;font-size:12px;color:var(--text2);font-style:italic;}
.thinking-block summary{cursor:pointer;color:var(--accent3);font-weight:600;}
#empty-state{text-align:center;margin:auto;padding:40px 20px;}
.empty-logo{font-family:'Orbitron',monospace;font-size:36px;font-weight:900;background:linear-gradient(135deg,var(--accent),var(--accent2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:6px;}
.empty-sub{color:var(--text2);font-size:12px;margin:8px 0 30px;letter-spacing:2px;}
.suggestion-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;max-width:520px;margin:0 auto;}
.suggestion{background:var(--bg3);border:1px solid var(--border);border-radius:8px;padding:12px 14px;font-size:11px;color:var(--text2);cursor:pointer;text-align:left;transition:all .15s;}
.suggestion:hover{border-color:var(--accent);color:var(--text);background:var(--bg2);}
#input-area{padding:14px 16px;border-top:1px solid var(--border);background:var(--bg2);}
#input-row{display:flex;gap:10px;align-items:flex-end;}
#prompt{flex:1;background:var(--bg3);border:1px solid var(--border);color:var(--text);padding:10px 14px;border-radius:8px;font-family:'JetBrains Mono',monospace;font-size:13px;resize:none;min-height:44px;max-height:160px;line-height:1.5;}
#prompt:focus{outline:1px solid var(--accent);}
#prompt::placeholder{color:var(--text2);}
#send-btn{background:linear-gradient(135deg,var(--accent3),var(--accent));border:none;color:#fff;width:44px;height:44px;border-radius:8px;cursor:pointer;font-size:18px;flex-shrink:0;display:flex;align-items:center;justify-content:center;}
#send-btn:disabled{opacity:.4;cursor:not-allowed;}
#send-btn:not(:disabled):hover{opacity:.85;}
#input-hint{font-size:10px;color:var(--text2);margin-top:6px;text-align:center;}
.typing-indicator{display:flex;gap:5px;align-items:center;padding:8px 0;}
.typing-indicator span{width:7px;height:7px;border-radius:50%;background:var(--accent2);animation:bounce .9s infinite;}
.typing-indicator span:nth-child(2){animation-delay:.15s;}
.typing-indicator span:nth-child(3){animation-delay:.3s;}
@keyframes bounce{0%,60%,100%{transform:translateY(0);}30%{transform:translateY(-6px);}}
#sys-row{display:flex;gap:8px;margin-bottom:8px;align-items:center;}
#sys-toggle{background:none;border:1px solid var(--border);color:var(--text2);padding:4px 10px;border-radius:5px;font-size:10px;cursor:pointer;}
#sys-toggle:hover{border-color:var(--accent3);color:var(--accent3);}
#sys-prompt{display:none;width:100%;background:var(--bg3);border:1px solid var(--accent3)44;color:var(--text2);padding:8px 12px;border-radius:6px;font-family:'JetBrains Mono',monospace;font-size:11px;resize:vertical;min-height:56px;margin-bottom:8px;}
#sys-prompt.open{display:block;}
</style>
</head>
<body>
<div id="app">
  <div id="sidebar">
    <div id="sidebar-header">
      <button id="toggle-sidebar" title="Toggle sidebar">☰</button>
      <div id="logo">N T</div>
    </div>
    <button id="new-chat-btn">＋ New chat</button>
    <div id="sessions-list"></div>
  </div>
  <div id="main">
    <div id="topbar">
      <select id="model-select"><option value="">Loading models…</option></select>
      <div id="status-dot"></div>
      <div id="status-text">checking…</div>
      <button id="export-btn">⬇ export</button>
    </div>
    <div id="messages"></div>
    <div id="input-area">
      <div id="sys-row"><button id="sys-toggle">⚙ system prompt</button></div>
      <textarea id="sys-prompt" placeholder="System prompt (optional)…"></textarea>
      <div id="input-row">
        <textarea id="prompt" rows="1" placeholder="Message… (Shift+Enter=newline, /think=reasoning)"></textarea>
        <button id="send-btn">▶</button>
      </div>
      <div id="input-hint">Enter = send · Shift+Enter = newline · /think = reasoning mode</div>
    </div>
  </div>
</div>
<script>
const API='http://localhost:11434';
let sessions=JSON.parse(localStorage.getItem('nt_sessions')||'[]');
let activeId=localStorage.getItem('nt_active')||null;
let isStreaming=false;
function save(){localStorage.setItem('nt_sessions',JSON.stringify(sessions));localStorage.setItem('nt_active',activeId||'');}
function newSession(){const id='sess_'+Date.now();sessions.unshift({id,name:'New chat',history:[]});activeId=id;save();renderSidebar();renderMessages();}
function getActive(){return sessions.find(s=>s.id===activeId)||sessions[0];}
if(!sessions.length)newSession();
if(!activeId||!sessions.find(s=>s.id===activeId))activeId=sessions[0].id;
const dot=document.getElementById('status-dot');
const stxt=document.getElementById('status-text');
const sel=document.getElementById('model-select');
async function checkOllama(){
  try{
    const r=await fetch(`${API}/api/tags`,{signal:AbortSignal.timeout(3000)});
    if(!r.ok)throw new Error();
    const d=await r.json();
    dot.className='online';stxt.textContent='Ollama online';
    const models=(d.models||[]).map(m=>m.name);
    const prev=sel.value;
    sel.innerHTML=models.length?models.map(m=>`<option value="${m}">${m}</option>`).join(''):'<option value="">No models — run: ollama pull qwen3:8b</option>';
    const saved=localStorage.getItem('nt_model');
    if(prev&&models.includes(prev))sel.value=prev;
    else if(saved&&models.includes(saved))sel.value=saved;
    else if(models.length)sel.value=models[0];
  }catch{dot.className='';stxt.textContent='Ollama offline';sel.innerHTML='<option value="">Ollama offline — run: ollama-start</option>';}
}
sel.addEventListener('change',()=>localStorage.setItem('nt_model',sel.value));
checkOllama();setInterval(checkOllama,8000);
function escHtml(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function renderMarkdown(text){
  text=text.replace(/<think>([\s\S]*?)<\/think>/gi,(_,t)=>`<details class="thinking-block"><summary>💭 Reasoning</summary><pre style="white-space:pre-wrap;margin:8px 0 0">${escHtml(t.trim())}</pre></details>`);
  text=text.replace(/```(\w*)\n?([\s\S]*?)```/g,(_,lang,code)=>{
    const e=escHtml(code.trim());
    const h=lang?(()=>{try{return hljs.highlight(e,{language:lang,ignoreIllegals:true}).value;}catch{return e;}})():hljs.highlightAuto(e).value;
    return `<pre><code class="hljs">${h}</code></pre>`;
  });
  text=text.replace(/`([^`\n]+)`/g,'<code>$1</code>');
  text=text.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
  text=text.replace(/\*([^*]+)\*/g,'<em>$1</em>');
  text=text.replace(/^### (.+)$/gm,'<strong style="color:var(--accent)">$1</strong>');
  text=text.replace(/^## (.+)$/gm,'<strong style="font-size:1.05em;color:var(--accent2)">$1</strong>');
  text=text.replace(/^# (.+)$/gm,'<strong style="font-size:1.1em;color:var(--accent)">$1</strong>');
  return text;
}
function appendMsg(role,content,streaming=false){
  const msgs=document.getElementById('messages');
  if(streaming){
    let el=document.getElementById('streaming-msg');
    if(!el){
      el=document.createElement('div');
      el.className=`msg ${role}`;
      el.id='streaming-msg';
      el.innerHTML=`<div class="avatar">${role==='user'?'👤':'🤖'}</div><div class="bubble"></div>`;
      msgs.appendChild(el);
    }
    el.querySelector('.bubble').innerHTML=renderMarkdown(content);
    msgs.scrollTop=msgs.scrollHeight;return;
  }
  const el=document.createElement('div');
  el.className=`msg ${role}`;
  el.innerHTML=`<div class="avatar">${role==='user'?'👤':'🤖'}</div><div class="bubble">${renderMarkdown(content)}</div>`;
  msgs.appendChild(el);msgs.scrollTop=msgs.scrollHeight;
}
function renderSidebar(){
  const list=document.getElementById('sessions-list');
  list.innerHTML=sessions.map(s=>`<div class="session-item${s.id===activeId?' active'}" data-id="${s.id}">${escHtml(s.name)}</div>`).join('');
  list.querySelectorAll('.session-item').forEach(el=>{
    el.addEventListener('click',()=>{activeId=el.dataset.id;save();renderSidebar();renderMessages();});
  });
}
document.getElementById('toggle-sidebar').addEventListener('click',()=>document.getElementById('sidebar').classList.toggle('collapsed'));
document.getElementById('new-chat-btn').addEventListener('click',newSession);
document.getElementById('sys-toggle').addEventListener('click',()=>document.getElementById('sys-prompt').classList.toggle('open'));
function renderMessages(){
  const msgs=document.getElementById('messages');
  const sess=getActive();
  if(!sess||!sess.history.filter(m=>m.role!=='system').length){
    msgs.innerHTML=`<div id="empty-state"><div class="empty-logo">N T</div><div class="empty-sub">Neural Terminal · Local LLM</div><div class="suggestion-grid"><div class="suggestion" onclick="useSuggestion(this)">Explain how transformers work</div><div class="suggestion" onclick="useSuggestion(this)">Write a Python script to batch rename files</div><div class="suggestion" onclick="useSuggestion(this)">/think What is the best sorting algorithm?</div><div class="suggestion" onclick="useSuggestion(this)">Debug this code:</div></div></div>`;
    return;
  }
  msgs.innerHTML='';
  sess.history.forEach(m=>{if(m.role==='system')return;appendMsg(m.role,m.content,false);});
}
function useSuggestion(el){document.getElementById('prompt').value=el.textContent;sendMessage();}
const promptEl=document.getElementById('prompt');
const sendBtn=document.getElementById('send-btn');
promptEl.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sendMessage();}});
promptEl.addEventListener('input',()=>{promptEl.style.height='auto';promptEl.style.height=Math.min(promptEl.scrollHeight,160)+'px';});
sendBtn.addEventListener('click',sendMessage);
async function sendMessage(){
  const text=promptEl.value.trim();
  if(!text||isStreaming)return;
  const model=sel.value;
  if(!model){alert('No model selected. Start Ollama: ollama-start');return;}
  const sess=getActive();
  const es=document.getElementById('empty-state');if(es)es.remove();
  const sysText=document.getElementById('sys-prompt').value.trim();
  if(sysText&&!sess.history.find(m=>m.role==='system'))sess.history.unshift({role:'system',content:sysText});
  let userContent=text,thinkMode=false;
  if(text.startsWith('/think ')){userContent=text.slice(7);thinkMode=true;}
  sess.history.push({role:'user',content:userContent});
  if(sess.name==='New chat')sess.name=userContent.slice(0,36)+(userContent.length>36?'…':'');
  save();renderSidebar();appendMsg('user',userContent);
  promptEl.value='';promptEl.style.height='auto';
  const msgs=document.getElementById('messages');
  const typingEl=document.createElement('div');
  typingEl.className='msg assistant';typingEl.id='typing-indicator';
  typingEl.innerHTML='<div class="avatar">🤖</div><div class="bubble"><div class="typing-indicator"><span></span><span></span><span></span></div></div>';
  msgs.appendChild(typingEl);msgs.scrollTop=msgs.scrollHeight;
  isStreaming=true;sendBtn.disabled=true;
  try{
    const apiMessages=[...sess.history];
    if(thinkMode){apiMessages[apiMessages.length-1]={role:'user',content:'/think '+userContent};}
    const resp=await fetch(`${API}/api/chat`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({model,messages:apiMessages,stream:true,options:{temperature:0.7,top_p:0.95}})});
    if(!resp.ok)throw new Error(`HTTP ${resp.status}`);
    typingEl.remove();
    let full='';
    const reader=resp.body.getReader();
    const dec=new TextDecoder();
    while(true){
      const{done,value}=await reader.read();if(done)break;
      for(const line of dec.decode(value).split('\n')){
        if(!line.trim())continue;
        try{const chunk=JSON.parse(line);if(chunk.message?.content){full+=chunk.message.content;appendMsg('assistant',full,true);}if(chunk.done)break;}catch{}
      }
    }
    const streamEl=document.getElementById('streaming-msg');if(streamEl)streamEl.removeAttribute('id');
    sess.history.push({role:'assistant',content:full});save();
  }catch(err){
    typingEl.remove();appendMsg('assistant',`⚠ Error: ${err.message}\n\nIs Ollama running? Try: ollama-start`);
  }finally{isStreaming=false;sendBtn.disabled=false;promptEl.focus();}
}
document.getElementById('export-btn').addEventListener('click',()=>{
  const sess=getActive();const msgs=sess.history.filter(m=>m.role!=='system');
  if(!msgs.length){alert('Nothing to export.');return;}
  const model=sel.value||'unknown';
  let md=`# ${sess.name}\n\n**Model:** ${model}  \n**Exported:** ${new Date().toLocaleString()}\n\n---\n\n`;
  msgs.forEach(m=>{md+=(m.role==='user'?'## 👤 User':'## 🤖 Assistant')+`\n\n${m.content}\n\n---\n\n`;});
  const a=document.createElement('a');
  a.href=URL.createObjectURL(new Blob([md],{type:'text/markdown'}));
  a.download=(sess.name.replace(/[^a-z0-9]/gi,'_').toLowerCase()||'chat')+'.md';
  a.click();URL.revokeObjectURL(a.href);
});
renderSidebar();renderMessages();promptEl.focus();
</script>
</body>
</html>
"""
path = os.path.expanduser('$HOME/.local/share/llm-webui/llm-chat.html')
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'w') as f:
    f.write(html)
print(f"Neural Terminal written: {path}")
PYHTML

# Neural Terminal launcher
cat > "$BIN_DIR/llm-chat" <<'NT_L'
#!/usr/bin/env bash
# llm-chat / chat — Neural Terminal (zero-dependency HTML fallback UI)
set -uo pipefail
GUI_DIR="$HOME/.local/share/llm-webui"
HTML_FILE="$GUI_DIR/llm-chat.html"
BIN_DIR="$HOME/.local/bin"
PORT=8090

[[ ! -f "$HTML_FILE" ]] && { echo "ERROR: HTML file not found. Run: llm-setup"; exit 1; }

_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
if ! _up; then
    echo "→ Starting Ollama…"
    grep -qi microsoft /proc/version 2>/dev/null \
        && { [[ -x "$BIN_DIR/ollama-start" ]] && "$BIN_DIR/ollama-start" \
            || nohup ollama serve >"$HOME/.ollama.log" 2>&1 &; } \
        || { sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >"$HOME/.ollama.log" 2>&1 &; }
    for _i in {1..12}; do _up && break; sleep 1; done
fi

# Kill stale server on port
OLD=$(lsof -ti tcp:$PORT 2>/dev/null || true)
[[ -n "$OLD" ]] && { kill "$OLD" 2>/dev/null || true; sleep 0.5; }

echo "→ Starting Neural Terminal on http://localhost:$PORT …"
python3 -m http.server "$PORT" --directory "$GUI_DIR" --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP_PID=$!
sleep 0.8

kill -0 "$HTTP_PID" 2>/dev/null || { echo "ERROR: HTTP server failed — port $PORT in use?"; exit 1; }
URL="http://localhost:$PORT/llm-chat.html"
echo "→ $URL  (Ctrl+C to stop)"
grep -qi microsoft /proc/version 2>/dev/null \
    && { cmd.exe /c start "" "$URL" 2>/dev/null || true; } \
    || xdg-open "$URL" 2>/dev/null || echo "  Open manually: $URL"

trap "echo ''; echo 'Stopping…'; kill $HTTP_PID 2>/dev/null; exit 0" INT TERM
wait "$HTTP_PID"
NT_L
chmod +x "$BIN_DIR/llm-chat"
cp "$BIN_DIR/llm-chat" "$BIN_DIR/chat" 2>/dev/null \
    || ln -sf "$BIN_DIR/llm-chat" "$BIN_DIR/chat" || true
chmod +x "$BIN_DIR/chat" 2>/dev/null || true
info "Neural Terminal: llm-chat / chat → http://localhost:8090"

# =============================================================================
# STEP 15 — OPTIONAL TOOLS
# =============================================================================
step "Optional tools"

HAVE_DISPLAY=0
{ [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; } && HAVE_DISPLAY=1
is_wsl2 && HAVE_DISPLAY=1

printf "\n"
printf "  ${CYAN}Which optional tools would you like?${NC}\n"
printf "  ${MUTED}Enter numbers space-separated, 'all', or Enter to skip.${NC}\n\n"
printf "  ${YELLOW}%-4s${NC}  %-20s  %s\n" "1" "tmux"       "terminal multiplexer"
printf "  ${YELLOW}%-4s${NC}  %-20s  %s\n" "2" "CLI tools"  "bat eza fzf ripgrep btop ncdu jq micro"
(( HAS_GPU )) \
    && printf "  ${YELLOW}%-4s${NC}  %-20s  %s\n" "3" "nvtop"      "live GPU VRAM monitor" \
    || printf "  ${MUTED}%-4s  %-20s  %s${NC}\n"  "3" "nvtop"      "(no GPU — skipped)"
(( HAVE_DISPLAY )) \
    && printf "  ${YELLOW}%-4s${NC}  %-20s  %s\n" "4" "GUI tools"  "Thunar Mousepad Meld" \
    || printf "  ${MUTED}%-4s  %-20s  %s${NC}\n"  "4" "GUI tools"  "(no display — skipped)"
printf "  ${YELLOW}%-4s${NC}  %-20s  %s\n" "5" "neofetch"   "system info banner"
printf "\n  ${CYAN}── AI coding agents ─────────────────────────────────────────${NC}\n"
printf "  ${YELLOW}%-4s${NC}  %-20s  %s\n" "6" "Claude Code"   "Anthropic CLI agent (needs ANTHROPIC_API_KEY)"
printf "  ${YELLOW}%-4s${NC}  %-20s  %s\n" "7" "OpenAI Codex"  "OpenAI CLI agent (needs OPENAI_API_KEY)"
printf "\n  ${CYAN}── Security / Pentesting ────────────────────────────────────${NC}\n"
printf "  ${YELLOW}%-4s${NC}  %-20s  %s\n" "8" "PentestAgent"  "AI pentesting framework (RAG + Ollama)"
printf "\n"
[[ -t 0 ]] && read -r -p "  > " _tools || _tools=""
[[ "${_tools:-}" == "all" ]] && _tools="1 2 3 4 5 6 7 8"

# 1 — tmux
if [[ " ${_tools:-} " == *" 1 "* ]]; then
    sudo apt-get install -y tmux >> "$LOG_FILE" 2>&1 && info "tmux installed." || warn "tmux install failed."
    [[ ! -f "$HOME/.tmux.conf" ]] && cat > "$HOME/.tmux.conf" <<'TC'
set -g default-terminal "screen-256color"
set -g history-limit 10000
set -g mouse on
set -g base-index 1
set -g pane-base-index 1
set -g status-style 'bg=#1a2535 fg=#00ff88'
set -g status-left '#[bold] 🤖 LLM  '
set -g status-right '#[fg=#00d4ff] %H:%M  #[fg=#00ff88]%d-%b '
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind r source-file ~/.tmux.conf \; display "Config reloaded"
TC
fi

# 2 — CLI tools
if [[ " ${_tools:-} " == *" 2 "* ]]; then
    _apt_install bat fzf ripgrep fd-find btop htop ncdu jq tree p7zip-full unzip zip
    command -v eza &>/dev/null || sudo apt-get install -y eza >> "$LOG_FILE" 2>&1 \
        || sudo apt-get install -y exa >> "$LOG_FILE" 2>&1 || true
    command -v micro &>/dev/null || {
        curl -fsSL https://getmic.ro 2>/dev/null | bash \
            && mv micro "$BIN_DIR/" 2>/dev/null || true
    }
    if ! grep -q "# llm-qol-aliases" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" <<'QOL'
# ── QoL aliases (llm-auto-setup) ────────────────────────────────────────────
# llm-qol-aliases
command -v bat    &>/dev/null && alias cat='bat --paging=never'
command -v eza    &>/dev/null && alias ls='eza --icons' && alias ll='eza -la --icons'
command -v btop   &>/dev/null && alias top='btop'
command -v fdfind &>/dev/null && ! command -v fd &>/dev/null && alias fd='fdfind'
QOL
    fi
    info "CLI tools installed."
fi

# 3 — nvtop
if [[ " ${_tools:-} " == *" 3 "* ]] && (( HAS_GPU )); then
    sudo apt-get install -y nvtop >> "$LOG_FILE" 2>&1 \
        && info "nvtop installed." || warn "nvtop: try: sudo snap install nvtop"
fi

# 4 — GUI tools
if [[ " ${_tools:-} " == *" 4 "* ]] && (( HAVE_DISPLAY )); then
    _apt_install thunar mousepad meld
    info "GUI tools installed."
fi

# 5 — neofetch/fastfetch
if [[ " ${_tools:-} " == *" 5 "* ]]; then
    sudo apt-get install -y neofetch >> "$LOG_FILE" 2>&1 || true
    sudo apt-get install -y fastfetch >> "$LOG_FILE" 2>&1 \
        || sudo snap install fastfetch >> "$LOG_FILE" 2>&1 || true
    info "neofetch / fastfetch installed."
fi

# 6 — Claude Code
if [[ " ${_tools:-} " == *" 6 "* ]]; then
    if command -v npm &>/dev/null; then
        sudo npm install -g @anthropic-ai/claude-code >> "$LOG_FILE" 2>&1 \
            && info "Claude Code installed." || warn "Claude Code install failed."
        cat > "$BIN_DIR/claude-code" <<'CC'
#!/usr/bin/env bash
mkdir -p "$HOME/work"; cd "$HOME/work"
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "  ANTHROPIC_API_KEY not set."
    echo "  Get a key: https://console.anthropic.com/"
    read -r -p "  Enter key (or Enter to exit): " _k
    [[ -z "$_k" ]] && exit 1
    export ANTHROPIC_API_KEY="$_k"
fi
exec claude "$@"
CC
        chmod +x "$BIN_DIR/claude-code"
        info "Claude Code → run: claude  (set: export ANTHROPIC_API_KEY=sk-ant-...)"
    else
        warn "Claude Code skipped — Node.js not available."
    fi
fi

# 7 — OpenAI Codex
if [[ " ${_tools:-} " == *" 7 "* ]]; then
    if command -v npm &>/dev/null; then
        sudo npm install -g @openai/codex >> "$LOG_FILE" 2>&1 \
            && info "OpenAI Codex installed." || warn "OpenAI Codex install failed."
    else
        warn "OpenAI Codex skipped — Node.js not available."
    fi
fi

# 8 — PentestAgent
if [[ " ${_tools:-} " == *" 8 "* ]]; then
    PA_DIR="$HOME/pentestagent"
    PA_VENV="$PA_DIR/venv"
    PA_LAUNCH="$BIN_DIR/pentestagent-start"
    info "Installing PentestAgent…"
    command -v git &>/dev/null || sudo apt-get install -y git >> "$LOG_FILE" 2>&1
    [[ -d "$PA_DIR" ]] || git clone https://github.com/vishnupriyavr/pentest-agent "$PA_DIR" >> "$LOG_FILE" 2>&1 \
        || warn "PentestAgent: git clone failed."
    if [[ -d "$PA_DIR" ]]; then
        _ensure_venv "$PA_VENV"
        _pip_with_ticker "pip: pentestagent deps" \
            "$PA_VENV/bin/pip" install -r "$PA_DIR/requirements.txt" \
            || warn "PentestAgent pip install failed."
        cat > "$BIN_DIR/pentestagent-start" <<'PA'
#!/usr/bin/env bash
PA_DIR="$HOME/pentestagent"; PA_VENV="$PA_DIR/venv"
[[ ! -d "$PA_VENV" ]] && { echo "PentestAgent not installed. Run: llm-setup → opt 8"; exit 1; }
_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
_up || { nohup ollama serve >"$HOME/.ollama.log" 2>&1 & sleep 3; }
ollama list 2>/dev/null | grep -q "nomic-embed-text" \
    || ollama pull nomic-embed-text 2>/dev/null || true
export OPENAI_API_KEY="ollama-local"
export OPENAI_BASE_URL="http://localhost:11434/v1"
source "$PA_VENV/bin/activate"
cd "$PA_DIR"
exec pentestagent "$@"
PA
        chmod +x "$BIN_DIR/pentestagent-start"
        info "PentestAgent installed. Launch: pentestagent-start"
        warn "LEGAL: Only test systems you own or have written permission to test."
    fi
fi

[[ -n "${_tools:-}" ]] && info "Optional tools complete." || info "Optional tools: skipped."
unset _tools HAVE_DISPLAY

# =============================================================================
# STEP 16 — AUTONOMOUS COWORKING (Open Interpreter + Aider)
# =============================================================================
step "Autonomous coworking (Open Interpreter + Aider)"

# ── Open Interpreter ─────────────────────────────────────────────────────────
info "Installing Open Interpreter (pkg_resources fix applied)…"

# Always recreate OI venv — stale venvs on Python 3.12 consistently break pkg_resources
rm -rf "$OI_VENV"
"${PYTHON_BIN:-python3}" -m venv "$OI_VENV" \
    || error "Failed to create Open Interpreter venv."

_pbar 10 "Bootstrap pip"
"$OI_VENV/bin/python3" -m ensurepip --upgrade >> "$LOG_FILE" 2>&1 || true
"$OI_VENV/bin/pip" install --upgrade --no-cache-dir pip >> "$LOG_FILE" 2>&1

_pbar 20 "setuptools≥70 (pkg_resources fix)"
"$OI_VENV/bin/pip" install --no-cache-dir "setuptools>=70" wheel >> "$LOG_FILE" 2>&1

# pkg_resources guaranteed check — covers Python 3.12+ stdlib omission
if ! "$OI_VENV/bin/python3" -c "import pkg_resources" 2>/dev/null; then
    _pbar 25 "Force-reinstall setuptools"
    "$OI_VENV/bin/pip" install --force-reinstall --no-cache-dir "setuptools>=70" >> "$LOG_FILE" 2>&1
fi

# Last resort: copy from system if pip can't deliver it
if ! "$OI_VENV/bin/python3" -c "import pkg_resources" 2>/dev/null; then
    _pbar 28 "Injecting system setuptools"
    _sys_st=$(python3 -c "import setuptools,os; print(os.path.dirname(setuptools.__file__))" 2>/dev/null || true)
    _venv_sp=$(ls -d "$OI_VENV/lib/python3"*/site-packages 2>/dev/null | head -1 || true)
    [[ -n "$_sys_st" && -n "$_venv_sp" ]] && cp -r "$_sys_st" "$_venv_sp/" 2>/dev/null || true
    unset _sys_st _venv_sp
fi

_pbar 30 "pip: open-interpreter"
_pip_with_ticker "pip: open-interpreter" \
    "$OI_VENV/bin/pip" install --no-cache-dir open-interpreter

if "$OI_VENV/bin/python3" -c "import pkg_resources; import interpreter" 2>/dev/null; then
    info "Open Interpreter ✓  (pkg_resources OK)"
else
    warn "Open Interpreter health check failed — run 'cowork' to test; re-run setup if it crashes."
fi

# cowork launcher — tool integration via Ollama OpenAI-compatible /v1 API
cat > "$BIN_DIR/cowork" <<'CW'
#!/usr/bin/env bash
# cowork — autonomous AI coworker (Open Interpreter + Ollama)
# Tool calling: models with [TOOLS] cap use openai/ prefix → Ollama /v1/chat/completions
set -uo pipefail
OI_VENV="$HOME/.local/share/open-interpreter-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"
WORK_DIR="$HOME/work"

[[ ! -x "$OI_VENV/bin/interpreter" ]] && {
    echo "ERROR: Open Interpreter not installed. Run: llm-setup"
    exit 1
}
mkdir -p "$WORK_DIR"; cd "$WORK_DIR"

OLLAMA_TAG=$(grep "^OLLAMA_TAG=" "$CONFIG" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "qwen3:8b")
MODEL_CAPS=$(grep "^MODEL_CAPS=" "$CONFIG" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "")

_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
STARTED_OLLAMA=0
if ! _up; then
    echo "→ Starting Ollama…"
    grep -qi microsoft /proc/version 2>/dev/null \
        && { command -v ollama-start &>/dev/null && ollama-start \
            || nohup ollama serve >"$HOME/.ollama.log" 2>&1 &; } \
        || { sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >"$HOME/.ollama.log" 2>&1 &; }
    STARTED_OLLAMA=1
    for _i in {1..15}; do _up && break; sleep 1; done
fi
_cleanup() { (( ${STARTED_OLLAMA:-0} )) && pkill -f "ollama serve" 2>/dev/null || true; }
trap '_cleanup' INT TERM EXIT

echo ""
echo "  ╔══════════════════════════════════════════════════════════════════════╗"
echo "  ║           🤖  AUTONOMOUS COWORKER                                    ║"
printf "  ║  Model  : %-39s║\n" "$OLLAMA_TAG"
printf "  ║  Caps   : %-39s║\n" "${MODEL_CAPS:-general}"
echo "  ║  Backend: Ollama /v1 (fully local)                                   ║"
echo "  ║  Dir    : ~/work  ·  type 'exit' to quit                             ║"
echo "  ╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Tool calling: Open Interpreter uses OpenAI-compatible /v1 endpoint
# Models with TOOLS capability (Qwen3, Phi-4, Mistral) support function calling
export OPENAI_API_KEY="ollama"
export OPENAI_BASE_URL="http://127.0.0.1:11434/v1"
export OPENAI_API_BASE="http://127.0.0.1:11434/v1"

"$OI_VENV/bin/interpreter" \
    --model "openai/${OLLAMA_TAG}" \
    --context_window 8192 \
    --max_tokens 4096 \
    --api_base "http://127.0.0.1:11434/v1" \
    --api_key "ollama" \
    --safe_mode "off" \
    "$@"
CW
chmod +x "$BIN_DIR/cowork"

# ── Aider ────────────────────────────────────────────────────────────────────
info "Installing Aider…"
_ensure_venv "$AI_VENV"
_pip_with_ticker "pip: aider-chat" \
    "$AI_VENV/bin/pip" install aider-chat \
    || warn "Aider install failed."

cat > "$BIN_DIR/aider" <<'AI'
#!/usr/bin/env bash
# aider — AI pair programmer with git integration (via Ollama)
set -uo pipefail
AI_VENV="$HOME/.local/share/aider-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"

[[ ! -x "$AI_VENV/bin/aider" ]] && { echo "ERROR: Aider not installed. Run: llm-setup"; exit 1; }

OLLAMA_TAG=$(grep "^OLLAMA_TAG=" "$CONFIG" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "qwen3:8b")

_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
STARTED_OLLAMA=0
if ! _up; then
    echo "→ Starting Ollama…"
    grep -qi microsoft /proc/version 2>/dev/null \
        && { command -v ollama-start &>/dev/null && ollama-start \
            || nohup ollama serve >"$HOME/.ollama.log" 2>&1 &; } \
        || { sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >"$HOME/.ollama.log" 2>&1 &; }
    STARTED_OLLAMA=1; sleep 3
fi
_cleanup() { (( ${STARTED_OLLAMA:-0} )) && pkill -f "ollama serve" 2>/dev/null || true; }
trap '_cleanup' INT TERM EXIT

echo ""
echo "  ╔══════════════════════════════════════════════════════════════════════╗"
echo "  ║         🛠  AIDER  —  AI PAIR PROGRAMMER                             ║"
printf "  ║  Model : %-41s║\n" "$OLLAMA_TAG"
echo "  ║  Usage : aider file.py  (or no args for chat)                        ║"
echo "  ╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Tool calling via ollama_chat/ provider (uses /api/chat — best Ollama integration)
export OLLAMA_API_BASE="http://127.0.0.1:11434"

"$AI_VENV/bin/aider" \
    --model "ollama_chat/${OLLAMA_TAG}" \
    --ollama-api-base "http://127.0.0.1:11434" \
    --no-auto-commits \
    --no-check-update \
    --no-show-model-warnings \
    --no-show-release-notes \
    --analytics-disable \
    --no-gitignore \
    --no-fancy-input \
    --stream \
    "$@"
AI
chmod +x "$BIN_DIR/aider"

info "cowork (Open Interpreter) and aider installed."

# =============================================================================
# STEP 17 — LLM-HELP
# =============================================================================
cat > "$BIN_DIR/llm-help" <<'HELP'
#!/usr/bin/env bash
_C='\033[0;36m' _Y='\033[1;33m' _G='\033[0;32m' _M='\033[0;35m' _N='\033[0m'
echo ""
echo -e "${_C}╔══════════════════════════════════════════════════════════════════════════════════╗${_N}"
echo -e "${_C}║              🤖  LOCAL LLM  —  COMMAND REFERENCE                                 ║${_N}"
echo -e "${_C}╚══════════════════════════════════════════════════════════════════════════════════╝${_N}"
echo ""
echo -e "${_C}  ── Chat UIs ─────────────────────────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}webui${_N}  /  ${_Y}llm-webui${_N}     Open WebUI  →  http://localhost:8080  (primary)"
echo -e "   ${_Y}chat${_N}   /  ${_Y}llm-chat${_N}      Neural Terminal  →  http://localhost:8090  (fallback)"
echo ""
echo -e "${_C}  ── CLI inference ─────────────────────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}run-model${_N}  /  ${_Y}ask${_N}    Direct terminal chat (active model)"
echo -e "   ${_Y}gguf-run${_N}              Run a raw GGUF file directly"
echo -e "   ${_Y}ollama-run${_N} <tag>      Run any Ollama model"
echo ""
echo -e "${_C}  ── Autonomous coworking ─────────────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}cowork${_N}                Open Interpreter — writes/runs code, edits files"
echo -e "   ${_Y}ai${_N}  /  ${_Y}aider${_N}          Aider — AI pair programmer (git-integrated)"
echo ""
echo -e "${_C}  ── Model management ─────────────────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}llm-add${_N}               Download additional models (with catalog)"
echo -e "   ${_Y}llm-switch${_N}            Change active model (no reinstall)"
echo -e "   ${_Y}llm-status${_N}            Show installed models + disk usage"
echo -e "   ${_Y}llm-checker${_N}           Hardware scan + model dashboard"
echo -e "   ${_Y}gguf-list${_N}             List all downloaded GGUF files"
echo -e "   ${_Y}ollama-list${_N}           ollama list"
echo ""
echo -e "${_C}  ── Service control ──────────────────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}ollama-start${_N}          Start Ollama backend"
echo -e "   ${_Y}llm-stop${_N}              Stop Ollama + WebUI + Neural Terminal"
echo -e "   ${_Y}llm-update${_N}            Upgrade Open WebUI + pip packages (Ollama stays locked)"
echo ""
echo -e "${_C}  ── Info / diagnostics ───────────────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}llm-show-config${_N}       Paths · model config · service status"
echo -e "   ${_Y}llm-help${_N}              This reference"
echo ""
echo -e "${_C}  ── Cloud AI (optional — needs API key) ─────────────────────────────────────────${_N}"
echo -e "   ${_Y}claude${_N}  /  ${_Y}claude-code${_N}   Anthropic Claude Code  ${_M}(ANTHROPIC_API_KEY)${_N}"
echo -e "   ${_Y}codex-agent${_N}            OpenAI Codex CLI  ${_M}(OPENAI_API_KEY)${_N}"
echo ""
echo -e "${_C}  ── Security (optional) ──────────────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}pentestagent-start${_N}    PentestAgent AI (RAG + Ollama — fully local)"
echo ""
echo -e "${_C}  ── Quick start ──────────────────────────────────────────────────────────────────${_N}"
echo -e "   1. ${_Y}ollama-start${_N}           Start the backend"
echo -e "   2. ${_Y}webui${_N}                   Open WebUI (primary interface)"
echo -e "   3. ${_Y}chat${_N}                    Neural Terminal (fallback interface)"
echo -e "   4. ${_Y}cowork${_N}                  Autonomous coding assistant"
echo ""
echo -e "${_G}  All commands available in ~/.local/bin — added to PATH in ~/.bashrc${_N}"
echo -e "${_G}  Log file: $HOME/llm-auto-setup-*.log${_N}"
echo ""
HELP
chmod +x "$BIN_DIR/llm-help"

# Create symlinks/aliases for common commands
ln -sf "$BIN_DIR/llm-webui" "$BIN_DIR/webui" 2>/dev/null || true
ln -sf "$BIN_DIR/llm-chat" "$BIN_DIR/chat" 2>/dev/null || true
ln -sf "$BIN_DIR/llm-checker" "$BIN_DIR/llm-status" 2>/dev/null || true
ln -sf "$BIN_DIR/run-gguf" "$BIN_DIR/gguf-run" 2>/dev/null || true
ln -sf "$BIN_DIR/run-gguf" "$BIN_DIR/gguf-list" 2>/dev/null || true

# =============================================================================
# STEP 18 — FINAL ALIASES & CLEANUP
# =============================================================================
step "Final configuration"

# Create a custom aliases file
cat > "$ALIAS_FILE" <<'ALIASES'
# Local LLM aliases
alias llm-help='llm-help'
alias webui='llm-webui'
alias chat='llm-chat'
alias cowork='cowork'
alias ai='aider'
alias ask='run-model'
alias ollama-list='ollama list'
alias gguf-list='ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null | sort -h'
alias models='llm-status'
alias check-gpu='watch -n 1 nvidia-smi 2>/dev/null || watch -n 1 rocm-smi 2>/dev/null || echo "No GPU monitor found"'
alias kill-llm='llm-stop'
alias update-llm='llm-update'
alias switch-model='llm-switch'
alias add-model='llm-add'
alias show-config='llm-show-config'

# Convenience functions
run-model() {
    local prompt="$*"
    if [[ -z "$prompt" ]]; then
        echo "Usage: run-model 'your question here'"
        return 1
    fi
    curl -X POST http://localhost:11434/api/generate -d "{
        \"model\": \"$(grep OLLAMA_TAG ~/.config/local-llm/selected_model.conf 2>/dev/null | cut -d'"' -f2 || echo 'qwen3:8b')\",
        \"prompt\": \"$prompt\",
        \"stream\": false
    }" | jq -r '.response' 2>/dev/null || echo "Error: Ollama not running or model not found"
}

# cd to work directory
work() {
    cd ~/work
    echo "📁 Working in: $(pwd)"
    ls -la
}
ALIASES

# Source aliases in .bashrc if not already present
if ! grep -q "# llm-auto-setup aliases" "$HOME/.bashrc" 2>/dev/null; then
    {
        printf '\n# llm-auto-setup aliases\n'
        printf 'if [[ -f "%s" ]]; then\n' "$ALIAS_FILE"
        printf '    source "%s"\n' "$ALIAS_FILE"
        printf 'fi\n'
    } >> "$HOME/.bashrc"
    info "Aliases added to ~/.bashrc"
fi

# Clean up temp files
rm -rf "$TEMP_DIR"/* 2>/dev/null || true
info "Temporary files cleaned up"

# =============================================================================
# STEP 19 — INSTALLATION COMPLETE
# =============================================================================
step "Installation complete!"

# Clear the progress bar line
printf "\n"

# Final success banner
_rule "═" "${ACCENT2}"
printf "${ACCENT2}${BOLD}  ✅  LLM AUTO-SETUP v%s SUCCESSFUL  ${NC}\n" "$SCRIPT_VERSION"
_rule "═" "${ACCENT2}"
printf "\n"

# Hardware summary
printf "  ${BOLD}${ACCENT}System:${NC}\n"
printf "  ├─ CPU: ${CPU_MODEL:0:50}\n"
printf "  ├─ RAM: ${TOTAL_RAM_GB} GB total, ${AVAIL_RAM_GB} GB available\n"
if (( HAS_NVIDIA )); then
    printf "  ├─ GPU: ${GPU_NAME} (${GPU_VRAM_GB} GB VRAM)\n"
    printf "  ├─ Driver: NVIDIA ${DRIVER_VER}\n"
elif (( HAS_AMD )); then
    printf "  ├─ GPU: ${GPU_NAME} (${GPU_VRAM_GB} GB VRAM)\n"
    printf "  ├─ Driver: AMD ROCm\n"
elif (( HAS_INTEL )); then
    printf "  ├─ GPU: ${GPU_NAME} (Intel Arc)\n"
else
    printf "  ├─ GPU: None detected (CPU mode)\n"
fi
printf "  └─ Disk: ${DISK_FREE_GB} GB free\n"
printf "\n"

# Model summary
printf "  ${BOLD}${ACCENT}Active model:${NC}\n"
printf "  ├─ ${M[name]}\n"
printf "  ├─ Capabilities: ${M[caps]}\n"
printf "  ├─ GPU layers: ${GPU_LAYERS} | CPU layers: ${CPU_LAYERS}\n"
printf "  └─ Ollama tag: ${OLLAMA_TAG}\n"
printf "\n"

# Available commands
printf "  ${BOLD}${ACCENT}Quick start:${NC}\n"
printf "  ┌─────────────────────────────────────────────────────────────┐\n"
printf "  │ ${BOLD}COMMAND${NC}           ${BOLD}DESCRIPTION${NC}                              │\n"
printf "  ├─────────────────────────────────────────────────────────────┤\n"
printf "  │ ${GREEN}ollama-start${NC}     Start Ollama backend                        │\n"
printf "  │ ${GREEN}webui${NC}             Open WebUI (http://localhost:8080)        │\n"
printf "  │ ${GREEN}chat${NC}              Neural Terminal (http://localhost:8090)   │\n"
printf "  │ ${GREEN}cowork${NC}            Autonomous AI coworker (Open Interpreter) │\n"
printf "  │ ${GREEN}aider${NC}             AI pair programmer                        │\n"
printf "  │ ${GREEN}ask${NC} 'question'     Quick CLI query                          │\n"
printf "  │ ${GREEN}llm-help${NC}          Show all commands                         │\n"
printf "  └─────────────────────────────────────────────────────────────┘\n"
printf "\n"

# Next steps
printf "  ${BOLD}${ACCENT}Next steps:${NC}\n"
printf "  1. Start Ollama:  ${CYAN}ollama-start${NC}\n"
printf "  2. Launch WebUI:  ${CYAN}webui${NC}  (or ${CYAN}chat${NC} for minimal interface)\n"
printf "  3. Open browser:  http://localhost:8080\n"
printf "  4. Try a query:   ${CYAN}ask 'What is machine learning?'${NC}\n"
printf "  5. Start coding:  ${CYAN}cowork${NC}  (autonomous) or ${CYAN}aider${NC} (pair programming)\n"
printf "\n"

# Additional models
printf "  ${BOLD}${ACCENT}Add more models:${NC}\n"
printf "  • ${CYAN}llm-add${NC}          Browse and download from catalog\n"
printf "  • ${CYAN}llm-switch${NC}       Switch between downloaded models\n"
printf "  • ${CYAN}llm-status${NC}       View installed models and disk usage\n"
printf "\n"

# Log location
printf "  ${MUTED}Installation log: ${LOG_FILE}${NC}\n"
printf "\n"

# Check if we need to source bashrc
printf "  ${YELLOW}Note:${NC} Run '${BOLD}source ~/.bashrc${NC}' or open a new terminal to use the new commands.\n"
printf "\n"

_rule "─" "${ACCENT}"
printf "${ACCENT2}${BOLD}  🚀  READY TO GO  ${NC}\n"
_rule "─" "${ACCENT}"
printf "\n"

# =============================================================================
# CLEAN EXIT
# =============================================================================
# Kill sudo keepalive
kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
trap - EXIT INT TERM

exit 0