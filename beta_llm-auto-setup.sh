#!/usr/bin/env bash
# =============================================================================
#
#   ██╗      ██████╗  ██████╗ █████╗ ██╗         ██╗     ██╗     ███╗   ███╗
#   ██║     ██╔═══██╗██╔════╝██╔══██╗██║        ██╔╝     ██║     ████╗ ████║
#   ██║     ██║   ██║██║     ███████║██║       ██╔╝      ██║     ██╔████╔██║
#   ██║     ██║   ██║██║     ██╔══██║██║      ██╔╝       ██║     ██║╚██╔╝██║
#   ███████╗╚██████╔╝╚██████╗██║  ██║███████╗██╔╝        ███████╗██║ ╚═╝ ██║
#   ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝         ╚══════╝╚═╝     ╚═╝
#
#   AUTO-SETUP  ·  Universal Edition v3.0.0
#   ─────────────────────────────────────────────────────────────────────────
#   Scans your hardware → picks the best model → installs the full stack.
#   No HuggingFace token needed. All models from public bartowski repos.
#
#   Supports: Ubuntu 22.04/24.04 · Debian 12 · Linux Mint 21+ · Pop!_OS
#             WSL2 · CPU-only through NVIDIA CUDA · AMD ROCm · Intel Arc
#   ─────────────────────────────────────────────────────────────────────────
#   Installs:  Ollama · llama-cpp-python · Neural Terminal (port 8090)
#              Open WebUI (port 8080) · cowork (Open Interpreter) · aider
#   Optional:  Claude Code · OpenAI Codex · tmux · CLI tools · GPU monitor
# =============================================================================

set -uo pipefail

# =============================================================================
# CONSTANTS & PATHS
# =============================================================================
SCRIPT_VERSION="3.0.0"
SCRIPT_UPDATE_URL=""     # Set to a hosted URL to enable auto-update checks
SCRIPT_INSTALL_PATH="$HOME/.config/local-llm/llm-auto-setup.sh"

LOG_FILE="$HOME/llm-auto-setup-$(date +%Y%m%d-%H%M%S).log"
VENV_DIR="$HOME/.local/share/llm-venv"
OWUI_VENV="$HOME/.local/share/open-webui-venv"
OI_VENV="$HOME/.local/share/open-interpreter-venv"
AI_VENV="$HOME/.local/share/aider-venv"
MODEL_BASE="$HOME/local-llm-models"
OLLAMA_MODELS="$MODEL_BASE/ollama"
GGUF_MODELS="$MODEL_BASE/gguf"
TEMP_DIR="$MODEL_BASE/temp"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/local-llm"
GUI_DIR="$HOME/.local/share/llm-webui"
MODEL_CONFIG="$CONFIG_DIR/selected_model.conf"
ALIAS_FILE="$HOME/.local_llm_aliases"
WORK_DIR="$HOME/work"

# Package download cache — reused across runs to avoid re-downloading CUDA etc.
PKG_CACHE_DIR="$HOME/.cache/llm-setup"
mkdir -p "$PKG_CACHE_DIR/pip" "$PKG_CACHE_DIR/npm" "$PKG_CACHE_DIR/apt"
export PIP_CACHE_DIR="$PKG_CACHE_DIR/pip"
export npm_config_cache="$PKG_CACHE_DIR/npm"

# =============================================================================
# COLORS  (auto-disabled when stdout is not a tty)
# =============================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; NC=''
fi

# =============================================================================
# LOGGING
# =============================================================================
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()       { echo -e "$(date +'%Y-%m-%d %H:%M:%S') $*"; }
info()      { log "${GREEN}[INFO]${NC}  $*"; }
warn()      { log "${YELLOW}[WARN]${NC}  $*"; }
error()     { log "${RED}[ERROR]${NC} $*"; log "${RED}[ERROR]${NC} Log: $LOG_FILE"; exit 1; }
step()      {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  ▶  $*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
highlight() { echo -e "\n${MAGENTA}  ◆  $*${NC}"; }

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# ask_yes_no <prompt>  → returns 0 for yes, 1 for no
ask_yes_no() {
    local ans=""
    if [[ ! -t 0 ]]; then
        warn "Non-interactive — treating '$1' as No."
        return 1
    fi
    read -r -p "$(echo -e "${YELLOW}?${NC} $1 (y/N) ")" -n 1 ans; echo
    [[ "$ans" =~ ^[Yy]$ ]]
}

# retry <attempts> <delay_s> <command...>
retry() {
    local n="$1" delay="$2"; shift 2
    local attempt=1
    while true; do
        "$@" && return 0
        (( attempt >= n )) && { warn "Failed after $n attempts: $*"; return 1; }
        warn "Attempt $attempt/$n failed — retrying in ${delay}s…"
        sleep "$delay"; (( attempt++ ))
    done
}

# is_wsl2 → true if running inside WSL
is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

# get_distro_id → lowercase distro id (ubuntu, debian, linuxmint, …)
get_distro_id() {
    grep -m1 '^ID=' /etc/os-release 2>/dev/null \
        | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' \
        || echo "unknown"
}

# get_distro_codename → codename (jammy, noble, bookworm, …)
get_distro_codename() {
    grep -m1 '^VERSION_CODENAME=' /etc/os-release 2>/dev/null \
        | cut -d= -f2 | tr -d '"' \
        || lsb_release -sc 2>/dev/null \
        || echo "unknown"
}

# ollama_running → true if Ollama is up and responsive
ollama_running() {
    curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1
}

# wait_for_ollama <max_seconds>
wait_for_ollama() {
    local max="${1:-15}" i=0
    while (( i < max )); do
        ollama_running && return 0
        sleep 1; (( i++ ))
    done
    return 1
}

# start_ollama_if_needed → starts Ollama if not already running
start_ollama_if_needed() {
    ollama_running && return 0
    echo "→ Starting Ollama…"
    if is_wsl2; then
        [[ -x "$BIN_DIR/ollama-start" ]] \
            && "$BIN_DIR/ollama-start" \
            || nohup ollama serve >/dev/null 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >/dev/null 2>&1 &
    fi
    wait_for_ollama 20 || warn "Ollama didn't respond within 20s."
}

# =============================================================================
# STEP 1 — PRE-FLIGHT
# =============================================================================
step "Pre-flight checks"

[[ "${EUID}" -eq 0 ]] && error "Do not run as root. Run as a normal user with sudo access."
command -v sudo &>/dev/null || error "sudo is required. Install it: apt-get install sudo"

# Architecture
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64)  : ;;
    aarch64) warn "ARM64 detected — CUDA pre-built wheels unavailable; will build from source." ;;
    *)       warn "Untested architecture: $HOST_ARCH. Proceeding anyway." ;;
esac

# Distro
DISTRO_ID=$(get_distro_id)
DISTRO_CODENAME=$(get_distro_codename)
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null \
    || grep -oP '(?<=^VERSION_ID=")[\d.]+' /etc/os-release 2>/dev/null \
    || echo "unknown")
info "Distro: ${DISTRO_ID} ${UBUNTU_VERSION} (${DISTRO_CODENAME}) on ${HOST_ARCH}"
case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|neon|elementary|zorin|kali|parrot) ;;
    *) warn "Distro '${DISTRO_ID}' not officially tested — apt paths will be used." ;;
esac

# Single sudo prompt; keepalive every 50s for the entire script
echo -e "${CYAN}[sudo]${NC} This script needs elevated privileges for apt, systemd, and GPU drivers."
sudo -v || error "sudo authentication failed."
( while true; do sleep 50; sudo -v 2>/dev/null; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; trap - EXIT INT TERM' EXIT INT TERM
info "sudo keepalive active (PID $SUDO_KEEPALIVE_PID)."

# Self-update check
_local_ver=""
if [[ -f "$SCRIPT_INSTALL_PATH" ]]; then
    _local_ver=$(grep '^SCRIPT_VERSION=' "$SCRIPT_INSTALL_PATH" 2>/dev/null \
                 | head -1 | cut -d'"' -f2 || true)
fi

# Exec local copy when running from a temporary/downloaded path
_running_path=$(realpath "$0" 2>/dev/null || echo "$0")
_install_rp=$(realpath "$SCRIPT_INSTALL_PATH" 2>/dev/null || echo "$SCRIPT_INSTALL_PATH")
if [[ -f "$SCRIPT_INSTALL_PATH" && "$_running_path" != "$_install_rp" && -n "${_local_ver:-}" ]]; then
    _ver_ge() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }
    if _ver_ge "$_local_ver" "$SCRIPT_VERSION"; then
        echo -e "${GREEN}[INFO]${NC}  Local copy found (v${_local_ver}) — switching to installed version."
        exec bash "$SCRIPT_INSTALL_PATH" "$@"
    fi
    unset -f _ver_ge 2>/dev/null || true
fi
unset _running_path _install_rp 2>/dev/null || true

# Remote update check (only if SCRIPT_UPDATE_URL is set)
if [[ -n "$SCRIPT_UPDATE_URL" ]]; then
    _remote_ver=$(curl -fsSL --max-time 3 "${SCRIPT_UPDATE_URL%.sh}.version" 2>/dev/null || true)
    if [[ -n "$_remote_ver" && "$_remote_ver" != "$SCRIPT_VERSION" ]]; then
        echo ""
        echo -e "${YELLOW}  ┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}  │  Update available: v${SCRIPT_VERSION} → v${_remote_ver}${NC}"
        echo -e "${YELLOW}  │  Set SCRIPT_UPDATE_URL to auto-download.                    │${NC}"
        echo -e "${YELLOW}  └──────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        if ask_yes_no "Download and run the updated version now?"; then
            _new="$(mktemp).sh"
            if curl -fsSL "$SCRIPT_UPDATE_URL" -o "$_new"; then
                chmod +x "$_new"
                info "Re-launching updated script…"
                exec bash "$_new" "$@"
            else
                warn "Download failed — continuing with current version."
            fi
        fi
    fi
elif [[ -n "$_local_ver" && "$_local_ver" != "$SCRIPT_VERSION" ]]; then
    info "Local installed version: v$_local_ver  (running: v$SCRIPT_VERSION)"
fi
unset _local_ver _remote_ver 2>/dev/null || true

info "Log: $LOG_FILE  (script v$SCRIPT_VERSION)"
is_wsl2 && info "WSL2 environment detected." || info "Native Linux detected."

# Internet check
if curl -fsSL --max-time 5 https://huggingface.co >/dev/null 2>&1; then
    info "Internet: reachable (huggingface.co)"
elif curl -fsSL --max-time 5 https://pypi.org >/dev/null 2>&1; then
    info "Internet: reachable (pypi.org)"
else
    warn "Internet appears unreachable. Downloads and pip installs may fail."
    warn "  Behind a proxy? Set: export https_proxy=http://proxy:port"
fi

# =============================================================================
# STEP 2 — HARDWARE DETECTION
# =============================================================================
step "Hardware detection"

# ── Already-installed models display ─────────────────────────────────────────
# Show this on second runs so the user knows what's already there.
_installed_gguf=()
if [[ -d "$GGUF_MODELS" ]]; then
    while IFS= read -r -d '' _f; do
        _installed_gguf+=( "$(basename "$_f")" )
    done < <(find "$GGUF_MODELS" -maxdepth 1 -name '*.gguf' -print0 2>/dev/null)
fi

_installed_ollama=()
if command -v ollama &>/dev/null && ollama_running; then
    while IFS= read -r _line; do
        [[ "$_line" == NAME* ]] && continue
        _tag=$(awk '{print $1}' <<< "$_line")
        [[ -n "$_tag" ]] && _installed_ollama+=( "$_tag" )
    done < <(ollama list 2>/dev/null || true)
fi

if (( ${#_installed_gguf[@]} > 0 || ${#_installed_ollama[@]} > 0 )); then
    echo ""
    echo -e "  ${GREEN}┌──────────────────────  INSTALLED MODELS  ──────────────────────┐${NC}"
    if (( ${#_installed_gguf[@]} > 0 )); then
        echo -e "  ${GREEN}│${NC}  ${CYAN}GGUF files  (${GGUF_MODELS}):${NC}"
        for _m in "${_installed_gguf[@]}"; do
            printf "  ${GREEN}│${NC}   ${GREEN}✔${NC}  %s\n" "$_m"
        done
    fi
    if (( ${#_installed_ollama[@]} > 0 )); then
        echo -e "  ${GREEN}│${NC}  ${CYAN}Ollama models:${NC}"
        for _m in "${_installed_ollama[@]}"; do
            printf "  ${GREEN}│${NC}   ${GREEN}✔${NC}  %s\n" "$_m"
        done
    fi
    echo -e "  ${GREEN}└────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
fi
unset _installed_gguf _installed_ollama _f _line _tag 2>/dev/null || true

# ── CPU ───────────────────────────────────────────────────────────────────────
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
    | cut -d: -f2 | xargs || echo "Unknown CPU")
CPU_THREADS=$(nproc 2>/dev/null || echo 4)
# Clamp build threads to reasonable maximum (avoids OOM during compilation)
HW_THREADS=$(( CPU_THREADS > 16 ? 16 : CPU_THREADS ))

CPU_FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null \
    || grep -m1 '^Features' /proc/cpuinfo 2>/dev/null || echo "")
HAS_AVX2=0;   [[ "$CPU_FLAGS" =~ (^| )avx2( |$)   ]] && HAS_AVX2=1
HAS_AVX512=0; [[ "$CPU_FLAGS" =~ (^| )avx512f( |$) ]] && HAS_AVX512=1
HAS_AVX=0;    [[ "$CPU_FLAGS" =~ (^| )avx( |$)     ]] && HAS_AVX=1
HAS_NEON=0;   [[ "$HOST_ARCH" == "aarch64" ]]          && HAS_NEON=1

# ── RAM ───────────────────────────────────────────────────────────────────────
TOTAL_RAM_KB=$(grep MemTotal     /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 4096000)
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 2048000)
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
AVAIL_RAM_GB=$(( AVAIL_RAM_KB / 1024 / 1024 ))
(( TOTAL_RAM_GB < 1 )) && TOTAL_RAM_GB=4
(( AVAIL_RAM_GB < 1 )) && AVAIL_RAM_GB=2

# ── GPU — NVIDIA ──────────────────────────────────────────────────────────────
HAS_NVIDIA=0; HAS_AMD_GPU=0; HAS_INTEL_GPU=0; HAS_GPU=0
GPU_NAME="None"; GPU_VRAM_MIB=0; GPU_VRAM_GB=0
DRIVER_VER="N/A"; CUDA_VER_SMI=""; AMD_ROCM_VER=""; AMD_GFX_VER=""

if command -v nvidia-smi &>/dev/null; then
    # Use the largest single GPU for model selection (layers fit one device)
    _nv_best=0
    while IFS= read -r _mib; do
        _mib="${_mib// /}"
        [[ "$_mib" =~ ^[0-9]+$ ]] && (( _mib > _nv_best )) && _nv_best=$_mib
    done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true)
    _nv_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo 1)
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown NVIDIA")
    (( _nv_count > 1 )) && GPU_NAME="${_nv_count}x ${GPU_NAME}"
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "N/A")
    CUDA_VER_SMI=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -1 || echo "")
    if (( _nv_best > 500 )); then
        HAS_NVIDIA=1; HAS_GPU=1
        GPU_VRAM_MIB=$_nv_best
        GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
    fi
    unset _nv_best _nv_count
fi

# ── GPU — AMD ─────────────────────────────────────────────────────────────────
if (( !HAS_NVIDIA )); then
    _best_amd_mib=0
    for _sysfs in /sys/class/drm/card*/device/mem_info_vram_total; do
        [[ -f "$_sysfs" ]] || continue
        _amd_bytes=$(< "$_sysfs" 2>/dev/null || echo 0)
        _amd_mib=$(( _amd_bytes / 1024 / 1024 ))
        (( _amd_mib > _best_amd_mib && _amd_mib > 512 )) && _best_amd_mib=$_amd_mib
    done
    if (( _best_amd_mib > 512 )); then
        GPU_VRAM_MIB=$_best_amd_mib
        GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
        HAS_AMD_GPU=1; HAS_GPU=1
        if command -v rocm-smi &>/dev/null; then
            GPU_NAME=$(rocm-smi --showproductname 2>/dev/null \
                | grep -oP '(?<=GPU\[0\] : ).*' | head -1 | xargs || echo "AMD GPU")
        else
            GPU_NAME=$(lspci 2>/dev/null \
                | grep -iE "VGA|Display|3D" | grep -iE "AMD|ATI|Radeon|gfx" \
                | head -1 | sed 's/.*: //' | xargs || echo "AMD GPU")
        fi
        if command -v rocminfo &>/dev/null; then
            AMD_ROCM_VER=$(rocminfo 2>/dev/null \
                | grep -oP 'Runtime Version:\s*\K[0-9.]+' | head -1 || echo "")
            AMD_GFX_VER=$(rocminfo 2>/dev/null | grep -oP 'gfx\d+[a-z]*' | head -1 || echo "")
        fi
        DRIVER_VER=$(< /sys/class/drm/card0/device/driver/module/version 2>/dev/null || uname -r)
    fi
    unset _best_amd_mib _sysfs _amd_bytes _amd_mib
fi

# ── GPU — Intel Arc ───────────────────────────────────────────────────────────
if (( !HAS_NVIDIA && !HAS_AMD_GPU )); then
    if lspci 2>/dev/null | grep -qiE "Intel.*Arc|Intel.*Xe"; then
        HAS_INTEL_GPU=1
        GPU_NAME=$(lspci 2>/dev/null \
            | grep -iE "Intel.*Arc|Intel.*Xe" | head -1 | sed 's/.*: //' | xargs \
            || echo "Intel Arc GPU")
        info "Intel Arc/Xe detected: $GPU_NAME"
        info "  SYCL backend not auto-configured — using CPU tiers."
    fi
fi

# ── Disk ──────────────────────────────────────────────────────────────────────
DISK_FREE_GB=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo 10)

# ── Hardware summary ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "  ${CYAN}│           HARDWARE SCAN RESULTS             │${NC}"
echo -e "  ${CYAN}├─────────────────────────────────────────────┤${NC}"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "CPU"      "$CPU_MODEL" | head -c 52; echo "${CYAN}│${NC}"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Threads"  "${CPU_THREADS} logical cores"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Arch"     "$HOST_ARCH"
_simd="baseline"
(( HAS_AVX512 )) && _simd="AVX-512 AVX2 AVX"
[[ "$_simd" == "baseline" ]] && (( HAS_AVX2  )) && _simd="AVX2 AVX"
[[ "$_simd" == "baseline" ]] && (( HAS_AVX   )) && _simd="AVX"
[[ "$_simd" == "baseline" ]] && (( HAS_NEON  )) && _simd="NEON (ARM64)"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "SIMD"     "$_simd"
unset _simd
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "RAM"      "${TOTAL_RAM_GB} GB total / ${AVAIL_RAM_GB} GB free"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "GPU"      "$GPU_NAME"
if (( HAS_NVIDIA )); then
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "VRAM"   "${GPU_VRAM_GB} GB (${GPU_VRAM_MIB} MiB)"
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Driver" "$DRIVER_VER"
    [[ -n "$CUDA_VER_SMI" ]] && \
        printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "CUDA"  "$CUDA_VER_SMI"
elif (( HAS_AMD_GPU )); then
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "VRAM"   "${GPU_VRAM_GB} GB (${GPU_VRAM_MIB} MiB)"
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Driver" "$DRIVER_VER"
    if [[ -n "$AMD_ROCM_VER" ]]; then
        _amd_api="ROCm $AMD_ROCM_VER"
        [[ -n "$AMD_GFX_VER" ]] && _amd_api+="  (${AMD_GFX_VER})"
        printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "ROCm" "$_amd_api"
        unset _amd_api
    else
        printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "ROCm" "(not yet installed)"
    fi
elif (( HAS_INTEL_GPU )); then
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Note"   "Intel Arc — CPU tiers used"
fi
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Disk free" "${DISK_FREE_GB} GB"
echo -e "  ${CYAN}└─────────────────────────────────────────────┘${NC}"
echo ""

# =============================================================================
# STEP 3 — MODEL SELECTION
# Rankings: Feb 2026 — whatllm.org, localllm.in, ArtificialAnalysis
# [TOOLS]=function calling  [THINK]=chain-of-thought  [UNCENS]=uncensored  ★=best
# =============================================================================
step "Model selection"

# VRAM headroom for KV-cache + activations (MiB)
VRAM_HEADROOM_MIB=1400
VRAM_USABLE_MIB=$(( GPU_VRAM_MIB - VRAM_HEADROOM_MIB ))
(( VRAM_USABLE_MIB < 0 )) && VRAM_USABLE_MIB=0

# How many GPU layers fit for a given model?
# $1=model_size_gb  $2=num_layers  → integer layer count
gpu_layers_for() {
    local size_gb="$1" num_layers="$2"
    local mib_per_layer=$(( (size_gb * 1024) / num_layers ))
    (( mib_per_layer < 1 )) && mib_per_layer=1
    local layers=$(( VRAM_USABLE_MIB / mib_per_layer ))
    (( layers > num_layers )) && layers=$num_layers
    (( layers < 0 ))          && layers=0
    echo "$layers"
}

declare -A M   # will hold the chosen model's fields

select_model() {
    local vram=$GPU_VRAM_GB ram=$TOTAL_RAM_GB

    # ── GPU tiers ─────────────────────────────────────────────────────────────
    if (( HAS_GPU && vram >= 48 )); then
        highlight "≥48 GB VRAM → Llama-3.3-70B Q4_K_M [TOOLS] ★"
        M[name]="Llama-3.3-70B-Instruct Q4_K_M"; M[caps]="TOOLS"
        M[file]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M[size_gb]=40; M[layers]=80; M[tier]="70B"

    elif (( HAS_GPU && vram >= 24 )); then
        highlight "≥24 GB VRAM → Qwen3-32B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-32B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
        M[size_gb]=19; M[layers]=64; M[tier]="32B"

    elif (( HAS_GPU && vram >= 16 )); then
        highlight "≥16 GB VRAM → Mistral-Small-3.2-24B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Mistral-Small-3.2-24B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
        M[size_gb]=14; M[layers]=40; M[tier]="24B"

    elif (( HAS_GPU && vram >= 12 )); then
        highlight "≥12 GB VRAM → Qwen3-14B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-14B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[size_gb]=9; M[layers]=40; M[tier]="14B"

    elif (( HAS_GPU && vram >= 10 )); then
        highlight "≥10 GB VRAM → Phi-4-14B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Phi-4-14B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="phi-4-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf"
        M[size_gb]=9; M[layers]=40; M[tier]="14B"

    elif (( HAS_GPU && vram >= 8 )); then
        highlight "≥8 GB VRAM → Qwen3-8B Q6_K [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q6_K"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q6_K.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
        M[size_gb]=6; M[layers]=36; M[tier]="8B"

    elif (( HAS_GPU && vram >= 6 )); then
        highlight "≥6 GB VRAM → Qwen3-8B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[size_gb]=5; M[layers]=36; M[tier]="8B"

    elif (( HAS_GPU && vram >= 4 )); then
        highlight "≥4 GB VRAM → Qwen3-4B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-4B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[size_gb]=3; M[layers]=36; M[tier]="4B"

    # ── CPU tiers ─────────────────────────────────────────────────────────────
    elif (( ram >= 32 )); then
        highlight "CPU ≥32 GB RAM → Qwen3-14B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-14B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[size_gb]=9; M[layers]=40; M[tier]="14B"

    elif (( ram >= 16 )); then
        highlight "CPU ≥16 GB RAM → Qwen3-8B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[size_gb]=5; M[layers]=36; M[tier]="8B"

    elif (( ram >= 8 )); then
        highlight "CPU ≥8 GB RAM → Qwen3-4B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-4B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[size_gb]=3; M[layers]=36; M[tier]="4B"

    else
        highlight "CPU <8 GB RAM → Qwen3-1.7B Q8_0 [TOOLS+THINK]"
        M[name]="Qwen3-1.7B Q8_0"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
        M[size_gb]=2; M[layers]=28; M[tier]="1.7B"
    fi
}
select_model

# Calculate GPU/CPU layer split
if (( HAS_GPU )); then
    GPU_LAYERS=$(gpu_layers_for "${M[size_gb]}" "${M[layers]}")
    CPU_LAYERS=$(( M[layers] - GPU_LAYERS ))
    (( CPU_LAYERS < 0 )) && CPU_LAYERS=0
else
    GPU_LAYERS=0
    CPU_LAYERS="${M[layers]}"
fi

# Batch size tuned to VRAM
if   (( GPU_VRAM_GB >= 24 )); then BATCH=2048
elif (( GPU_VRAM_GB >= 16 )); then BATCH=1024
elif (( GPU_VRAM_GB >= 8  )); then BATCH=512
elif (( GPU_VRAM_GB >= 4  )); then BATCH=256
else                               BATCH=128
fi

# ── Manual override ───────────────────────────────────────────────────────────
# Show picker with installed-model indicators
_is_installed() { [[ -f "$GGUF_MODELS/$1" ]] && echo -e " ${GREEN}✔${NC}" || echo "  "; }

info "Auto-selected: ${M[name]}  (${M[tier]})  GPU:${GPU_LAYERS} CPU:${CPU_LAYERS} layers"
echo ""

if ask_yes_no "Override with manual model selection?"; then
    echo ""
    echo -e "  ${CYAN}┌────┬──────────────────────────────────────┬──────┬──────┬──────────────────────────┬───┐${NC}"
    echo -e "  ${CYAN}│ #  │ Model                                │ Quant│ VRAM │ Capabilities             │ ✔ │${NC}"
    echo -e "  ${CYAN}├────┼──────────────────────────────────────┼──────┼──────┼──────────────────────────┼───┤${NC}"
    echo "  │    │ ── Small / CPU ──────────────────── │      │      │                          │   │"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "1"  "Qwen3-1.7B"                           "Q8"   "CPU"   "★ [TOOLS] [THINK]"          "$(_is_installed Qwen_Qwen3-1.7B-Q8_0.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "2"  "Qwen3-4B"                             "Q4"   "~3GB"  "★ [TOOLS] [THINK]"          "$(_is_installed Qwen_Qwen3-4B-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "3"  "Phi-4-mini 3.8B"                      "Q4"   "CPU"   "★ [TOOLS] [THINK]"          "$(_is_installed microsoft_Phi-4-mini-instruct-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "4"  "Qwen3-0.6B"                           "Q8"   "CPU"   "[TOOLS] [THINK] tiny"       "$(_is_installed Qwen_Qwen3-0.6B-Q8_0.gguf)"
    echo "  │    │ ── 6-8 GB VRAM ──────────────────── │      │      │                          │   │"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "5"  "Qwen3-8B"                             "Q4"   "~5GB"  "★ [TOOLS] [THINK]"          "$(_is_installed Qwen_Qwen3-8B-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "6"  "Qwen3-8B"                             "Q6"   "~6GB"  "★ [TOOLS] [THINK]"          "$(_is_installed Qwen_Qwen3-8B-Q6_K.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "7"  "DeepSeek-R1-Distill-8B"             "Q4"   "~5GB"  "[THINK] deep reasoning"     "$(_is_installed DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "8"  "Gemma-3-9B"                           "Q4"   "~6GB"  "[TOOLS] Google"             "$(_is_installed google_gemma-3-9b-it-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "9"  "Gemma-3-12B"                          "Q4"   "~8GB"  "[TOOLS] Google vision"      "$(_is_installed google_gemma-3-12b-it-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "10" "Dolphin3.0-8B"                        "Q4"   "~5GB"  "[UNCENS] uncensored"        "$(_is_installed Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf)"
    echo "  │    │ ── 10-12 GB VRAM ─────────────────── │      │      │                          │   │"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "11" "Phi-4-14B"                            "Q4"   "~9GB"  "★ [TOOLS] top coding+math"  "$(_is_installed phi-4-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "12" "Qwen3-14B"                            "Q4"   "~9GB"  "★ [TOOLS] [THINK]"          "$(_is_installed Qwen_Qwen3-14B-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "13" "DeepSeek-R1-Distill-Qwen-14B"         "Q4"   "~9GB"  "[THINK] deep reasoning"     "$(_is_installed DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf)"
    echo "  │    │ ── 16 GB VRAM ────────────────────── │      │      │                          │   │"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "14" "Gemma-3-27B"                          "Q4"   "~12GB" "[TOOLS] Google"             "$(_is_installed google_gemma-3-27b-it-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "15" "Mistral-Small-3.1-24B"                "Q4"   "~14GB" "[TOOLS] [THINK] 128K"       "$(_is_installed mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "16" "Mistral-Small-3.2-24B"                "Q4"   "~14GB" "★ [TOOLS] [THINK] newest"   "$(_is_installed mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "17" "Qwen3-30B-A3B (MoE ★fast)"            "Q4"   "~16GB" "★ [TOOLS] [THINK] MoE"      "$(_is_installed Qwen_Qwen3-30B-A3B-Q4_K_M.gguf)"
    echo "  │    │ ── 24+ GB VRAM ───────────────────── │      │      │                          │   │"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "18" "Qwen3-32B"                            "Q4"   "~19GB" "★ [TOOLS] [THINK]"          "$(_is_installed Qwen_Qwen3-32B-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "19" "DeepSeek-R1-Distill-Qwen-32B"         "Q4"   "~19GB" "[THINK] deep reasoning"     "$(_is_installed DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf)"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "20" "Gemma-3-27B (Google)"                 "Q4"   "~16GB" "[TOOLS] Google"             "$(_is_installed google_gemma-3-27b-it-Q4_K_M.gguf)"
    echo "  │    │ ── 48 GB VRAM ────────────────────── │      │      │                          │   │"
    printf "  │ %-3s│ %-39s│ %-6s│ %-6s│ %-26s│%s │\n" \
        "21" "Llama-3.3-70B"                        "Q4"   "~40GB" "★ [TOOLS] multi-GPU"        "$(_is_installed Llama-3.3-70B-Instruct-Q4_K_M.gguf)"
    echo -e "  ${CYAN}└────┴──────────────────────────────────────┴──────┴──────┴──────────────────────────┴───┘${NC}"
    echo -e "  ${GREEN}✔ = already downloaded${NC}"
    echo ""
    echo -e "  ${YELLOW}MoE tip (17):${NC} 30B params, only 3B active — 30B quality at 8B speed."
    echo -e "  ${YELLOW}R1-0528 (7):${NC}  Updated May 2025 distill — major reasoning improvement."
    echo ""
    read -r -p "  Choice [1-21] (Enter to keep auto-selected): " _manual_choice

    case "${_manual_choice:-}" in
        1)  M[name]="Qwen3-1.7B Q8_0";                         M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[size_gb]=2;  M[layers]=28; M[tier]="1.7B" ;;
        2)  M[name]="Qwen3-4B Q4_K_M";                         M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[size_gb]=3;  M[layers]=36; M[tier]="4B" ;;
        3)  M[name]="Phi-4-mini Q4_K_M";                       M[caps]="TOOLS + THINK"
            M[file]="microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
            M[size_gb]=3;  M[layers]=32; M[tier]="3.8B" ;;
        4)  M[name]="Qwen3-0.6B Q8_0";                         M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-0.6B-Q8_0.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen_Qwen3-0.6B-Q8_0.gguf"
            M[size_gb]=1;  M[layers]=28; M[tier]="0.6B" ;;
        5)  M[name]="Qwen3-8B Q4_K_M";                         M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=36; M[tier]="8B" ;;
        6)  M[name]="Qwen3-8B Q6_K";                           M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q6_K.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
            M[size_gb]=6;  M[layers]=36; M[tier]="8B" ;;
        7)  M[name]="DeepSeek-R1-Distill-Qwen-8B Q4_K_M";        M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-8B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=36; M[tier]="8B" ;;
        8)  M[name]="Gemma-3-9B Q4_K_M";                       M[caps]="TOOLS"
            M[file]="google_gemma-3-9b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-9b-it-GGUF/resolve/main/google_gemma-3-9b-it-Q4_K_M.gguf"
            M[size_gb]=6;  M[layers]=42; M[tier]="9B" ;;
        9)  M[name]="Gemma-3-12B Q4_K_M";                      M[caps]="TOOLS"
            M[file]="google_gemma-3-12b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-12b-it-GGUF/resolve/main/google_gemma-3-12b-it-Q4_K_M.gguf"
            M[size_gb]=8;  M[layers]=46; M[tier]="12B" ;;
        10) M[name]="Dolphin3.0-Llama3.1-8B Q4_K_M";           M[caps]="UNCENS"
            M[file]="Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=32; M[tier]="8B" ;;
        11) M[name]="Phi-4-14B Q4_K_M";                        M[caps]="TOOLS + THINK"
            M[file]="phi-4-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        12) M[name]="Qwen3-14B Q4_K_M";                        M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        13) M[name]="DeepSeek-R1-Distill-Qwen-14B Q4_K_M";     M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        14) M[name]="Gemma-3-27B Q4_K_M";                      M[caps]="TOOLS"
            M[file]="google_gemma-3-27b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-27b-it-GGUF/resolve/main/google_gemma-3-27b-it-Q4_K_M.gguf"
            M[size_gb]=16; M[layers]=62; M[tier]="27B" ;;
        15) M[name]="Mistral-Small-3.1-24B Q4_K_M";            M[caps]="TOOLS + THINK"
            M[file]="mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.1-24B-Instruct-2503-GGUF/resolve/main/mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"
            M[size_gb]=14; M[layers]=40; M[tier]="24B" ;;
        16) M[name]="Mistral-Small-3.2-24B Q4_K_M";            M[caps]="TOOLS + THINK"
            M[file]="mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
            M[size_gb]=14; M[layers]=40; M[tier]="24B" ;;
        17) M[name]="Qwen3-30B-A3B Q4_K_M (MoE)";              M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
            M[size_gb]=18; M[layers]=48; M[tier]="30B-A3B (MoE)" ;;
        18) M[name]="Qwen3-32B Q4_K_M";                        M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        19) M[name]="DeepSeek-R1-Distill-Qwen-32B Q4_K_M";     M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        20) M[name]="Gemma-3-27B Q4_K_M";                      M[caps]="TOOLS"
            M[file]="google_gemma-3-27b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-27b-it-GGUF/resolve/main/google_gemma-3-27b-it-Q4_K_M.gguf"
            M[size_gb]=16; M[layers]=62; M[tier]="27B" ;;
        21) M[name]="Llama-3.3-70B-Instruct Q4_K_M";           M[caps]="TOOLS"
            M[file]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
            M[size_gb]=40; M[layers]=80; M[tier]="70B" ;;
        "")  info "Keeping auto-selected model." ;;
        *)   warn "Invalid choice '${_manual_choice}' — keeping auto-selected model." ;;
    esac
    unset _manual_choice

    # Recalculate layer split and batch for the manually chosen model
    if (( HAS_GPU )); then
        GPU_LAYERS=$(gpu_layers_for "${M[size_gb]}" "${M[layers]}")
        CPU_LAYERS=$(( M[layers] - GPU_LAYERS ))
        (( CPU_LAYERS < 0 )) && CPU_LAYERS=0
    else
        GPU_LAYERS=0; CPU_LAYERS="${M[layers]}"
    fi
    if   (( GPU_VRAM_GB >= 24 )); then BATCH=2048
    elif (( GPU_VRAM_GB >= 16 )); then BATCH=1024
    elif (( GPU_VRAM_GB >= 8  )); then BATCH=512
    elif (( GPU_VRAM_GB >= 4  )); then BATCH=256
    else                               BATCH=128
    fi
fi

info "Final selection: ${M[name]}  GPU:${GPU_LAYERS} CPU:${CPU_LAYERS} layers  batch:${BATCH}"

# Disk space check
if (( DISK_FREE_GB < M[size_gb] + 2 )); then
    warn "Low disk: ${DISK_FREE_GB} GB free, model needs ~${M[size_gb]} GB."
    ask_yes_no "Continue anyway?" || error "Aborting — free up disk space and re-run."
fi

# =============================================================================
# STEP 3b — PYTHON ENVIRONMENT
# =============================================================================
step "Python environment"

mkdir -p "$TEMP_DIR"
info "Running apt-get update…"
sudo apt-get update -qq || warn "apt update returned non-zero."

PYVER_RAW=$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "0.0")
PYVER_MAJOR=$(echo "$PYVER_RAW" | cut -d. -f1)
PYVER_MINOR=$(echo "$PYVER_RAW" | cut -d. -f2)
info "System Python: ${PYVER_RAW:-not found}"
PYTHON_BIN="python3"

# Install Python 3.11 via deadsnakes if system Python is < 3.10
if (( PYVER_MAJOR < 3 || (PYVER_MAJOR == 3 && PYVER_MINOR < 10) )); then
    warn "Python $PYVER_RAW is too old (need 3.10+). Installing Python 3.11 via deadsnakes PPA…"
    sudo apt-get install -y software-properties-common 2>/dev/null || true
    if ! grep -rq "deadsnakes" /etc/apt/sources.list.d/ 2>/dev/null; then
        sudo add-apt-repository -y ppa:deadsnakes/ppa \
            || warn "Failed to add deadsnakes PPA — will try system python."
        sudo apt-get update -qq || true
    fi
    sudo apt-get install -y python3.11 python3.11-venv python3.11-dev \
        || warn "python3.11 install failed — falling back to system python."
    command -v python3.11 &>/dev/null && { PYTHON_BIN="python3.11"; info "Using Python 3.11."; }
else
    info "Python $PYVER_RAW ✔"
fi

# Refresh version vars for the binary we'll actually use
_pver=$("$PYTHON_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "$PYVER_RAW")
PYVER_MAJOR=$(echo "$_pver" | cut -d. -f1)
PYVER_MINOR=$(echo "$_pver" | cut -d. -f2)
unset _pver

# Install pip + venv packages for the correct Python version
info "Installing python3-pip, python3-venv, python${PYVER_MAJOR}.${PYVER_MINOR}-venv…"
sudo apt-get install -y \
    python3-pip \
    python3-venv \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-venv" \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-dev" \
    2>/dev/null \
    || warn "Some Python packages failed — will attempt to continue."

# Bootstrap pip if still missing
if ! "$PYTHON_BIN" -m pip --version &>/dev/null 2>&1; then
    info "pip not found — bootstrapping via get-pip.py…"
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$TEMP_DIR/get-pip.py" \
        && "$PYTHON_BIN" "$TEMP_DIR/get-pip.py" --quiet \
        && rm -f "$TEMP_DIR/get-pip.py" \
        || warn "get-pip.py bootstrap failed."
fi
"$PYTHON_BIN" -m pip install --upgrade pip --quiet 2>/dev/null || true
info "pip $("$PYTHON_BIN" -m pip --version 2>/dev/null | awk '{print $2}' || echo '?') ✔"

# Verify venv works before we depend on it
_test_venv="$TEMP_DIR/.test_venv_$$"
if "$PYTHON_BIN" -m venv "$_test_venv" 2>/dev/null; then
    rm -rf "$_test_venv"
    info "Python venv: OK"
else
    warn "venv test failed — retrying package install…"
    sudo apt-get install -y "python${PYVER_MAJOR}.${PYVER_MINOR}-venv" python3-venv 2>/dev/null || true
    if ! "$PYTHON_BIN" -m venv "$_test_venv" 2>/dev/null; then
        error "Python venv still failing. Run: sudo apt-get install python${PYVER_MAJOR}.${PYVER_MINOR}-venv"
    fi
    rm -rf "$_test_venv"
    info "Python venv: OK (after reinstall)"
fi
unset _test_venv
export PYTHON_BIN

# =============================================================================
# STEP 4 — SYSTEM DEPENDENCIES
# =============================================================================
step "System dependencies"

PKGS=(
    curl wget git build-essential cmake ninja-build
    python3 lsb-release zstd ffmpeg pciutils
    bat grc source-highlight
)
(( HAS_AVX2 )) && PKGS+=(libopenblas-dev)

sudo apt-get install -y "${PKGS[@]}" || warn "Some packages may have failed."

for _cmd in curl wget git python3; do
    command -v "$_cmd" &>/dev/null || error "Critical dependency missing: $_cmd"
done
"$PYTHON_BIN" -m pip --version &>/dev/null \
    || error "pip not available — check Python environment step above."
info "System dependencies OK."
unset _cmd

# =============================================================================
# STEP 5 — DIRECTORIES & PATH
# =============================================================================
step "Directories"

mkdir -p \
    "$OLLAMA_MODELS" "$GGUF_MODELS" "$TEMP_DIR" \
    "$BIN_DIR" "$CONFIG_DIR" "$GUI_DIR" \
    "$WORK_DIR"
info "Directories created."

# Add $BIN_DIR to PATH in .bashrc (idempotent)
if ! grep -q "# llm-auto-setup PATH" "$HOME/.bashrc" 2>/dev/null; then
    {   printf '\n# llm-auto-setup PATH\n'
        printf '[[ ":$PATH:" != *":%s:"* ]] && export PATH="%s:$PATH"\n' \
            "$BIN_DIR" "$BIN_DIR"
    } >> "$HOME/.bashrc"
    info "Added $BIN_DIR to PATH in ~/.bashrc"
fi
[[ ":$PATH:" != *":$BIN_DIR:"* ]] && export PATH="$BIN_DIR:$PATH"

# Terminal syntax highlighting via bat + grc (idempotent)
if ! grep -q "# llm-bat-grc" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'BATGRC'

# ── Syntax highlighting — llm-auto-setup ──────────────────────────────────────
# bat: syntax-highlighted cat; Ubuntu ships it as 'batcat'
if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
    alias bat='batcat'
fi
if command -v bat &>/dev/null; then
    alias cat='bat --paging=never --style=plain'
    alias less='bat --paging=always'
    alias head='bat --paging=never --style=plain -n 20'
    alias tail='bat --paging=never --style=plain -n 20'
    export MANPAGER='sh -c "col -bx | bat --language=man --style=plain --paging=always"'
    export LESSOPEN="| src-hilite-lesspipe.sh %s" 2>/dev/null || true
fi
# grc: colorize diff, make, gcc, ping, ps, netstat, etc.
if command -v grc &>/dev/null; then
    alias diff='grc diff'; alias make='grc make'
    alias gcc='grc gcc';   alias g++='grc g++'
    alias ping='grc ping'; alias ps='grc ps'; alias netstat='grc netstat'
fi
# llm-bat-grc
BATGRC
    info "Terminal syntax highlighting configured (bat + grc)."
fi

# =============================================================================
# STEP 6 — SAVE CONFIG TO DISK
# (Needed before GPU steps so path is known for llm-show-config)
# =============================================================================
step "Saving model config"

# Derive OLLAMA_TAG from filename now so every subsequent step can use it
OLLAMA_TAG=$(basename "${M[file]}" .gguf \
    | sed -E 's/-([Qq][0-9].*)$/:\1/' \
    | tr '[:upper:]' '[:lower:]')

cat > "$MODEL_CONFIG" <<EOF
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
EOF
info "Config saved: $MODEL_CONFIG"

# =============================================================================
# STEP 7 — CUDA TOOLKIT  (NVIDIA only)
# =============================================================================
if (( HAS_NVIDIA )); then
    step "CUDA toolkit"

    setup_cuda_env() {
        # Find CUDA bin path and add to PATH / .bashrc
        local cuda_bin=""
        for _p in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
            [[ -d "$_p" ]] && { cuda_bin="$_p"; break; }
        done
        if [[ -n "$cuda_bin" && ":$PATH:" != *":$cuda_bin:"* ]]; then
            export PATH="$cuda_bin:$PATH"
            ! grep -q "# CUDA — llm-auto-setup" "$HOME/.bashrc" 2>/dev/null && {
                printf '\n# CUDA — llm-auto-setup\n' >> "$HOME/.bashrc"
                printf 'export PATH="%s:$PATH"\n' "$cuda_bin" >> "$HOME/.bashrc"
            }
            info "CUDA bin: $cuda_bin"
        fi
        # Detect nvcc path (alternative locations on some distros)
        local nvcc_path
        nvcc_path=$(command -v nvcc 2>/dev/null || find /usr/local/cuda* /usr/bin -name nvcc 2>/dev/null | head -1 || true)
        [[ -n "$nvcc_path" ]] && export PATH="$(dirname "$nvcc_path"):$PATH"
    }

    # Check if CUDA is already present
    CUDA_PRESENT=0
    command -v nvcc &>/dev/null && CUDA_PRESENT=1
    if (( !CUDA_PRESENT )); then
        for _p in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
            [[ -d "$_p" ]] && { CUDA_PRESENT=1; break; }
        done
    fi
    (( !CUDA_PRESENT )) && ldconfig -p 2>/dev/null | grep -q 'libcudart\.so\.12' && CUDA_PRESENT=1
    (( !CUDA_PRESENT )) && dpkg -l 'cuda-toolkit-*' 2>/dev/null | grep -q '^ii' && CUDA_PRESENT=1

    if (( CUDA_PRESENT )); then
        info "CUDA already installed: $(nvcc --version 2>/dev/null | grep release | head -1 || echo 'present')"
        setup_cuda_env || true
    else
        info "Installing CUDA toolkit…"
        _uver=$(lsb_release -rs 2>/dev/null || echo "unknown")
        [[ "$_uver" != "22.04" && "$_uver" != "24.04" ]] && warn "Ubuntu $_uver not tested — attempting anyway."
        _kr_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${_uver//./}/x86_64/cuda-keyring_1.1-1_all.deb"
        retry 3 5 wget -q -O "$TEMP_DIR/cuda-keyring.deb" "$_kr_url" \
            || error "Failed to download CUDA keyring from $_kr_url"
        sudo dpkg -i "$TEMP_DIR/cuda-keyring.deb" || true
        rm -f "$TEMP_DIR/cuda-keyring.deb"
        sudo apt-get update -qq || true
        _cuda_pkg=$(apt-cache search --names-only '^cuda-toolkit-12-' 2>/dev/null \
            | awk '{print $1}' | sort -V | tail -1 || true)
        [[ -z "$_cuda_pkg" ]] && _cuda_pkg="cuda-toolkit"
        sudo apt-get install -y "$_cuda_pkg" \
            || warn "CUDA install returned non-zero — check apt output."
        sudo ldconfig 2>/dev/null || true
        setup_cuda_env || true
        unset _uver _kr_url _cuda_pkg
    fi

    ldconfig -p 2>/dev/null | grep -q "libcudart.so.12" \
        && info "libcudart.so.12 in ldconfig ✔" \
        || warn "libcudart.so.12 not found — GPU inference may fail."
fi

# =============================================================================
# STEP 7b — ROCm TOOLKIT  (AMD only)
# =============================================================================
if (( HAS_AMD_GPU && !HAS_NVIDIA )); then
    step "ROCm toolkit"

    setup_rocm_env() {
        local rocm_lib=""
        for _rp in /opt/rocm/lib /opt/rocm-*/lib /usr/lib/x86_64-linux-gnu; do
            if [[ -f "$_rp/libhipblas.so" || -f "$_rp/librocblas.so" ]]; then
                rocm_lib="$_rp"; break
            fi
        done
        [[ -z "$rocm_lib" ]] && rocm_lib="/opt/rocm/lib"
        export LD_LIBRARY_PATH="$rocm_lib:${LD_LIBRARY_PATH:-}"
        export PATH="/opt/rocm/bin:$PATH"
        if ! grep -q "# ROCm — llm-auto-setup" "$HOME/.bashrc" 2>/dev/null; then
            printf '\n# ROCm — llm-auto-setup\n'          >> "$HOME/.bashrc"
            printf 'export PATH="/opt/rocm/bin:$PATH"\n'  >> "$HOME/.bashrc"
            printf 'export LD_LIBRARY_PATH="%s:${LD_LIBRARY_PATH:-}"\n' \
                "$rocm_lib"                                >> "$HOME/.bashrc"
        fi
        info "ROCm env configured: $rocm_lib"
    }

    ROCM_PRESENT=0
    { command -v rocminfo &>/dev/null || [[ -d /opt/rocm ]]; } && ROCM_PRESENT=1

    if (( ROCM_PRESENT )); then
        info "ROCm already installed."
        AMD_ROCM_VER=$(cat /opt/rocm/.info/version 2>/dev/null \
            || rocminfo 2>/dev/null | grep -oP 'Runtime Version: \K[0-9.]+' | head -1 \
            || echo "present")
        info "ROCm version: $AMD_ROCM_VER"
        setup_rocm_env
    else
        info "Installing ROCm via amdgpu-install…"
        _uver=$(lsb_release -rs 2>/dev/null || echo "unknown")
        _base="https://repo.radeon.com/amdgpu-install/latest/ubuntu/${_uver}/"
        _deb=$(wget -qO- "$_base" 2>/dev/null \
            | grep -oP 'amdgpu-install_[^"]+_all\.deb' | tail -1 \
            || echo "amdgpu-install_6.3.60300-1_all.deb")
        if retry 3 10 wget -q -O "$TEMP_DIR/amdgpu-install.deb" "${_base}${_deb}"; then
            sudo dpkg -i "$TEMP_DIR/amdgpu-install.deb" || true
            sudo apt-get update -qq || true
            rm -f "$TEMP_DIR/amdgpu-install.deb"
            sudo amdgpu-install --usecase=rocm --no-dkms -y \
                || warn "amdgpu-install returned non-zero — ROCm may be partial."
            setup_rocm_env
        else
            warn "amdgpu-install download failed — trying fallback apt path…"
            wget -qO- https://repo.radeon.com/rocm/rocm.gpg.key 2>/dev/null \
                | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/rocm.gpg || true
            echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/6.3 ${_uver} main" \
                | sudo tee /etc/apt/sources.list.d/rocm.list >/dev/null
            sudo apt-get update -qq || true
            sudo apt-get install -y rocm-hip-sdk rocm-opencl-sdk \
                || warn "ROCm apt install failed — see https://rocm.docs.amd.com"
            setup_rocm_env
        fi
        sudo usermod -aG render,video "$USER" 2>/dev/null \
            && info "Added $USER to render+video groups (takes effect on next login)." || true
        unset _uver _base _deb
    fi

    command -v hipconfig &>/dev/null \
        && info "HIP: $(hipconfig --version 2>/dev/null || echo 'present') ✔" \
        || warn "hipconfig not found — ROCm may need a reboot to activate."
fi

# =============================================================================
# STEP 8 — PYTHON VENV (main inference venv)
# =============================================================================
step "Python virtual environment"

[[ ! -d "$VENV_DIR" ]] && "${PYTHON_BIN:-python3}" -m venv "$VENV_DIR"
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate" || error "Failed to activate venv at $VENV_DIR"
[[ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]] && error "Venv activation sanity check failed."
info "Venv: $VIRTUAL_ENV"
pip install --upgrade pip setuptools wheel --quiet || true

# =============================================================================
# STEP 9 — LLAMA-CPP-PYTHON
# =============================================================================
step "llama-cpp-python"

check_llama() { "$VENV_DIR/bin/python3" -c "import llama_cpp" 2>/dev/null; }

# Build flags from detected CPU features
CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release"
(( HAS_NVIDIA  )) && CMAKE_ARGS+=" -DGGML_CUDA=ON -DLLAMA_CUBLAS=ON"
(( HAS_AVX512  )) && CMAKE_ARGS+=" -DGGML_AVX512=ON -DGGML_AVX2=ON -DGGML_FMA=ON"
(( !HAS_AVX512 && HAS_AVX2 )) && CMAKE_ARGS+=" -DGGML_AVX2=ON -DGGML_FMA=ON"
(( !HAS_AVX2   && HAS_AVX  )) && CMAKE_ARGS+=" -DGGML_AVX=ON"
(( HAS_NEON    )) && CMAKE_ARGS+=" -DGGML_NEON=ON"
export SOURCE_BUILD_CMAKE_ARGS="$CMAKE_ARGS"

LLAMA_INSTALLED=0

# ── NVIDIA: try pre-built CUDA wheels ────────────────────────────────────────
if (( HAS_NVIDIA )); then
    CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1 || true)
    [[ -z "$CUDA_VER" ]] && CUDA_VER="$CUDA_VER_SMI"
    [[ -z "$CUDA_VER" ]] && CUDA_VER="12.1"
    CUDA_TAG="cu$(echo "$CUDA_VER" | tr -d '.')"
    info "CUDA $CUDA_VER → wheel tag $CUDA_TAG"
    for _whl in \
        "https://abetlen.github.io/llama-cpp-python/whl/${CUDA_TAG}" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu124" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu122" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu121"
    do
        info "Trying CUDA wheel: $_whl"
        pip install llama-cpp-python \
            --index-url "$_whl" \
            --extra-index-url https://pypi.org/simple \
            --quiet 2>&1 \
            && { info "CUDA wheel OK from $_whl"; LLAMA_INSTALLED=1; break; } \
            || warn "Failed — trying next."
    done
    unset _whl
fi

# ── AMD: try pre-built ROCm wheels ───────────────────────────────────────────
if (( HAS_AMD_GPU && !HAS_NVIDIA && LLAMA_INSTALLED == 0 )); then
    info "Trying ROCm pre-built wheels for llama-cpp-python…"
    for _whl in \
        "https://abetlen.github.io/llama-cpp-python/whl/rocm600" \
        "https://abetlen.github.io/llama-cpp-python/whl/rocm550"
    do
        info "Trying ROCm wheel: $_whl"
        pip install llama-cpp-python \
            --index-url "$_whl" \
            --extra-index-url https://pypi.org/simple \
            --quiet 2>&1 \
            && { info "ROCm wheel OK from $_whl"; LLAMA_INSTALLED=1; break; } \
            || warn "Failed — trying next."
    done
    unset _whl
fi

# ── Source build fallback ─────────────────────────────────────────────────────
if (( LLAMA_INSTALLED == 0 )); then
    if (( HAS_NVIDIA )); then
        warn "No pre-built CUDA wheel found — building from source (~5 min)…"
        MAKE_JOBS="$HW_THREADS" CMAKE_ARGS="$SOURCE_BUILD_CMAKE_ARGS" \
            pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python CUDA build failed."
    elif (( HAS_AMD_GPU )); then
        warn "No pre-built ROCm wheel found — building from source (~8 min)…"
        MAKE_JOBS="$HW_THREADS" \
        CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DGGML_HIPBLAS=ON" \
            pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python ROCm build failed."
    else
        info "CPU-only build (~3 min)…"
        MAKE_JOBS="$HW_THREADS" CMAKE_ARGS="$SOURCE_BUILD_CMAKE_ARGS" \
            pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python CPU build failed."
    fi
fi

check_llama && info "llama-cpp-python ✔" \
    || warn "llama-cpp-python import failed — check CUDA/ROCm paths and re-run."

# =============================================================================
# STEP 10 — OLLAMA
# =============================================================================
step "Ollama"

if ! command -v ollama &>/dev/null; then
    info "Installing Ollama…"
    retry 3 10 bash -c "curl -fsSL https://ollama.com/install.sh | sh" </dev/null \
        || error "Ollama install failed."
else
    info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'version unknown')"
fi

# Tune concurrency to available RAM
OLLAMA_PARALLEL=1
(( TOTAL_RAM_GB >= 32 )) && OLLAMA_PARALLEL=2

if is_wsl2; then
    # WSL2: run Ollama as a background process
    cat > "$BIN_DIR/ollama-start" <<OLSTART
#!/usr/bin/env bash
# ollama-start — launch Ollama in WSL2
export OLLAMA_MODELS="$OLLAMA_MODELS"
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_NUM_PARALLEL=$OLLAMA_PARALLEL
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_NUM_THREAD=$HW_THREADS
export OLLAMA_ORIGINS="*"
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
# AMD ROCm — only set if already exported by caller (avoids confusing NVIDIA)
[[ -n "\${HSA_OVERRIDE_GFX_VERSION:-}" ]] && export HSA_OVERRIDE_GFX_VERSION
export ROCR_VISIBLE_DEVICES=\${ROCR_VISIBLE_DEVICES:-0}

pgrep -f "ollama serve" >/dev/null 2>&1 && { echo "Ollama already running."; exit 0; }
echo "Starting Ollama…"
nohup ollama serve >"\$HOME/.ollama.log" 2>&1 &
sleep 3
pgrep -f "ollama serve" >/dev/null 2>&1 \
    && echo "Ollama started." \
    || { echo "ERROR: Ollama failed to start. Check: cat ~/.ollama.log"; exit 1; }
OLSTART
    chmod +x "$BIN_DIR/ollama-start"
    "$BIN_DIR/ollama-start" || warn "Ollama launcher returned non-zero."
else
    # Native Linux: use systemd with an override drop-in
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS"
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_NUM_PARALLEL=$OLLAMA_PARALLEL"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_THREAD=$HW_THREADS"
Environment="OLLAMA_ORIGINS=*"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="ROCR_VISIBLE_DEVICES=0"
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ollama  || warn "systemctl enable ollama failed."
    sudo systemctl restart ollama || warn "systemctl restart ollama failed."

    # Also write ollama-start wrapper for scripts/launchers
    cat > "$BIN_DIR/ollama-start" <<'OLSTART_NATIVE'
#!/usr/bin/env bash
# ollama-start — start/check Ollama systemd service
if systemctl is-active --quiet ollama 2>/dev/null; then
    echo "Ollama service already running."
else
    echo "Starting Ollama service…"
    sudo systemctl start ollama \
        || { echo "ERROR: sudo systemctl start ollama failed."; exit 1; }
    sleep 2
    systemctl is-active --quiet ollama \
        && echo "Ollama started." \
        || echo "WARNING: Ollama may not be running — check: sudo journalctl -u ollama -n 30"
fi
OLSTART_NATIVE
    chmod +x "$BIN_DIR/ollama-start"
fi

# Verify Ollama is up
sleep 3
if is_wsl2; then
    pgrep -f "ollama serve" >/dev/null 2>&1 \
        && info "Ollama running." || warn "Ollama not running — try: ollama-start"
else
    systemctl is-active --quiet ollama \
        && info "Ollama service active." || warn "Ollama service not active — try: ollama-start"
fi

# =============================================================================
# STEP 11 — MODEL DOWNLOAD
# =============================================================================
step "Model download"

if ask_yes_no "Download ${M[name]} (~${M[size_gb]} GB) now?"; then
    info "Downloading ${M[file]} → $GGUF_MODELS"
    pushd "$GGUF_MODELS" >/dev/null

    DL_OK=0
    if command -v curl &>/dev/null; then
        retry 3 20 curl -L --fail -C - --progress-bar \
            -o "${M[file]}" "${M[url]}" \
            && DL_OK=1 || warn "curl download failed."
    fi
    if [[ $DL_OK -eq 0 ]] && command -v wget &>/dev/null; then
        retry 3 20 wget --tries=1 --show-progress -c \
            -O "${M[file]}" "${M[url]}" \
            && DL_OK=1 || warn "wget also failed."
    fi

    if [[ $DL_OK -eq 1 && -f "${M[file]}" ]]; then
        info "Download complete: $(du -h "${M[file]}" | cut -f1)"

        # Register with Ollama so it appears in Neural Terminal + Open WebUI
        if command -v ollama &>/dev/null; then
            info "Registering model with Ollama as: $OLLAMA_TAG"
            _mf="$TEMP_DIR/Modelfile.$$"
            cat > "$_mf" <<MODELFILE
FROM $GGUF_MODELS/${M[file]}
PARAMETER num_thread $HW_THREADS
PARAMETER num_ctx 8192
MODELFILE
            if start_ollama_if_needed && ollama create "$OLLAMA_TAG" -f "$_mf"; then
                info "✔ Registered: $OLLAMA_TAG"
            else
                warn "ollama create failed — model won't appear in WebUI until registered."
                warn "  Retry manually: ollama create $OLLAMA_TAG -f $GGUF_MODELS/${M[file]}"
            fi
            rm -f "$_mf"
            unset _mf
        fi
    else
        warn "Download failed. Resume with:"
        warn "  curl -L -C - -o '$GGUF_MODELS/${M[file]}' '${M[url]}'"
    fi

    popd >/dev/null
fi

# =============================================================================
# STEP 12 — HELPER SCRIPTS
# =============================================================================
step "Helper scripts"

# ── run-gguf ──────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/run-gguf" <<'PYEOF'
#!/usr/bin/env python3
"""Run a local GGUF model. Hardware defaults loaded from selected_model.conf."""
import sys, os, glob, argparse

MODEL_DIR  = os.path.expanduser("~/local-llm-models/gguf")
CONFIG_DIR = os.path.expanduser("~/.config/local-llm")
VENV_SITE  = os.path.expanduser("~/.local/share/llm-venv/lib")

# Add venv site-packages so llama_cpp is importable without activating venv
for _sp in glob.glob(os.path.join(VENV_SITE, "python3*/site-packages")):
    if _sp not in sys.path:
        sys.path.insert(0, _sp)

def load_conf():
    cfg = {}
    p = os.path.join(CONFIG_DIR, "selected_model.conf")
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
        print("No GGUF models in", MODEL_DIR)
        return
    print("Available models:")
    for m in models:
        print(f"  {os.path.basename(m):<55} {os.path.getsize(m)/1024**3:.1f} GB")

def main():
    cfg = load_conf()
    p = argparse.ArgumentParser(description="Run a GGUF model (hardware-tuned defaults)")
    p.add_argument("model",  nargs="?")
    p.add_argument("prompt", nargs="*")
    p.add_argument("--gpu-layers", type=int, default=None)
    p.add_argument("--ctx",        type=int, default=8192)
    p.add_argument("--max-tokens", type=int, default=512)
    p.add_argument("--threads",    type=int, default=int(cfg.get("HW_THREADS", 4)))
    p.add_argument("--batch",      type=int, default=int(cfg.get("BATCH", 256)))
    args = p.parse_args()

    if not args.model:
        list_models()
        sys.exit(0)

    model_path = args.model if os.path.isabs(args.model) \
        else os.path.join(MODEL_DIR, args.model)
    if not os.path.exists(model_path):
        print(f"Not found: {model_path}")
        list_models()
        sys.exit(1)

    prompt     = " ".join(args.prompt) if args.prompt else "Hello! How are you?"
    gpu_layers = args.gpu_layers if args.gpu_layers is not None \
        else int(cfg.get("GPU_LAYERS", 0))

    try:
        from llama_cpp import Llama
        print(f"Loading {os.path.basename(model_path)} "
              f"| GPU:{gpu_layers} threads:{args.threads} batch:{args.batch} ctx:{args.ctx}",
              flush=True)
        llm = Llama(
            model_path=model_path,
            n_gpu_layers=gpu_layers,
            n_threads=args.threads,
            n_batch=args.batch,
            verbose=False,
            n_ctx=args.ctx,
        )
        out = llm(prompt, max_tokens=args.max_tokens, echo=True, temperature=0.7, top_p=0.95)
        print(out["choices"][0]["text"])
    except ImportError:
        print("ERROR: Activate venv first: source ~/.local/share/llm-venv/bin/activate")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
PYEOF
chmod +x "$BIN_DIR/run-gguf"

# ── local-models-info (llm-status) ───────────────────────────────────────────
cat > "$BIN_DIR/local-models-info" <<'INFOEOF'
#!/usr/bin/env bash
# local-models-info — show installed models and active config
_cfg="$HOME/.config/local-llm/selected_model.conf"
_cfgread() { grep "^${1}=" "$_cfg" 2>/dev/null | head -1 | cut -d'"' -f2; }

echo ""
echo "═══════════════════════════════════════════"
echo "  Ollama Models"
echo "═══════════════════════════════════════════"
ollama list 2>/dev/null || echo "  (Ollama not running — run: ollama-start)"

echo ""
echo "═══════════════════════════════════════════"
echo "  GGUF Models  ($HOME/local-llm-models/gguf)"
echo "═══════════════════════════════════════════"
shopt -s nullglob
_files=(~/local-llm-models/gguf/*.gguf)
if [[ ${#_files[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for _f in "${_files[@]}"; do
        printf "  %-55s %s\n" "$(basename "$_f")" "$(du -sh "$_f" 2>/dev/null | cut -f1)"
    done
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Disk Usage"
echo "═══════════════════════════════════════════"
du -sh ~/local-llm-models 2>/dev/null || echo "  (no models dir)"

if [[ -f "$_cfg" ]]; then
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Active Config"
    echo "═══════════════════════════════════════════"
    echo "  Model:      $(_cfgread MODEL_NAME)  ($(_cfgread MODEL_SIZE))"
    echo "  Caps:       $(_cfgread MODEL_CAPS)"
    echo "  GPU layers: $(_cfgread GPU_LAYERS) / $(_cfgread MODEL_LAYERS)"
    echo "  CPU layers: $(_cfgread CPU_LAYERS)"
    echo "  Threads:    $(_cfgread HW_THREADS)  Batch: $(_cfgread BATCH)"
    echo "  Ollama tag: $(_cfgread OLLAMA_TAG)"
    echo "  File:       $(_cfgread MODEL_FILENAME)"
fi
echo ""
INFOEOF
chmod +x "$BIN_DIR/local-models-info"

# ── llm-show-config ───────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-show-config" <<'SHOWCFG'
#!/usr/bin/env bash
# llm-show-config — show all paths, config values, and install locations

_G='\033[0;32m'; _Y='\033[1;33m'; _C='\033[0;36m'; _N='\033[0m'
_cfg="$HOME/.config/local-llm/selected_model.conf"
_cfgread() { grep "^${1}=" "$_cfg" 2>/dev/null | head -1 | cut -d'"' -f2; }

echo ""
echo -e "${_C}╔══════════════════════════════════════════════════════════════════╗${_N}"
echo -e "${_C}║                    LOCAL LLM — PATHS & CONFIG                   ║${_N}"
echo -e "${_C}╚══════════════════════════════════════════════════════════════════╝${_N}"
echo ""

echo -e "${_C}  ── Install paths ───────────────────────────────────────────────${_N}"
_show_path() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        printf "  ${_G}✔${_N}  %-24s  %s\n" "$label" "$path"
    else
        printf "  ${_Y}✗${_N}  %-24s  %s  ${_Y}(not found)${_N}\n" "$label" "$path"
    fi
}
_show_path "Config dir"        "$HOME/.config/local-llm"
_show_path "Config file"       "$HOME/.config/local-llm/selected_model.conf"
_show_path "GGUF models"       "$HOME/local-llm-models/gguf"
_show_path "Ollama models"     "$HOME/local-llm-models/ollama"
_show_path "Neural Terminal"   "$HOME/.local/share/llm-webui/llm-chat.html"
_show_path "Open WebUI venv"   "$HOME/.local/share/open-webui-venv"
_show_path "Open WebUI data"   "$HOME/.local/share/llm-webui/open-webui-data"
_show_path "llm-venv (main)"   "$HOME/.local/share/llm-venv"
_show_path "cowork venv"       "$HOME/.local/share/open-interpreter-venv"
_show_path "aider venv"        "$HOME/.local/share/aider-venv"
_show_path "bin dir"           "$HOME/.local/bin"
_show_path "work dir"          "$HOME/work"
_show_path "aliases file"      "$HOME/.local_llm_aliases"
_show_path "log (latest)"      "$(ls -t "$HOME"/llm-auto-setup-*.log 2>/dev/null | head -1 || echo '(none)')"
_show_path "pkg cache"         "$HOME/.cache/llm-setup"

echo ""
echo -e "${_C}  ── Active model config ─────────────────────────────────────────${_N}"
if [[ -f "$_cfg" ]]; then
    printf "  %-24s  ${_G}%s${_N}\n" "Model name"    "$(_cfgread MODEL_NAME)"
    printf "  %-24s  %s\n"           "Size tier"     "$(_cfgread MODEL_SIZE)"
    printf "  %-24s  %s\n"           "Capabilities"  "$(_cfgread MODEL_CAPS)"
    printf "  %-24s  %s\n"           "GGUF file"     "$(_cfgread MODEL_FILENAME)"
    printf "  %-24s  ${_Y}%s${_N}\n" "Ollama tag"    "$(_cfgread OLLAMA_TAG)"
    printf "  %-24s  %s / %s total\n" "GPU layers"   "$(_cfgread GPU_LAYERS)" "$(_cfgread MODEL_LAYERS)"
    printf "  %-24s  %s\n"           "CPU layers"    "$(_cfgread CPU_LAYERS)"
    printf "  %-24s  %s\n"           "Threads"       "$(_cfgread HW_THREADS)"
    printf "  %-24s  %s\n"           "Batch size"    "$(_cfgread BATCH)"
    echo ""
    printf "  %-24s  %s\n"           "Download URL"  "$(_cfgread MODEL_URL)"
    echo ""
    _gguf_file="$HOME/local-llm-models/gguf/$(_cfgread MODEL_FILENAME)"
    if [[ -f "$_gguf_file" ]]; then
        printf "  ${_G}✔${_N}  %-22s  %s  (%s)\n" \
            "GGUF file on disk" "$_gguf_file" "$(du -sh "$_gguf_file" 2>/dev/null | cut -f1)"
    else
        printf "  ${_Y}✗${_N}  %-22s  %s  ${_Y}(not downloaded)${_N}\n" \
            "GGUF file on disk" "$_gguf_file"
    fi
else
    echo "  (no config found — run: llm-setup)"
fi

echo ""
echo -e "${_C}  ── Services ────────────────────────────────────────────────────${_N}"
if curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo -e "  ${_G}✔${_N}  Ollama             running at http://127.0.0.1:11434"
else
    echo -e "  ${_Y}✗${_N}  Ollama             not running  (run: ollama-start)"
fi
if curl -sf --max-time 2 http://127.0.0.1:8090 >/dev/null 2>&1; then
    echo -e "  ${_G}✔${_N}  Neural Terminal    running at http://localhost:8090"
else
    echo -e "  ${_Y}–${_N}  Neural Terminal    not running  (run: chat)"
fi
if curl -sf --max-time 2 http://127.0.0.1:8080 >/dev/null 2>&1; then
    echo -e "  ${_G}✔${_N}  Open WebUI         running at http://localhost:8080"
else
    echo -e "  ${_Y}–${_N}  Open WebUI         not running  (run: webui)"
fi
echo ""
SHOWCFG
chmod +x "$BIN_DIR/llm-show-config"

# ── llm-stop ──────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-stop" <<'STOP_EOF'
#!/usr/bin/env bash
# llm-stop — stop Ollama and Open WebUI
_is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

echo "Stopping local LLM services…"

# Ollama
if _is_wsl2 || ! systemctl is-active --quiet ollama 2>/dev/null; then
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        pkill -f "ollama serve" 2>/dev/null && echo "✔ Ollama stopped." || echo "Could not stop Ollama."
    else
        echo "  Ollama: not running."
    fi
else
    sudo systemctl stop ollama && echo "✔ Ollama service stopped." || echo "Could not stop Ollama service."
fi

# Open WebUI
if pgrep -f "open-webui" >/dev/null 2>&1; then
    pkill -f "open-webui" 2>/dev/null && echo "✔ Open WebUI stopped." || true
else
    echo "  Open WebUI: not running."
fi

# Neural Terminal HTTP server
if pgrep -f "http.server.*8090" >/dev/null 2>&1; then
    pkill -f "http.server.*8090" 2>/dev/null && echo "✔ Neural Terminal stopped." || true
fi
STOP_EOF
chmod +x "$BIN_DIR/llm-stop"

# ── llm-update ────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-update" <<'UPDATE_EOF'
#!/usr/bin/env bash
# llm-update — upgrade Ollama, Open WebUI, and pull the latest model tag
set -uo pipefail

CONFIG="$HOME/.config/local-llm/selected_model.conf"
OWUI_VENV="$HOME/.local/share/open-webui-venv"

echo ""
echo "═══════════════════════  LLM Stack Updater  ══════════════════════"
echo ""

echo "[ 1/3 ] Checking Ollama version…"
_cur=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
_latest=$(curl -fsSL --max-time 8 https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null \
    | grep '"tag_name"' | grep -oP 'v\K[\d.]+' | head -1 || echo "")
echo "  Installed: $_cur  |  Latest: ${_latest:-unknown}"
_ver_gt() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" ]] && [[ "$1" != "$2" ]]; }
if [[ -n "$_latest" ]] && _ver_gt "$_latest" "$_cur"; then
    echo "  Upgrading $_cur → $_latest…"
    curl -fsSL https://ollama.com/install.sh | sh \
        && echo "  ✔ Ollama updated: $(ollama --version 2>/dev/null || echo ok)" \
        || echo "  ✘ Ollama update failed."
elif [[ -z "$_latest" ]]; then
    echo "  Could not reach GitHub — skipping Ollama upgrade."
else
    echo "  ✔ Ollama is already up to date ($_cur)."
fi
unset -f _ver_gt 2>/dev/null; unset _cur _latest

echo ""
echo "[ 2/3 ] Updating Open WebUI…"
if [[ -d "$OWUI_VENV" ]]; then
    OLD_VER=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?")
    "$OWUI_VENV/bin/pip" install --upgrade open-webui --quiet \
        && NEW_VER=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?") \
        && echo "  ✔ Open WebUI: $OLD_VER → $NEW_VER" \
        || echo "  ✘ Open WebUI update failed."
else
    echo "  Open WebUI venv not found — run: llm-setup to install."
fi

echo ""
echo "[ 3/3 ] Pulling latest model tag…"
OLLAMA_TAG=""
[[ -f "$CONFIG" ]] && OLLAMA_TAG=$(grep "^OLLAMA_TAG=" "$CONFIG" | head -1 | cut -d'"' -f2)
if [[ -n "$OLLAMA_TAG" ]]; then
    # Ensure Ollama is running
    if ! curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        echo "  Starting Ollama for model pull…"
        if grep -qi microsoft /proc/version 2>/dev/null; then
            command -v ollama-start &>/dev/null && ollama-start \
                || nohup ollama serve >/dev/null 2>&1 &
        else
            sudo systemctl start ollama 2>/dev/null \
                || nohup ollama serve >/dev/null 2>&1 &
        fi
        sleep 3
    fi
    ollama pull "$OLLAMA_TAG" \
        && echo "  ✔ Model up to date: $OLLAMA_TAG" \
        || echo "  ✘ ollama pull failed — check internet connection."
else
    echo "  ✘ No OLLAMA_TAG in config — skipping model pull."
fi

echo ""
echo "Done. Restart: ollama-start && webui"
echo ""
UPDATE_EOF
chmod +x "$BIN_DIR/llm-update"

# ── llm-switch ────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-switch" <<'SWITCH_EOF'
#!/usr/bin/env bash
# llm-switch — change active model without re-running full setup
set -uo pipefail

CONFIG="$HOME/.config/local-llm/selected_model.conf"
GGUF_DIR="$HOME/local-llm-models/gguf"

echo ""
echo "═══════════════════════════════════════════"
echo "  LLM Model Switcher"
echo "═══════════════════════════════════════════"
if [[ -f "$CONFIG" ]]; then
    _cur=$(grep "^MODEL_NAME=" "$CONFIG" | cut -d'"' -f2)
    _tag=$(grep "^OLLAMA_TAG="  "$CONFIG" | cut -d'"' -f2)
    echo "  Current: $_cur  [$_tag]"
fi
echo ""

# Ensure Ollama is running so 'ollama list' works
if ! curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "  Ollama not running — starting it…"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        command -v ollama-start &>/dev/null && ollama-start \
            || nohup ollama serve >/dev/null 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >/dev/null 2>&1 &
    fi
    for _i in {1..10}; do
        curl -sf --max-time 1 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
        sleep 1
    done
fi

mapfile -t TAGS < <(ollama list 2>/dev/null | awk 'NR>1{print $1}')
if [[ ${#TAGS[@]} -eq 0 ]]; then
    echo "  No models in Ollama. Download one: ollama pull qwen3:8b"
    echo "  Or re-run setup to download the auto-selected model."
    exit 0
fi

echo "  Available Ollama models:"
for i in "${!TAGS[@]}"; do
    printf "    %2d)  %s\n" "$((i+1))" "${TAGS[$i]}"
done
echo ""
read -r -p "  Choice [1-${#TAGS[@]}] (or Enter to cancel): " choice
[[ -z "$choice" ]] && echo "Cancelled." && exit 0
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#TAGS[@]} )); then
    echo "Invalid choice." && exit 1
fi
NEW_TAG="${TAGS[$((choice-1))]}"

if [[ -f "$CONFIG" ]]; then
    if grep -q "^OLLAMA_TAG=" "$CONFIG"; then
        sed -i "s|^OLLAMA_TAG=.*|OLLAMA_TAG=\"$NEW_TAG\"|" "$CONFIG"
    else
        echo "OLLAMA_TAG=\"$NEW_TAG\"" >> "$CONFIG"
    fi
    sed -i "s|^MODEL_NAME=.*|MODEL_NAME=\"$NEW_TAG\"|" "$CONFIG"
fi

echo ""
echo "  ✔ Switched to: $NEW_TAG"
echo "  Run: webui  or  ollama-run $NEW_TAG"
echo ""
SWITCH_EOF
chmod +x "$BIN_DIR/llm-switch"

# ── llm-add ────────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-add" <<'ADD_EOF'
#!/usr/bin/env bash
# llm-add — download additional models with hardware-filtered catalog
set -uo pipefail

CONFIG="$HOME/.config/local-llm/selected_model.conf"
GGUF_DIR="$HOME/local-llm-models/gguf"
TEMP_DIR="$HOME/local-llm-models/temp"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$GGUF_DIR" "$TEMP_DIR"

# Detect hardware at runtime
GPU_VRAM_GB=0
if command -v nvidia-smi &>/dev/null; then
    _v=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    [[ "$_v" =~ ^[0-9]+$ ]] && GPU_VRAM_GB=$(( _v / 1024 ))
fi
if [[ $GPU_VRAM_GB -eq 0 ]]; then
    for _f in /sys/class/drm/card*/device/mem_info_vram_total; do
        [[ -f "$_f" ]] || continue
        _b=$(cat "$_f" 2>/dev/null || echo 0)
        _m=$(( _b / 1024 / 1024 ))
        if (( _m > 512 )); then GPU_VRAM_GB=$(( _m / 1024 )); break; fi
    done
fi
TOTAL_RAM_GB=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 4)
HW_THREADS=$(nproc 2>/dev/null || echo 4)

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  LLM Model Downloader"
[[ $GPU_VRAM_GB -gt 0 ]] \
    && printf "  Hardware: GPU %d GB VRAM   RAM %d GB\n" "$GPU_VRAM_GB" "$TOTAL_RAM_GB" \
    || printf "  Hardware: CPU-only   RAM %d GB\n" "$TOTAL_RAM_GB"
echo "══════════════════════════════════════════════════════════════════"

# Catalog: "name|quant|min_vram_gb|caps|file_gb|layers|filename|hf_repo_path"
declare -a _CAT=(
    "Qwen3-1.7B|Q8_0|0|TOOLS+THINK|2|28|Qwen_Qwen3-1.7B-Q8_0.gguf|Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
    "Phi-4-mini 3.8B|Q4_K_M|0|TOOLS+THINK|3|32|microsoft_Phi-4-mini-instruct-Q4_K_M.gguf|microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
    "Qwen3-4B|Q4_K_M|3|TOOLS+THINK|3|36|Qwen_Qwen3-4B-Q4_K_M.gguf|Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
    "Qwen3-8B|Q4_K_M|5|TOOLS+THINK|5|36|Qwen_Qwen3-8B-Q4_K_M.gguf|Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
    "Qwen3-8B|Q6_K|6|TOOLS+THINK|6|36|Qwen_Qwen3-8B-Q6_K.gguf|Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
    "DeepSeek-R1-Distill-8B ★|Q4_K_M|5|THINK|5|36|DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-8B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"
    "Dolphin3.0-8B|Q4_K_M|5|UNCENS|5|32|Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf|Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
    "Gemma-3-12B|Q4_K_M|8|TOOLS|8|46|google_gemma-3-12b-it-Q4_K_M.gguf|google_gemma-3-12b-it-GGUF/resolve/main/google_gemma-3-12b-it-Q4_K_M.gguf"
    "Phi-4-14B|Q4_K_M|9|TOOLS+THINK|9|40|phi-4-Q4_K_M.gguf|phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf"
    "Qwen3-14B|Q4_K_M|9|TOOLS+THINK|9|40|Qwen_Qwen3-14B-Q4_K_M.gguf|Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
    "DeepSeek-R1-Distill-14B|Q4_K_M|9|THINK|9|40|DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
    "Mistral-Small-3.1-24B ★|Q4_K_M|14|TOOLS+THINK|14|40|mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf|mistralai_Mistral-Small-3.1-24B-Instruct-2503-GGUF/resolve/main/mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"
    "Mistral-Small-3.2-24B ★★|Q4_K_M|14|TOOLS+THINK|14|40|mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf|mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
    "Gemma-3-27B (Google)|Q4_K_M|12|TOOLS|16|62|google_gemma-3-27b-it-Q4_K_M.gguf|google_gemma-3-27b-it-GGUF/resolve/main/google_gemma-3-27b-it-Q4_K_M.gguf"
    "Qwen3-30B-A3B MoE|Q4_K_M|16|TOOLS+THINK|18|48|Qwen_Qwen3-30B-A3B-Q4_K_M.gguf|Qwen_Qwen3-30B-A3B-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
    "Qwen3-32B|Q4_K_M|19|TOOLS+THINK|19|64|Qwen_Qwen3-32B-Q4_K_M.gguf|Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
    "DeepSeek-R1-Distill-32B|Q4_K_M|19|THINK|19|64|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
)

_show_table() {
    local show_all="${1:-0}"
    echo ""
    echo "  Legend: [TOOLS] function calling   [THINK] reasoning   [UNCENS] uncensored   ★ best"
    echo ""
    echo "  ┌────┬──────────────────────────────┬──────┬────────┬──────────────────┐"
    echo "  │ #  │ Model                        │ Quant│  VRAM  │ Capabilities     │"
    echo "  ├────┼──────────────────────────────┼──────┼────────┼──────────────────┤"
    local row=0 visible=0
    for entry in "${_CAT[@]}"; do
        (( row++ ))
        IFS='|' read -r mname mquant mvram mcaps mfgb mlayers mfile mpath <<< "$entry"
        local fits=0
        if [[ $show_all -eq 1 ]]; then
            fits=1
        elif (( GPU_VRAM_GB > 0 && mvram <= GPU_VRAM_GB )); then
            fits=1
        elif (( GPU_VRAM_GB == 0 && mfgb * 2 <= TOTAL_RAM_GB )); then
            fits=1
        fi
        if [[ $fits -eq 1 ]]; then
            printf "  │ %-3s│ %-29s│ %-6s│ ~%-6s│ %-18s│\n" \
                "$row" "$mname" "$mquant" "${mvram}GB" "$mcaps"
            (( visible++ ))
        fi
    done
    echo "  └────┴──────────────────────────────┴──────┴────────┴──────────────────┘"
    echo ""
    printf "  Showing %d/%d models that fit your hardware." "$visible" "${#_CAT[@]}"
    [[ $show_all -eq 0 ]] && echo " Type 'all' to see everything." || echo ""
    echo ""
}

_show_table 0

while true; do
    read -r -p "  Choice (number, 'all', or Enter to cancel): " _choice
    [[ -z "$_choice" ]] && echo "Cancelled." && exit 0
    if [[ "$_choice" == "all" ]]; then
        _show_table 1; continue
    fi
    if ! [[ "$_choice" =~ ^[0-9]+$ ]] || (( _choice < 1 || _choice > ${#_CAT[@]} )); then
        echo "  Invalid — enter a number between 1 and ${#_CAT[@]}."; continue
    fi
    break
done

IFS='|' read -r M_NAME M_QUANT M_VRAM M_CAPS M_FGB M_LAYERS M_FILE M_PATH \
    <<< "${_CAT[$(( _choice - 1 ))]}"
M_URL="https://huggingface.co/bartowski/${M_PATH}"

echo ""
echo "  Selected: $M_NAME $M_QUANT  (~${M_FGB} GB)"
echo "  URL:      $M_URL"
echo ""

_DO_DL=0
if [[ -f "$GGUF_DIR/$M_FILE" ]]; then
    echo "  Already downloaded: $(du -sh "$GGUF_DIR/$M_FILE" | cut -f1)"
    read -r -p "  Re-download? (y/N) " _yn; echo
    [[ "$_yn" =~ ^[Yy]$ ]] && _DO_DL=1
else
    _DO_DL=1
fi

if [[ $_DO_DL -eq 1 ]]; then
    echo "  Downloading — this may take a while…"
    pushd "$GGUF_DIR" >/dev/null
    DL_OK=0
    command -v curl &>/dev/null \
        && curl -L --fail -C - --progress-bar -o "$M_FILE" "$M_URL" \
        && DL_OK=1 || true
    [[ $DL_OK -eq 0 ]] && command -v wget &>/dev/null \
        && wget --tries=1 --show-progress -c -O "$M_FILE" "$M_URL" \
        && DL_OK=1 || true
    if [[ $DL_OK -eq 1 ]]; then
        echo "  ✔ Downloaded: $(du -sh "$M_FILE" | cut -f1)"
    else
        echo "  ✘ Download failed. Try:"
        echo "    curl -L -C - -o '$GGUF_DIR/$M_FILE' '$M_URL'"
        popd >/dev/null; exit 1
    fi
    popd >/dev/null
fi

# Register with Ollama
OLLAMA_TAG=""
if command -v ollama &>/dev/null; then
    OLLAMA_TAG=$(basename "$M_FILE" .gguf \
        | sed -E 's/-([Qq][0-9].*)$/:\1/' | tr '[:upper:]' '[:lower:]')
    echo "  Registering with Ollama as: $OLLAMA_TAG"
    _mf="$TEMP_DIR/Modelfile.llm-add.$$"
    cat > "$_mf" <<MODELFILE_ADD
FROM $GGUF_DIR/$M_FILE
PARAMETER num_gpu 999
PARAMETER num_thread $HW_THREADS
PARAMETER num_ctx 8192
MODELFILE_ADD
    if ollama create "$OLLAMA_TAG" -f "$_mf"; then
        echo "  ✔ Registered: $OLLAMA_TAG"
    else
        echo "  ✘ ollama create failed. Is Ollama running?  Try: ollama-start"
    fi
    rm -f "$_mf"
else
    echo "  Ollama not found — model saved but not registered."
fi

# Optionally set as active model
echo ""
read -r -p "  Set '$M_NAME $M_QUANT' as your active default? (y/N) " _sw; echo
if [[ "$_sw" =~ ^[Yy]$ && -f "$CONFIG" ]]; then
    sed -i "s|^MODEL_NAME=.*|MODEL_NAME=\"$M_NAME $M_QUANT\"|" "$CONFIG"
    sed -i "s|^MODEL_FILENAME=.*|MODEL_FILENAME=\"$M_FILE\"|" "$CONFIG"
    [[ -n "${OLLAMA_TAG:-}" ]] \
        && sed -i "s|^OLLAMA_TAG=.*|OLLAMA_TAG=\"$OLLAMA_TAG\"|" "$CONFIG"
    echo "  ✔ Active model updated."
fi

echo ""
[[ -n "${OLLAMA_TAG:-}" ]] \
    && echo "  Done. Run: webui  or  ollama-run $OLLAMA_TAG" \
    || echo "  Done. Model saved to: $GGUF_DIR/$M_FILE"
echo ""
ADD_EOF
chmod +x "$BIN_DIR/llm-add"

info "Helper scripts written."

# =============================================================================
# STEP 13 — WEB UI
# Open WebUI is the primary UI — always installed.
# Neural Terminal is the zero-dep fallback — always written.
# =============================================================================
step "Web UI (Open WebUI + Neural Terminal)"

# ── Open WebUI — always installed ─────────────────────────────────────────────
info "Installing Open WebUI (primary chat UI)…"
if is_wsl2; then _OWUI_HOST="0.0.0.0"; else _OWUI_HOST="127.0.0.1"; fi

[[ ! -d "$OWUI_VENV" ]] && "${PYTHON_BIN:-python3}" -m venv "$OWUI_VENV"
"$OWUI_VENV/bin/pip" install --upgrade pip --quiet || true

# Check if already installed; only upgrade if already present, install if not
if "$OWUI_VENV/bin/pip" show open-webui &>/dev/null 2>&1; then
    OLD_OWUI=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?")
    "$OWUI_VENV/bin/pip" install --upgrade open-webui --quiet \
        && NEW_OWUI=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?") \
        && info "Open WebUI: $OLD_OWUI → $NEW_OWUI" \
        || warn "Open WebUI upgrade failed."
else
    "$OWUI_VENV/bin/pip" install open-webui \
        || warn "Open WebUI install failed — check output above."
    NEW_OWUI=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?")
    info "Open WebUI $NEW_OWUI installed."
fi

# ── Open WebUI launcher script ────────────────────────────────────────────────
# Using a non-quoted heredoc delimiter so $_OWUI_HOST expands at write time,
# but \$VAR and \$(...) inside the script stay literal.
OWUI_DATA_DIR="$GUI_DIR/open-webui-data"
mkdir -p "$OWUI_DATA_DIR"

cat > "$BIN_DIR/llm-webui" <<OWUI_LAUNCHER
#!/usr/bin/env bash
# llm-webui — Open WebUI (primary chat interface)
# Starts Ollama if needed, then serves Open WebUI on http://localhost:8080
set -uo pipefail

OWUI_VENV="\$HOME/.local/share/open-webui-venv"
OWUI_DATA="\$HOME/.local/share/llm-webui/open-webui-data"
BIN_DIR="\$HOME/.local/bin"

if [[ ! -x "\$OWUI_VENV/bin/open-webui" ]]; then
    echo ""
    echo "  ERROR: Open WebUI not installed."
    echo "  Re-run setup: llm-setup"
    echo ""
    exit 1
fi

# ── Ollama ────────────────────────────────────────────────────────────────────
_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
if ! _ollama_up; then
    echo "→ Starting Ollama…"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        [[ -x "\$BIN_DIR/ollama-start" ]] && "\$BIN_DIR/ollama-start" \
            || nohup ollama serve >/dev/null 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >/dev/null 2>&1 &
    fi
    for _i in {1..20}; do _ollama_up && break; sleep 1; done
    _ollama_up || echo "  WARNING: Ollama not responding yet — WebUI may show 'no models'."
fi

# ── Kill any stale server already on port 8080 ────────────────────────────────
_stale=\$(ss -lptn 'sport = :8080' 2>/dev/null \
    | awk 'NR>1{match(\$NF,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1 || true)
[[ -z "\$_stale" ]] && _stale=\$(fuser 8080/tcp 2>/dev/null || true)
[[ -n "\$_stale" ]] && { kill "\$_stale" 2>/dev/null; sleep 1; }

mkdir -p "\$OWUI_DATA"

# ── Environment ───────────────────────────────────────────────────────────────
# Ollama connection
export OLLAMA_BASE_URL="http://127.0.0.1:11434"
export OLLAMA_API_BASE_URL="http://127.0.0.1:11434"
export ENABLE_OLLAMA_API="true"

# Auth: disabled for local single-user use
export WEBUI_AUTH="false"
export ENABLE_LOGIN_FORM="false"
export ENABLE_SIGNUP="false"
export DEFAULT_USER_ROLE="admin"
export CORS_ALLOW_ORIGIN="*"

# Timeouts: 15 min — needed for large models on slow GPUs
export AIOHTTP_CLIENT_TIMEOUT=900
export AIOHTTP_CLIENT_TIMEOUT_TOTAL=900
export OLLAMA_REQUEST_TIMEOUT=900
export OLLAMA_CLIENT_TIMEOUT=900

# Data + misc
export DATA_DIR="\$OWUI_DATA"
export PYTHONWARNINGS="ignore::RuntimeWarning"

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║        🌐  OPEN WEBUI  —  LOCAL LLM         ║"
echo "  ║  URL:  http://localhost:8080                 ║"
echo "  ║  Press Ctrl+C to stop                       ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

exec "\$OWUI_VENV/bin/open-webui" serve --host $_OWUI_HOST --port 8080
OWUI_LAUNCHER
chmod +x "$BIN_DIR/llm-webui"
info "Open WebUI launcher: $BIN_DIR/llm-webui  →  http://localhost:8080"

# ── Neural Terminal (standalone HTML, zero pip deps) ──────────────────────────
# Always write — serves as backup when Open WebUI is unreachable
HTML_UI="$GUI_DIR/llm-chat.html"
python3 - <<'PYEOF_HTML'
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
:root{
  --bg:#0a0e1a;--bg2:#0f1525;--bg3:#141b2d;--border:#1e2d4a;
  --accent:#00d4ff;--accent2:#00ff88;--accent3:#7b2fff;
  --text:#c8d8f0;--text2:#7a9cc0;--user-bg:#0d1f35;
  --ai-bg:#081520;--code-bg:#050c18;
  --danger:#ff4466;--warn:#ffaa00;
}
*{margin:0;padding:0;box-sizing:border-box;}
html,body{height:100%;font-family:'JetBrains Mono',monospace;background:var(--bg);color:var(--text);overflow:hidden;}
/* ── Layout ─────────────────────────────────────── */
#app{display:flex;height:100vh;}
#sidebar{width:260px;min-width:200px;background:var(--bg2);border-right:1px solid var(--border);display:flex;flex-direction:column;transition:width .2s;}
#sidebar.collapsed{width:48px;min-width:48px;}
#main{flex:1;display:flex;flex-direction:column;overflow:hidden;}
/* ── Sidebar ────────────────────────────────────── */
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
/* ── Top bar ─────────────────────────────────────── */
#topbar{padding:10px 16px;border-bottom:1px solid var(--border);background:var(--bg2);display:flex;align-items:center;gap:10px;}
#model-select{flex:1;background:var(--bg3);border:1px solid var(--border);color:var(--text);padding:6px 10px;border-radius:6px;font-family:'JetBrains Mono',monospace;font-size:12px;cursor:pointer;}
#model-select:focus{outline:1px solid var(--accent);}
#status-dot{width:8px;height:8px;border-radius:50%;background:var(--danger);flex-shrink:0;}
#status-dot.online{background:var(--accent2);}
#status-text{font-size:11px;color:var(--text2);white-space:nowrap;}
#export-btn{background:none;border:1px solid var(--border);color:var(--text2);padding:5px 10px;border-radius:6px;font-size:11px;cursor:pointer;white-space:nowrap;}
#export-btn:hover{border-color:var(--accent);color:var(--accent);}
/* ── Messages ─────────────────────────────────────── */
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
/* ── Empty state ─────────────────────────────────── */
#empty-state{text-align:center;margin:auto;padding:40px 20px;}
.empty-logo{font-family:'Orbitron',monospace;font-size:36px;font-weight:900;background:linear-gradient(135deg,var(--accent),var(--accent2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;letter-spacing:6px;}
.empty-sub{color:var(--text2);font-size:12px;margin:8px 0 30px;letter-spacing:2px;}
.suggestion-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;max-width:520px;margin:0 auto;}
.suggestion{background:var(--bg3);border:1px solid var(--border);border-radius:8px;padding:12px 14px;font-size:11px;color:var(--text2);cursor:pointer;text-align:left;transition:all .15s;}
.suggestion:hover{border-color:var(--accent);color:var(--text);background:var(--bg2);}
/* ── Input ───────────────────────────────────────── */
#input-area{padding:14px 16px;border-top:1px solid var(--border);background:var(--bg2);}
#input-row{display:flex;gap:10px;align-items:flex-end;}
#prompt{flex:1;background:var(--bg3);border:1px solid var(--border);color:var(--text);padding:10px 14px;border-radius:8px;font-family:'JetBrains Mono',monospace;font-size:13px;resize:none;min-height:44px;max-height:160px;line-height:1.5;}
#prompt:focus{outline:1px solid var(--accent);}
#prompt::placeholder{color:var(--text2);}
#send-btn{background:linear-gradient(135deg,var(--accent3),var(--accent));border:none;color:#fff;width:44px;height:44px;border-radius:8px;cursor:pointer;font-size:18px;flex-shrink:0;display:flex;align-items:center;justify-content:center;}
#send-btn:disabled{opacity:.4;cursor:not-allowed;}
#send-btn:not(:disabled):hover{opacity:.85;}
#input-hint{font-size:10px;color:var(--text2);margin-top:6px;text-align:center;}
/* ── Thinking spinner ────────────────────────────── */
.typing-indicator{display:flex;gap:5px;align-items:center;padding:8px 0;}
.typing-indicator span{width:7px;height:7px;border-radius:50%;background:var(--accent2);animation:bounce .9s infinite;}
.typing-indicator span:nth-child(2){animation-delay:.15s;}
.typing-indicator span:nth-child(3){animation-delay:.3s;}
@keyframes bounce{0%,60%,100%{transform:translateY(0);}30%{transform:translateY(-6px);}}
/* ── System prompt ───────────────────────────────── */
#sys-row{display:flex;gap:8px;margin-bottom:8px;align-items:center;}
#sys-toggle{background:none;border:1px solid var(--border);color:var(--text2);padding:4px 10px;border-radius:5px;font-size:10px;cursor:pointer;}
#sys-toggle:hover{border-color:var(--accent3);color:var(--accent3);}
#sys-prompt{display:none;width:100%;background:var(--bg3);border:1px solid var(--accent3)44;color:var(--text2);padding:8px 12px;border-radius:6px;font-family:'JetBrains Mono',monospace;font-size:11px;resize:vertical;min-height:56px;margin-bottom:8px;}
#sys-prompt.open{display:block;}
/* ── Scrollbar ───────────────────────────────────── */
select option{background:var(--bg3);}
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
      <div id="sys-row">
        <button id="sys-toggle">⚙ system prompt</button>
      </div>
      <textarea id="sys-prompt" placeholder="System prompt (optional)…"></textarea>
      <div id="input-row">
        <textarea id="prompt" rows="1" placeholder='Message the AI… (Shift+Enter for newline, /think prefix for reasoning)'></textarea>
        <button id="send-btn">▶</button>
      </div>
      <div id="input-hint">Shift+Enter = newline · Enter = send · /think = reasoning mode</div>
    </div>
  </div>
</div>
<script>
// ── State ──────────────────────────────────────────────────────────────────
const API = 'http://localhost:11434';
let sessions = JSON.parse(localStorage.getItem('nt_sessions') || '[]');
let activeId  = localStorage.getItem('nt_active') || null;
let isStreaming = false;

function save() {
  localStorage.setItem('nt_sessions', JSON.stringify(sessions));
  localStorage.setItem('nt_active', activeId || '');
}

function newSession() {
  const id = 'sess_' + Date.now();
  sessions.unshift({ id, name: 'New chat', history: [] });
  activeId = id;
  save();
  renderSidebar();
  renderMessages();
}

function getActive() {
  return sessions.find(s => s.id === activeId) || sessions[0];
}

if (!sessions.length) newSession();
if (!activeId || !sessions.find(s => s.id === activeId)) activeId = sessions[0].id;

// ── Status + models ────────────────────────────────────────────────────────
const dot  = document.getElementById('status-dot');
const stxt = document.getElementById('status-text');
const sel  = document.getElementById('model-select');

async function checkOllama() {
  try {
    const r = await fetch(`${API}/api/tags`, { signal: AbortSignal.timeout(3000) });
    if (!r.ok) throw new Error();
    const d = await r.json();
    dot.className = 'online'; stxt.textContent = 'Ollama online';
    const models = (d.models || []).map(m => m.name);
    const prev = sel.value;
    sel.innerHTML = models.length
      ? models.map(m => `<option value="${m}">${m}</option>`).join('')
      : '<option value="">No models — run: ollama pull qwen3:8b</option>';
    if (prev && models.includes(prev)) sel.value = prev;
    else if (models.length) {
      const saved = localStorage.getItem('nt_model');
      sel.value = (saved && models.includes(saved)) ? saved : models[0];
    }
  } catch {
    dot.className = ''; stxt.textContent = 'Ollama offline';
    sel.innerHTML = '<option value="">Ollama offline — run: ollama-start</option>';
  }
}
sel.addEventListener('change', () => localStorage.setItem('nt_model', sel.value));
checkOllama();
setInterval(checkOllama, 8000);

// ── Markdown / code rendering ──────────────────────────────────────────────
function renderMarkdown(text) {
  // thinking blocks: <think>…</think>
  text = text.replace(/<think>([\s\S]*?)<\/think>/gi, (_, t) =>
    `<details class="thinking-block"><summary>💭 Reasoning</summary><pre style="white-space:pre-wrap;margin:8px 0 0">${escHtml(t.trim())}</pre></details>`);
  // fenced code blocks
  text = text.replace(/```(\w*)\n?([\s\S]*?)```/g, (_, lang, code) => {
    const escaped = escHtml(code.trim());
    const highlighted = lang
      ? (() => { try { return hljs.highlight(escaped, {language: lang, ignoreIllegals:true}).value; } catch { return escaped; } })()
      : hljs.highlightAuto(escaped).value;
    return `<pre><code class="hljs">${highlighted}</code></pre>`;
  });
  // inline code
  text = text.replace(/`([^`\n]+)`/g, '<code>$1</code>');
  // bold / italic
  text = text.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  text = text.replace(/\*([^*]+)\*/g,   '<em>$1</em>');
  // headings
  text = text.replace(/^### (.+)$/gm, '<h3 style="color:var(--accent);margin:10px 0 4px">$1</h3>');
  text = text.replace(/^## (.+)$/gm,  '<h2 style="color:var(--accent);margin:12px 0 4px">$1</h2>');
  text = text.replace(/^# (.+)$/gm,   '<h1 style="color:var(--accent);margin:14px 0 6px">$1</h1>');
  // lists
  text = text.replace(/^\* (.+)$/gm, '<li style="margin-left:18px">$1</li>');
  text = text.replace(/^- (.+)$/gm,  '<li style="margin-left:18px">$1</li>');
  // line breaks (double newline = paragraph)
  text = text.replace(/\n\n/g, '</p><p style="margin:8px 0">');
  text = text.replace(/\n/g, '<br>');
  return text;
}

function escHtml(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ── Append message to DOM ──────────────────────────────────────────────────
function appendMsg(role, content, stream = false) {
  const msgs = document.getElementById('messages');
  if (stream) {
    let el = document.getElementById('streaming-msg');
    if (!el) {
      el = makeMsgEl(role, '');
      el.id = 'streaming-msg';
      msgs.appendChild(el);
    }
    el.querySelector('.bubble').innerHTML = renderMarkdown(content);
    msgs.scrollTop = msgs.scrollHeight;
    return el;
  }
  const el = makeMsgEl(role, content);
  msgs.appendChild(el);
  msgs.scrollTop = msgs.scrollHeight;
  return el;
}

function makeMsgEl(role, content) {
  const div = document.createElement('div');
  div.className = `msg ${role}`;
  const avatar = role === 'user' ? '👤' : '🤖';
  div.innerHTML = `<div class="avatar">${avatar}</div><div class="bubble">${renderMarkdown(content)}</div>`;
  return div;
}

// ── Sidebar ────────────────────────────────────────────────────────────────
function renderSidebar() {
  const list = document.getElementById('sessions-list');
  list.innerHTML = sessions.map(s =>
    `<div class="session-item ${s.id === activeId ? 'active' : ''}" data-id="${s.id}">${s.name}</div>`
  ).join('');
  list.querySelectorAll('.session-item').forEach(el => {
    el.addEventListener('click', () => {
      activeId = el.dataset.id; save(); renderSidebar(); renderMessages();
    });
  });
}

document.getElementById('toggle-sidebar').addEventListener('click', () => {
  document.getElementById('sidebar').classList.toggle('collapsed');
});
document.getElementById('new-chat-btn').addEventListener('click', newSession);
document.getElementById('sys-toggle').addEventListener('click', () => {
  document.getElementById('sys-prompt').classList.toggle('open');
});

// ── Render messages ────────────────────────────────────────────────────────
function renderMessages() {
  const msgs = document.getElementById('messages');
  const sess = getActive();
  if (!sess || !sess.history.filter(m => m.role !== 'system').length) {
    msgs.innerHTML = `<div id="empty-state">
      <div class="empty-logo">N T</div>
      <div class="empty-sub">Neural Terminal · Local LLM</div>
      <div class="suggestion-grid">
        <div class="suggestion" onclick="useSuggestion(this)">Explain how neural networks learn</div>
        <div class="suggestion" onclick="useSuggestion(this)">Write a Python script to rename files</div>
        <div class="suggestion" onclick="useSuggestion(this)">/think What is the best sorting algorithm?</div>
        <div class="suggestion" onclick="useSuggestion(this)">Summarise the key ideas in this text:</div>
      </div>
    </div>`;
    return;
  }
  msgs.innerHTML = '';
  sess.history.forEach(m => {
    if (m.role === 'system') return;
    appendMsg(m.role, m.content, false);
  });
}

function useSuggestion(el) {
  document.getElementById('prompt').value = el.textContent;
  sendMessage();
}

// ── Send ───────────────────────────────────────────────────────────────────
const promptEl = document.getElementById('prompt');
const sendBtn  = document.getElementById('send-btn');

promptEl.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});
promptEl.addEventListener('input', () => {
  promptEl.style.height = 'auto';
  promptEl.style.height = Math.min(promptEl.scrollHeight, 160) + 'px';
});
sendBtn.addEventListener('click', sendMessage);

async function sendMessage() {
  const text = promptEl.value.trim();
  if (!text || isStreaming) return;
  const model = sel.value;
  if (!model) { alert('No model selected. Start Ollama: ollama-start'); return; }

  const sess = getActive();
  // Remove empty-state if present
  const es = document.getElementById('empty-state');
  if (es) es.remove();

  // Build messages array — include system prompt if set
  const sysText = document.getElementById('sys-prompt').value.trim();
  if (sysText && !sess.history.find(m => m.role === 'system')) {
    sess.history.unshift({ role: 'system', content: sysText });
  }

  // Handle /think prefix — wrap in <think> tags for Qwen3 et al.
  let userContent = text;
  let thinkMode = false;
  if (text.startsWith('/think ')) {
    userContent = text.slice(7);
    thinkMode = true;
  }

  sess.history.push({ role: 'user', content: userContent });
  if (sess.name === 'New chat') {
    sess.name = userContent.slice(0, 36) + (userContent.length > 36 ? '…' : '');
  }
  save();
  renderSidebar();
  appendMsg('user', userContent);
  promptEl.value = ''; promptEl.style.height = 'auto';

  // Typing indicator
  const msgs = document.getElementById('messages');
  const typingEl = document.createElement('div');
  typingEl.className = 'msg assistant';
  typingEl.id = 'typing-indicator';
  typingEl.innerHTML = '<div class="avatar">🤖</div><div class="bubble"><div class="typing-indicator"><span></span><span></span><span></span></div></div>';
  msgs.appendChild(typingEl);
  msgs.scrollTop = msgs.scrollHeight;

  isStreaming = true;
  sendBtn.disabled = true;

  try {
    // Build API messages — add /think instruction if needed
    const apiMessages = [...sess.history];
    if (thinkMode) {
      apiMessages[apiMessages.length - 1] = {
        role: 'user',
        content: '/think ' + userContent
      };
    }

    const resp = await fetch(`${API}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        messages: apiMessages,
        stream: true,
        options: { temperature: 0.7, top_p: 0.95 }
      })
    });

    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

    // Remove typing indicator and start streaming
    typingEl.remove();
    let full = '';
    const reader = resp.body.getReader();
    const dec    = new TextDecoder();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      for (const line of dec.decode(value).split('\n')) {
        if (!line.trim()) continue;
        try {
          const chunk = JSON.parse(line);
          if (chunk.message?.content) {
            full += chunk.message.content;
            appendMsg('assistant', full, true);
          }
          if (chunk.done) break;
        } catch { /* partial JSON — ignore */ }
      }
    }

    // Finalise
    const streamEl = document.getElementById('streaming-msg');
    if (streamEl) streamEl.removeAttribute('id');
    sess.history.push({ role: 'assistant', content: full });
    save();

  } catch (err) {
    typingEl.remove();
    appendMsg('assistant', `⚠ Error: ${err.message}\n\nIs Ollama running? Try: ollama-start`);
  } finally {
    isStreaming = false;
    sendBtn.disabled = false;
    promptEl.focus();
  }
}

// ── Export conversation ────────────────────────────────────────────────────
document.getElementById('export-btn').addEventListener('click', () => {
  const sess = getActive();
  const msgs = sess.history.filter(m => m.role !== 'system');
  if (!msgs.length) { alert('Nothing to export yet.'); return; }
  const model = sel.value || 'unknown';
  let md = `# ${sess.name}\n\n**Model:** ${model}  \n**Exported:** ${new Date().toLocaleString()}\n\n---\n\n`;
  msgs.forEach(m => {
    const label = m.role === 'user' ? '## 👤 User' : '## 🤖 Assistant';
    md += `${label}\n\n${m.content}\n\n---\n\n`;
  });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([md], {type:'text/markdown'}));
  a.download = (sess.name.replace(/[^a-z0-9]/gi,'_').toLowerCase() || 'chat') + '.md';
  a.click();
  URL.revokeObjectURL(a.href);
});

// ── Init ───────────────────────────────────────────────────────────────────
renderSidebar();
renderMessages();
promptEl.focus();
</script>
</body>
</html>
"""
path = os.path.expanduser('$HOME/.local/share/llm-webui/llm-chat.html')
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'w') as f:
    f.write(html)
print(f"Neural Terminal written: {path}")
PYEOF_HTML

# ── llm-chat launcher ─────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-chat" <<'HTMLLAUNCHER'
#!/usr/bin/env bash
# llm-chat — Neural Terminal (lightweight fallback HTML chat UI)
set -euo pipefail

GUI_DIR="$HOME/.local/share/llm-webui"
HTML_FILE="$GUI_DIR/llm-chat.html"
HTTP_PORT=8090
BIN_DIR="$HOME/.local/bin"

[[ ! -f "$HTML_FILE" ]] && { echo "ERROR: HTML UI not found. Re-run: llm-setup"; exit 1; }

_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
if ! _ollama_up; then
    echo "→ Starting Ollama…"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        [[ -x "$BIN_DIR/ollama-start" ]] && "$BIN_DIR/ollama-start" \
            || nohup ollama serve >/dev/null 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null || nohup ollama serve >/dev/null 2>&1 &
    fi
    for _i in {1..12}; do
        _ollama_up && break; sleep 1
        (( _i == 12 )) && echo "  WARNING: Ollama didn't respond in 12s."
    done
fi

# Kill stale server on our port
OLD_PID=$(lsof -ti tcp:$HTTP_PORT 2>/dev/null || true)
[[ -n "$OLD_PID" ]] && { kill "$OLD_PID" 2>/dev/null || true; sleep 0.5; }

echo "→ Starting Neural Terminal on http://localhost:$HTTP_PORT …"
python3 -m http.server "$HTTP_PORT" \
    --directory "$GUI_DIR" \
    --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP_PID=$!
sleep 0.8

if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "ERROR: HTTP server failed. Port $HTTP_PORT in use? lsof -i :$HTTP_PORT"; exit 1
fi

URL="http://localhost:$HTTP_PORT/llm-chat.html"
echo "→ $URL  (Press Ctrl+C to stop)"

if grep -qi microsoft /proc/version 2>/dev/null; then
    cmd.exe /c start "" "$URL" 2>/dev/null \
        || powershell.exe -Command "Start-Process '$URL'" 2>/dev/null \
        || echo "  Open manually: $URL"
else
    xdg-open "$URL" 2>/dev/null || echo "  Open manually: $URL"
fi

trap "echo ''; echo 'Stopping…'; kill $HTTP_PID 2>/dev/null; exit 0" INT TERM
wait "$HTTP_PID"
HTMLLAUNCHER
chmod +x "$BIN_DIR/llm-chat"
info "Neural Terminal: llm-chat  →  http://localhost:8090"

# =============================================================================
# STEP 14 — OPTIONAL TOOLS
# Open WebUI is already the primary UI (installed above).
# Options here: system utilities + AI coding agents.
# =============================================================================
step "Optional tools"

HAVE_DISPLAY=0
{ [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; } && HAVE_DISPLAY=1
is_wsl2 && HAVE_DISPLAY=1

echo ""
echo -e "  ${CYAN}Which tools would you like? Enter numbers (space-separated), 'all', or Enter to skip.${NC}"
echo ""
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "1" "tmux"         "terminal multiplexer — split panes, detach sessions"
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "2" "CLI tools"    "bat, eza, fzf, ripgrep, btop, ncdu, jq, micro"
if (( HAS_GPU )); then
    printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "3" "nvtop"    "live GPU monitor — VRAM usage during inference"
else
    printf "    ${GREEN}%-4s${NC} %-20s %s\n" "3" "nvtop"     "(no GPU — will skip)"
fi
if (( HAVE_DISPLAY )); then
    printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "4" "GUI tools" "Thunar file manager, Mousepad editor, Meld diff"
else
    printf "    ${GREEN}%-4s${NC} %-20s %s\n" "4" "GUI tools"  "(no display — will skip)"
fi
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "5" "neofetch"     "system info banner + fastfetch"
echo ""
echo -e "  ${CYAN}── AI coding agents ──────────────────────────────────────────────${NC}"
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "6" "Claude Code"  "Anthropic CLI agent — codes, edits, runs commands"
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "7" "OpenAI Codex" "OpenAI CLI coding agent — needs Node 22"
echo ""
if [[ -t 0 ]]; then
    read -r -p "  > " _tool_sel
else
    _tool_sel=""
fi
[[ "${_tool_sel:-}" == "all" ]] && _tool_sel="1 2 3 4 5 6 7"

# ── 1: tmux ───────────────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"1"* ]]; then
    sudo apt-get install -y tmux || warn "tmux install failed."
    if [[ ! -f "$HOME/.tmux.conf" ]]; then
        cat > "$HOME/.tmux.conf" <<'TMUXCFG'
# ── Local LLM tmux config ─────────────────────────────────────────────────
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
# ─────────────────────────────────────────────────────────────────────────
TMUXCFG
        info "tmux config written."
    fi
    info "tmux installed."
fi

# ── 2: CLI tools ──────────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"2"* ]]; then
    CLI_PKGS=(bat fzf ripgrep fd-find btop htop ncdu jq tree p7zip-full unzip zip)
    sudo apt-get install -y "${CLI_PKGS[@]}" || warn "Some CLI tools failed — continuing."

    if ! command -v micro &>/dev/null; then
        info "Installing micro editor…"
        mkdir -p "$BIN_DIR"
        if curl -fsSL https://getmic.ro | bash 2>/dev/null; then
            mv micro "$BIN_DIR/micro" 2>/dev/null \
                || sudo mv micro /usr/local/bin/micro 2>/dev/null || true
            info "micro installed."
        else
            warn "micro install failed — try: sudo apt-get install micro"
        fi
    fi

    if ! command -v eza &>/dev/null; then
        sudo apt-get install -y eza 2>/dev/null \
            || sudo apt-get install -y exa 2>/dev/null \
            || warn "eza/exa not in apt — skipping."
    fi

    if ! grep -q "# llm-qol-aliases" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" <<'QOLALIASES'

# ── QoL tool aliases (llm-auto-setup) ─────────────────────────────────────
command -v bat    &>/dev/null && alias cat='bat --paging=never'
command -v eza    &>/dev/null && alias ls='eza --icons' && alias ll='eza -la --icons'
command -v btop   &>/dev/null && alias top='btop'
command -v fdfind &>/dev/null && ! command -v fd &>/dev/null && alias fd='fdfind'
# llm-qol-aliases
QOLALIASES
    fi
    info "CLI tools installed."
fi

# ── 3: nvtop ──────────────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"3"* ]]; then
    if (( HAS_GPU )); then
        sudo apt-get install -y nvtop \
            || warn "nvtop not in apt — try: sudo snap install nvtop"
        info "nvtop installed."
    else
        info "nvtop skipped — no GPU detected."
    fi
fi

# ── 4: GUI tools ──────────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"4"* ]]; then
    if (( HAVE_DISPLAY )); then
        sudo apt-get install -y thunar mousepad meld gcolor3 \
            || warn "Some GUI packages failed."
        info "GUI tools installed: thunar, mousepad, meld"
    else
        info "GUI tools skipped — no display detected."
    fi
fi

# ── 5: neofetch ───────────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"5"* ]]; then
    sudo apt-get install -y neofetch 2>/dev/null || true
    command -v fastfetch &>/dev/null \
        || sudo apt-get install -y fastfetch 2>/dev/null \
        || warn "fastfetch not in apt — try: sudo snap install fastfetch"
    info "neofetch + fastfetch installed."
fi

# ── 6: Claude Code ────────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"6"* ]]; then
    step "Claude Code (Anthropic CLI coding agent)"
    _node_ok=0
    if command -v node &>/dev/null; then
        _nver=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
        (( _nver >= 18 )) && _node_ok=1
    fi
    if [[ $_node_ok -eq 0 ]]; then
        info "Installing Node.js 20 LTS…"
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - \
            && sudo apt-get install -y nodejs \
            && _node_ok=1 \
            || warn "Node.js install failed — Claude Code requires Node >= 18."
    fi
    if [[ $_node_ok -eq 1 ]]; then
        sudo npm install -g @anthropic-ai/claude-code \
            && info "Claude Code installed." \
            || warn "Claude Code install failed."
        cat > "$BIN_DIR/claude-code" <<'CC_EOF'
#!/usr/bin/env bash
# claude-code — Claude Code wrapper (sets work dir and checks API key)
WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  ANTHROPIC_API_KEY not set.                         ║"
    echo "  ║  Get a key: https://console.anthropic.com/          ║"
    echo "  ║  Then run:  export ANTHROPIC_API_KEY=sk-ant-...     ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo ""
    read -r -p "  Enter key now (or Enter to exit): " _key
    [[ -z "$_key" ]] && exit 1
    export ANTHROPIC_API_KEY="$_key"
fi
echo "  Working dir: $PWD"
exec claude "$@"
CC_EOF
        chmod +x "$BIN_DIR/claude-code"
        grep -q "claude-code" "$ALIAS_FILE" 2>/dev/null \
            || echo "alias claude-code='$BIN_DIR/claude-code'" >> "$ALIAS_FILE"
        info "Claude Code → run: claude  (or: claude-code)"
        info "  API key: export ANTHROPIC_API_KEY=sk-ant-..."
    else
        warn "Claude Code skipped — Node.js >= 18 required."
    fi
fi

# ── 7: OpenAI Codex ───────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"7"* ]]; then
    step "OpenAI Codex CLI coding agent"
    _node_ok=0
    if command -v node &>/dev/null; then
        _nver=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
        (( _nver >= 22 )) && _node_ok=1
    fi
    if [[ $_node_ok -eq 0 ]]; then
        info "Installing Node.js 22 LTS (required for Codex)…"
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - \
            && sudo apt-get install -y nodejs \
            && _node_ok=1 \
            || warn "Node.js install failed — OpenAI Codex requires Node >= 22."
    fi
    if [[ $_node_ok -eq 1 ]]; then
        sudo npm install -g @openai/codex \
            && info "OpenAI Codex installed." \
            || warn "OpenAI Codex install failed."
        cat > "$BIN_DIR/codex-agent" <<'CODEX_EOF'
#!/usr/bin/env bash
# codex-agent — OpenAI Codex wrapper
WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  OPENAI_API_KEY not set.                            ║"
    echo "  ║  Get a key: https://platform.openai.com/api-keys   ║"
    echo "  ║  Then run:  export OPENAI_API_KEY=sk-...           ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo ""
    read -r -p "  Enter key now (or Enter to exit): " _key
    [[ -z "$_key" ]] && exit 1
    export OPENAI_API_KEY="$_key"
fi
echo "  Working dir: $PWD"
exec codex "$@"
CODEX_EOF
        chmod +x "$BIN_DIR/codex-agent"
        grep -q "codex-agent" "$ALIAS_FILE" 2>/dev/null \
            || echo "alias codex-agent='$BIN_DIR/codex-agent'" >> "$ALIAS_FILE"
        info "OpenAI Codex → run: codex-agent"
        info "  API key: export OPENAI_API_KEY=sk-..."
    else
        warn "OpenAI Codex skipped — Node.js >= 22 required."
    fi
fi

[[ -n "${_tool_sel:-}" ]] \
    && info "Optional tools step complete." \
    || info "Optional tools: skipped."

# =============================================================================
# STEP 15 — AUTONOMOUS COWORKING  (Open Interpreter + Aider)
# Always installed — core part of the local LLM workflow.
# =============================================================================
step "Autonomous coworking tools"

OI_VENV="$HOME/.local/share/open-interpreter-venv"
AI_VENV="$HOME/.local/share/aider-venv"

# ── Open Interpreter ──────────────────────────────────────────────────────────
info "Installing Open Interpreter…"

# Python 3.12+ venvs do NOT include pkg_resources by default (it lives in
# setuptools, which is no longer bundled with the stdlib). We must:
#   1. Always rebuild the venv from scratch (stale state causes repeated failures)
#   2. Install setuptools BEFORE open-interpreter so pkg_resources is importable
#   3. Use --no-cache-dir to skip any broken cached wheels
if [[ -d "$OI_VENV" ]]; then
    warn "Removing stale Open Interpreter venv (ensures clean setuptools install)…"
    rm -rf "$OI_VENV"
fi
"${PYTHON_BIN:-python3}" -m venv "$OI_VENV" \
    || error "Failed to create Open Interpreter venv at $OI_VENV"

# Step 1: pip + setuptools  (pkg_resources is a setuptools component)
"$OI_VENV/bin/pip" install --upgrade --no-cache-dir pip --quiet
"$OI_VENV/bin/pip" install --no-cache-dir "setuptools>=70" wheel --quiet \
    || warn "setuptools install failed — will retry."

# Verify pkg_resources is importable BEFORE installing open-interpreter
if ! "$OI_VENV/bin/python3" -c "import pkg_resources" 2>/dev/null; then
    warn "pkg_resources not found after setuptools install — force-reinstalling…"
    "$OI_VENV/bin/pip" install --force-reinstall --no-cache-dir "setuptools>=70" --quiet
fi

# Final check — bail with a clear message if still broken
if ! "$OI_VENV/bin/python3" -c "import pkg_resources" 2>/dev/null; then
    warn "pkg_resources still unavailable. Open Interpreter may not start correctly."
fi

# Step 2: install open-interpreter (no cache to avoid stale wheels)
"$OI_VENV/bin/pip" install --no-cache-dir open-interpreter \
    || warn "Open Interpreter install failed — check output above."

# Health check
if "$OI_VENV/bin/python3" -c "import pkg_resources; import interpreter" 2>/dev/null; then
    info "Open Interpreter ✔ (pkg_resources OK)"
else
    warn "Open Interpreter health check failed. Run 'cowork' to test; re-run setup if broken."
fi

# ── cowork launcher ───────────────────────────────────────────────────────────
cat > "$BIN_DIR/cowork" <<'COWORK_EOF'
#!/usr/bin/env bash
# cowork — autonomous AI coworker via Open Interpreter + local Ollama
set -uo pipefail

WORK_DIR="$HOME/work"
OI_VENV="$HOME/.local/share/open-interpreter-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"

[[ ! -x "$OI_VENV/bin/interpreter" ]] && {
    echo "ERROR: Open Interpreter not installed. Re-run: llm-setup"
    exit 1
}

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Read OLLAMA_TAG from config without sourcing (avoids env pollution)
OLLAMA_TAG=""
[[ -f "$CONFIG" ]] && OLLAMA_TAG=$(grep "^OLLAMA_TAG=" "$CONFIG" | head -1 | cut -d'"' -f2)
OLLAMA_TAG="${OLLAMA_TAG:-qwen_qwen3-8b:q4_k_m}"

# WSL2-aware Ollama check
_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }

STARTED_OLLAMA=0
if ! _ollama_up; then
    echo "→ Starting Ollama…"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        command -v ollama-start &>/dev/null && ollama-start \
            || nohup ollama serve >/dev/null 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >/dev/null 2>&1 &
    fi
    STARTED_OLLAMA=1
    for _i in {1..15}; do _ollama_up && break; sleep 1; done
fi

_cowork_cleanup() {
    if [[ ${STARTED_OLLAMA:-0} -eq 1 ]]; then
        echo ""; echo "Stopping Ollama (started by cowork)…"
        pkill -f "ollama serve" 2>/dev/null || true
    fi
}
trap '_cowork_cleanup' INT TERM EXIT

echo ""
echo "  ╔════════════════════════════════════════════════════╗"
echo "  ║            🤖  AUTONOMOUS COWORKER                ║"
echo "  ║  Model  : $OLLAMA_TAG"
echo "  ║  Powered: Open Interpreter + Ollama (fully local) ║"
echo "  ║  Dir    : ~/work                                   ║"
echo "  ║  Type 'exit' or Ctrl-D to quit                    ║"
echo "  ╚════════════════════════════════════════════════════╝"
echo ""

# Open Interpreter talks to Ollama via its OpenAI-compatible /v1 endpoint
export OPENAI_API_KEY="ollama"
export OPENAI_API_BASE="http://127.0.0.1:11434/v1"

"$OI_VENV/bin/interpreter" \
    --model "openai/${OLLAMA_TAG}" \
    --context_window 8192 \
    --max_tokens 4096 \
    --api_base "http://127.0.0.1:11434/v1" \
    --api_key "ollama" \
    "$@"
COWORK_EOF
chmod +x "$BIN_DIR/cowork"
info "cowork launcher written."

# ── Aider ─────────────────────────────────────────────────────────────────────
info "Installing Aider…"
if [[ ! -d "$AI_VENV" ]]; then
    "${PYTHON_BIN:-python3}" -m venv "$AI_VENV"
fi
"$AI_VENV/bin/pip" install --upgrade pip --quiet || true
"$AI_VENV/bin/pip" install aider-chat \
    || warn "Aider install failed — check output above."

cat > "$BIN_DIR/aider" <<'AIDER_EOF'
#!/usr/bin/env bash
# aider — AI pair programmer with git integration, powered by local Ollama
set -uo pipefail

AI_VENV="$HOME/.local/share/aider-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"

[[ ! -x "$AI_VENV/bin/aider" ]] && {
    echo "ERROR: Aider not installed. Re-run: llm-setup"
    exit 1
}

OLLAMA_TAG=""
[[ -f "$CONFIG" ]] && OLLAMA_TAG=$(grep "^OLLAMA_TAG=" "$CONFIG" | head -1 | cut -d'"' -f2)
OLLAMA_TAG="${OLLAMA_TAG:-qwen_qwen3-8b:q4_k_m}"

_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }

STARTED_OLLAMA=0
if ! _ollama_up; then
    echo "→ Starting Ollama…"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        command -v ollama-start &>/dev/null && ollama-start \
            || nohup ollama serve >/dev/null 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >/dev/null 2>&1 &
    fi
    STARTED_OLLAMA=1
    sleep 3
fi

_aider_cleanup() {
    if [[ ${STARTED_OLLAMA:-0} -eq 1 ]]; then
        echo ""; echo "Stopping Ollama (started by aider)…"
        pkill -f "ollama serve" 2>/dev/null || true
    fi
}
trap '_aider_cleanup' INT TERM EXIT

echo ""
echo "  ╔════════════════════════════════════════════════════╗"
echo "  ║         🛠  AIDER  —  AI PAIR PROGRAMMER          ║"
echo "  ║  Model  : $OLLAMA_TAG"
echo "  ║  Usage  : aider file.py  (or no args for chat)    ║"
echo "  ║  Powered: Aider + Ollama (fully local)            ║"
echo "  ╚════════════════════════════════════════════════════╝"
echo ""

export OLLAMA_API_BASE="http://127.0.0.1:11434"

"$AI_VENV/bin/aider" \
    --model "ollama_chat/${OLLAMA_TAG}" \
    --no-auto-commits \
    --no-check-update \
    --no-show-model-warnings \
    --no-show-release-notes \
    --analytics-disable \
    --no-gitignore \
    --no-fancy-input \
    --stream \
    "$@"
AIDER_EOF
chmod +x "$BIN_DIR/aider"
info "aider launcher written."

info "Autonomous coworking tools ready."
info "  cowork — Open Interpreter (code execution, file ops, web browsing)"
info "  aider  — AI pair programmer (git-integrated, edits files directly)"

# =============================================================================
# STEP 16 — LLM-CHECKER
# =============================================================================
cat > "$BIN_DIR/llm-checker" <<'CHECKER_EOF'
#!/usr/bin/env bash
# llm-checker — live hardware + model ranking dashboard
set -uo pipefail

if [[ -t 1 ]]; then
    G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' M='\033[0;35m'
    R='\033[0;31m' W='\033[1;37m' N='\033[0m'
else
    G='' Y='' C='' M='' R='' W='' N=''
fi

VRAM=0; GPU_NAME="None"; HAS_GPU=0
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
    VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
           | head -1 | awk '{print int($1/1024)}' || echo 0)
    (( VRAM > 0 )) && HAS_GPU=1
elif command -v rocminfo &>/dev/null; then
    GPU_NAME=$(rocminfo 2>/dev/null \
        | awk '/Marketing Name/{$1=$2=""; print $0; exit}' | xargs || echo "AMD GPU")
    VRAM=$(rocminfo 2>/dev/null | grep -i "size:" | grep -v "0 bytes" \
        | awk '{print int($2/1024/1024/1024)}' | sort -rn | head -1 || echo 0)
    (( VRAM > 0 )) && HAS_GPU=1
fi
RAM_GB=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 0)
THREADS=$(nproc 2>/dev/null || echo 4)

CONFIG="$HOME/.config/local-llm/selected_model.conf"
ACTIVE_MODEL=""; ACTIVE_TAG=""
if [[ -f "$CONFIG" ]]; then
    ACTIVE_MODEL=$(grep "^MODEL_NAME=" "$CONFIG" | head -1 | cut -d'"' -f2 || true)
    ACTIVE_TAG=$(  grep "^OLLAMA_TAG="  "$CONFIG" | head -1 | cut -d'"' -f2 || true)
fi

echo ""
echo -e "${C}╔══════════════════════════════════════════════════════════════════╗${N}"
echo -e "${C}║         🔍  LLM CHECKER  —  System & Model Status              ║${N}"
echo -e "${C}╚══════════════════════════════════════════════════════════════════╝${N}"
echo ""

echo -e "${C}  ┌──────────────────────  HARDWARE  ───────────────────────────┐${N}"
printf "${C}  │${N}  %-14s %-46s${C}│${N}\n" "CPU threads" "$THREADS"
printf "${C}  │${N}  %-14s %-46s${C}│${N}\n" "RAM"         "${RAM_GB} GB"
if (( HAS_GPU )); then
    printf "${C}  │${N}  %-14s %-46s${C}│${N}\n" "GPU"     "$GPU_NAME"
    printf "${C}  │${N}  %-14s %-46s${C}│${N}\n" "VRAM"    "${VRAM} GB"
else
    printf "${C}  │${N}  %-14s %-46s${C}│${N}\n" "GPU"     "None (CPU-only mode)"
fi
echo -e "${C}  └──────────────────────────────────────────────────────────────┘${N}"
echo ""

echo -e "${C}  ┌──────────────────────  ACTIVE MODEL  ───────────────────────┐${N}"
if [[ -n "$ACTIVE_MODEL" ]]; then
    printf "${C}  │${N}  %-14s ${G}%-46s${C}│${N}\n" "Model"  "$ACTIVE_MODEL"
    [[ -n "$ACTIVE_TAG" ]] && \
    printf "${C}  │${N}  %-14s ${Y}%-46s${C}│${N}\n" "Ollama" "ollama run $ACTIVE_TAG"
else
    printf "${C}  │${N}  %-14s %-46s${C}│${N}\n" "Model"  "(not configured — run llm-setup)"
fi
echo -e "${C}  └──────────────────────────────────────────────────────────────┘${N}"
echo ""

echo -e "${C}  ┌──────────────────────  OLLAMA  ──────────────────────────────┐${N}"
if command -v ollama &>/dev/null; then
    OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
    printf "${C}  │${N}  %-14s ${G}%-46s${C}│${N}\n" "Version" "ollama $OLLAMA_VER"
    if curl -s --max-time 2 http://localhost:11434/api/tags &>/dev/null; then
        printf "${C}  │${N}  %-14s ${G}%-46s${C}│${N}\n" "Status" "running ✔"
        ollama list 2>/dev/null | tail -n +2 | while IFS= read -r line; do
            printf "${C}  │${N}   ${Y}%-60s${C}│${N}\n" "$line"
        done
    else
        printf "${C}  │${N}  %-14s ${R}%-46s${C}│${N}\n" "Status" "not running  (run: ollama-start)"
    fi
else
    printf "${C}  │${N}  %-14s ${R}%-46s${C}│${N}\n" "Ollama" "not installed  (run: llm-setup)"
fi
echo -e "${C}  └──────────────────────────────────────────────────────────────┘${N}"
echo ""

# Model recommendations based on live hardware
echo -e "${C}  ┌──────────────────────  RECOMMENDATIONS  ────────────────────┐${N}"
if   (( HAS_GPU && VRAM >= 24 )); then M_REC="Qwen3-32B Q4_K_M (24GB+)"
elif (( HAS_GPU && VRAM >= 16 )); then M_REC="Mistral-Small-3.2-24B Q4_K_M"
elif (( HAS_GPU && VRAM >= 12 )); then M_REC="Qwen3-14B Q4_K_M"
elif (( HAS_GPU && VRAM >= 8  )); then M_REC="Qwen3-8B Q6_K"
elif (( HAS_GPU && VRAM >= 6  )); then M_REC="Qwen3-8B Q4_K_M"
elif (( HAS_GPU && VRAM >= 4  )); then M_REC="Qwen3-4B Q4_K_M"
elif (( RAM_GB >= 32 ));           then M_REC="Qwen3-14B Q4_K_M (CPU)"
elif (( RAM_GB >= 16 ));           then M_REC="Qwen3-8B Q4_K_M (CPU)"
elif (( RAM_GB >= 8  ));           then M_REC="Qwen3-4B Q4_K_M (CPU)"
else                                    M_REC="Qwen3-1.7B Q8_0 (CPU)"
fi
printf "${C}  │${N}  %-14s ${G}%-46s${C}│${N}\n" "Best model" "$M_REC"
printf "${C}  │${N}  %-14s %-46s${C}│${N}\n"     "More models" "llm-add   (hardware-filtered catalog)"
echo -e "${C}  └──────────────────────────────────────────────────────────────┘${N}"
echo ""
CHECKER_EOF
chmod +x "$BIN_DIR/llm-checker"
info "llm-checker written."

# =============================================================================
# STEP 17 — LLM-HELP
# =============================================================================
cat > "$BIN_DIR/llm-help" <<'HELP_EOF'
#!/usr/bin/env bash
# llm-help — full command reference for the local LLM stack
_C='\033[0;36m'; _Y='\033[1;33m'; _G='\033[0;32m'; _M='\033[0;35m'; _N='\033[0m'

echo ""
echo -e "${_C}╔══════════════════════════════════════════════════════════════════════╗${_N}"
echo -e "${_C}║                 🤖  LOCAL LLM COMMAND REFERENCE                    ║${_N}"
echo -e "${_C}╚══════════════════════════════════════════════════════════════════════╝${_N}"
echo ""

echo -e "${_C}  ── Chat interfaces ────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}webui${_N}            Open WebUI → http://localhost:8080  (primary)"
echo -e "   ${_Y}chat${_N}             Neural Terminal → http://localhost:8090  (fallback)"
echo ""

echo -e "${_C}  ── Run a model from CLI ───────────────────────────────────────────${_N}"
echo -e "   ${_Y}run-model${_N}        Quick inference from terminal (uses active model)"
echo -e "   ${_Y}ask${_N}              Alias for run-model"
echo -e "   ${_Y}ollama-run${_N}       Run any Ollama model:  ollama-run <tag>"
echo -e "   ${_Y}gguf-run${_N}         Run a raw GGUF file:  gguf-run model.gguf"
echo ""

echo -e "${_C}  ── Autonomous coworking ───────────────────────────────────────────${_N}"
echo -e "   ${_Y}cowork${_N}           AI that writes & runs code, edits files, browses web"
echo -e "   ${_Y}ai${_N} / ${_Y}aider${_N}       AI pair programmer with git integration"
echo ""

echo -e "${_C}  ── Model management ───────────────────────────────────────────────${_N}"
echo -e "   ${_Y}llm-add${_N}          Download more models (hardware-filtered catalog)"
echo -e "   ${_Y}llm-switch${_N}       Change active model (no reinstall needed)"
echo -e "   ${_Y}llm-status${_N}       Show installed models + disk usage"
echo -e "   ${_Y}llm-checker${_N}      Hardware scan + model ranking dashboard"
echo -e "   ${_Y}gguf-list${_N}        List all downloaded GGUF files"
echo -e "   ${_Y}ollama-list${_N}      List all Ollama models (ollama list)"
echo ""

echo -e "${_C}  ── Service control ────────────────────────────────────────────────${_N}"
echo -e "   ${_Y}ollama-start${_N}     Start the Ollama backend"
echo -e "   ${_Y}llm-stop${_N}         Stop Ollama + WebUI"
echo -e "   ${_Y}llm-update${_N}       Upgrade Ollama + Open WebUI + re-pull model"
echo ""

echo -e "${_C}  ── Info & diagnostics ─────────────────────────────────────────────${_N}"
echo -e "   ${_Y}llm-show-config${_N}  Show all paths, model config, and service status"
echo -e "   ${_Y}llm-help${_N}         This help screen"
echo ""

echo -e "${_C}  ── AI coding agents ───────────────────────────────────────────────${_N}"
echo -e "   ${_Y}claude${_N}           Claude Code (Anthropic, cloud — needs API key)"
echo -e "   ${_Y}codex-agent${_N}      OpenAI Codex (cloud — needs API key)"
echo ""

echo -e "${_C}  ── WSL2 quickstart ────────────────────────────────────────────────${_N}"
echo -e "   Run ${_Y}ollama-start${_N} first, then ${_Y}webui${_N}"
echo -e "   Or just:  ${_Y}webui${_N}   (it starts Ollama automatically)"
echo ""
HELP_EOF
chmod +x "$BIN_DIR/llm-help"
info "llm-help written."

# =============================================================================
# STEP 18 — SELF-INSTALL + ALIASES
# =============================================================================
step "Aliases and self-install"

# ── Install script to canonical config path ───────────────────────────────────
mkdir -p "$CONFIG_DIR"
if [[ "$(realpath "$0" 2>/dev/null || echo "$0")" != "$(realpath "$SCRIPT_INSTALL_PATH" 2>/dev/null || echo "$SCRIPT_INSTALL_PATH")" ]]; then
    cp "$0" "$SCRIPT_INSTALL_PATH" \
        && chmod +x "$SCRIPT_INSTALL_PATH" \
        && info "Script installed: $SCRIPT_INSTALL_PATH"
fi

# ── Alias file ────────────────────────────────────────────────────────────────
cat > "$ALIAS_FILE" <<ALIASES
# ── Local LLM aliases — sourced by .bashrc ─────────────────────────────────
alias llm-setup='bash "$SCRIPT_INSTALL_PATH"'
alias webui='$BIN_DIR/llm-webui'
alias chat='$BIN_DIR/llm-chat'
alias run-model='$BIN_DIR/run-gguf'
alias ask='$BIN_DIR/run-gguf'
alias gguf-run='$BIN_DIR/run-gguf'
alias gguf-list='ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null || echo "(no GGUF files)"'
alias ollama-run='ollama run'
alias ollama-pull='ollama pull'
alias ollama-list='ollama list'
alias ollama-start='$BIN_DIR/ollama-start'
alias llm-status='$BIN_DIR/local-models-info'
alias llm-stop='$BIN_DIR/llm-stop'
alias llm-update='$BIN_DIR/llm-update'
alias llm-switch='$BIN_DIR/llm-switch'
alias llm-add='$BIN_DIR/llm-add'
alias llm-checker='$BIN_DIR/llm-checker'
alias llm-help='$BIN_DIR/llm-help'
alias llm-show-config='$BIN_DIR/llm-show-config'
alias ai='$BIN_DIR/aider'
alias aider='$BIN_DIR/aider'
alias cowork='$BIN_DIR/cowork'
ALIASES

# ── Source aliases from .bashrc (idempotent) ──────────────────────────────────
if ! grep -q "# llm-auto-setup aliases" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'BASHRC_BLOCK'

# ── llm-auto-setup aliases ─────────────────────────────────────────────────
# llm-auto-setup aliases
[[ -f "$HOME/.local_llm_aliases" ]] && source "$HOME/.local_llm_aliases"
BASHRC_BLOCK
fi

# ── WSL2 welcome screen ───────────────────────────────────────────────────────
# Show llm-help in the first login shell after WSL restarts.
# .bash_profile is only sourced for login shells — exactly when WSL starts.
if is_wsl2; then
    if ! grep -q "# llm-auto-setup welcome" "$HOME/.bash_profile" 2>/dev/null; then
        cat >> "$HOME/.bash_profile" <<'BASH_PROFILE_BLOCK'

# ── llm-auto-setup welcome ──────────────────────────────────────────────────
# llm-auto-setup welcome
# Load aliases so all llm-* commands are available on WSL login
[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc"
# Show help/welcome screen on WSL login
if [[ -x "$HOME/.local/bin/llm-help" ]]; then
    "$HOME/.local/bin/llm-help"
fi
BASH_PROFILE_BLOCK
        info "WSL2 welcome screen configured (~/.bash_profile)"
    else
        info "WSL2 welcome screen already configured."
    fi
fi

# Source aliases in current shell immediately
# shellcheck source=/dev/null
[[ -f "$ALIAS_FILE" ]] && source "$ALIAS_FILE" || true
info "Aliases active."

# =============================================================================
# STEP 19 — FINAL CHECKS
# =============================================================================
step "Final checks"

PASS=0; WARN_COUNT=0

_check() {
    local label="$1" ok="$2" detail="${3:-}"
    if (( ok )); then
        echo -e "  ${GREEN}✔${NC}  $label${detail:+  ($detail)}"
        (( PASS++ ))
    else
        echo -e "  ${YELLOW}✗${NC}  $label${detail:+  — $detail}"
        (( WARN_COUNT++ ))
    fi
}

echo ""
# Ollama
_ollama_chk=0; command -v ollama &>/dev/null && _ollama_chk=1
_check "Ollama binary"   "$_ollama_chk"  "$(ollama --version 2>/dev/null | head -1 || true)"
_olup=0; ollama_running && _olup=1
_check "Ollama service"  "$_olup"  "$([ $_olup -eq 1 ] && echo 'running' || echo 'not running — run: ollama-start')"

# llama-cpp-python
_llama_chk=0
"$VENV_DIR/bin/python3" -c "import llama_cpp" 2>/dev/null && _llama_chk=1
_check "llama-cpp-python"  "$_llama_chk"  "$([ $_llama_chk -eq 0 ] && echo 'import failed — check CUDA/ROCm' || true)"

# Open WebUI
_owui_chk=0
[[ -x "$OWUI_VENV/bin/open-webui" ]] && _owui_chk=1
_check "Open WebUI"  "$_owui_chk"  "$([ $_owui_chk -eq 1 ] && echo "$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}')" || echo 'run: llm-setup')"

# GGUF model
_gguf_chk=0
_gguf_path="$GGUF_MODELS/${M[file]}"
[[ -f "$_gguf_path" ]] && _gguf_chk=1
_check "GGUF model"  "$_gguf_chk"  "$([ $_gguf_chk -eq 1 ] && du -h "$_gguf_path" | cut -f1 || echo 'not downloaded — answered No to download prompt')"

# Ollama model registered
_tag_chk=0
if (( _olup )) && ollama list 2>/dev/null | grep -q "^$OLLAMA_TAG"; then
    _tag_chk=1
fi
_check "Ollama tag registered"  "$_tag_chk"  "$OLLAMA_TAG"

# cowork
_cowork_chk=0; [[ -x "$BIN_DIR/cowork" ]] && _cowork_chk=1
_check "cowork launcher"  "$_cowork_chk"

# aider
_aider_chk=0; [[ -x "$AI_VENV/bin/aider" ]] && _aider_chk=1
_check "aider"  "$_aider_chk"

# Open Interpreter health
_oi_chk=0
"$OI_VENV/bin/python3" -c "import pkg_resources; import interpreter" 2>/dev/null && _oi_chk=1
_check "Open Interpreter (pkg_resources)"  "$_oi_chk"  "$([ $_oi_chk -eq 0 ] && echo 're-run setup' || true)"

# Neural Terminal
_html_chk=0; [[ -f "$GUI_DIR/llm-chat.html" ]] && _html_chk=1
_check "Neural Terminal HTML"  "$_html_chk"

# Aliases
_alias_chk=0; [[ -f "$ALIAS_FILE" ]] && _alias_chk=1
_check "Alias file"  "$_alias_chk"  "$ALIAS_FILE"

# Script self-install
_self_chk=0; [[ -f "$SCRIPT_INSTALL_PATH" ]] && _self_chk=1
_check "Script installed"  "$_self_chk"  "$SCRIPT_INSTALL_PATH"

echo ""
if (( WARN_COUNT == 0 )); then
    echo -e "  ${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║   ✔  All checks passed ($PASS/$PASS)                       ║${NC}"
    echo -e "  ${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
else
    echo -e "  ${YELLOW}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}║   Checks: ${PASS} passed · ${WARN_COUNT} warnings                      ║${NC}"
    echo -e "  ${YELLOW}╚═══════════════════════════════════════════════════╝${NC}"
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "  ${CYAN}┌─────────────────────────  YOUR SETUP  ──────────────────────────┐${NC}"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "CPU"   "$CPU_MODEL"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "RAM"   "${TOTAL_RAM_GB} GB"
if (( HAS_NVIDIA )); then
    printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "GPU" "$GPU_NAME  (${GPU_VRAM_GB} GB VRAM) [CUDA]"
elif (( HAS_AMD_GPU )); then
    printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "GPU" "$GPU_NAME  (${GPU_VRAM_GB} GB VRAM) [ROCm]"
elif (( HAS_INTEL_GPU )); then
    printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "GPU" "$GPU_NAME  [Arc — CPU tiers used]"
else
    printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "GPU" "None (CPU-only)"
fi
echo -e "  ${CYAN}├────────────────────────────────────────────────────────────────┤${NC}"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "Model"      "${M[name]}"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "Caps"       "${M[caps]}"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "Ollama tag" "$OLLAMA_TAG"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "GPU layers" "${GPU_LAYERS} / ${M[layers]} total   batch: $BATCH"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "Threads"    "$HW_THREADS"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "GGUF path"  "$GGUF_MODELS/${M[file]}"
printf "  ${CYAN}│${NC}  %-18s  %-41s${CYAN}│${NC}\n" "Config"     "$MODEL_CONFIG"
echo -e "  ${CYAN}└────────────────────────────────────────────────────────────────┘${NC}"

echo ""
echo -e "${GREEN}  ╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║                                                               ║${NC}"
echo -e "${GREEN}  ║   Activate all aliases in this terminal:                     ║${NC}"
echo -e "${GREEN}  ║                                                               ║${NC}"
echo -e "${GREEN}  ║          ${YELLOW}exec bash${GREEN}                                          ║${NC}"
echo -e "${GREEN}  ║                                                               ║${NC}"
echo -e "${GREEN}  ║   Same window. Same directory. Aliases live immediately.     ║${NC}"
echo -e "${GREEN}  ╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Then:${NC}"
echo -e "    ${YELLOW}webui${NC}          → Open WebUI   http://localhost:8080   ${CYAN}(primary UI)${NC}"
echo -e "    ${YELLOW}chat${NC}           → Neural Terminal   http://localhost:8090"
echo -e "    ${YELLOW}cowork${NC}         → autonomous coding AI"
echo -e "    ${YELLOW}ai${NC}             → aider AI pair programmer"
echo -e "    ${YELLOW}llm-show-config${NC} → all paths & service status"
echo -e "    ${YELLOW}llm-help${NC}       → full command reference"
is_wsl2 && echo "" && echo -e "  ${YELLOW}  WSL2:${NC} ${YELLOW}webui${NC} starts Ollama automatically — just run it."
echo ""

# Troubleshooting hints (only when there are warnings)
if (( WARN_COUNT > 0 )); then
    echo -e "  ${YELLOW}┌──────────────────────  TROUBLESHOOTING  ─────────────────────┐${NC}"
    (( HAS_NVIDIA && !_llama_chk )) && \
        echo -e "  ${YELLOW}│${NC}  CUDA error → sudo ldconfig && exec bash                   ${YELLOW}│${NC}"
    (( HAS_AMD_GPU && !_llama_chk )) && \
        echo -e "  ${YELLOW}│${NC}  ROCm error → exec bash  (then: hipconfig --version)        ${YELLOW}│${NC}"
    (( !_olup )) && \
        echo -e "  ${YELLOW}│${NC}  Ollama offline → ollama-start                              ${YELLOW}│${NC}"
    (( !_owui_chk )) && \
        echo -e "  ${YELLOW}│${NC}  WebUI missing → re-run setup                               ${YELLOW}│${NC}"
    (( !_oi_chk )) && \
        echo -e "  ${YELLOW}│${NC}  cowork crash → re-run setup (setuptools reinstall)         ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  Log: $LOG_FILE ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
fi

echo -e "  🚀  Enjoy your local LLM!"
echo ""

# Clean up sudo keepalive
kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
trap - EXIT INT TERM
