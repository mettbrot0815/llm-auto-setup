#!/usr/bin/env bash
# =============================================================================
# Local LLM Auto-Setup — Universal Edition v3.0.0
# Scans your hardware and automatically selects the best model.
# No Hugging Face token required — all models are from public repos.
# Supports: Ubuntu 22.04 / 24.04, Debian 12, Linux Mint 21+, Pop!_OS 22.04.
# CPU-only through high-end GPU (NVIDIA CUDA, AMD ROCm, Intel Arc noted).
# =============================================================================

set -uo pipefail

# ---------- Version -----------------------------------------------------------
SCRIPT_VERSION="3.0.0"
# Set this to your hosted URL to enable auto-update checks on each run:
SCRIPT_UPDATE_URL=""
# Local install path — script saves itself here after a successful install:
SCRIPT_INSTALL_PATH="$HOME/.config/local-llm/llm-auto-setup.sh"

# ---------- Configuration -----------------------------------------------------
LOG_FILE="$HOME/llm-auto-setup-$(date +%Y%m%d-%H%M%S).log"
VENV_DIR="$HOME/.local/share/llm-venv"
MODEL_BASE="$HOME/local-llm-models"
OLLAMA_MODELS="$MODEL_BASE/ollama"
GGUF_MODELS="$MODEL_BASE/gguf"
TEMP_DIR="$MODEL_BASE/temp"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/local-llm"
ALIAS_FILE="$HOME/.local_llm_aliases"
# Shared download cache — pip, npm, apt downloads reused across runs
PKG_CACHE_DIR="$HOME/.cache/llm-setup"
mkdir -p "$PKG_CACHE_DIR/pip" "$PKG_CACHE_DIR/npm" "$PKG_CACHE_DIR/apt"
export PIP_CACHE_DIR="$PKG_CACHE_DIR/pip"   # pip respects this env var automatically
# npm cache reuse (avoids re-downloading during Claude Code / Codex install)
export npm_config_cache="$PKG_CACHE_DIR/npm"
# apt: keep downloaded .deb files in a persistent cache dir between setup runs.
# This is optional — apt already caches in /var/cache/apt — but our dir is
# inside $HOME so it survives system cache cleans and is user-accessible.
_APT_OPTS=(-o Dir::Cache::archives="$PKG_CACHE_DIR/apt" -o Debug::NoLocking=1)
_apt_install() { sudo apt-get install -y "${_APT_OPTS[@]}" "$@"; }
MODEL_CONFIG="$CONFIG_DIR/selected_model.conf"
GUI_DIR="$HOME/.local/share/llm-webui"

# ---------- Colors (disabled automatically when stdout is not a tty) ----------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; NC=''
fi

# ---------- Logging -----------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()   { echo -e "$(date +'%Y-%m-%d %H:%M:%S') $1"; }
info()  { log "${GREEN}[INFO]${NC}  $1"; }
warn()  { log "${YELLOW}[WARN]${NC}  $1"; }
error() {
    log "${RED}[ERROR]${NC} $1"
    log "${RED}[ERROR]${NC} Log: $LOG_FILE"
    exit 1
}
step()  {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  ▶  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
highlight() {
    echo -e "\n${MAGENTA}  ◆  $1${NC}"
}

ask_yes_no() {
    local prompt="$1" ans=""
    if [[ ! -t 0 ]]; then warn "Non-interactive — treating '$prompt' as No."; return 1; fi
    read -r -p "$(echo -e "${YELLOW}?${NC} $prompt (y/N) ")" -n 1 ans; echo
    [[ "$ans" =~ ^[Yy]$ ]] && return 0 || return 1
}

retry() {
    local n="$1" delay="$2"; shift 2
    local attempt=1
    while true; do
        "$@" && return 0
        (( attempt >= n )) && { warn "Failed after $n attempts: $*"; return 1; }
        warn "Attempt $attempt/$n failed — retrying in ${delay}s…"
        sleep "$delay"; attempt=$(( attempt + 1 ))
    done
}

is_wsl2() {
    # Check /proc/version for "microsoft" (present on all WSL1 and WSL2 kernels).
    grep -qi microsoft /proc/version 2>/dev/null
}

# get_distro_id: returns lowercase distro ID (ubuntu, debian, linuxmint, pop, …)
get_distro_id() {
    grep -m1 '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'  | tr '[:upper:]' '[:lower:]' || echo "unknown"
}

# get_distro_codename: returns ubuntu-style codename (jammy, noble, bookworm, …)
get_distro_codename() {
    grep -m1 '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'  ||     lsb_release -sc 2>/dev/null || echo "unknown"
}

# =============================================================================
# STEP 1 — PRE-FLIGHT
# =============================================================================
step "Pre-flight checks"

[[ "${EUID}" -eq 0 ]] && error "Do not run as root. Run as a normal user with sudo access."
command -v sudo &>/dev/null || error "sudo is required but not found. Install it: apt-get install sudo"

# ── Architecture check ────────────────────────────────────────────────────────
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64)  : ;;
    aarch64) warn "ARM64 detected — CUDA pre-built wheels unavailable; will build from source." ;;
    *)       warn "Untested architecture: $HOST_ARCH. Proceeding anyway." ;;
esac

# ── Distro check ──────────────────────────────────────────────────────────────
DISTRO_ID=$(get_distro_id)
DISTRO_CODENAME=$(get_distro_codename)
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || grep -oP '(?<=^VERSION_ID=")[\d.]+' /etc/os-release 2>/dev/null || echo "unknown")
info "Distro: ${DISTRO_ID} ${UBUNTU_VERSION} (${DISTRO_CODENAME}) on ${HOST_ARCH}"
case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|neon|elementary|zorin) ;;
    *) warn "Distro '${DISTRO_ID}' not officially tested. apt-based paths will be used." ;;
esac

# ── Single sudo prompt — keep credentials alive for the entire script ─────────
# sudo -v extends the TTY-scoped timestamp every 50 s (Ubuntu 22.04+ ppid mode).
echo -e "${CYAN}[sudo]${NC} This script needs elevated privileges for apt, systemd, and CUDA/ROCm."
sudo -v || error "sudo authentication failed."
( while true; do sleep 50; sudo -v; done ) &
SUDO_KEEPALIVE_PID=$!
# Ensure keepalive is killed even if script exits early (error, Ctrl-C, etc.)
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; trap - EXIT INT TERM' EXIT INT TERM
info "sudo keepalive active (PID $SUDO_KEEPALIVE_PID)."

# ── Self-update check ─────────────────────────────────────────────────────────
# Compares running version against local installed copy.
# If SCRIPT_UPDATE_URL is set, also checks for remote updates.
_local_ver=""
if [[ -f "$SCRIPT_INSTALL_PATH" ]]; then
    _local_ver=$(grep '^SCRIPT_VERSION=' "$SCRIPT_INSTALL_PATH" 2>/dev/null \
                 | head -1 | cut -d'"' -f2 || true)
fi

# ── Exec local copy when running from a downloaded/temp path ─────────────────
# If the canonical local copy exists, is same or newer version, AND we are not
# already running it → exec it, so users always get their installed copy.
_running_path=$(realpath "$0" 2>/dev/null || echo "$0")
_install_rp=$(realpath "$SCRIPT_INSTALL_PATH" 2>/dev/null || echo "$SCRIPT_INSTALL_PATH")
if [[ -f "$SCRIPT_INSTALL_PATH" && "$_running_path" != "$_install_rp" && -n "${_local_ver:-}" ]]; then
    _ver_ge() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }
    if _ver_ge "$_local_ver" "$SCRIPT_VERSION"; then
        echo -e "\033[0;32m[INFO]\033[0m  Local copy found (v${_local_ver}) — switching to installed version."
        exec bash "$SCRIPT_INSTALL_PATH" "$@"
    fi
    unset -f _ver_ge 2>/dev/null || true
fi
unset _running_path _install_rp 2>/dev/null || true

if [[ -n "$SCRIPT_UPDATE_URL" ]]; then
    _remote_ver=$(curl -fsSL --max-time 3 "${SCRIPT_UPDATE_URL%.sh}.version" 2>/dev/null || true)
    if [[ -n "$_remote_ver" && "$_remote_ver" != "$SCRIPT_VERSION" ]]; then
        echo ""
        echo -e "${YELLOW}  ┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}  │  Update available: v${SCRIPT_VERSION} → v${_remote_ver}                           │${NC}"
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

# ── Internet connectivity check ───────────────────────────────────────────────
if curl -fsSL --max-time 5 https://huggingface.co >/dev/null 2>&1; then
    info "Internet: reachable (huggingface.co)"
elif curl -fsSL --max-time 5 https://pypi.org >/dev/null 2>&1; then
    info "Internet: reachable (pypi.org)"
else
    warn "Internet appears unreachable. Model downloads and pip installs may fail."
    warn "  If behind a proxy, set: export https_proxy=http://proxy:port"
fi 

# =============================================================================
# STEP 2 — SYSTEM SCAN
# =============================================================================
step "Hardware detection"
# ── Show already-installed models so user knows what's there ──────────────────
_GGUF_DIR="$HOME/local-llm-models/gguf"
_OLLAMA_OK=0; command -v ollama &>/dev/null && _OLLAMA_OK=1

_installed_gguf=()
if [[ -d "$_GGUF_DIR" ]]; then
    while IFS= read -r -d '' _f; do
        _installed_gguf+=( "$(basename "$_f")" )
    done < <(find "$_GGUF_DIR" -maxdepth 1 -name '*.gguf' -print0 2>/dev/null)
fi

_installed_ollama=()
if (( _OLLAMA_OK )); then
    while IFS= read -r _line; do
        [[ "$_line" == NAME* ]] && continue
        _tag=$(awk '{print $1}' <<< "$_line")
        [[ -n "$_tag" ]] && _installed_ollama+=( "$_tag" )
    done < <(ollama list 2>/dev/null || true)
fi

if (( ${#_installed_gguf[@]} > 0 || ${#_installed_ollama[@]} > 0 )); then
    echo ""
    echo -e "  ${GREEN}┌──────────────────────  INSTALLED MODELS  ───────────────────────┐${NC}"
    if (( ${#_installed_gguf[@]} > 0 )); then
        echo -e "  ${GREEN}│${NC}  ${CYAN}GGUF files:${NC}                                                    ${GREEN}│${NC}"
        for _m in "${_installed_gguf[@]}"; do
            printf "  ${GREEN}│${NC}   ✔  %-56s ${GREEN}│${NC}
" "$_m"
        done
    fi
    if (( ${#_installed_ollama[@]} > 0 )); then
        echo -e "  ${GREEN}│${NC}  ${CYAN}Ollama models:${NC}                                                 ${GREEN}│${NC}"
        for _m in "${_installed_ollama[@]}"; do
            printf "  ${GREEN}│${NC}   ✔  %-56s ${GREEN}│${NC}
" "$_m"
        done
    fi
    echo -e "  ${GREEN}└────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
fi


# ---------- CPU ---------------------------------------------------------------
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
CPU_THREADS=$(nproc 2>/dev/null || echo 4)

# Detect instruction sets (important for choosing optimal llama.cpp build)
# Read CPU flags once; avoid spawning multiple grep subshells.
CPU_FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null \
            || grep -m1 '^Features' /proc/cpuinfo 2>/dev/null \
            || echo "")
HAS_AVX2=0;   [[ "$CPU_FLAGS" =~ (^| )avx2( |$)   ]] && HAS_AVX2=1
HAS_AVX512=0; [[ "$CPU_FLAGS" =~ (^| )avx512f( |$) ]] && HAS_AVX512=1
HAS_AVX=0;    [[ "$CPU_FLAGS" =~ (^| )avx( |$)     ]] && HAS_AVX=1
# NEON is ARM's equivalent of SSE/AVX — used for ARM64 builds
HAS_NEON=0;   [[ "$HOST_ARCH" == "aarch64" ]] && HAS_NEON=1

# ---------- RAM ---------------------------------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 4096000)
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 2048000)
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
AVAIL_RAM_GB=$(( AVAIL_RAM_KB / 1024 / 1024 ))
# Ensure sane minimums in case of weird /proc/meminfo output
(( TOTAL_RAM_GB < 1 )) && TOTAL_RAM_GB=4
(( AVAIL_RAM_GB < 1 )) && AVAIL_RAM_GB=2

# ---------- GPU ---------------------------------------------------------------
# We detect NVIDIA and AMD independently, then set unified HAS_GPU / GPU_VRAM_GB
# so the model selection engine works identically for both.
HAS_NVIDIA=0
HAS_AMD_GPU=0
HAS_GPU=0          # set to 1 if any capable GPU found
GPU_NAME="None"
GPU_VRAM_MIB=0
GPU_VRAM_GB=0
DRIVER_VER="N/A"
CUDA_VER_SMI=""
AMD_ROCM_VER=""

# ── NVIDIA ────────────────────────────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    # For model selection use the VRAM of the largest single GPU (layers offload
    # to one device; summing across GPUs would overstate capacity).
    _nv_vram_max=0
    while IFS= read -r _mib_line; do
        _mib_line="${_mib_line// /}"
        if [[ "$_mib_line" =~ ^[0-9]+$ ]] && (( _mib_line > _nv_vram_max )); then
            _nv_vram_max=$_mib_line
        fi
    done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true)
    _nv_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo 1)
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo "Unknown NVIDIA GPU")
    (( _nv_count > 1 )) && GPU_NAME="${_nv_count}x ${GPU_NAME}"
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo "N/A")
    CUDA_VER_SMI=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -n1 || echo "")
    if (( _nv_vram_max > 500 )); then
        HAS_NVIDIA=1; HAS_GPU=1
        GPU_VRAM_MIB=$_nv_vram_max
        GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
    fi
fi

# ── AMD GPU ───────────────────────────────────────────────────────────────────
# Probe AMD only if no NVIDIA found (avoids dual-GPU confusion on Optimus etc.)
AMD_GFX_VER=""     # gfx1100 etc. — needed for HSA_OVERRIDE_GFX_VERSION
if (( !HAS_NVIDIA )); then
    # sysfs mem_info_vram_total works on kernels ≥ 4.15 without ROCm installed.
    # Iterate all drm cards; pick the one with the most VRAM > 512 MiB.
    _best_amd_mib=0
    for _sysfs_card in /sys/class/drm/card*/device/mem_info_vram_total; do
        [[ -f "$_sysfs_card" ]] || continue
        _amd_vram_bytes=$(< "$_sysfs_card" 2>/dev/null || echo 0)
        _amd_vram_mib=$(( _amd_vram_bytes / 1024 / 1024 ))
        if (( _amd_vram_mib > _best_amd_mib && _amd_vram_mib > 512 )); then
            _best_amd_mib=$_amd_vram_mib
        fi
    done
    if (( _best_amd_mib > 512 )); then
        GPU_VRAM_MIB=$_best_amd_mib
        GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
        HAS_AMD_GPU=1; HAS_GPU=1
        # GPU name: prefer rocm-smi, fall back to lspci
        if command -v rocm-smi &>/dev/null; then
            GPU_NAME=$(rocm-smi --showproductname 2>/dev/null \
                       | grep -oP '(?<=GPU\[0\] : ).*' | head -n1 | xargs \
                       || echo "AMD GPU")
        else
            GPU_NAME=$(lspci 2>/dev/null \
                       | grep -iE "VGA|Display|3D" \
                       | grep -iE "AMD|ATI|Radeon|gfx" \
                       | head -n1 | sed 's/.*: //' | xargs || echo "AMD GPU")
        fi
        # ROCm version and gfx target if installed
        if command -v rocminfo &>/dev/null; then
            AMD_ROCM_VER=$(rocminfo 2>/dev/null \
                           | grep -oP 'Runtime Version:\s*\K[0-9.]+' | head -n1 || echo "")
            AMD_GFX_VER=$(rocminfo 2>/dev/null \
                          | grep -oP 'gfx\d+[a-z]*' | head -n1 || echo "")
        fi
        DRIVER_VER=$(< /sys/class/drm/card0/device/driver/module/version 2>/dev/null \
                     || uname -r)
    fi
fi

# ── Intel Arc / Xe GPU ────────────────────────────────────────────────────────
# Intel Arc uses i915/xe driver. GPU offload via SYCL is possible but not
# auto-configured here; we detect and note it, then fall through to CPU tiers.
HAS_INTEL_GPU=0
if (( !HAS_NVIDIA && !HAS_AMD_GPU )); then
    if lspci 2>/dev/null | grep -qiE "Intel.*Arc|Intel.*Xe"; then
        HAS_INTEL_GPU=1
        GPU_NAME=$(lspci 2>/dev/null \
                   | grep -iE "Intel.*Arc|Intel.*Xe" | head -n1 | sed 's/.*: //' | xargs \
                   || echo "Intel Arc GPU")
        info "Intel Arc/Xe GPU detected: $GPU_NAME"
        info "  llama.cpp SYCL backend is not auto-configured — using CPU tiers."
    fi
fi

# ---------- Disk --------------------------------------------------------------
DISK_FREE_GB=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo 10)

# ---------- Print summary -----------------------------------------------------
echo ""
echo -e "  ${CYAN}┌─────────────────────────────────────────────┐${NC}"
echo -e "  ${CYAN}│           HARDWARE SCAN RESULTS             │${NC}"
echo -e "  ${CYAN}├─────────────────────────────────────────────┤${NC}"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "CPU" "$CPU_MODEL" | cut -c1-52
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Threads"  "${CPU_THREADS} logical cores"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Arch"     "${HOST_ARCH}"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "SIMD"     "$(
    flags=""
    (( HAS_AVX512 )) && flags="AVX-512 AVX2 AVX"
    [[ -z "$flags" ]] && (( HAS_AVX2 ))   && flags="AVX2 AVX"
    [[ -z "$flags" ]] && (( HAS_AVX ))    && flags="AVX"
    [[ -z "$flags" ]] && (( HAS_NEON ))   && flags="NEON (ARM64)"
    [[ -z "$flags" ]] && flags="baseline"
    echo "$flags"
)"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "RAM"      "${TOTAL_RAM_GB} GB total / ${AVAIL_RAM_GB} GB free"
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "GPU"      "$GPU_NAME"
if (( HAS_NVIDIA )); then
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "VRAM"     "${GPU_VRAM_GB} GB (${GPU_VRAM_MIB} MiB)"
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Driver"   "$DRIVER_VER"
    [[ -n "$CUDA_VER_SMI" ]] && \
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "API"      "CUDA $CUDA_VER_SMI"
elif (( HAS_AMD_GPU )); then
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "VRAM"     "${GPU_VRAM_GB} GB (${GPU_VRAM_MIB} MiB)"
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Driver"   "$DRIVER_VER"
    if [[ -n "$AMD_ROCM_VER" ]]; then
        _amd_api="ROCm $AMD_ROCM_VER"
        [[ -n "$AMD_GFX_VER" ]] && _amd_api+="  (${AMD_GFX_VER})"
        printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "API" "$_amd_api"
    else
        printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "API" "ROCm (not yet installed)"
    fi
elif (( HAS_INTEL_GPU )); then
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Note" "Intel Arc — CPU tiers used"
fi
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Disk free" "${DISK_FREE_GB} GB"
echo -e "  ${CYAN}└─────────────────────────────────────────────┘${NC}"
echo ""

# =============================================================================
# STEP 3 — MODEL SELECTION ENGINE
# All public models (bartowski). Catalog: 2026-02. Tiers: 24GB→32B, 16GB→MoE,
# 12-10GB→Phi-4/Qwen3-14B, 8GB→8B-Q6, 6GB→8B-Q4, 4GB→4B, CPU→Phi-4-mini.
# =============================================================================

step "Auto-selecting model"

# Helper: MiB needed per layer for a given model total size and layer count
# Used to calculate how many layers fit in VRAM
# $1=model_size_gb  $2=num_layers  → MiB per layer
mib_per_layer() {
    local size_gb="$1" layers="$2"
    echo $(( (size_gb * 1024) / layers ))
}

# Headroom to keep free in VRAM for KV-cache + activations
VRAM_HEADROOM_MIB=1400
VRAM_USABLE_MIB=$(( GPU_VRAM_MIB - VRAM_HEADROOM_MIB ))
(( VRAM_USABLE_MIB < 0 )) && VRAM_USABLE_MIB=0

# Maximum RAM we want to commit to model layers (leave 4 GB for OS + Python)
RAM_FOR_LAYERS_GB=$(( TOTAL_RAM_GB - 4 ))
(( RAM_FOR_LAYERS_GB < 1 )) && RAM_FOR_LAYERS_GB=1

# Calculate layers that fit fully in VRAM given model size and layer count
# Returns the number of layers to offload to GPU
gpu_layers_for() {
    local size_gb="$1" num_layers="$2"
    local mib_layer=$(( (size_gb * 1024) / num_layers ))
    (( mib_layer < 1 )) && mib_layer=1
    local layers=$(( VRAM_USABLE_MIB / mib_layer ))
    (( layers > num_layers )) && layers=$num_layers
    (( layers < 0 )) && layers=0
    echo $layers
}

# ── Model definitions ─────────────────────────────────────────────────────────
# Rankings updated Feb 2026 from whatllm.org, localllm.in, ArtificialAnalysis
# [TOOLS]=function calling  [THINK]=chain-of-thought via /think  [UNCENS]=uncensored  ★=best pick

declare -A M   # holds the chosen model's fields

select_model() {
    local vram=$GPU_VRAM_GB
    local ram=$TOTAL_RAM_GB

    # ── ≥ 48 GB VRAM (multi-GPU / H100 / A100 class) ─────────────────────────
    if (( HAS_GPU && vram >= 48 )); then
        highlight "≥48 GB VRAM → Llama-3.3-70B Q4_K_M [TOOLS] ★"
        M[name]="Llama-3.3-70B-Instruct Q4_K_M"; M[caps]="TOOLS"
        M[file]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M[size_gb]=40; M[layers]=80; M[tier]="70B"; return

    # ── ≥ 24 GB VRAM ─────────────────────────────────────────────────────────
    # Qwen3-32B: #1 open-weight GGUF at this tier (Feb 2026).
    # Fully on GPU at 24 GB; 128K context; best TOOLS+THINK combo.
    elif (( HAS_GPU && vram >= 24 )); then
        highlight "≥24 GB VRAM → Qwen3-32B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-32B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
        M[size_gb]=19; M[layers]=64; M[tier]="32B"; return

    # ── ≥ 16 GB VRAM ─────────────────────────────────────────────────────────
    # Mistral-Small-3.2-24B: March 2025 update, 128K context, vision-ready,
    # Apache 2.0. 14GB file fits comfortably in 16 GB VRAM at ~40 t/s.
    # Benchmarks: beats Qwen3-30B-A3B on instruction following; A3B faster.
    # Tip: pick A3B (#19 in manual picker) if you prioritise raw speed.
    elif (( HAS_GPU && vram >= 16 )); then
        highlight "≥16 GB VRAM → Mistral-Small-3.2-24B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Mistral-Small-3.2-24B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
        M[size_gb]=14; M[layers]=40; M[tier]="24B"; return

    # ── ≥ 12 GB VRAM ─────────────────────────────────────────────────────────
    # Qwen3-14B: best overall 12 GB VRAM choice. TOOLS + THINK native.
    elif (( HAS_GPU && vram >= 12 )); then
        highlight "≥12 GB VRAM → Qwen3-14B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-14B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[size_gb]=9; M[layers]=40; M[tier]="14B"; return

    # ── ≥ 10 GB VRAM ─────────────────────────────────────────────────────────
    # Phi-4-14B: replaces Mistral-Nemo here. Strong coding + math benchmark
    # leader at 14B (Microsoft, Dec 2024). ~8.5 GB VRAM at Q4_K_M.
    elif (( HAS_GPU && vram >= 10 )); then
        highlight "≥10 GB VRAM → Phi-4-14B Q4_K_M [TOOLS] ★"
        M[name]="Phi-4-14B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="phi-4-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf"
        M[size_gb]=9; M[layers]=40; M[tier]="14B"; return

    # ── ≥ 8 GB VRAM ──────────────────────────────────────────────────────────
    # Qwen3-8B Q6_K: near Q8 quality, still fits in 8 GB. Top 8B choice Feb 2026.
    elif (( HAS_GPU && vram >= 8 )); then
        highlight "≥8 GB VRAM → Qwen3-8B Q6_K [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q6_K"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q6_K.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
        M[size_gb]=6; M[layers]=36; M[tier]="8B"; return

    # ── ≥ 6 GB VRAM ──────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 6 )); then
        highlight "≥6 GB VRAM → Qwen3-8B Q4_K_M [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[size_gb]=5; M[layers]=36; M[tier]="8B"; return

    # ── ≥ 4 GB VRAM ──────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 4 )); then
        highlight "≥4 GB VRAM → Qwen3-4B Q4_K_M [TOOLS+THINK]"
        M[name]="Qwen3-4B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[size_gb]=3; M[layers]=36; M[tier]="4B"; return

    # ── ≥ 2 GB VRAM (partial offload) ────────────────────────────────────────
    elif (( HAS_GPU && vram >= 2 )); then
        highlight "Small GPU (${vram} GB) → Qwen3-1.7B Q8_0 partial offload"
        M[name]="Qwen3-1.7B Q8_0"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
        M[size_gb]=2; M[layers]=28; M[tier]="1.7B"; return

    # ── CPU-only ──────────────────────────────────────────────────────────────
    else
        if (( ram >= 32 )); then
            highlight "CPU-only (${ram} GB RAM) → Qwen3-14B Q4_K_M [TOOLS+THINK] ★"
            M[name]="Qwen3-14B Q4_K_M"; M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[size_gb]=9; M[layers]=40; M[tier]="14B"
        elif (( ram >= 16 )); then
            highlight "CPU-only (${ram} GB RAM) → Qwen3-8B Q4_K_M [TOOLS+THINK] ★"
            M[name]="Qwen3-8B Q4_K_M"; M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[size_gb]=5; M[layers]=36; M[tier]="8B"
        elif (( ram >= 8 )); then
            highlight "CPU-only (${ram} GB RAM) → Qwen3-4B Q4_K_M [TOOLS+THINK]"
            M[name]="Qwen3-4B Q4_K_M"; M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[size_gb]=3; M[layers]=36; M[tier]="4B"
        else
            highlight "Low RAM CPU-only → Qwen3-1.7B Q8_0 (most efficient)"
            M[name]="Qwen3-1.7B Q8_0"; M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[size_gb]=2; M[layers]=28; M[tier]="1.7B"
        fi
        return
    fi
}

select_model

# Calculate optimal GPU and CPU layer counts
if (( HAS_GPU )); then
    GPU_LAYERS=$(gpu_layers_for "${M[size_gb]}" "${M[layers]}")
    CPU_LAYERS=$(( M[layers] - GPU_LAYERS ))
    (( CPU_LAYERS < 0 )) && CPU_LAYERS=0
else
    GPU_LAYERS=0
    CPU_LAYERS="${M[layers]}"
fi

# Clamp CPU layers to available RAM
MIB_PER_LAYER=$(( (M[size_gb] * 1024) / M[layers] ))
MAX_CPU_LAYERS=$(( (RAM_FOR_LAYERS_GB * 1024) / (MIB_PER_LAYER > 0 ? MIB_PER_LAYER : 1) ))
(( CPU_LAYERS > MAX_CPU_LAYERS )) && CPU_LAYERS=$MAX_CPU_LAYERS

# Optimal thread count (physical cores, capped at 16)
# Detect physical (non-hyperthreaded) core count for optimal inference threading.
# We run lscpu once and parse both fields to avoid spawning two subshells.
LSCPU_OUT=$(lscpu 2>/dev/null || true)
PHYS_ONLY=$(echo "$LSCPU_OUT" | awk '/^Core\(s\) per socket/{print $NF}')
SOCKETS=$(echo   "$LSCPU_OUT" | awk '/^Socket\(s\)/{print $NF}')
if [[ -n "$PHYS_ONLY" && -n "$SOCKETS" && "$PHYS_ONLY" =~ ^[0-9]+$ && "$SOCKETS" =~ ^[0-9]+$ ]]; then
    HW_THREADS=$(( PHYS_ONLY * SOCKETS ))
else
    # Fall back to logical core count from /proc/cpuinfo
    HW_THREADS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
fi
(( HW_THREADS < 1  )) && HW_THREADS=1
(( HW_THREADS > 16 )) && HW_THREADS=16

# Batch size: scale with VRAM; larger = more throughput on GPU
if (( GPU_VRAM_GB >= 24 )); then  BATCH=2048
elif (( GPU_VRAM_GB >= 16 )); then BATCH=1024
elif (( GPU_VRAM_GB >= 8 ));  then BATCH=512
elif (( GPU_VRAM_GB >= 4 ));  then BATCH=256
else                               BATCH=128
fi

# Print recommendation box
VRAM_USED_GB=$(( (GPU_LAYERS * MIB_PER_LAYER) / 1024 ))
RAM_USED_GB=$(( (CPU_LAYERS  * MIB_PER_LAYER) / 1024 ))

echo ""
echo -e "  ${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${GREEN}║           RECOMMENDED CONFIGURATION                   ║${NC}"
echo -e "  ${GREEN}╠═══════════════════════════════════════════════════════╣${NC}"
printf "  ${GREEN}║${NC}  %-16s %-36.36s${GREEN}║${NC}\n" "Model"         "${M[name]}"
printf "  ${GREEN}║${NC}  %-16s %-36.36s${GREEN}║${NC}\n" "Capabilities"  "${M[caps]}"
printf "  ${GREEN}║${NC}  %-16s %-36.36s${GREEN}║${NC}\n" "Size"          "${M[tier]}  (~${M[size_gb]} GB file)"
printf "  ${GREEN}║${NC}  %-16s %-36.36s${GREEN}║${NC}\n" "GPU layers"    "${GPU_LAYERS} / ${M[layers]}  (~${VRAM_USED_GB} GB VRAM)"
printf "  ${GREEN}║${NC}  %-16s %-36.36s${GREEN}║${NC}\n" "CPU layers"    "${CPU_LAYERS}  (~${RAM_USED_GB} GB RAM)"
printf "  ${GREEN}║${NC}  %-16s %-36.36s${GREEN}║${NC}\n" "Threads"       "${HW_THREADS}"
printf "  ${GREEN}║${NC}  %-16s %-36.36s${GREEN}║${NC}\n" "Batch size"    "${BATCH}"
echo -e "  ${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

if ! ask_yes_no "Proceed with this configuration?"; then
    echo ""
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━  MODEL PICKER  (Feb 2026 ranking)  ━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    # ── Detect already-installed models for visual indicators ────────────────
    _gguf_dir="$HOME/local-llm-models/gguf"
    _installed_gguf=(); while IFS= read -r -d '' f; do _installed_gguf+=("$(basename "$f")"); done < <(find "$_gguf_dir" -maxdepth 1 -name "*.gguf" -print0 2>/dev/null)
    _installed_ollama=(); while IFS= read -r line; do _installed_ollama+=("$line"); done < <(ollama list 2>/dev/null | awk 'NR>1{print $1}')
    _is_installed() {
        local f="$1"
        for _g in "${_installed_gguf[@]:-}"; do [[ "$_g" == "$f" ]] && return 0; done
        return 1
    }
    _mark() { _is_installed "$1" && echo -e " ${GREEN}✔${NC}" || echo "  "; }

    echo -e "  Capability legend:"
    echo -e "    ${GREEN}[TOOLS]${NC}   tool/function calling — agents, JSON, APIs"
    echo -e "    ${YELLOW}[THINK]${NC}   chain-of-thought mode — add /think to prompt  |  /no_think = fast"
    echo -e "    ${MAGENTA}[UNCENS]${NC}  uncensored fine-tune — no content restrictions"
    echo -e "    ${CYAN}★${NC}         recommended pick for that VRAM tier"
    echo ""
    # Dynamic table — green ✔ if GGUF already downloaded, space if not
    _D="$GREEN✔$NC"   # installed marker
    _X="  "           # not installed
    printf "  ┌────┬──────────────────────────────────────┬──────┬──────┬──────────────────────────┬───┐\n"
    printf "  │ #  │ Model                                │ Quant│ VRAM │ Capabilities             │Got│\n"
    printf "  ├────┼──────────────────────────────────────┼──────┼──────┼──────────────────────────┼───┤\n"
    printf "  │    │ ── TINY / CPU ────────────────────── │      │      │                          │   │\n"
    printf "  │  1 │ Qwen3-1.7B                           │ Q8   │ CPU  │ ★ [TOOLS] [THINK]        │%s │\n" "$(_mark Qwen_Qwen3-1.7B-Q8_0.gguf)"
    printf "  │  2 │ Qwen3-4B                             │ Q4   │ ~3GB │ ★ [TOOLS] [THINK]        │%s │\n" "$(_mark Qwen_Qwen3-4B-Q4_K_M.gguf)"
    printf "  │  3 │ Phi-4-mini 3.8B                      │ Q4   │ CPU  │ ★ [TOOLS] [THINK]        │%s │\n" "$(_mark microsoft_Phi-4-mini-instruct-Q4_K_M.gguf)"
    printf "  ├────┼──────────────────────────────────────┼──────┼──────┼──────────────────────────┼───┤\n"
    printf "  │  4 │ Qwen3-0.6B                           │ Q8   │ CPU  │ [TOOLS] [THINK]  (tiny)  │%s │\n" "$(_mark Qwen_Qwen3-0.6B-Q8_0.gguf)"
    printf "  ├────┼──────────────────────────────────────┼──────┼──────┼──────────────────────────┼───┤\n"
    printf "  │    │ ── 6-8 GB VRAM ───────────────────── │      │      │                          │   │\n"
    printf "  │  5 │ Qwen3-8B                             │ Q4   │ ~5GB │ ★ [TOOLS] [THINK]        │%s │\n" "$(_mark Qwen_Qwen3-8B-Q4_K_M.gguf)"
    printf "  │  6 │ Qwen3-8B                             │ Q6   │ ~6GB │ ★ [TOOLS] [THINK]        │%s │\n" "$(_mark Qwen_Qwen3-8B-Q6_K.gguf)"
    printf "  │  7 │ DeepSeek-R1-0528-Qwen3-8B            │ Q4   │ ~5GB │ ★ [THINK] top reasoning  │%s │\n" "$(_mark DeepSeek-R1-0528-Qwen3-8B-Q4_K_M.gguf)"
    printf "  │  8 │ Gemma-3-9B                           │ Q4   │ ~6GB │ [TOOLS] Google           │%s │\n" "$(_mark google_gemma-3-9b-it-Q4_K_M.gguf)"
    printf "  │  9 │ Gemma-3-12B                          │ Q4   │ ~8GB │ [TOOLS] Google vision    │%s │\n" "$(_mark google_gemma-3-12b-it-Q4_K_M.gguf)"
    printf "  │ 10 │ Dolphin3.0-8B                        │ Q4   │ ~5GB │ [UNCENS]                 │%s │\n" "$(_mark Dolphin3.0-Mistral-7B-Q4_K_M.gguf)"
    printf "  ├────┼──────────────────────────────────────┼──────┼──────┼──────────────────────────┼───┤\n"
    printf "  │    │ ── 10-12 GB VRAM ─────────────────── │      │      │                          │   │\n"
    printf "  │ 11 │ Phi-4-14B                            │ Q4   │ ~9GB │ ★ [TOOLS] top coding+math│%s │\n" "$(_mark Phi-4-Q4_K_M.gguf)"
    printf "  │ 12 │ Qwen3-14B                            │ Q4   │ ~9GB │ ★ [TOOLS] [THINK]        │%s │\n" "$(_mark Qwen_Qwen3-14B-Q4_K_M.gguf)"
    printf "  │ 13 │ DeepSeek-R1-Distill-Qwen-14B         │ Q4   │ ~9GB │ [THINK] deep reasoning   │%s │\n" "$(_mark DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf)"
    printf "  │ 14 │ Gemma-3-27B (partial offload)        │ Q4   │~12GB │ [TOOLS] Google           │%s │\n" "$(_mark google_gemma-3-27b-it-Q4_K_M.gguf)"
    printf "  ├────┼──────────────────────────────────────┼──────┼──────┼──────────────────────────┼───┤\n"
    printf "  │    │ ── 16-24 GB VRAM ─────────────────── │      │      │                          │   │\n"
    printf "  │ 15 │ Mistral-Small-3.1-24B                │ Q4   │~14GB │ [TOOLS] [THINK] 128K ctx │%s │\n" "$(_mark Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf)"
    printf "  │ 16 │ Mistral-Small-3.2-24B                │ Q4   │~14GB │ ★ [TOOLS] [THINK] newest │%s │\n" "$(_mark Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf)"
    printf "  │ 17 │ Qwen3-30B-A3B  (MoE ★fast)          │ Q4   │~16GB │ ★ [TOOLS] [THINK] MoE    │%s │\n" "$(_mark Qwen3-30B-A3B-Q4_K_M.gguf)"
    printf "  │ 18 │ Qwen3-32B                            │ Q4   │~19GB │ ★ [TOOLS] [THINK]        │%s │\n" "$(_mark Qwen_Qwen3-32B-Q4_K_M.gguf)"
    printf "  │ 19 │ DeepSeek-R1-Distill-Qwen-32B         │ Q4   │~19GB │ [THINK] deep reasoning   │%s │\n" "$(_mark DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf)"
    printf "  │ 20 │ Gemma-3-27B                          │ Q4   │~16GB │ [TOOLS] Google           │%s │\n" "$(_mark google_gemma-3-27b-it-Q4_K_M.gguf)"
    printf "  │    │ ── 48 GB VRAM ────────────────────── │      │      │                          │   │\n"
    printf "  │ 21 │ Llama-3.3-70B                        │ Q4   │~40GB │ ★ [TOOLS] multi-GPU      │%s │\n" "$(_mark Llama-3.3-70B-Instruct-Q4_K_M.gguf)"
    printf "  └────┴──────────────────────────────────────┴──────┴──────┴──────────────────────────┴───┘\n"
    echo -e "  ${GREEN}✔ = already downloaded${NC}"
    echo ""
    echo -e "  ${YELLOW}MoE note (17):${NC} 30B total params, only 3B active per token → 30B quality, 8B speed."
    echo -e "  ${YELLOW}R1-0528 (7):${NC}  Updated May 2025 distill — significantly improved reasoning over original R1."
    echo -e "  ${CYAN}Tip:${NC} gpt-oss:20b (OpenAI open-weight, 16 GB, 140 t/s) is available via: llm-add"
    echo ""
    read -r -p "  Choice [1-21]: " manual_choice
    case "$manual_choice" in
        1)  M[name]="Qwen3-1.7B Q8_0";                            M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[size_gb]=2;  M[layers]=28; M[tier]="1.7B" ;;
        2)  M[name]="Qwen3-4B Q4_K_M";                            M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[size_gb]=3;  M[layers]=36; M[tier]="4B" ;;
        3)  M[name]="Phi-4-mini Q4_K_M";                          M[caps]="TOOLS + THINK"
            M[file]="microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
            M[size_gb]=3;  M[layers]=32; M[tier]="3.8B" ;;
        4)  M[name]="Qwen3-0.6B Q8_0";                            M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-0.6B-Q8_0.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen_Qwen3-0.6B-Q8_0.gguf"
            M[size_gb]=1;  M[layers]=28; M[tier]="0.6B" ;;
        5)  M[name]="Qwen3-8B Q4_K_M";                            M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=36; M[tier]="8B" ;;
        6)  M[name]="Qwen3-8B Q6_K";                              M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q6_K.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
            M[size_gb]=6;  M[layers]=36; M[tier]="8B" ;;
        7)  M[name]="DeepSeek-R1-0528-Qwen3-8B Q4_K_M";          M[caps]="THINK"
            M[file]="DeepSeek-R1-0528-Qwen3-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-0528-Qwen3-8B-GGUF/resolve/main/DeepSeek-R1-0528-Qwen3-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=36; M[tier]="8B" ;;
        8)  M[name]="Gemma-3-9B Q4_K_M";                          M[caps]="TOOLS"
            M[file]="google_gemma-3-9b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-9b-it-GGUF/resolve/main/google_gemma-3-9b-it-Q4_K_M.gguf"
            M[size_gb]=6;  M[layers]=42; M[tier]="9B" ;;
        9)  M[name]="Gemma-3-12B Q4_K_M";                         M[caps]="TOOLS"
            M[file]="google_gemma-3-12b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-12b-it-GGUF/resolve/main/google_gemma-3-12b-it-Q4_K_M.gguf"
            M[size_gb]=8;  M[layers]=46; M[tier]="12B" ;;
        10) M[name]="Dolphin3.0-Llama3.1-8B Q4_K_M";             M[caps]="UNCENS"
            M[file]="Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=32; M[tier]="8B" ;;
        11) M[name]="Phi-4-14B Q4_K_M";                           M[caps]="TOOLS + THINK"
            M[file]="phi-4-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        12) M[name]="Qwen3-14B Q4_K_M";                           M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        13) M[name]="DeepSeek-R1-Distill-Qwen-14B Q4_K_M";       M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        14) M[name]="Gemma-3-27B Q4_K_M";                         M[caps]="TOOLS"
            M[file]="google_gemma-3-27b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-27b-it-GGUF/resolve/main/google_gemma-3-27b-it-Q4_K_M.gguf"
            M[size_gb]=16; M[layers]=62; M[tier]="27B" ;;
        15) M[name]="Mistral-Small-3.1-24B Q4_K_M";               M[caps]="TOOLS + THINK"
            M[file]="mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.1-24B-Instruct-2503-GGUF/resolve/main/mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"
            M[size_gb]=14; M[layers]=40; M[tier]="24B" ;;
        16) M[name]="Mistral-Small-3.2-24B Q4_K_M";               M[caps]="TOOLS + THINK"
            M[file]="mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
            M[size_gb]=14; M[layers]=40; M[tier]="24B" ;;
        17) M[name]="Qwen3-30B-A3B Q4_K_M (MoE)";                M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
            M[size_gb]=18; M[layers]=48; M[tier]="30B-A3B (MoE)" ;;
        18) M[name]="Qwen3-32B Q4_K_M";                           M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        19) M[name]="DeepSeek-R1-Distill-Qwen-32B Q4_K_M";       M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        20) M[name]="Gemma-3-27B Q4_K_M";                         M[caps]="TOOLS"
            M[file]="google_gemma-3-27b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-27b-it-GGUF/resolve/main/google_gemma-3-27b-it-Q4_K_M.gguf"
            M[size_gb]=16; M[layers]=62; M[tier]="27B" ;;
        21) M[name]="Llama-3.3-70B-Instruct Q4_K_M";              M[caps]="TOOLS"
            M[file]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
            M[size_gb]=40; M[layers]=80; M[tier]="70B" ;;
        *)  warn "Invalid choice — keeping auto-selected model." ;;
    esac

    # Recalculate layers and batch for manually chosen model
    if (( HAS_GPU )); then
        GPU_LAYERS=$(gpu_layers_for "${M[size_gb]}" "${M[layers]}")
        CPU_LAYERS=$(( M[layers] - GPU_LAYERS ))
        (( CPU_LAYERS < 0 )) && CPU_LAYERS=0
    else
        GPU_LAYERS=0; CPU_LAYERS="${M[layers]}"
    fi
    if (( GPU_VRAM_GB >= 24 )); then  BATCH=2048
    elif (( GPU_VRAM_GB >= 16 )); then BATCH=1024
    elif (( GPU_VRAM_GB >= 8 ));  then BATCH=512
    elif (( GPU_VRAM_GB >= 4 ));  then BATCH=256
    else                               BATCH=128
    fi
fi  # end manual override block
MODEL_SIZE_GB="${M[size_gb]}"
if (( DISK_FREE_GB < MODEL_SIZE_GB + 2 )); then
    warn "Low disk space: ${DISK_FREE_GB} GB free, model needs ~${MODEL_SIZE_GB} GB."
    ask_yes_no "Continue anyway?" || error "Aborting — free up disk space and re-run."
fi

# =============================================================================
# STEP 3b — PYTHON INSTALLATION
# =============================================================================
step "Python environment"

# Ensure TEMP_DIR exists — used for venv test and get-pip.py bootstrap
mkdir -p "$TEMP_DIR"

# ── apt-get update first — this step needs packages before anything else ──────
info "Running apt-get update…"
sudo apt-get update -qq || warn "apt update returned non-zero."

# ── Detect current Python version ─────────────────────────────────────────────
PYVER_RAW=$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+' | head -n1 || echo "0.0")
PYVER_MAJOR=$(echo "$PYVER_RAW" | cut -d. -f1)
PYVER_MINOR=$(echo "$PYVER_RAW" | cut -d. -f2)
info "System Python: ${PYVER_RAW:-not found}"

PYTHON_BIN="python3"

# ── If Python < 3.10: install 3.11 via deadsnakes PPA ─────────────────────────
# llama-cpp-python pre-built wheels exist for 3.10/3.11/3.12.
# Ubuntu 20.04 ships 3.8 and needs an upgrade. 22.04→3.10, 24.04→3.12 are fine.
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
    command -v python3.11 &>/dev/null && PYTHON_BIN="python3.11" \
        && info "Using Python 3.11 for venv."
else
    info "Python $PYVER_RAW ✔ — meets 3.10+ requirement."
fi

# ── Refresh PYVER_* from the actual binary we will use ────────────────────────
# If we just installed python3.11 via deadsnakes, PYVER_MAJOR/MINOR still hold
# the old system python version (e.g. 3.8). The venv package install below uses
# these variables, so we must update them to match PYTHON_BIN.
_PYVER_REFRESH=$("$PYTHON_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -n1 || echo "$PYVER_RAW")
PYVER_MAJOR=$(echo "$_PYVER_REFRESH" | cut -d. -f1)
PYVER_MINOR=$(echo "$_PYVER_REFRESH" | cut -d. -f2)
unset _PYVER_REFRESH

# ── Install pip + venv for the detected version ───────────────────────────────
# On Ubuntu 24.04, python3-venv alone is not enough — python3.12-venv is needed.
# We install both the generic and version-specific packages to cover all cases.
info "Installing python3-pip, python3-venv, python${PYVER_MAJOR}.${PYVER_MINOR}-venv…"
sudo apt-get install -y \
    python3-pip \
    python3-venv \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-venv" \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-dev" \
    2>/dev/null \
    || warn "Some Python packages failed — will attempt to continue."

# If pip still not available, bootstrap it
if ! "$PYTHON_BIN" -m pip --version &>/dev/null 2>&1; then
    info "pip not found — bootstrapping via get-pip.py…"
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$TEMP_DIR/get-pip.py" \
        && "$PYTHON_BIN" "$TEMP_DIR/get-pip.py" --quiet \
        && rm -f "$TEMP_DIR/get-pip.py" \
        || warn "get-pip.py bootstrap failed — pip may be unavailable."
fi

# Upgrade pip to latest
"$PYTHON_BIN" -m pip install --upgrade pip --quiet 2>/dev/null \
    || warn "pip upgrade failed — using whatever version is installed."
PIP_VER=$("$PYTHON_BIN" -m pip --version 2>/dev/null | awk '{print $2}' || echo "unknown")
info "pip $PIP_VER ✔"

# ── Verify venv works before proceeding ───────────────────────────────────────
TEST_VENV="$TEMP_DIR/.test_venv_$$"
if "$PYTHON_BIN" -m venv "$TEST_VENV" 2>/dev/null; then
    rm -rf "$TEST_VENV"
    info "Python venv: OK  ($("$PYTHON_BIN" --version 2>&1))"
else
    # Last resort: try to install the venv module directly
    warn "venv test failed — trying to install python3-venv one more time…"
    sudo apt-get install -y "python${PYVER_MAJOR}.${PYVER_MINOR}-venv" python3-venv 2>/dev/null || true
    if ! "$PYTHON_BIN" -m venv "$TEST_VENV" 2>/dev/null; then
        error "Python venv creation still failing. Run manually: sudo apt-get install python${PYVER_MAJOR}.${PYVER_MINOR}-venv"
    fi
    rm -rf "$TEST_VENV"
    info "Python venv: OK after reinstall."
fi

export PYTHON_BIN

# =============================================================================
# STEP 4 — SYSTEM DEPENDENCIES
# =============================================================================
step "System dependencies"

# Note: apt-get update already ran in the Python environment step above

PKGS=(curl wget git build-essential cmake ninja-build python3 lsb-release zstd ffmpeg pciutils bat grc source-highlight)
(( HAS_AVX2 )) && PKGS+=(libopenblas-dev)   # AVX2 path for CPU layers

sudo apt-get install -y "${PKGS[@]}" || warn "Some packages may have failed."

for cmd in curl wget git python3; do
    command -v "$cmd" &>/dev/null || error "Critical dependency missing: $cmd"
done
# pip is accessed via python3 -m pip (no standalone pip3 on Ubuntu 24.04)
"$PYTHON_BIN" -m pip --version &>/dev/null || error "pip not available — check Python environment step above."
info "System dependencies OK."

# =============================================================================
# STEP 5 — DIRECTORIES + PATH
# =============================================================================
step "Directories"
mkdir -p "$OLLAMA_MODELS" "$GGUF_MODELS" "$TEMP_DIR" "$BIN_DIR" "$CONFIG_DIR" "$GUI_DIR"
mkdir -p "$HOME/work"
info "Coworking workspace: $HOME/work  (use: cd ~/work)"
info "Directories ready."

# PATH: $BIN_DIR baked in now; \$PATH expands when .bashrc is sourced.
if ! grep -q "# llm-auto-setup PATH" "$HOME/.bashrc" 2>/dev/null; then
    { printf '\n# llm-auto-setup PATH\n'
      printf '[[ ":$PATH:" != *":%s:"* ]] && export PATH="%s:$PATH"\n'           "$BIN_DIR" "$BIN_DIR"; } >> "$HOME/.bashrc"
    info "Added $BIN_DIR to PATH in ~/.bashrc"
fi
[[ ":$PATH:" != *":$BIN_DIR:"* ]] && export PATH="$BIN_DIR:$PATH"

# ── Terminal syntax highlighting (bat + grc) ──────────────────────────────────
if ! grep -q "# llm-bat-grc" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'BATGRC'

# ── Syntax highlighting — llm-auto-setup ──────────────────────────────────────
# bat: syntax-highlighted cat; fall back transparently if not installed
if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
    alias bat='batcat'
fi
if command -v bat &>/dev/null; then
    alias cat='bat --paging=never --style=plain'
    alias less='bat --paging=always'
    alias head='bat --paging=never --style=plain -n 20'
    alias tail='bat --paging=never --style=plain -n 20'
    export MANPAGER='sh -c "col -bx | bat --language=man --style=plain --paging=always"'
    # source-highlight: colorize less output (falls back silently if absent)
    export LESSOPEN="| src-hilite-lesspipe.sh %s" 2>/dev/null || true
fi
# grc: colorize common commands (gcc, make, diff, ping, ps, netstat, etc.)
if command -v grc &>/dev/null; then
    alias diff='grc diff'
    alias make='grc make'
    alias gcc='grc gcc'
    alias g++='grc g++'
    alias ping='grc ping'
    alias ps='grc ps'
    alias netstat='grc netstat'
fi
# llm-bat-grc
BATGRC
    info "Terminal syntax highlighting configured (bat + grc)."
fi

# =============================================================================
# STEP 6 — NVIDIA DRIVER CHECK
# =============================================================================
if (( HAS_NVIDIA )); then
    step "NVIDIA driver"
    info "GPU: $GPU_NAME | Driver: $DRIVER_VER | VRAM: ${GPU_VRAM_MIB} MiB"
elif (( HAS_AMD_GPU )); then
    step "AMD GPU detected"
    info "GPU: $GPU_NAME | VRAM: ${GPU_VRAM_MIB} MiB | Driver: $DRIVER_VER"
    [[ -n "$AMD_ROCM_VER" ]] && info "ROCm already present: $AMD_ROCM_VER"
else
    info "No discrete GPU found — running CPU-only mode."
fi

# =============================================================================
# STEP 7 — CUDA TOOLKIT (skip if no GPU)
# =============================================================================
if (( HAS_NVIDIA )); then
    step "CUDA toolkit"

    setup_cuda_env() {
            sudo ldconfig 2>/dev/null || true

        local lib_dir=""
        # Search for libcudart.so.12* (wildcard catches .12, .12.x, .12.x.y.z)
        # Also check the standard CUDA targets path which find sometimes misses at low depth
        while IFS= read -r -d '' p; do lib_dir="$(dirname "$p")"; break
        done < <(find /usr/local /usr/lib /opt \
                    -maxdepth 8 \
                    \( -name "libcudart.so.12" -o -name "libcudart.so.12.*" \) \
                    -print0 2>/dev/null)

        # Fallback: check ldconfig cache directly
        if [[ -z "$lib_dir" ]]; then
            local ldcache_path
            ldcache_path=$(ldconfig -p 2>/dev/null | grep 'libcudart\.so\.12' | awk '{print $NF}' | head -n1 || true)
            [[ -n "$ldcache_path" ]] && lib_dir="$(dirname "$ldcache_path")"
        fi

        if [[ -z "$lib_dir" ]]; then
            warn "libcudart.so.12 not found in filesystem or ldconfig cache."
            warn "  This usually means CUDA installed but ldconfig hasn't run yet."
            warn "  Try: sudo ldconfig && exec bash"
            return 1
        fi

        export LD_LIBRARY_PATH="$lib_dir:${LD_LIBRARY_PATH:-}"
        info "CUDA libs found at: $lib_dir"

        # Walk up to find the CUDA root (handles /usr/local/cuda-12.x/targets/arch/lib)
        local base_dir; base_dir="$(echo "$lib_dir" | sed 's|/targets/.*||; s|/lib[^/]*$||')"
        local bin_dir="$base_dir/bin"
        [[ -d "$bin_dir" ]] && { export PATH="$bin_dir:$PATH"; info "CUDA bin: $bin_dir"; }

        _RC="$HOME/.bashrc"
        ! grep -q "# CUDA toolkit — llm-auto-setup" "$_RC" 2>/dev/null && {
            { echo ""; echo "# CUDA toolkit — llm-auto-setup"
              [[ -d "$bin_dir" ]] && echo "export PATH=\"${bin_dir}:\$PATH\""
              echo "export LD_LIBRARY_PATH=\"${lib_dir}:\${LD_LIBRARY_PATH:-}\""; } >> "$_RC"; }
        return 0
    }

    # Three-probe CUDA detection (PATH → filesystem → ldconfig/dpkg)
    CUDA_PRESENT=0
    if ! command -v nvcc &>/dev/null; then
        NVCC_PATH=$(find /usr/local /usr/lib/cuda /opt/cuda -maxdepth 6 -name nvcc -type f 2>/dev/null | head -n1 || true)
        [[ -n "$NVCC_PATH" ]] && { export PATH="$(dirname "$NVCC_PATH"):$PATH"; info "nvcc at $NVCC_PATH"; }
    fi
    command -v nvcc &>/dev/null && CUDA_PRESENT=1
    if (( !CUDA_PRESENT )); then
        # Wildcard: catches libcudart.so.12, libcudart.so.12.x, libcudart.so.12.x.y.z
        find /usr/local /usr/lib /opt -maxdepth 8 \
            \( -name "libcudart.so.12" -o -name "libcudart.so.12.*" \) 2>/dev/null | grep -q . \
            && CUDA_PRESENT=1
    fi
    if (( !CUDA_PRESENT )); then
        ldconfig -p 2>/dev/null | grep -q 'libcudart\.so\.12' && CUDA_PRESENT=1
    fi
    if (( !CUDA_PRESENT )); then
        dpkg -l 'cuda-toolkit-*' 'cuda-libraries-*' 2>/dev/null | grep -q '^ii' && CUDA_PRESENT=1
    fi

    if (( CUDA_PRESENT )); then
        info "CUDA already installed: $(nvcc --version 2>/dev/null | grep release | head -n1 || echo 'present')"
        setup_cuda_env || true
    else
        info "Installing CUDA toolkit…"
        UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
        if [[ "$UBUNTU_VERSION" != "22.04" && "$UBUNTU_VERSION" != "24.04" ]]; then
            warn "Ubuntu $UBUNTU_VERSION not tested. Attempting anyway."
        fi
        KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION//./}/x86_64/cuda-keyring_1.1-1_all.deb"
        retry 3 5 wget -q -O "$TEMP_DIR/cuda-keyring.deb" "$KEYRING_URL" \
            || error "Failed to download CUDA keyring."
        sudo dpkg -i "$TEMP_DIR/cuda-keyring.deb" || true
        rm -f "$TEMP_DIR/cuda-keyring.deb"
        sudo apt-get update -qq || true
        CUDA_PKG=$(apt-cache search --names-only '^cuda-toolkit-12-' 2>/dev/null | awk '{print $1}' | sort -V | tail -n1 || true)
        [[ -z "$CUDA_PKG" ]] && CUDA_PKG="cuda-toolkit"
        sudo apt-get install -y "$CUDA_PKG" || warn "CUDA install returned non-zero."
        info "Running ldconfig to register CUDA libraries…"
        sudo ldconfig 2>/dev/null || true
        setup_cuda_env || true
    fi

    ldconfig -p 2>/dev/null | grep -q "libcudart.so.12" && info "libcudart.so.12 in ldconfig ✔"
fi

# =============================================================================
# STEP 7b — ROCm TOOLKIT (AMD GPU only)
# =============================================================================
if (( HAS_AMD_GPU && !HAS_NVIDIA )); then
    step "ROCm toolkit (AMD GPU)"

    setup_rocm_env() {
        # Add ROCm lib path to LD_LIBRARY_PATH and persist it
        local rocm_lib=""
        for _rp in /opt/rocm/lib /opt/rocm-*/lib /usr/lib/x86_64-linux-gnu; do
            if [[ -f "$_rp/libhipblas.so" || -f "$_rp/librocblas.so" ]]; then
                rocm_lib="$_rp"; break
            fi
        done
        [[ -z "$rocm_lib" ]] && rocm_lib="/opt/rocm/lib"   # best guess
        export LD_LIBRARY_PATH="$rocm_lib:${LD_LIBRARY_PATH:-}"
        export PATH="/opt/rocm/bin:$PATH"
        _RC="$HOME/.bashrc"
        ! grep -q "# ROCm — llm-auto-setup" "$_RC" 2>/dev/null && {
            # printf with single-quoted format: $PATH stays literal (expands at shell startup).
            # $rocm_lib expands now (we want the real path baked in).
            printf '\n# ROCm — llm-auto-setup\n' >> "$_RC"
            printf 'export PATH="/opt/rocm/bin:$PATH"\n' >> "$_RC"
            printf 'export LD_LIBRARY_PATH="%s:${LD_LIBRARY_PATH:-}"\n' "$rocm_lib" >> "$_RC"
        }
        info "ROCm env configured: $rocm_lib"
    }

    ROCM_PRESENT=0
    command -v rocminfo &>/dev/null && ROCM_PRESENT=1
    [[ -d /opt/rocm ]] && ROCM_PRESENT=1

    if (( ROCM_PRESENT )); then
        info "ROCm already installed."
        AMD_ROCM_VER=$(cat /opt/rocm/.info/version 2>/dev/null             || rocminfo 2>/dev/null | grep -oP 'Runtime Version: \K[0-9.]+' | head -n1             || echo "present")
        info "ROCm version: $AMD_ROCM_VER"
        setup_rocm_env
    else
        info "Installing ROCm via amdgpu-install…"
        UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
        # amdgpu-install is the official AMD installer — handles kernel modules + ROCm
        # Discover the current deb filename dynamically from the /latest/ directory listing
        # so we don't hardcode a version that may 404 after AMD ships a new release.
        AMDGPU_BASE="https://repo.radeon.com/amdgpu-install/latest/ubuntu/${UBUNTU_VERSION}/"
        AMDGPU_DEB=$(wget -qO- "$AMDGPU_BASE" 2>/dev/null             | grep -oP 'amdgpu-install_[^"]+_all\.deb' | tail -1             || echo "amdgpu-install_6.3.60300-1_all.deb")
        AMDGPU_DEB_URL="${AMDGPU_BASE}${AMDGPU_DEB}"
        info "AMD installer: $AMDGPU_DEB"
        if retry 3 10 wget -q -O "$TEMP_DIR/amdgpu-install.deb" "$AMDGPU_DEB_URL"; then
            sudo dpkg -i "$TEMP_DIR/amdgpu-install.deb" || true
            sudo apt-get update -qq || true
            rm -f "$TEMP_DIR/amdgpu-install.deb"
            # rocm metapackage includes HIP, hipBLAS, rocBLAS — everything llama.cpp needs
            sudo amdgpu-install --usecase=rocm --no-dkms -y                 || warn "amdgpu-install returned non-zero — ROCm may be partially installed."
            setup_rocm_env
        else
            warn "Failed to download amdgpu-install deb — trying manual apt path…"
            # Fallback: direct apt install of minimal ROCm components
            wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key 2>/dev/null                 | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/rocm.gpg || true
            echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/6.3 ${UBUNTU_VERSION} main"                 | sudo tee /etc/apt/sources.list.d/rocm.list >/dev/null
            sudo apt-get update -qq || true
            sudo apt-get install -y rocm-hip-sdk rocm-opencl-sdk                 || warn "ROCm apt install failed — check https://rocm.docs.amd.com"
            setup_rocm_env
        fi
        # Add current user to render + video groups (required for GPU access)
        sudo usermod -aG render,video "$USER" 2>/dev/null             && info "Added $USER to render+video groups (takes effect on next login)." || true
    fi

    # Verify HIP is usable
    if command -v hipconfig &>/dev/null; then
        info "HIP: $(hipconfig --version 2>/dev/null || echo 'present') ✔"
    else
        warn "hipconfig not found — ROCm may need a reboot to fully activate."
    fi
fi

# =============================================================================
# STEP 8 — PYTHON VENV
# =============================================================================
step "Python virtual environment"

[[ ! -d "$VENV_DIR" ]] && "${PYTHON_BIN:-python3}" -m venv "$VENV_DIR" || true
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate" || error "Failed to activate venv."
[[ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]] && error "Venv activation failed."
info "Venv: $VIRTUAL_ENV"
pip install --upgrade pip setuptools wheel --quiet || true

# =============================================================================
# STEP 9 — LLAMA-CPP-PYTHON
# =============================================================================
step "llama-cpp-python"

check_python_module() { "$VENV_DIR/bin/python3" -c "import $1" 2>/dev/null; }

# Build flags tuned to detected CPU features
CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release"
(( HAS_NVIDIA ))  && CMAKE_ARGS+=" -DGGML_CUDA=ON -DLLAMA_CUBLAS=ON"
(( HAS_AVX512 ))  && CMAKE_ARGS+=" -DGGML_AVX512=ON -DGGML_AVX2=ON -DGGML_FMA=ON"
(( !HAS_AVX512 && HAS_AVX2 )) && CMAKE_ARGS+=" -DGGML_AVX2=ON -DGGML_FMA=ON"
(( !HAS_AVX2 && HAS_AVX )) && CMAKE_ARGS+=" -DGGML_AVX=ON"
(( HAS_NEON ))              && CMAKE_ARGS+=" -DGGML_NEON=ON"
export SOURCE_BUILD_CMAKE_ARGS="$CMAKE_ARGS"

LLAMA_INSTALLED=0

# ── NVIDIA CUDA wheels ────────────────────────────────────────────────────────
if (( HAS_NVIDIA )); then
    CUDA_VER=""
    CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -n1 || true)
    [[ -z "$CUDA_VER" ]] && CUDA_VER="$CUDA_VER_SMI"
    [[ -z "$CUDA_VER" ]] && CUDA_VER="12.1"
    CUDA_TAG="cu$(echo "$CUDA_VER" | tr -d '.')"
    info "CUDA $CUDA_VER → wheel tag $CUDA_TAG"
    for wheel_url in \
        "https://abetlen.github.io/llama-cpp-python/whl/${CUDA_TAG}" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu124" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu122" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu121"; do
        info "Trying CUDA wheel: $wheel_url"
        pip install llama-cpp-python \
            --index-url "$wheel_url" \
            --extra-index-url https://pypi.org/simple \
            --quiet 2>&1 && { info "CUDA wheel installed from $wheel_url"; LLAMA_INSTALLED=1; break; } \
            || warn "Failed — trying next."
    done
fi

# ── AMD ROCm/HIP wheels ───────────────────────────────────────────────────────
if (( HAS_AMD_GPU && !HAS_NVIDIA && LLAMA_INSTALLED == 0 )); then
    info "Trying ROCm pre-built wheels for llama-cpp-python…"
    for wheel_url in \
        "https://abetlen.github.io/llama-cpp-python/whl/rocm600" \
        "https://abetlen.github.io/llama-cpp-python/whl/rocm550"; do
        info "Trying ROCm wheel: $wheel_url"
        pip install llama-cpp-python \
            --index-url "$wheel_url" \
            --extra-index-url https://pypi.org/simple \
            --quiet 2>&1 && { info "ROCm wheel installed from $wheel_url"; LLAMA_INSTALLED=1; break; } \
            || warn "Failed — trying next."
    done
fi

# ── Source build fallback ─────────────────────────────────────────────────────
if (( LLAMA_INSTALLED == 0 )); then
    if (( HAS_NVIDIA )); then
        warn "No pre-built CUDA wheel found — building from source (~5 min)…"
        MAKE_JOBS="$HW_THREADS" CMAKE_ARGS="$SOURCE_BUILD_CMAKE_ARGS" \
        pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python CUDA build failed. Check logs."
    elif (( HAS_AMD_GPU )); then
        warn "No pre-built ROCm wheel found — building from source (~8 min)…"
        # GGML_HIPBLAS=ON enables ROCm GPU offload in llama.cpp
        MAKE_JOBS="$HW_THREADS" \
        CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DGGML_HIPBLAS=ON" \
        pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python ROCm build failed. Check logs."
    else
        info "CPU-only build — compiling llama-cpp-python (~3 min)…"
        MAKE_JOBS="$HW_THREADS" CMAKE_ARGS="$SOURCE_BUILD_CMAKE_ARGS" \
        pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python CPU build failed. Check logs."
    fi
fi

if check_python_module llama_cpp; then info "llama-cpp-python ✔"
else warn "llama-cpp-python import failed — check CUDA paths."; fi

# =============================================================================
# STEP 10 — OLLAMA
# =============================================================================
step "Ollama"

if ! command -v ollama &>/dev/null; then
    info "Installing Ollama…"
    retry 3 10 bash -c "curl -fsSL https://ollama.com/install.sh | sh" </dev/null \
        || error "Ollama install failed."
else
    info "Ollama: $(ollama --version 2>/dev/null || echo 'already installed')"
fi

# Tune Ollama concurrency to detected RAM
OLLAMA_PARALLEL=1
(( TOTAL_RAM_GB >= 32 )) && OLLAMA_PARALLEL=2

if is_wsl2; then
    cat > "$BIN_DIR/ollama-start" <<OLSTART
#!/usr/bin/env bash
export OLLAMA_MODELS="$OLLAMA_MODELS"
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_NUM_PARALLEL=$OLLAMA_PARALLEL
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_NUM_THREAD=$HW_THREADS
export OLLAMA_ORIGINS="*"
# ── GPU maximisation ──────────────────────────────────────────────────────────
# Flash attention halves KV-cache VRAM usage → more room for model layers on GPU
export OLLAMA_FLASH_ATTENTION=1
# Quantise the KV-cache to q8_0 — further reduces VRAM with negligible quality loss
# (q4_0 saves even more if you run very long contexts)
export OLLAMA_KV_CACHE_TYPE=q8_0
# ── AMD ROCm GPU vars (no-op on NVIDIA systems) ───────────────────────────────
# HSA_OVERRIDE_GFX_VERSION: needed for some RDNA2/3 cards not yet in ROCm whitelist
# ROCR_VISIBLE_DEVICES=0:  use first AMD GPU (safe default for single-GPU setups)
# Only set HSA_OVERRIDE_GFX_VERSION if user pre-defined it (e.g. for RX 6000/7000 whitelist bypass)
# Exporting it empty causes ROCm to treat it as unrecognised, which is worse than absent.
[[ -n "\${HSA_OVERRIDE_GFX_VERSION:-}" ]] && export HSA_OVERRIDE_GFX_VERSION
export ROCR_VISIBLE_DEVICES=\${ROCR_VISIBLE_DEVICES:-0}
pgrep -f "ollama serve" >/dev/null 2>&1 && { echo "Ollama already running."; exit 0; }
echo "Starting Ollama…"
nohup ollama serve >"\$HOME/.ollama.log" 2>&1 &
sleep 3
pgrep -f "ollama serve" >/dev/null 2>&1 && echo "Ollama started." || { echo "ERROR: Ollama failed to start. Check: cat ~/.ollama.log"; exit 1; }
OLSTART
    chmod +x "$BIN_DIR/ollama-start"
    "$BIN_DIR/ollama-start" || warn "Ollama launcher returned non-zero."
else
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

    # Write ollama-start wrapper for native Linux too (used by llm-chat launcher)
    cat > "$BIN_DIR/ollama-start" <<OLSTART_NATIVE
#!/usr/bin/env bash
if systemctl is-active --quiet ollama 2>/dev/null; then
    echo "Ollama service already running."
else
    echo "Starting Ollama service…"
    sudo systemctl start ollama || { echo "ERROR: sudo systemctl start ollama failed."; exit 1; }
    sleep 2
    systemctl is-active --quiet ollama && echo "Ollama started." || echo "WARNING: check: sudo journalctl -u ollama -n 30"
fi
OLSTART_NATIVE
    chmod +x "$BIN_DIR/ollama-start"
fi

sleep 3
if is_wsl2; then
    pgrep -f "ollama serve" >/dev/null 2>&1 && info "Ollama running." || warn "Ollama not running."
else
    systemctl is-active --quiet ollama && info "Ollama service active." || warn "Ollama service not active."
fi

# =============================================================================
# STEP 11 — SAVE CONFIG + DOWNLOAD MODEL
# =============================================================================
step "Model download"

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
EOF
info "Config saved: $MODEL_CONFIG"

if ask_yes_no "Download ${M[name]} (~${M[size_gb]} GB) now?"; then
    info "Downloading ${M[file]} → $GGUF_MODELS"
    pushd "$GGUF_MODELS" >/dev/null

    DL_OK=0
    if command -v curl &>/dev/null; then
        retry 3 20 curl -L --fail -C - --progress-bar \
            -o "${M[file]}" "${M[url]}" \
            && DL_OK=1 || warn "curl download failed."
    fi
    if [[ "$DL_OK" -eq 0 ]] && command -v wget &>/dev/null; then
        retry 3 20 wget --tries=1 --show-progress -c \
            -O "${M[file]}" "${M[url]}" \
            && DL_OK=1 || warn "wget download also failed."
    fi

    if [[ "$DL_OK" -eq 1 && -f "${M[file]}" ]]; then
        info "Download complete: $(du -h "${M[file]}" | cut -f1)"

        # ── Register GGUF with Ollama ─────────────────────────────────────────
        # Register GGUF with Ollama so it appears in Neural Terminal and any Ollama UI.
        if command -v ollama &>/dev/null; then
            # Derive a clean Ollama model tag from the filename.
            # Ollama requires lowercase tags. We separate the quant suffix with ':'
            # e.g. Qwen_Qwen3-8B-Q4_K_M.gguf → qwen_qwen3-8b:q4_k_m
            # sed: case-insensitive match on -Q or -q followed by digit → replace hyphen with colon
            OLLAMA_TAG=$(basename "${M[file]}" .gguf                 | sed -E 's/-([Qq][0-9].*)$/:\1/'                 | tr '[:upper:]' '[:lower:]')

            info "Registering model with Ollama as: $OLLAMA_TAG"
            info "  This lets Neural Terminal, Open WebUI, and 'ollama run' use it."

            MODELFILE_PATH="$TEMP_DIR/Modelfile.$$"
            mkdir -p "$TEMP_DIR"
            cat > "$MODELFILE_PATH" <<MODELFILE
FROM $GGUF_MODELS/${M[file]}
PARAMETER num_thread $HW_THREADS
PARAMETER num_ctx 8192
MODELFILE

            if ollama create "$OLLAMA_TAG" -f "$MODELFILE_PATH"; then
                info "✔ Model registered: $OLLAMA_TAG"
                info "  Now available in llm-chat / Open WebUI. Run: ollama run $OLLAMA_TAG"
                # Save tag to config so other tools can reference it
                echo "OLLAMA_TAG=\"$OLLAMA_TAG\"" >> "$MODEL_CONFIG"
            else
                warn "ollama create failed — model won't appear in Neural Terminal or Open WebUI."
                warn "  To register manually:"
                warn "    ollama create $OLLAMA_TAG -f $MODELFILE_PATH"
            fi
            rm -f "$MODELFILE_PATH"
        else
            warn "Ollama not found — skipping model registration."
            warn "  Install Ollama first, then run:"
            warn "    ollama create my-model -f <(echo 'FROM $GGUF_MODELS/${M[file]}')"
        fi
    else
        warn "Download failed. Resume with:"
        warn "  curl -L -C - -o '$GGUF_MODELS/${M[file]}' '${M[url]}'"
    fi
    popd >/dev/null
fi

# ── Ensure OLLAMA_TAG is always in config ─────────────────────────────────────
# If the user skipped the download, OLLAMA_TAG was never derived or written.
# Derive it from the filename now so cowork / aider / llm-switch always have it.
if ! grep -q "^OLLAMA_TAG=" "$MODEL_CONFIG" 2>/dev/null; then
    _derived_tag=$(basename "${M[file]}" .gguf                    | sed -E 's/-([Qq][0-9].*)$/:\1/'                    | tr '[:upper:]' '[:lower:]')
    echo "OLLAMA_TAG=\"$_derived_tag\"" >> "$MODEL_CONFIG"
    info "OLLAMA_TAG saved to config: $_derived_tag"
fi

# =============================================================================
# STEP 12 — HELPER SCRIPTS
# =============================================================================
step "Helper scripts"

# run-gguf: uses hardware-tuned defaults from config
cat > "$BIN_DIR/run-gguf" <<PYEOF
#!/usr/bin/env python3
"""Run a local GGUF model. Defaults loaded from ~/.config/local-llm/selected_model.conf"""
import sys, os, glob, argparse

MODEL_DIR  = os.path.expanduser("~/local-llm-models/gguf")
CONFIG_DIR = os.path.expanduser("~/.config/local-llm")
VENV_SITE  = os.path.expanduser("~/.local/share/llm-venv/lib")

for _sp in glob.glob(os.path.join(VENV_SITE, "python3*/site-packages")):
    if _sp not in sys.path: sys.path.insert(0, _sp)

def load_conf():
    cfg = {}
    p = os.path.join(CONFIG_DIR, "selected_model.conf")
    if os.path.exists(p):
        with open(p) as f:
            for line in f:
                line = line.strip()
                if '=' in line:
                    k, v = line.split('=', 1)
                    cfg[k] = v.strip('"')
    return cfg

def list_models():
    models = glob.glob(os.path.join(MODEL_DIR, "*.gguf"))
    if not models: print("No GGUF models in", MODEL_DIR); return
    print("Available models:")
    for m in sorted(models):
        print(f"  {os.path.basename(m):<55} {os.path.getsize(m)/1024**3:.1f} GB")

def main():
    cfg = load_conf()
    parser = argparse.ArgumentParser(description="Run a GGUF model (auto-tuned to your hardware)")
    parser.add_argument("model",  nargs="?")
    parser.add_argument("prompt", nargs="*")
    parser.add_argument("--gpu-layers", type=int,   default=None)
    parser.add_argument("--cpu-layers", type=int,   default=None)
    parser.add_argument("--ctx",        type=int,   default=8192)
    parser.add_argument("--max-tokens", type=int,   default=512)
    parser.add_argument("--threads",    type=int,   default=int(cfg.get("HW_THREADS", 4)))
    parser.add_argument("--batch",      type=int,   default=int(cfg.get("BATCH", 256)))
    args = parser.parse_args()

    if not args.model: list_models(); sys.exit(0)

    model_path = args.model if os.path.isabs(args.model) else os.path.join(MODEL_DIR, args.model)
    if not os.path.exists(model_path):
        print(f"Not found: {model_path}"); list_models(); sys.exit(1)

    prompt     = " ".join(args.prompt) if args.prompt else "Hello! How are you?"
    gpu_layers = args.gpu_layers if args.gpu_layers is not None else int(cfg.get("GPU_LAYERS", 0))
    cpu_layers = args.cpu_layers if args.cpu_layers is not None else int(cfg.get("CPU_LAYERS", 32))

    try:
        from llama_cpp import Llama
        print(f"Loading {os.path.basename(model_path)} | GPU:{gpu_layers} CPU:{cpu_layers} "
              f"threads:{args.threads} batch:{args.batch} ctx:{args.ctx}", flush=True)
        llm = Llama(model_path=model_path, n_gpu_layers=gpu_layers,
                    n_threads=args.threads, n_batch=args.batch,
                    verbose=False, n_ctx=args.ctx)
        out = llm(prompt, max_tokens=args.max_tokens, echo=True, temperature=0.7, top_p=0.95)
        print(out["choices"][0]["text"])
    except ImportError:
        print("ERROR: activate venv first: source ~/.local/share/llm-venv/bin/activate")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)

if __name__ == "__main__": main()
PYEOF
chmod +x "$BIN_DIR/run-gguf"

cat > "$BIN_DIR/local-models-info" <<'INFOEOF'
#!/usr/bin/env bash
echo "=== Ollama Models ==="; ollama list 2>/dev/null || echo "  (Ollama not running)"
echo ""; echo "=== GGUF Models ==="
shopt -s nullglob; files=(~/local-llm-models/gguf/*.gguf)
if [[ ${#files[@]} -eq 0 ]]; then echo "  (none)"
else for f in "${files[@]}"; do printf "  %-55s %s\n" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null|cut -f1)"; done; fi
echo ""; echo "=== Disk ==="
du -sh ~/local-llm-models 2>/dev/null || echo "  (no models dir)"
if [[ -f ~/.config/local-llm/selected_model.conf ]]; then
    echo ""; echo "=== Active Config ==="
    # Read individual keys — do NOT source (avoids polluting env with BATCH etc.)
    _cfg=~/.config/local-llm/selected_model.conf
    _cfgread() { grep "^${1}=" "$_cfg" 2>/dev/null | head -1 | cut -d'"' -f2; }
    echo "  Model:      $(_cfgread MODEL_NAME)  ($(_cfgread MODEL_SIZE))"
    echo "  GPU layers: $(_cfgread GPU_LAYERS)  CPU layers: $(_cfgread CPU_LAYERS)"
    echo "  Threads:    $(_cfgread HW_THREADS)  Batch: $(_cfgread BATCH)"
    echo "  Ollama tag: $(_cfgread OLLAMA_TAG)"
    echo "  File:       $(_cfgread MODEL_FILENAME)"
fi
INFOEOF
chmod +x "$BIN_DIR/local-models-info"

# ── llm-stop ──────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-stop" <<'STOP_EOF'
#!/usr/bin/env bash
# llm-stop — stop Ollama and Open WebUI if running
_is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

echo "Stopping local LLM services…"

# ── Ollama ────────────────────────────────────────────────────────────────────
if _is_wsl2 || ! systemctl is-active --quiet ollama 2>/dev/null; then
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        pkill -f "ollama serve" 2>/dev/null && echo "✔ Ollama stopped." || echo "Could not stop Ollama."
    else
        echo "  Ollama: not running."
    fi
else
    sudo systemctl stop ollama && echo "✔ Ollama service stopped." || echo "Could not stop Ollama service."
fi

# ── Open WebUI (optional) ─────────────────────────────────────────────────────
if pgrep -f "open-webui" >/dev/null 2>&1; then
    pkill -f "open-webui" 2>/dev/null && echo "✔ Open WebUI stopped." || true
fi
STOP_EOF
chmod +x "$BIN_DIR/llm-stop"

# ── llm-update ────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-update" <<'UPDATE_EOF'
#!/usr/bin/env bash
# llm-update — upgrade Ollama, Open WebUI (if installed), and pull latest model
set -uo pipefail

CONFIG="$HOME/.config/local-llm/selected_model.conf"
OWUI_VENV="$HOME/.local/share/open-webui-venv"

echo ""
echo "═══════════════  LLM Stack Updater  ═══════════════"
echo ""

echo "[ 1/3 ] Updating Ollama…"
curl -fsSL https://ollama.com/install.sh | sh \
    && echo "  ✔ Ollama: $(ollama --version 2>/dev/null || echo ok)" \
    || echo "  ✘ Ollama update failed."

echo ""
echo "[ 2/3 ] Updating Open WebUI (if installed)…"
if [[ -d "$OWUI_VENV" ]]; then
    OLD_VER=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?")
    "$OWUI_VENV/bin/pip" install --upgrade open-webui --quiet \
        && NEW_VER=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?") \
        && echo "  ✔ Open WebUI: $OLD_VER → $NEW_VER" \
        || echo "  ✘ Open WebUI update failed."
else
    echo "  Open WebUI not installed (optional tool, install via optional tools step)."
fi

echo ""
echo "[ 3/3 ] Pulling latest model tag…"
OLLAMA_TAG=""
[[ -f "$CONFIG" ]] && OLLAMA_TAG=$(grep "^OLLAMA_TAG=" "$CONFIG" | head -1 | cut -d'"' -f2)
if [[ -n "$OLLAMA_TAG" ]]; then
    # Ensure Ollama is running for the pull
    if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        echo "  Starting Ollama for model pull…"
        if grep -qi microsoft /proc/version 2>/dev/null; then
            command -v ollama-start &>/dev/null && ollama-start || nohup ollama serve >/dev/null 2>&1 &
        else
            sudo systemctl start ollama 2>/dev/null || nohup ollama serve >/dev/null 2>&1 &
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
echo "Done. Restart with: ollama-start && webui"
echo ""
UPDATE_EOF
chmod +x "$BIN_DIR/llm-update"

# ── llm-switch ────────────────────────────────────────────────────────────────
# Re-runs just the model picker + layer calculation, no full reinstall
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

# ── Show current model ────────────────────────────────────────────────────────
if [[ -f "$CONFIG" ]]; then
    _cur=$(grep "^MODEL_NAME=" "$CONFIG" | cut -d'"' -f2)
    _tag=$(grep "^OLLAMA_TAG=" "$CONFIG" | cut -d'"' -f2)
    echo "  Current: $_cur  [$_tag]"
fi
echo ""

# ── Ensure Ollama is running so 'ollama list' works ───────────────────────────
if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "  Ollama not running — starting it…"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        command -v ollama-start &>/dev/null && ollama-start || nohup ollama serve >/dev/null 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null || nohup ollama serve >/dev/null 2>&1 &
    fi
    for i in {1..10}; do
        curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
        sleep 1
    done
fi

# ── Build picker from what's actually registered in Ollama ───────────────────
echo "  Available Ollama models:"
mapfile -t TAGS < <(ollama list 2>/dev/null | awk 'NR>1{print $1}')
if [[ ${#TAGS[@]} -eq 0 ]]; then
    echo "  (none — download a model first: ollama pull qwen3:8b)"
    echo "  Or re-run the setup script to download the auto-selected model."
    exit 0
fi
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

# ── Update config ─────────────────────────────────────────────────────────────
if [[ -f "$CONFIG" ]]; then
    # Replace OLLAMA_TAG line (or append if missing)
    if grep -q "^OLLAMA_TAG=" "$CONFIG"; then
        sed -i "s|^OLLAMA_TAG=.*|OLLAMA_TAG=\"$NEW_TAG\"|" "$CONFIG"
    else
        echo "OLLAMA_TAG=\"$NEW_TAG\"" >> "$CONFIG"
    fi
    # Also update MODEL_NAME for display purposes
    sed -i "s|^MODEL_NAME=.*|MODEL_NAME=\"$NEW_TAG\"|" "$CONFIG"
fi

echo ""
echo "  ✔ Switched to: $NEW_TAG"
echo "  Run: ollama-run $NEW_TAG   or   webui   to start chatting."
echo ""
SWITCH_EOF
chmod +x "$BIN_DIR/llm-switch"

# ── llm-add ────────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-add" <<'ADD_EOF'
#!/usr/bin/env bash
# llm-add — download additional models with hardware-filtered picker
# Detects your VRAM/RAM and shows only models that actually fit.
set -uo pipefail

CONFIG="$HOME/.config/local-llm/selected_model.conf"
GGUF_DIR="$HOME/local-llm-models/gguf"
TEMP_DIR="$HOME/local-llm-models/temp"
BIN_DIR_="$HOME/.local/bin"
mkdir -p "$GGUF_DIR" "$TEMP_DIR"

# ── Detect hardware at runtime ────────────────────────────────────────────────
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
echo "═══════════════════════════════════════════════════════════════════"
echo "  LLM Model Downloader"
if [[ $GPU_VRAM_GB -gt 0 ]]; then
    printf "  Hardware: GPU %d GB VRAM   RAM %d GB\n" "$GPU_VRAM_GB" "$TOTAL_RAM_GB"
else
    printf "  Hardware: CPU-only   RAM %d GB\n" "$TOTAL_RAM_GB"
fi
echo "═══════════════════════════════════════════════════════════════════"

# ── Model catalog ─────────────────────────────────────────────────────────────
# Format: "display_name|quant|vram_gb|caps|file_gb|layers|filename|hf_path"
# hf_path = repo/resolve/main/filename (after bartowski/)
declare -a _CATALOG=(
    "Qwen3-1.7B|Q8_0|0|TOOLS+THINK|2|28|Qwen_Qwen3-1.7B-Q8_0.gguf|Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
    "Phi-4-mini 3.8B|Q4_K_M|0|TOOLS+THINK|3|32|microsoft_Phi-4-mini-instruct-Q4_K_M.gguf|microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
    "Qwen3-4B|Q4_K_M|3|TOOLS+THINK|3|36|Qwen_Qwen3-4B-Q4_K_M.gguf|Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
    "Qwen3-8B|Q4_K_M|5|TOOLS+THINK|5|36|Qwen_Qwen3-8B-Q4_K_M.gguf|Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
    "Qwen3-8B|Q6_K|6|TOOLS+THINK|6|36|Qwen_Qwen3-8B-Q6_K.gguf|Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
    "DeepSeek-R1-0528-8B ★|Q4_K_M|5|THINK|5|36|DeepSeek-R1-0528-Qwen3-8B-Q4_K_M.gguf|DeepSeek-R1-0528-Qwen3-8B-GGUF/resolve/main/DeepSeek-R1-0528-Qwen3-8B-Q4_K_M.gguf"
    "Dolphin3.0-8B|Q4_K_M|5|UNCENS|5|32|Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf|Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
    "Dolphin3.0-8B|Q6_K|6|UNCENS|6|32|Dolphin3.0-Llama3.1-8B-Q6_K.gguf|Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q6_K.gguf"
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
    echo "  Legend: [TOOLS] function calling   [THINK] reasoning   [UNCENS] uncensored   ★ best pick"
    echo ""
    echo "  ┌────┬──────────────────────────────┬──────┬────────┬──────────────────┐"
    echo "  │ #  │ Model                        │ Quant│  VRAM  │ Capabilities     │"
    echo "  ├────┼──────────────────────────────┼──────┼────────┼──────────────────┤"
    local row=0
    declare -a _VISIBLE_I=()
    for entry in "${_CATALOG[@]}"; do
        row=$(( row + 1 ))
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
            _VISIBLE_I+=("$row")
        fi
    done
    echo "  └────┴──────────────────────────────┴──────┴────────┴──────────────────┘"
    echo ""
    printf "  Showing %d/%d models that fit your hardware. " "${#_VISIBLE_I[@]}" "${#_CATALOG[@]}"
    [[ $show_all -eq 0 ]] && echo "Type 'all' to see everything." || echo ""
    echo ""
}

_SHOW_ALL=0
_show_table 0

while true; do
    read -r -p "  Choice (number, 'all', or Enter to cancel): " _choice
    [[ -z "$_choice" ]] && echo "Cancelled." && exit 0
    if [[ "$_choice" == "all" ]]; then
        _SHOW_ALL=1
        _show_table 1
        continue
    fi
    if ! [[ "$_choice" =~ ^[0-9]+$ ]] || (( _choice < 1 || _choice > ${#_CATALOG[@]} )); then
        echo "  Invalid — enter a number between 1 and ${#_CATALOG[@]}."
        continue
    fi
    break
done

# Extract chosen model fields
IFS='|' read -r M_NAME M_QUANT M_VRAM M_CAPS M_FGB M_LAYERS M_FILE M_PATH \
    <<< "${_CATALOG[$(( _choice - 1 ))]}"
M_URL="https://huggingface.co/bartowski/${M_PATH}"

echo ""
echo "  Selected: $M_NAME $M_QUANT  (~${M_FGB} GB)"
echo "  URL:      $M_URL"
echo ""

if [[ -f "$GGUF_DIR/$M_FILE" ]]; then
    echo "  File already exists: $(du -sh "$GGUF_DIR/$M_FILE" | cut -f1)"
    read -r -p "  Re-download? (y/N) " _yn; echo
    [[ ! "$_yn" =~ ^[Yy]$ ]] && echo "  Skipping download." || _DO_DL=1
else
    _DO_DL=1
fi

if [[ "${_DO_DL:-0}" -eq 1 ]]; then
    echo "  Downloading — this may take a while…"
    pushd "$GGUF_DIR" >/dev/null
    DL_OK=0
    command -v curl &>/dev/null && \
        curl -L --fail -C - --progress-bar -o "$M_FILE" "$M_URL" && DL_OK=1 || true
    [[ $DL_OK -eq 0 ]] && command -v wget &>/dev/null && \
        wget --tries=1 --show-progress -c -O "$M_FILE" "$M_URL" && DL_OK=1 || true
    if [[ $DL_OK -eq 1 ]]; then
        echo "  ✔ Downloaded: $(du -sh "$M_FILE" | cut -f1)"
    else
        echo "  ✘ Download failed. Try manually:"
        echo "    curl -L -C - -o '$GGUF_DIR/$M_FILE' '$M_URL'"
        popd >/dev/null; exit 1
    fi
    popd >/dev/null
fi

# ── Register with Ollama ──────────────────────────────────────────────────────
if command -v ollama &>/dev/null; then
    OLLAMA_TAG=$(basename "$M_FILE" .gguf \
                 | sed -E 's/-([Qq][0-9].*)$/:\1/' \
                 | tr '[:upper:]' '[:lower:]')
    echo "  Registering with Ollama as: $OLLAMA_TAG"
    _MF="$TEMP_DIR/Modelfile.llm-add.$$"
    cat > "$_MF" << MODELFILE_ADD
FROM $GGUF_DIR/$M_FILE
PARAMETER num_gpu 999
PARAMETER num_thread $HW_THREADS
PARAMETER num_ctx 8192
MODELFILE_ADD
    if ollama create "$OLLAMA_TAG" -f "$_MF"; then
        echo "  ✔ Registered: $OLLAMA_TAG"
        rm -f "$_MF"
    else
        echo "  ✘ ollama create failed. Is Ollama running?  Try: ollama-start"
        rm -f "$_MF"
    fi
else
    OLLAMA_TAG=""
    echo "  Ollama not found — model file saved but not registered."
fi

# ── Optionally set as active model ────────────────────────────────────────────
echo ""
read -r -p "  Set '$M_NAME $M_QUANT' as your active default model? (y/N) " _sw; echo
if [[ "$_sw" =~ ^[Yy]$ ]]; then
    if [[ -f "$CONFIG" ]]; then
        sed -i "s|^MODEL_NAME=.*|MODEL_NAME=\"$M_NAME $M_QUANT\"|" "$CONFIG"
        sed -i "s|^MODEL_FILENAME=.*|MODEL_FILENAME=\"$M_FILE\"|" "$CONFIG"
        [[ -n "${OLLAMA_TAG:-}" ]] && \
            sed -i "s|^OLLAMA_TAG=.*|OLLAMA_TAG=\"$OLLAMA_TAG\"|" "$CONFIG"
    fi
    echo "  ✔ Active model updated."
fi

echo ""
if [[ -n "${OLLAMA_TAG:-}" ]]; then
    echo "  Done. Run: ollama-run $OLLAMA_TAG"
else
    echo "  Done. Model saved to: $GGUF_DIR/$M_FILE"
    echo "  Install Ollama to register it: https://ollama.com"
fi
echo ""
ADD_EOF
chmod +x "$BIN_DIR/llm-add"

info "Helper scripts written."

# =============================================================================
# STEP 13 — WEB UI
# =============================================================================
step "Web UI"

# Standalone HTML chat UI (zero dependencies — just open in browser)
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
  --bg:#080b0f;--bg2:#0d1117;--bg3:#111820;--bg4:#151e28;
  --border:#1a2535;--border2:#243040;
  --green:#00ff88;--green-dim:#00aa55;--green-dark:#003322;
  --cyan:#00d4ff;--amber:#ffaa00;--red:#ff4455;--purple:#b060ff;
  --text:#b8c8d8;--text-dim:#4a6070;--text-bright:#d8eaf8;
  --glow:0 0 20px rgba(0,255,136,0.25);--glow-sm:0 0 8px rgba(0,255,136,0.15);
  --sidebar:260px;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:14px;overflow:hidden}
body::before{content:'';position:fixed;inset:0;background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,0,0,0.06) 2px,rgba(0,0,0,0.06) 4px);pointer-events:none;z-index:9999}

/* ── Layout ────────────────────────────────────────────────────────── */
#shell{display:flex;height:100vh;overflow:hidden}

/* ── LEFT SIDEBAR — sessions ───────────────────────────────────────── */
#sidebar{
  width:var(--sidebar);min-width:var(--sidebar);
  background:var(--bg2);border-right:1px solid var(--border);
  display:flex;flex-direction:column;overflow:hidden;
  transition:width .2s;
}
#sidebar.collapsed{width:0;min-width:0;border:none}
#sidebar-header{
  padding:14px 12px 10px;border-bottom:1px solid var(--border);
  display:flex;align-items:center;justify-content:space-between;
  gap:8px;flex-shrink:0;
}
.logo{font-family:'Orbitron',monospace;font-size:14px;font-weight:900;letter-spacing:3px;color:var(--green);text-shadow:var(--glow);white-space:nowrap}
.logo span{color:var(--cyan)}
#new-chat-btn{
  background:var(--green-dark);border:1px solid var(--green-dim);color:var(--green);
  font-family:'JetBrains Mono',monospace;font-size:11px;padding:5px 9px;border-radius:4px;
  cursor:pointer;white-space:nowrap;transition:all .15s;letter-spacing:1px;
}
#new-chat-btn:hover{background:#004422;box-shadow:var(--glow-sm)}
#session-list{flex:1;overflow-y:auto;padding:8px 0;scrollbar-width:thin;scrollbar-color:var(--border) transparent}
.session-item{
  padding:9px 12px;cursor:pointer;transition:background .15s;
  border-left:2px solid transparent;display:flex;align-items:center;gap:8px;
}
.session-item:hover{background:var(--bg3)}
.session-item.active{background:var(--bg3);border-left-color:var(--green)}
.session-name{font-size:12px;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
.session-del{font-size:10px;color:var(--text-dim);padding:2px 4px;border-radius:2px;opacity:0;transition:opacity .15s}
.session-item:hover .session-del{opacity:1}
.session-del:hover{color:var(--red)}

/* ── MAIN AREA ──────────────────────────────────────────────────────── */
#main{display:flex;flex-direction:column;flex:1;min-width:0;overflow:hidden}

/* ── TOP BAR ────────────────────────────────────────────────────────── */
#topbar{
  display:flex;align-items:center;padding:10px 14px;
  border-bottom:1px solid var(--border);gap:10px;flex-shrink:0;flex-wrap:wrap;
  background:var(--bg2);
}
#sidebar-toggle{background:transparent;border:1px solid var(--border);color:var(--text-dim);padding:6px 9px;border-radius:4px;cursor:pointer;font-size:13px;transition:all .15s}
#sidebar-toggle:hover{border-color:var(--green-dim);color:var(--green)}
.status-wrap{display:flex;align-items:center;gap:6px}
.status-dot{width:8px;height:8px;border-radius:50%;background:var(--green);box-shadow:0 0 8px var(--green);animation:pulse 2s ease-in-out infinite;flex-shrink:0}
.status-dot.offline{background:var(--red);box-shadow:0 0 8px var(--red);animation:none}
.status-dot.connecting{background:var(--amber);box-shadow:0 0 8px var(--amber)}
#status-label{font-size:11px;color:var(--text-dim)}
select{background:var(--bg3);border:1px solid var(--border);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:12px;padding:5px 8px;border-radius:4px;outline:none;cursor:pointer;max-width:220px;transition:border-color .2s}
select:hover,select:focus{border-color:var(--green-dim)}
.stat{font-size:11px;color:var(--text-dim);padding:4px 8px;border:1px solid var(--border);border-radius:4px;white-space:nowrap}
.stat .val{color:var(--cyan)}
.topbar-btns{display:flex;gap:6px;margin-left:auto}
.icon-btn{background:transparent;border:1px solid var(--border);color:var(--text-dim);font-family:'JetBrains Mono',monospace;font-size:11px;padding:5px 9px;border-radius:4px;cursor:pointer;transition:all .15s;white-space:nowrap;letter-spacing:.5px}
.icon-btn:hover{border-color:var(--text-dim);color:var(--text)}
.icon-btn.active{border-color:var(--amber);color:var(--amber)}
#reconnect-btn{border-color:var(--amber);color:var(--amber)}
#reconnect-btn:hover{background:rgba(255,170,0,0.08)}

/* ── SYSTEM PROMPT PANEL ────────────────────────────────────────────── */
#sysprompt-panel{
  border-bottom:1px solid var(--border);background:var(--bg3);
  overflow:hidden;max-height:0;transition:max-height .3s ease;flex-shrink:0;
}
#sysprompt-panel.open{max-height:160px}
#sysprompt-inner{padding:10px 14px}
#sysprompt-label{font-size:11px;color:var(--amber);letter-spacing:2px;text-transform:uppercase;margin-bottom:6px}
#sysprompt{
  width:100%;background:var(--bg2);border:1px solid var(--border);
  color:var(--text);font-family:'JetBrains Mono',monospace;font-size:12px;
  padding:8px 10px;border-radius:4px;resize:none;height:80px;outline:none;
  transition:border-color .2s;line-height:1.5;
}
#sysprompt:focus{border-color:var(--amber)}
#sysprompt::placeholder{color:var(--text-dim)}
#sysprompt-clear{font-size:10px;color:var(--text-dim);padding:2px 6px;border:1px solid var(--border);background:transparent;border-radius:3px;cursor:pointer;margin-top:4px;font-family:'JetBrains Mono',monospace}
#sysprompt-clear:hover{border-color:var(--red);color:var(--red)}

/* ── MESSAGES ───────────────────────────────────────────────────────── */
#messages{overflow-y:auto;padding:20px 16px;display:flex;flex-direction:column;gap:16px;flex:1;scrollbar-width:thin;scrollbar-color:var(--border) transparent}
#messages::-webkit-scrollbar{width:4px}
#messages::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px}

.msg{display:grid;grid-template-columns:36px 1fr;gap:12px;animation:fadeIn .2s ease}
@keyframes fadeIn{from{opacity:0;transform:translateY(5px)}to{opacity:1;transform:translateY(0)}}
.msg-avatar{width:36px;height:36px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;flex-shrink:0;margin-top:2px;font-family:'Orbitron',monospace}
.msg.user .msg-avatar{background:var(--green-dark);color:var(--green);border:1px solid var(--green-dim)}
.msg.ai   .msg-avatar{background:#0d1a2a;color:var(--cyan);border:1px solid #1a3a55}
.msg.system-msg .msg-avatar{background:#1a1000;color:var(--amber);border:1px solid #443300;font-size:16px}
.msg-body{min-width:0}
.msg-meta{display:flex;align-items:center;gap:10px;margin-bottom:5px}
.msg-role{font-size:11px;font-weight:600;letter-spacing:2px;text-transform:uppercase}
.msg.user .msg-role{color:var(--green)}.msg.ai .msg-role{color:var(--cyan)}.msg.system-msg .msg-role{color:var(--amber)}
.msg-time{font-size:10px;color:var(--text-dim)}
.msg-actions{display:flex;gap:4px;margin-left:auto}
.msg-btn{font-size:10px;padding:2px 6px;background:transparent;border:1px solid var(--border);color:var(--text-dim);border-radius:3px;cursor:pointer;font-family:'JetBrains Mono',monospace;transition:all .15s}
.msg-btn:hover{border-color:var(--green-dim);color:var(--green)}
.msg-btn.regen{border-color:var(--purple);color:var(--purple)}
.msg-btn.regen:hover{background:rgba(176,96,255,0.1)}
.msg-content{color:var(--text-bright);line-height:1.75;word-break:break-word}
.msg.user .msg-content{background:var(--bg2);border:1px solid var(--border);border-left:3px solid var(--green-dim);padding:10px 14px;border-radius:0 6px 6px 0}
.msg.ai   .msg-content{background:var(--bg2);border:1px solid var(--border);border-left:3px solid #1a4060;padding:10px 14px;border-radius:0 6px 6px 0}
.msg.system-msg .msg-content{background:#0d0a00;border:1px solid #332200;border-left:3px solid var(--amber);padding:8px 12px;border-radius:0 6px 6px 0;font-size:12px;color:var(--amber)}
.msg-content p{margin:0 0 8px}
.msg-content p:last-child{margin-bottom:0}
.msg-content code{background:var(--bg3);border:1px solid var(--border);padding:1px 5px;border-radius:3px;color:var(--amber);font-size:12px}
.msg-content pre{background:#050709 !important;border:1px solid var(--border);border-left:3px solid var(--amber);border-radius:0 6px 6px 6px;margin:10px 0;overflow:hidden}
.msg-content pre .code-header{display:flex;align-items:center;justify-content:space-between;padding:5px 12px;background:#0a0c10;border-bottom:1px solid var(--border)}
.msg-content pre .lang-tag{font-size:10px;color:var(--amber);letter-spacing:1px;text-transform:uppercase}
.msg-content pre .copy-code{font-size:10px;padding:2px 7px;background:transparent;border:1px solid var(--border);color:var(--text-dim);border-radius:3px;cursor:pointer;font-family:'JetBrains Mono',monospace}
.msg-content pre .copy-code:hover{border-color:var(--green-dim);color:var(--green)}
.msg-content pre code{background:none !important;border:none !important;padding:12px 14px !important;display:block;overflow-x:auto;font-size:12px;line-height:1.6}
.msg-content pre code.hljs{background:#050709 !important;padding:12px 14px !important}
.msg-content strong{color:var(--text-bright);font-weight:600}
.msg-content ul,.msg-content ol{margin:6px 0 6px 20px}
.msg-content li{margin-bottom:3px}
.msg-content h1,.msg-content h2,.msg-content h3{color:var(--cyan);margin:12px 0 6px;font-family:'Orbitron',monospace;letter-spacing:1px}
.msg-content h1{font-size:16px}.msg-content h2{font-size:14px}.msg-content h3{font-size:13px}
.msg-content blockquote{border-left:3px solid var(--purple);padding:6px 12px;color:var(--text-dim);background:var(--bg3);margin:8px 0}
.msg-content hr{border:none;border-top:1px solid var(--border);margin:10px 0}
.msg-content table{border-collapse:collapse;width:100%;margin:8px 0;font-size:12px}
.msg-content th,.msg-content td{border:1px solid var(--border);padding:6px 10px;text-align:left}
.msg-content th{background:var(--bg3);color:var(--cyan)}

.cursor::after{content:'▋';color:var(--green);animation:blink .6s step-end infinite}
@keyframes blink{50%{opacity:0}}

#empty-state{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:16px;color:var(--text-dim);text-align:center;user-select:none}
.empty-logo{font-family:'Orbitron',monospace;font-size:32px;font-weight:900;color:var(--border);letter-spacing:6px}
.empty-sub{font-size:11px;letter-spacing:2px;text-transform:uppercase}
.suggestion-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:8px;max-width:600px}
.suggestion{background:var(--bg2);border:1px solid var(--border);padding:10px 14px;border-radius:6px;font-size:12px;color:var(--text-dim);cursor:pointer;transition:all .2s;text-align:left}
.suggestion:hover{border-color:var(--green-dim);color:var(--text);background:var(--bg3)}

/* ── INPUT AREA ─────────────────────────────────────────────────────── */
#input-area{border-top:1px solid var(--border);padding:12px 14px 14px;display:flex;flex-direction:column;gap:8px;flex-shrink:0;background:var(--bg2)}
.input-row{display:flex;gap:8px;align-items:flex-end}
#prompt{
  flex:1;background:var(--bg3);border:1px solid var(--border);border-radius:6px;
  color:var(--text-bright);font-family:'JetBrains Mono',monospace;font-size:14px;
  padding:10px 14px;resize:none;outline:none;min-height:44px;max-height:200px;
  line-height:1.5;transition:border-color .2s,box-shadow .2s;
}
#prompt:focus{border-color:var(--green-dim);box-shadow:var(--glow-sm)}
#prompt::placeholder{color:var(--text-dim)}
.btn{background:transparent;border:1px solid var(--border);color:var(--text-dim);font-family:'JetBrains Mono',monospace;font-size:12px;padding:10px 14px;border-radius:6px;cursor:pointer;white-space:nowrap;transition:all .15s;display:flex;align-items:center;gap:6px;letter-spacing:1px;text-transform:uppercase}
#send-btn{background:var(--green-dark);border-color:var(--green-dim);color:var(--green);font-weight:600;min-width:80px;justify-content:center}
#send-btn:hover:not(:disabled){background:#004422;box-shadow:var(--glow-sm)}
#send-btn:disabled{opacity:.35;cursor:not-allowed}
#stop-btn{display:none;border-color:var(--red);color:var(--red)}
#stop-btn:hover{background:rgba(255,68,85,0.08)}
#stop-btn.visible{display:flex}

/* ── PARAMS ROW ─────────────────────────────────────────────────────── */
#params-row{display:flex;align-items:center;gap:16px;flex-wrap:wrap;font-size:11px;color:var(--text-dim)}
.param-group{display:flex;align-items:center;gap:6px}
.param-label{letter-spacing:1px;text-transform:uppercase;white-space:nowrap;font-size:10px}
input[type=range]{padding:0;width:72px;height:3px;accent-color:var(--green);border:none;background:none;cursor:pointer}
.param-val{color:var(--cyan);min-width:28px;text-align:right;font-size:11px}
#max-tokens-input{
  width:58px;background:var(--bg3);border:1px solid var(--border);border-radius:3px;
  color:var(--cyan);font-family:'JetBrains Mono',monospace;font-size:11px;
  padding:2px 5px;outline:none;text-align:right;
}
#max-tokens-input:focus{border-color:var(--green-dim)}
.input-footer-right{margin-left:auto;font-size:10px;color:var(--text-dim)}

/* ── PARAMS PANEL TOGGLE ────────────────────────────────────────────── */
#params-toggle{
  background:transparent;border:none;color:var(--text-dim);font-family:'JetBrains Mono',monospace;
  font-size:10px;cursor:pointer;padding:0;letter-spacing:1px;text-transform:uppercase;
  transition:color .15s;
}
#params-toggle:hover{color:var(--text)}
#params-panel{overflow:hidden;max-height:0;transition:max-height .25s ease}
#params-panel.open{max-height:60px}

@media(max-width:650px){
  #sidebar{display:none}
  .stat{display:none}
  .suggestion-grid{grid-template-columns:1fr}
  #params-row{gap:10px}
}
</style>
</head>
<body>
<div id="shell">

  <!-- ── Sidebar ── -->
  <aside id="sidebar">
    <div id="sidebar-header">
      <div class="logo">NEURAL<span>TERM</span></div>
      <button id="new-chat-btn" onclick="newSession()">+ NEW</button>
    </div>
    <div id="session-list"></div>
  </aside>

  <!-- ── Main ── -->
  <div id="main">

    <!-- Topbar -->
    <div id="topbar">
      <button id="sidebar-toggle" onclick="toggleSidebar()" title="Toggle sessions">☰</button>
      <div class="status-wrap">
        <div class="status-dot offline" id="status-dot"></div>
        <span id="status-label">connecting…</span>
      </div>
      <select id="model-select"><option value="">— loading —</option></select>
      <div class="stat">CTX <span class="val" id="token-count">—</span></div>
      <div class="stat">SPEED <span class="val" id="speed-display">—</span></div>
      <div class="topbar-btns">
        <button class="icon-btn" id="sysprompt-btn" onclick="toggleSysprompt()" title="System prompt">⚙ SYSTEM</button>
        <button class="icon-btn" onclick="exportChat()" title="Export conversation as Markdown">↓ EXPORT</button>
        <button class="icon-btn" onclick="clearChat()" title="Clear current chat">✕ CLEAR</button>
        <button class="icon-btn" id="reconnect-btn" onclick="reconnect()" title="Reconnect to Ollama">↻ RECONNECT</button>
      </div>
    </div>

    <!-- System prompt panel -->
    <div id="sysprompt-panel">
      <div id="sysprompt-inner">
        <div id="sysprompt-label">⚙ SYSTEM PROMPT</div>
        <textarea id="sysprompt" placeholder="You are a helpful assistant… (leave blank for model default)"></textarea>
        <button id="sysprompt-clear" onclick="document.getElementById('sysprompt').value=''">✕ CLEAR</button>
      </div>
    </div>

    <!-- Messages -->
    <div id="messages">
      <div id="empty-state">
        <div class="empty-logo">N T</div>
        <div class="empty-sub">Neural Terminal · Local LLM</div>
        <div class="suggestion-grid">
          <div class="suggestion" onclick="useSuggestion(this)">Explain how neural networks learn</div>
          <div class="suggestion" onclick="useSuggestion(this)">Write a Python script to rename files</div>
          <div class="suggestion" onclick="useSuggestion(this)">/think What is the best sorting algorithm?</div>
          <div class="suggestion" onclick="useSuggestion(this)">Summarise the key ideas in this text:</div>
        </div>
      </div>
    </div>

    <!-- Input area -->
    <div id="input-area">
      <div class="input-row">
        <textarea id="prompt" rows="1" placeholder="Send a message… (Enter = send, Shift+Enter = newline)  |  /think for reasoning mode"></textarea>
        <button class="btn" id="stop-btn" onclick="stopGeneration()">■ STOP</button>
        <button class="btn" id="send-btn" onclick="sendMessage()">▶ SEND</button>
      </div>
      <div>
        <button id="params-toggle" onclick="toggleParams()">▸ PARAMETERS</button>
        <div id="params-panel">
          <div id="params-row">
            <div class="param-group">
              <span class="param-label">TEMP</span>
              <input type="range" id="temp" min="0" max="2" step="0.05" value="0.7">
              <span class="param-val" id="temp-val">0.70</span>
            </div>
            <div class="param-group">
              <span class="param-label">TOP-P</span>
              <input type="range" id="topp" min="0" max="1" step="0.01" value="0.95">
              <span class="param-val" id="topp-val">0.95</span>
            </div>
            <div class="param-group">
              <span class="param-label">TOP-K</span>
              <input type="range" id="topk" min="1" max="100" step="1" value="40">
              <span class="param-val" id="topk-val">40</span>
            </div>
            <div class="param-group">
              <span class="param-label">MAX TOK</span>
              <input type="number" id="max-tokens-input" value="2048" min="64" max="32768" step="64">
            </div>
            <div class="input-footer-right">Enter = send · Shift+Enter = newline</div>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<script>
const OLLAMA = 'http://127.0.0.1:11434';

// ── Session management ─────────────────────────────────────────────────────
let sessions = JSON.parse(localStorage.getItem('nt_sessions') || '[]');
let activeId  = localStorage.getItem('nt_active') || null;

if (!sessions.length) { createSession('Chat 1'); }
else if (!activeId || !sessions.find(s=>s.id===activeId)) {
  activeId = sessions[0].id;
}

function createSession(name) {
  const id = 'sess_' + Date.now();
  sessions.push({ id, name: name||'New Chat', history: [] });
  activeId = id;
  saveSessions();
  return id;
}
function saveSessions() {
  localStorage.setItem('nt_sessions', JSON.stringify(sessions));
  localStorage.setItem('nt_active', activeId);
}
function getActive() { return sessions.find(s=>s.id===activeId) || sessions[0]; }
function newSession() {
  const id = createSession('Chat ' + (sessions.length+1));
  activeId = id;
  saveSessions();
  renderSidebar();
  renderMessages();
}
function switchSession(id) {
  activeId = id;
  saveSessions();
  renderSidebar();
  renderMessages();
  stopGeneration();
}
function deleteSession(id, e) {
  e.stopPropagation();
  sessions = sessions.filter(s=>s.id!==id);
  if (!sessions.length) createSession('Chat 1');
  if (activeId===id) activeId = sessions[0].id;
  saveSessions();
  renderSidebar();
  renderMessages();
}
function renderSidebar() {
  const list = document.getElementById('session-list');
  list.innerHTML = sessions.map(s=>`
    <div class="session-item${s.id===activeId?' active':''}" onclick="switchSession('${s.id}')">
      <span class="session-name" title="${s.name}">${s.name}</span>
      <span class="session-del" onclick="deleteSession('${s.id}',event)">✕</span>
    </div>`).join('');
}
function autoRenameSession(text) {
  const sess = getActive();
  if (sess.history.length === 1) {
    sess.name = text.slice(0, 28) + (text.length>28?'…':'');
    saveSessions();
    renderSidebar();
  }
}

// ── Sidebar toggle ─────────────────────────────────────────────────────────
let sidebarOpen = true;
function toggleSidebar() {
  sidebarOpen = !sidebarOpen;
  document.getElementById('sidebar').classList.toggle('collapsed', !sidebarOpen);
}

// ── System prompt toggle ───────────────────────────────────────────────────
let syspromptOpen = false;
function toggleSysprompt() {
  syspromptOpen = !syspromptOpen;
  document.getElementById('sysprompt-panel').classList.toggle('open', syspromptOpen);
  document.getElementById('sysprompt-btn').classList.toggle('active', syspromptOpen);
}

// ── Params panel toggle ────────────────────────────────────────────────────
let paramsOpen = false;
function toggleParams() {
  paramsOpen = !paramsOpen;
  document.getElementById('params-panel').classList.toggle('open', paramsOpen);
  document.getElementById('params-toggle').textContent = (paramsOpen?'▾':'▸') + ' PARAMETERS';
}

// ── Ollama connection ──────────────────────────────────────────────────────
let ollamaOnline = false;
async function loadModels() {
  const dot   = document.getElementById('status-dot');
  const label = document.getElementById('status-label');
  dot.className = 'status-dot connecting';
  label.textContent = 'connecting…';
  try {
    const r = await fetch(OLLAMA+'/api/tags', {signal: AbortSignal.timeout(4000)});
    if (!r.ok) throw new Error('HTTP '+r.status);
    const d = await r.json();
    const sel = document.getElementById('model-select');
    sel.innerHTML = '';
    if (!d.models?.length) {
      sel.innerHTML = '<option value="">No models — run: ollama pull qwen3:8b</option>';
    } else {
      d.models.forEach(m=>{
        const o = document.createElement('option');
        o.value = m.name; o.textContent = m.name; sel.appendChild(o);
      });
    }
    dot.className = 'status-dot';
    label.textContent = 'online';
    ollamaOnline = true;
  } catch {
    dot.className = 'status-dot offline';
    label.textContent = 'offline';
    ollamaOnline = false;
    document.getElementById('model-select').innerHTML =
      '<option value="">Ollama offline — run: ollama-start</option>';
  }
}
async function reconnect() {
  document.getElementById('status-label').textContent = 'reconnecting…';
  await loadModels();
}
setInterval(loadModels, 20000);
loadModels();

// ── Slider bindings ────────────────────────────────────────────────────────
['temp','topp','topk'].forEach(id => {
  const el = document.getElementById(id);
  const vl = document.getElementById(id+'-val');
  el.addEventListener('input', () => {
    vl.textContent = id==='topk' ? el.value : parseFloat(el.value).toFixed(2);
  });
});

// ── Prompt box ─────────────────────────────────────────────────────────────
const promptEl = document.getElementById('prompt');
promptEl.addEventListener('input', () => {
  promptEl.style.height = 'auto';
  promptEl.style.height = Math.min(promptEl.scrollHeight, 200) + 'px';
});
promptEl.addEventListener('keydown', e => {
  if (e.key==='Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

// ── Markdown + syntax highlighting renderer ────────────────────────────────
function escHtml(t) {
  return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function renderMarkdown(raw) {
  let t = raw;
  // Code blocks
  t = t.replace(/```(\w*)\n?([\s\S]*?)```/g, (_, lang, code) => {
    const trimmed = code.trim();
    const highlighted = lang && hljs.getLanguage(lang)
      ? hljs.highlight(trimmed, {language:lang}).value
      : hljs.highlightAuto(trimmed).value;
    const langLabel = lang || 'code';
    return `<pre><div class="code-header"><span class="lang-tag">${langLabel}</span><button class="copy-code" onclick="copyCode(this)">COPY</button></div><code class="hljs">${highlighted}</code></pre>`;
  });
  // Inline code
  t = t.replace(/`([^`\n]+)`/g, (_, c) => `<code>${escHtml(c)}</code>`);
  // Headers
  t = t.replace(/^### (.+)$/gm, '<h3>$1</h3>');
  t = t.replace(/^## (.+)$/gm, '<h2>$1</h2>');
  t = t.replace(/^# (.+)$/gm, '<h1>$1</h1>');
  // Bold / italic
  t = t.replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>');
  t = t.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  t = t.replace(/\*(.+?)\*/g, '<em>$1</em>');
  // Blockquote
  t = t.replace(/^> (.+)$/gm, '<blockquote>$1</blockquote>');
  // Horizontal rule
  t = t.replace(/^---+$/gm, '<hr>');
  // Tables (simple)
  t = t.replace(/(\|.+\|\n\|[-| :]+\|\n(?:\|.+\|\n?)+)/g, tbl => {
    const rows = tbl.trim().split('\n');
    const header = rows[0].split('|').filter(c=>c.trim()).map(c=>`<th>${c.trim()}</th>`).join('');
    const body = rows.slice(2).map(r=>'<tr>'+r.split('|').filter(c=>c.trim()).map(c=>`<td>${c.trim()}</td>`).join('')+'</tr>').join('');
    return `<table><thead><tr>${header}</tr></thead><tbody>${body}</tbody></table>`;
  });
  // Lists
  t = t.replace(/^(\s*[-*+] .+(\n|$))+/gm, blk => '<ul>'+blk.replace(/^\s*[-*+] (.+)$/gm,'<li>$1</li>')+'</ul>');
  t = t.replace(/^(\s*\d+\. .+(\n|$))+/gm, blk => '<ol>'+blk.replace(/^\s*\d+\. (.+)$/gm,'<li>$1</li>')+'</ol>');
  // Paragraphs (double newline)
  t = t.replace(/\n\n+/g, '</p><p>');
  if (!t.startsWith('<')) t = '<p>' + t + '</p>';
  return t;
}
function copyCode(btn) {
  const code = btn.closest('pre').querySelector('code');
  navigator.clipboard.writeText(code.innerText).then(()=>{
    btn.textContent='COPIED'; setTimeout(()=>btn.textContent='COPY',1500);
  }).catch(()=>{});
}

// ── Message rendering ──────────────────────────────────────────────────────
function now() { return new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}); }
function scrollBot() { const m=document.getElementById('messages'); m.scrollTop=m.scrollHeight; }
function setStreaming(on) {
  streaming=on;
  document.getElementById('send-btn').disabled=on;
  document.getElementById('stop-btn').classList.toggle('visible',on);
}

function appendMsg(role, content, stream=false) {
  const empty = document.getElementById('empty-state');
  if (empty) empty.remove();
  const msgs  = document.getElementById('messages');
  const id    = 'msg_'+Date.now()+'_'+Math.random().toString(36).slice(2);
  const isU   = role==='user';
  const div   = document.createElement('div');
  div.className = 'msg '+(isU?'user':'ai');
  div.id = id;
  const actions = isU
    ? `<button class="msg-btn" onclick="copyMsg('${id}')">COPY</button>`
    : `<button class="msg-btn" onclick="copyMsg('${id}')">COPY</button>
       <button class="msg-btn regen" onclick="regenerate('${id}')">↻ REGEN</button>`;
  div.innerHTML = `
    <div class="msg-avatar">${isU?'U':'AI'}</div>
    <div class="msg-body">
      <div class="msg-meta">
        <span class="msg-role">${isU?'USER':'ASSISTANT'}</span>
        <span class="msg-time">${now()}</span>
        <div class="msg-actions">${actions}</div>
      </div>
      <div class="msg-content${stream?' cursor':''}">${isU?escHtml(content):renderMarkdown(content)}</div>
    </div>`;
  msgs.appendChild(div);
  scrollBot();
  return id;
}
function updateMsg(id, content, done=false) {
  const el = document.getElementById(id)?.querySelector('.msg-content');
  if (!el) return;
  el.innerHTML = renderMarkdown(content);
  done ? el.classList.remove('cursor') : el.classList.add('cursor');
  scrollBot();
}
function copyMsg(id) {
  const el = document.getElementById(id)?.querySelector('.msg-content');
  if (el) navigator.clipboard.writeText(el.innerText).catch(()=>{});
}

// ── Regenerate ────────────────────────────────────────────────────────────
function regenerate(msgId) {
  const sess = getActive();
  // Find last user message
  const lastUser = [...sess.history].reverse().find(m=>m.role==='user');
  if (!lastUser) return;
  // Remove last assistant turn from history
  while (sess.history.length && sess.history[sess.history.length-1].role==='assistant')
    sess.history.pop();
  saveSessions();
  // Remove the AI bubble from DOM
  document.getElementById(msgId)?.remove();
  // Re-run the prompt
  runInference(lastUser.content);
}

// ── Send message ──────────────────────────────────────────────────────────
let streaming = false, abortCtrl = null;
function useSuggestion(el) { promptEl.value=el.textContent; promptEl.dispatchEvent(new Event('input')); promptEl.focus(); }

async function sendMessage() {
  const model = document.getElementById('model-select').value;
  const text  = promptEl.value.trim();
  if (!text || !model || streaming) return;
  promptEl.value=''; promptEl.style.height='auto';
  const sess = getActive();
  sess.history.push({role:'user',content:text});
  saveSessions();
  appendMsg('user', text);
  autoRenameSession(text);
  await runInference(text);
}

async function runInference(userText) {
  const model = document.getElementById('model-select').value;
  if (!model) return;
  const sess = getActive();
  const aiId = appendMsg('assistant','',true);
  setStreaming(true);
  abortCtrl = new AbortController();
  const t0 = Date.now();
  let full='', tokenCount=0;

  // Build messages array — prepend system prompt if set
  const sysPrompt = document.getElementById('sysprompt').value.trim();
  const messages = sysPrompt
    ? [{role:'system',content:sysPrompt}, ...sess.history]
    : [...sess.history];

  const opts = {
    temperature: parseFloat(document.getElementById('temp').value),
    top_p:       parseFloat(document.getElementById('topp').value),
    top_k:       parseInt(document.getElementById('topk').value),
    num_predict: parseInt(document.getElementById('max-tokens-input').value)||2048,
  };

  try {
    const res = await fetch(OLLAMA+'/api/chat', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      signal: abortCtrl.signal,
      body: JSON.stringify({model, messages, stream:true, options:opts})
    });
    if (!res.ok) throw new Error('HTTP '+res.status);
    const reader=res.body.getReader(), dec=new TextDecoder();
    while(true){
      const{done,value}=await reader.read(); if(done) break;
      for(const line of dec.decode(value,{stream:true}).split('\n')){
        if(!line.trim()) continue;
        try{
          const j=JSON.parse(line);
          if(j.message?.content){ full+=j.message.content; updateMsg(aiId,full,false); }
          if(j.eval_count){ tokenCount=j.eval_count; }
          if(j.eval_duration){
            const secs = j.eval_duration/1e9;
            const tps  = secs>0 ? (tokenCount/secs).toFixed(1) : '?';
            document.getElementById('speed-display').textContent = tps+' t/s';
          }
          if(j.done) updateMsg(aiId,full,true);
        }catch{}
      }
    }
    document.getElementById('token-count').textContent = tokenCount+' tok';
  } catch(err){
    if(err.name==='AbortError'){
      updateMsg(aiId, full+'\n\n*[stopped]*', true);
    } else {
      updateMsg(aiId, '**ERROR:** '+err.message+'\n\nIs Ollama running? Try the **↻ RECONNECT** button.', true);
    }
  } finally {
    sess.history.push({role:'assistant',content:full});
    saveSessions();
    setStreaming(false);
    abortCtrl=null;
  }
}

function stopGeneration() { if(abortCtrl){abortCtrl.abort();abortCtrl=null;} setStreaming(false); }

// ── Clear chat ────────────────────────────────────────────────────────────
function clearChat() {
  const sess = getActive();
  sess.history = [];
  saveSessions();
  renderMessages();
  document.getElementById('token-count').textContent = '—';
  document.getElementById('speed-display').textContent = '—';
}

// ── Render messages from session history ──────────────────────────────────
function renderMessages() {
  const msgs = document.getElementById('messages');
  const sess = getActive();
  if (!sess.history.length) {
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
    if (m.role==='system') return; // don't render system messages
    appendMsg(m.role, m.content, false);
  });
}

// ── Export conversation ───────────────────────────────────────────────────
function exportChat() {
  const sess = getActive();
  if (!sess.history.filter(m=>m.role!=='system').length) {
    alert('Nothing to export yet.'); return;
  }
  const model = document.getElementById('model-select').value || 'unknown';
  let md = `# ${sess.name}\n\n**Model:** ${model}  \n**Exported:** ${new Date().toLocaleString()}\n\n---\n\n`;
  sess.history.forEach(m => {
    if (m.role==='system') { md += `> **System:** ${m.content}\n\n`; return; }
    const label = m.role==='user' ? '## 👤 User' : '## 🤖 Assistant';
    md += `${label}\n\n${m.content}\n\n---\n\n`;
  });
  const blob = new Blob([md], {type:'text/markdown'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = (sess.name.replace(/[^a-z0-9]/gi,'_').toLowerCase() || 'chat') + '.md';
  a.click();
  URL.revokeObjectURL(a.href);
}

// ── Init ──────────────────────────────────────────────────────────────────
renderSidebar();
renderMessages();
promptEl.focus();
</script>
</body>
</html>
"""
path = os.path.expandvars(os.path.expanduser('$HOME/.local/share/llm-webui/llm-chat.html'))
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'w') as f:
    f.write(html)
print(f"HTML UI written to {path}")
PYEOF_HTML

# ── llm-chat launcher — Python HTTP server bypasses CORS for file:// origins ──
cat > "$BIN_DIR/llm-chat" <<'HTMLLAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

GUI_DIR="$HOME/.local/share/llm-webui"
HTML_FILE="$GUI_DIR/llm-chat.html"
HTTP_PORT=8090
BIN_DIR="$HOME/.local/bin"

# ── Check UI file exists ──────────────────────────────────────────────────────
if [[ ! -f "$HTML_FILE" ]]; then
    echo "ERROR: HTML UI not found at $HTML_FILE"
    echo "       Re-run the setup script to regenerate it."
    exit 1
fi

# ── Ensure Ollama is running ──────────────────────────────────────────────────
_ollama_running() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        pgrep -f "ollama serve" >/dev/null 2>&1
    else
        systemctl is-active --quiet ollama 2>/dev/null
    fi
}
if ! _ollama_running; then
    echo "→ Ollama not running — starting it…"
    if [[ -x "$BIN_DIR/ollama-start" ]]; then
        "$BIN_DIR/ollama-start"
    else
        nohup ollama serve >/dev/null 2>&1 &
    fi
    echo "  Waiting for Ollama to come up…"
    for i in {1..12}; do
        curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
        sleep 1
        (( i == 12 )) && echo "  WARNING: Ollama didn't respond in 12s. UI may show 'offline'."
    done
else
    echo "→ Ollama already running."
fi

# ── Kill any stale HTTP server on our port ────────────────────────────────────
OLD_PID=$(lsof -ti tcp:$HTTP_PORT 2>/dev/null || true)
if [[ -n "$OLD_PID" ]]; then
    kill "$OLD_PID" 2>/dev/null || true
    sleep 0.5
fi

# ── Start HTTP server in background ──────────────────────────────────────────
echo "→ Starting HTTP server on http://localhost:$HTTP_PORT …"
python3 -m http.server "$HTTP_PORT" \
    --directory "$GUI_DIR" \
    --bind 127.0.0.1 \
    >/dev/null 2>&1 &
HTTP_PID=$!

# Give the server a moment to bind
sleep 0.8

# Verify it's up
if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "ERROR: HTTP server failed to start."
    echo "       Is port $HTTP_PORT already in use? Try: lsof -i :$HTTP_PORT"
    exit 1
fi

URL="http://localhost:$HTTP_PORT/llm-chat.html"
echo "→ Opening $URL"
echo ""
echo "  Press Ctrl+C here to stop the server when done."
echo ""

# ── Open browser ──────────────────────────────────────────────────────────────
if grep -qi microsoft /proc/version 2>/dev/null; then
    # WSL2 — open in Windows default browser
    cmd.exe /c start "" "$URL" 2>/dev/null \
        || powershell.exe -Command "Start-Process '$URL'" 2>/dev/null \
        || echo "  Open manually: $URL"
else
    xdg-open "$URL" 2>/dev/null \
        || sensible-browser "$URL" 2>/dev/null \
        || echo "  Open manually: $URL"
fi

# ── Keep server alive until Ctrl+C ───────────────────────────────────────────
trap "echo ''; echo 'Stopping HTTP server…'; kill $HTTP_PID 2>/dev/null; exit 0" INT TERM
wait "$HTTP_PID"
HTMLLAUNCHER
chmod +x "$BIN_DIR/llm-chat"
info "Web UI: llm-chat  →  serves on http://localhost:8090"

# =============================================================================
# STEP — OPTIONAL TOOLS
# =============================================================================
step "Optional tools"

HAVE_DISPLAY=0
[[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] && HAVE_DISPLAY=1
grep -qi microsoft /proc/version 2>/dev/null && HAVE_DISPLAY=1

echo ""
echo -e "  ${CYAN}Which tools would you like? Enter numbers (space-separated), 'all', or Enter to skip.${NC}"
echo ""
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "1" "tmux" "terminal multiplexer — split panes, detach sessions"
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "2" "CLI tools" "bat, eza, fzf, ripgrep, btop, ncdu, jq, micro"
if (( HAS_GPU )); then
    printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "3" "nvtop" "live GPU monitor — VRAM usage during inference"
else
    printf "    ${GREEN}%-4s${NC} %-20s %s\n" "3" "nvtop" "(no GPU — will skip)"
fi
if (( HAVE_DISPLAY )); then
    printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "4" "GUI tools" "Thunar file mgr, Mousepad editor, Meld diff"
else
    printf "    ${GREEN}%-4s${NC} %-20s %s\n" "4" "GUI tools" "(no display — will skip)"
fi
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "5" "neofetch" "system info banner + fastfetch"
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "6" "Open WebUI" "full browser chat UI with auth + history (~500 MB pip install)"
echo ""
echo -e "  ${CYAN}── AI coding agents ──────────────────────────────────────────────${NC}"
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "7" "Claude Code" "Anthropic CLI agent — codes, edits, runs commands"
printf "    ${YELLOW}%-4s${NC} %-20s %s\n" "8" "OpenAI Codex" "OpenAI CLI coding agent"
echo ""
if [[ -t 0 ]]; then
    read -r -p "  > " _tool_sel
else
    _tool_sel=""
fi
[[ "${_tool_sel:-}" == "all" ]] && _tool_sel="1 2 3 4 5 6 7 8"

# ── 1: tmux ───────────────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"1"* ]]; then
    sudo apt-get install -y tmux || warn "tmux install failed."
    if [[ ! -f "$HOME/.tmux.conf" ]]; then
        cat > "$HOME/.tmux.conf" <<'TMUXCFG'
# ── Local LLM tmux config ────────────────────────────────────────────────
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
# ────────────────────────────────────────────────────────────────────────
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
            info "micro: OK"
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
# shellcheck disable=SC2154
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
        info "GUI tools installed: thunar mousepad meld"
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

# ── 6: Open WebUI ─────────────────────────────────────────────────────────────
# Always write the launcher script so the 'webui' alias never says "not found"
if is_wsl2; then _OWUI_HOST="0.0.0.0"; else _OWUI_HOST="127.0.0.1"; fi
OWUI_VENV="$HOME/.local/share/open-webui-venv"

if [[ "${_tool_sel:-}" == *"6"* ]]; then
    info "Installing Open WebUI (browser-based full-stack chat UI, ~500 MB)…"
    [[ ! -d "$OWUI_VENV" ]] && "${PYTHON_BIN:-python3}" -m venv "$OWUI_VENV"
    "$OWUI_VENV/bin/pip" install --upgrade pip --quiet || true
    "$OWUI_VENV/bin/pip" install open-webui \
        || { warn "Open WebUI pip install failed — check output above."; }
    OWUI_VER=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "unknown")
    info "Open WebUI $OWUI_VER installed."
fi

cat > "$BIN_DIR/llm-webui-alt" <<OWUI_ALT_LAUNCHER
#!/usr/bin/env bash
# llm-webui-alt — Open WebUI browser interface
OWUI_VENV="$HOME/.local/share/open-webui-venv"

# Guard: print helpful message if Open WebUI isn't installed
if [[ ! -x "$OWUI_VENV/bin/open-webui" ]]; then
    echo ""
    echo "  Open WebUI is not installed yet."
    echo "  Run: llm-setup  →  then select option 6 (Open WebUI)"
    echo ""
    exit 1
fi

export DATA_DIR="$GUI_DIR/open-webui-data"
mkdir -p "\$DATA_DIR"

# ── Ollama connection ─────────────────────────────────────────────────
# Use the Ollama API endpoint — must match what Ollama listens on
export OLLAMA_BASE_URL="http://127.0.0.1:11434"

# ── Streaming fix ─────────────────────────────────────────────────────
# Open WebUI uses aiohttp; default 300s timeout causes blank output on
# slow GPUs. Raise all timeouts to 15 min for large model responses.
export AIOHTTP_CLIENT_TIMEOUT=900
export AIOHTTP_CLIENT_TIMEOUT_TOTAL=900
export OLLAMA_REQUEST_TIMEOUT=900

# ── Auth: disabled for local single-user use ──────────────────────────
export WEBUI_AUTH=false
export ENABLE_LOGIN_FORM=false
export ENABLE_SIGNUP=false
export DEFAULT_USER_ROLE=admin
export CORS_ALLOW_ORIGIN="*"
# ── Ollama API: enable it explicitly so model list appears ────────────
export ENABLE_OLLAMA_API=true
export OLLAMA_API_BASE_URL="http://127.0.0.1:11434"
# ── Connection timeout: raise for large models ────────────────────────
export OLLAMA_CLIENT_TIMEOUT=900

export PYTHONWARNINGS="ignore::RuntimeWarning"

_ollama_running() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        pgrep -f "ollama serve" >/dev/null 2>&1
    else
        systemctl is-active --quiet ollama 2>/dev/null
    fi
}
if ! _ollama_running; then
    echo "→ Starting Ollama…"
    command -v ollama-start &>/dev/null && ollama-start \
        || nohup ollama serve >/dev/null 2>&1 &
    for i in {1..15}; do
        curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break; sleep 1
    done
fi

# ── Kill any stale server on port 8080 (use ss, fall back to fuser) ──
_stale=\$(ss -lptn 'sport = :8080' 2>/dev/null | awk 'NR>1{match(\$NF,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1 || true)
[[ -z "\$_stale" ]] && _stale=\$(fuser 8080/tcp 2>/dev/null || true)
[[ -n "\$_stale" ]] && kill "\$_stale" 2>/dev/null && sleep 1

echo "→ Open WebUI starting on http://localhost:8080"
echo "  If output hangs: ensure Ollama is running and the model is pulled."
echo "  Press Ctrl+C to stop."
"$OWUI_VENV/bin/open-webui" serve --host $_OWUI_HOST --port 8080
OWUI_ALT_LAUNCHER
chmod +x "$BIN_DIR/llm-webui-alt"
grep -q "llm-webui-alt" "$HOME/.local_llm_aliases" 2>/dev/null     || echo "alias webui-alt='\$HOME/.local/bin/llm-webui-alt'" >> "$HOME/.local_llm_aliases"

if [[ "${_tool_sel:-}" == *"6"* ]]; then
    info "Open WebUI installed → run: webui  (http://localhost:8080)"
fi

# ── 7: Claude Code ───────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"7"* ]]; then
    step "Claude Code (Anthropic CLI coding agent)"

    # Ensure Node.js >= 18 is available
    _node_ok=0
    if command -v node &>/dev/null; then
        _nver=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
        (( _nver >= 18 )) && _node_ok=1
    fi
    if [[ $_node_ok -eq 0 ]]; then
        info "Installing Node.js 20 LTS…"
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -             && sudo apt-get install -y nodejs             && _node_ok=1             || warn "Node.js install failed — Claude Code requires Node >= 18."
    fi

    if [[ $_node_ok -eq 1 ]]; then
        sudo npm install -g @anthropic-ai/claude-code             && info "Claude Code installed → run: claude"             || warn "Claude Code install failed."

        # Write a wrapper that reminds about the API key and sets work dir
        cat > "$BIN_DIR/claude-code" <<'CC_EOF'
#!/usr/bin/env bash
# claude-code — Anthropic Claude Code CLI agent wrapper
WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  ANTHROPIC_API_KEY not set.                         ║"
    echo "  ║  Get a key: https://console.anthropic.com/          ║"
    echo "  ║  Then run:  export ANTHROPIC_API_KEY=sk-ant-...     ║"
    echo "  ║  Or add it to ~/.bashrc for persistence.            ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo ""
    read -r -p "  Enter ANTHROPIC_API_KEY now (or press Enter to exit): " _key
    [[ -z "$_key" ]] && exit 1
    export ANTHROPIC_API_KEY="$_key"
fi

echo "  Working dir: $PWD"
exec claude "$@"
CC_EOF
        chmod +x "$BIN_DIR/claude-code"
        grep -q "claude-code" "$ALIAS_FILE" 2>/dev/null             || echo "alias claude-code='claude-code'" >> "$ALIAS_FILE"
        info "Claude Code → run: claude  (or: claude-code)"
        info "  Set key: export ANTHROPIC_API_KEY=sk-ant-..."
        info "  Docs: https://docs.anthropic.com/en/docs/claude-code"
    else
        warn "Claude Code skipped — Node.js >= 18 required."
    fi
fi

# ── 8: OpenAI Codex ───────────────────────────────────────────────────────────
if [[ "${_tool_sel:-}" == *"8"* ]]; then
    step "OpenAI Codex CLI coding agent"

    # Ensure Node.js >= 22 is available (Codex requires 22+)
    _node_ok=0
    if command -v node &>/dev/null; then
        _nver=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
        (( _nver >= 22 )) && _node_ok=1
    fi
    if [[ $_node_ok -eq 0 ]]; then
        info "Installing Node.js 22 LTS (required for OpenAI Codex)…"
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -             && sudo apt-get install -y nodejs             && _node_ok=1             || warn "Node.js install failed — OpenAI Codex requires Node >= 22."
    fi

    if [[ $_node_ok -eq 1 ]]; then
        sudo npm install -g @openai/codex             && info "OpenAI Codex installed → run: codex"             || warn "OpenAI Codex install failed."

        # Write a wrapper
        cat > "$BIN_DIR/codex" <<'CODEX_EOF'
#!/usr/bin/env bash
# codex — OpenAI Codex CLI agent wrapper
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
    read -r -p "  Enter OPENAI_API_KEY now (or press Enter to exit): " _key
    [[ -z "$_key" ]] && exit 1
    export OPENAI_API_KEY="$_key"
fi

echo "  Working dir: $PWD"
exec codex "$@"
CODEX_EOF
        chmod +x "$BIN_DIR/codex"
        grep -q "alias codex" "$ALIAS_FILE" 2>/dev/null             || echo "alias codex='codex'" >> "$ALIAS_FILE"
        info "OpenAI Codex → run: codex"
        info "  Set key: export OPENAI_API_KEY=sk-..."
        info "  Docs: https://github.com/openai/codex"
    else
        warn "OpenAI Codex skipped — Node.js >= 22 required."
    fi
fi

[[ -n "${_tool_sel:-}" ]] && info "Optional tools step complete." || info "Optional tools: skipped." 

# Create the coworking directory now so it exists even before first use
mkdir -p "$HOME/work"
info "Coworking workspace: $HOME/work"

# =============================================================================
# STEP 13b — AUTONOMOUS COWORKING (Open Interpreter + Aider)
# =============================================================================
step "Autonomous coworking tools"
# cowork (Open Interpreter) + aider are core tools — always installed.
OI_VENV="$HOME/.local/share/open-interpreter-venv"
AI_VENV="$HOME/.local/share/aider-venv"

# ── Open Interpreter ──────────────────────────────────────────────────────
info "Installing Open Interpreter…"
    # Python 3.12+ no longer ships pkg_resources in venvs. We always remove and
    # rebuild the venv to ensure setuptools is present in the correct order.
    if [[ -d "$OI_VENV" ]]; then
        warn "Rebuilding Open Interpreter venv (ensures setuptools/pkg_resources OK)…"
        rm -rf "$OI_VENV"
    fi
    "${PYTHON_BIN:-python3}" -m venv "$OI_VENV"
    # Step 1: pip + setuptools FIRST — pkg_resources lives inside setuptools
    "$OI_VENV/bin/pip" install --upgrade pip --quiet
    "$OI_VENV/bin/pip" install --upgrade "setuptools>=70" "wheel" --quiet         || { warn "setuptools install failed."; }
    # Verify pkg_resources is importable before installing OI
    if ! "$OI_VENV/bin/python3" -c "import pkg_resources" 2>/dev/null; then
        warn "pkg_resources still absent — trying pip install of setuptools with no-cache…"
        "$OI_VENV/bin/pip" install --force-reinstall --no-cache-dir "setuptools>=70" --quiet || true
    fi
    # Step 2: open-interpreter itself
    "$OI_VENV/bin/pip" install open-interpreter         || warn "Open Interpreter install failed — check output above."
    # Final health check
    if ! "$OI_VENV/bin/python3" -c "import pkg_resources; import interpreter" 2>/dev/null; then
        warn "Open Interpreter health check failed — cowork may not work correctly."
    else
        info "Open Interpreter OK (pkg_resources ✔)"
    fi

    # Write cowork launcher — reads OLLAMA_TAG from config at runtime
    cat > "$BIN_DIR/cowork" <<'COWORK_EOF'
#!/usr/bin/env bash
# cowork — autonomous AI coworker via Open Interpreter + local Ollama
# The AI can run code, browse the web, manage files — fully local, no cloud.
set -uo pipefail

# Work directory — all cowork sessions land here by default
WORK_DIR="$HOME/work"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

OI_VENV="$HOME/.local/share/open-interpreter-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"

if [[ ! -x "$OI_VENV/bin/interpreter" ]]; then
    echo "ERROR: Open Interpreter not installed. Re-run llm-auto-setup.sh."
    exit 1
fi

# Read OLLAMA_TAG from config without sourcing (avoids env pollution)
OLLAMA_TAG=""
if [[ -f "$CONFIG" ]]; then
    OLLAMA_TAG=$(grep "^OLLAMA_TAG=" "$CONFIG" | head -1 | cut -d'"'  -f2)
fi
OLLAMA_TAG="${OLLAMA_TAG:-qwen_qwen3-14b:q4_k_m}"

# WSL2-aware Ollama running check
_ollama_running() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        pgrep -f "ollama serve" >/dev/null 2>&1
    else
        systemctl is-active --quiet ollama 2>/dev/null
    fi
}

# Start Ollama if not running; track whether WE started it for cleanup
STARTED_OLLAMA=0
if ! _ollama_running; then
    echo "→ Ollama not running — starting it…"
    command -v ollama-start &>/dev/null && ollama-start || nohup ollama serve >/dev/null 2>&1 &
    STARTED_OLLAMA=1
    for i in {1..15}; do
        curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
        sleep 1
    done
fi

# Named cleanup function — avoids quoting issues with trap + single-quoted heredoc
_cowork_cleanup() {
    if [[ ${STARTED_OLLAMA:-0} -eq 1 ]]; then
        echo ""
        echo "Stopping Ollama (started by cowork)…"
        pkill -f "ollama serve" 2>/dev/null || true
    fi
}
trap '_cowork_cleanup' INT TERM EXIT

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║          🤖  AUTONOMOUS COWORKER                ║"
echo "  ║  Model  : $OLLAMA_TAG"
echo "  ║  Powered: Open Interpreter + Ollama (local)     ║"
echo "  ║  Working dir: ~/work                            ║"
echo "  ║  Type 'exit' or Ctrl-D to quit                  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""

# Open Interpreter talks to Ollama via its OpenAI-compatible /v1 shim.
# OPENAI_API_KEY can be any non-empty string — Ollama doesn't validate it.
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
info "cowork launcher written: $BIN_DIR/cowork"

# ── Aider ─────────────────────────────────────────────────────────────────
info "Installing Aider…"
[[ ! -d "$AI_VENV" ]] && "${PYTHON_BIN:-python3}" -m venv "$AI_VENV"
"$AI_VENV/bin/pip" install --upgrade pip --quiet || true
"$AI_VENV/bin/pip" install aider-chat         || warn "Aider install failed — check output above."

    # Write aider launcher
    cat > "$BIN_DIR/aider" <<'AIDER_EOF'
#!/usr/bin/env bash
# aider — AI pair programmer with git integration, powered by local Ollama
set -uo pipefail

AI_VENV="$HOME/.local/share/aider-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"

if [[ ! -x "$AI_VENV/bin/aider" ]]; then
    echo "ERROR: Aider not installed. Re-run llm-auto-setup.sh."
    exit 1
fi

# Read OLLAMA_TAG from config without sourcing (avoids env pollution)
OLLAMA_TAG=""
if [[ -f "$CONFIG" ]]; then
    OLLAMA_TAG=$(grep "^OLLAMA_TAG=" "$CONFIG" | head -1 | cut -d'"'  -f2)
fi
OLLAMA_TAG="${OLLAMA_TAG:-qwen_qwen3-14b:q4_k_m}"

# WSL2-aware Ollama running check
_ollama_running() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        pgrep -f "ollama serve" >/dev/null 2>&1
    else
        systemctl is-active --quiet ollama 2>/dev/null
    fi
}

STARTED_OLLAMA=0
if ! _ollama_running; then
    echo "→ Starting Ollama…"
    command -v ollama-start &>/dev/null && ollama-start || nohup ollama serve >/dev/null 2>&1 &
    STARTED_OLLAMA=1
    sleep 3
fi

_aider_cleanup() {
    if [[ ${STARTED_OLLAMA:-0} -eq 1 ]]; then
        echo ""
        echo "Stopping Ollama (started by aider)…"
        pkill -f "ollama serve" 2>/dev/null || true
    fi
}
trap '_aider_cleanup' INT TERM EXIT

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║         🛠  AIDER  AI PAIR PROGRAMMER           ║"
echo "  ║  Model  : $OLLAMA_TAG"
echo "  ║  Powered: Aider + Ollama (fully local)          ║"
echo "  ║  Usage  : aider file.py file2.js  (or no args)  ║"
echo "  ║  Type /help inside aider for commands           ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""

# Aider native Ollama integration via ollama_chat/ provider prefix.
# OLLAMA_API_BASE points aider at the local server; no key needed.
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
info "aider launcher written: $BIN_DIR/aider"

info "Autonomous coworking tools installed."
info "  cowork  — Open Interpreter (code execution, file ops, web browsing)"
info "  aider   — AI pair programmer (git-integrated, edit files directly)"


# =============================================================================
# LLM-CHECKER — hardware scan, model ranking, installed models status
# =============================================================================
cat > "$BIN_DIR/llm-checker" <<'CHECKER_EOF'
#!/usr/bin/env bash
# llm-checker — live hardware + model ranking dashboard
# Shows: GPU/VRAM/RAM, installed models, recommended pick, full ranked catalog.

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m' M='\033[0;35m'
    R='\033[0;31m' W='\033[1;37m' N='\033[0m'
else
    G='' Y='' C='' M='' R='' W='' N=''
fi

# ── Hardware ─────────────────────────────────────────────────────────────────
VRAM=0; GPU_NAME="None"; HAS_GPU=0
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name          --format=csv,noheader 2>/dev/null | head -1 || true)
    VRAM=$(     nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
                | head -1 | awk '{print int($1/1024)}' || echo 0)
    (( VRAM > 0 )) && HAS_GPU=1
elif command -v rocminfo &>/dev/null; then
    GPU_NAME=$(rocminfo 2>/dev/null | awk '/Marketing Name/{$1=$2=""; print $0; exit}' | xargs)
    VRAM=$(rocminfo 2>/dev/null | grep -i "size:" | grep -v "0 bytes" \
        | awk '{print int($2/1024/1024/1024)}' | sort -rn | head -1 || echo 0)
    (( VRAM > 0 )) && HAS_GPU=1
fi
RAM_GB=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 0)
THREADS=$(nproc 2>/dev/null || echo 4)

# ── Config ────────────────────────────────────────────────────────────────────
CONFIG="$HOME/.config/local-llm/selected_model.conf"
GGUF_DIR="$HOME/.local/share/llm-models"
ACTIVE_MODEL=""; ACTIVE_TAG=""
if [[ -f "$CONFIG" ]]; then
    ACTIVE_MODEL=$(grep "^MODEL_NAME=" "$CONFIG" | head -1 | cut -d'"' -f2 || true)
    ACTIVE_TAG=$(  grep "^OLLAMA_TAG="  "$CONFIG" | head -1 | cut -d'"' -f2 || true)
fi

# ── Header ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${C}╔══════════════════════════════════════════════════════════════════╗${N}"
echo -e "${C}║              🔍  LLM CHECKER  —  System & Model Status          ║${N}"
echo -e "${C}╚══════════════════════════════════════════════════════════════════╝${N}"
echo ""

# ── Hardware box ──────────────────────────────────────────────────────────────
echo -e "${C}  ┌───────────────────────  HARDWARE  ──────────────────────────┐${N}"
printf "${C}  │${N}  %-12s %-48s${C}│${N}\n" "CPU threads" "$THREADS"
printf "${C}  │${N}  %-12s %-48s${C}│${N}\n" "RAM"         "${RAM_GB} GB"
if (( HAS_GPU )); then
    printf "${C}  │${N}  %-12s %-48s${C}│${N}\n" "GPU"     "$GPU_NAME"
    printf "${C}  │${N}  %-12s %-48s${C}│${N}\n" "VRAM"    "${VRAM} GB"
else
    printf "${C}  │${N}  %-12s %-48s${C}│${N}\n" "GPU"     "None (CPU-only mode)"
fi
echo -e "${C}  └──────────────────────────────────────────────────────────────┘${N}"
echo ""

# ── Active config ─────────────────────────────────────────────────────────────
echo -e "${C}  ┌───────────────────────  ACTIVE MODEL  ──────────────────────┐${N}"
if [[ -n "$ACTIVE_MODEL" ]]; then
    printf "${C}  │${N}  %-12s ${G}%-48s${C}│${N}\n" "Model"   "$ACTIVE_MODEL"
    [[ -n "$ACTIVE_TAG" ]] && \
    printf "${C}  │${N}  %-12s ${Y}%-48s${C}│${N}\n" "Ollama"  "ollama run $ACTIVE_TAG"
else
    printf "${C}  │${N}  %-12s %-48s${C}│${N}\n" "Model"   "(not configured — run llm-setup)"
fi
echo -e "${C}  └──────────────────────────────────────────────────────────────┘${N}"
echo ""

# ── Ollama status ─────────────────────────────────────────────────────────────
echo -e "${C}  ┌───────────────────────  OLLAMA  ────────────────────────────┐${N}"
if command -v ollama &>/dev/null; then
    OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
    printf "${C}  │${N}  %-12s ${G}%-48s${C}│${N}\n" "Version" "ollama $OLLAMA_VER"
    if curl -s --max-time 1 http://localhost:11434/api/tags &>/dev/null; then
        INSTALLED_TAGS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | tr '\n' ' ')
        printf "${C}  │${N}  %-12s ${G}%-48s${C}│${N}\n" "Status" "running ✔"
        if [[ -n "$INSTALLED_TAGS" ]]; then
            echo -e "${C}  │${N}  Installed models:                                             ${C}│${N}"
            ollama list 2>/dev/null | tail -n +2 | while IFS= read -r line; do
                printf "${C}  │${N}   ${Y}%-61s${C}│${N}\n" "$line"
            done
        else
            printf "${C}  │${N}  %-12s %-48s${C}│${N}\n" "Models" "(none downloaded yet)"
        fi
    else
        printf "${C}  │${N}  %-12s ${R}%-48s${C}│${N}\n" "Status" "not running  (run: ollama-start)"
    fi
else
    printf "${C}  │${N}  %-12s ${R}%-48s${C}│${N}\n" "Ollama" "not installed  (run: llm-setup)"
fi
echo -e "${C}  └──────────────────────────────────────────────────────────────┘${N}"
echo ""

# ── GGUF files ────────────────────────────────────────────────────────────────
if [[ -d "$GGUF_DIR" ]] && ls "$GGUF_DIR"/*.gguf &>/dev/null 2>&1; then
    echo -e "${C}  ┌───────────────────────  GGUF FILES  ────────────────────────┐${N}"
    while IFS= read -r f; do
        sz=$(du -sh "$f" 2>/dev/null | cut -f1)
        printf "${C}  │${N}  ${Y}%-12s${N}  %-48s${C}│${N}\n" "$sz" "$(basename "$f")"
    done < <(ls "$GGUF_DIR"/*.gguf 2>/dev/null)
    echo -e "${C}  └──────────────────────────────────────────────────────────────┘${N}"
    echo ""
fi

# ── Ranked model catalog ──────────────────────────────────────────────────────
# Format: name | quant | vram_gb | caps | file_gb | rank_tier | note
declare -a _RANKED=(
    "Qwen3-1.7B          |Q8_0  |  0|TOOLS+THINK |  2|1   |ultra-fast tiny model"
    "Phi-4-mini 3.8B ★  |Q4_K_M|  0|TOOLS+THINK |  3|1   |strong tiny ★"
    "Qwen3-4B            |Q4_K_M|  3|TOOLS+THINK |  3|2   |best 4B"
    "Qwen3-8B            |Q4_K_M|  5|TOOLS+THINK |  5|3   |great all-rounder ★"
    "Qwen3-8B            |Q6_K  |  6|TOOLS+THINK |  6|3   |higher quality"
    "DeepSeek-R1-D-7B    |Q4_K_M|  5|THINK       |  5|3   |reasoning specialist"
    "Dolphin3.0-8B       |Q4_K_M|  5|UNCENS      |  5|3   |no restrictions"
    "Gemma-3-12B         |Q4_K_M|  8|TOOLS       |  8|3   |Google quality"
    "Phi-4-14B           |Q4_K_M|  9|TOOLS+THINK |  9|4   |best <16GB ★"
    "Qwen3-14B           |Q4_K_M|  9|TOOLS+THINK |  9|4   |top general ★"
    "DeepSeek-R1-D-14B   |Q4_K_M|  9|THINK       |  9|4   |best reasoning <16GB"
    "Qwen2.5-14B         |Q4_K_M|  9|TOOLS       |  9|4   |proven performer"
    "Mistral-Small-3.1   |Q4_K_M| 14|TOOLS       | 14|5   |fast + capable 24B"
    "Gemma-3-27B         |Q4_K_M| 16|TOOLS       | 16|5   |Google flagship"
    "Qwen3-30B-A3B (MoE) |Q4_K_M| 16|TOOLS+THINK | 18|5   |30B at 8B speed ★"
    "Qwen3-32B           |Q4_K_M| 19|TOOLS+THINK | 19|6   |best consumer ★"
    "DeepSeek-R1-D-32B   |Q4_K_M| 19|THINK       | 19|6   |best local reasoning"
    "Qwen2.5-32B         |Q4_K_M| 19|TOOLS       | 19|6   |strong coder"
)

# Auto-recommend
_RECOMMEND=""
for entry in "${_RANKED[@]}"; do
    IFS='|' read -r _n _q _v _c _fg _t _note <<< "$entry"
    _vg=$(echo "$_v" | tr -d ' ')
    if (( HAS_GPU && VRAM >= _vg && _vg >= 0 )) || \
       (( ! HAS_GPU && _vg == 0 )) || \
       (( ! HAS_GPU && _fg * 2 <= RAM_GB )); then
        _RECOMMEND="${_n// /} ${_q// /}  —  ${_note// /}"
        break
    fi
done

echo -e "${G}  ┌──────────────────────  MODEL RANKING  ──────────────────────┐${N}"
echo -e "${G}  │  Sorted by quality tier. ✓ = fits your hardware.            │${N}"
echo -e "${G}  ├────┬─────────────────────┬──────┬──────┬─────────────────────┤${N}"
printf "${G}  │${N} %-3s${G}│${N} %-21s${G}│${N}%-6s${G}│${N}%-6s${G}│${N} %-21s${G}│${N}\n" \
    "Fit" "Model" "Quant" " VRAM " "Notes"
echo -e "${G}  ├────┼─────────────────────┼──────┼──────┼─────────────────────┤${N}"

for entry in "${_RANKED[@]}"; do
    IFS='|' read -r _n _q _v _c _fg _t _note <<< "$entry"
    _vg=$(echo "$_v" | tr -d ' ')
    _fits=" "
    if (( HAS_GPU && _vg == 0 )) || \
       (( HAS_GPU && VRAM >= _vg )) || \
       (( ! HAS_GPU && _vg == 0 )) || \
       (( ! HAS_GPU && _fg * 2 <= RAM_GB )); then
        _fits="${G}✓${N}"
    fi
    _vstr="CPU"
    (( _vg > 0 )) && _vstr="~${_vg}GB"
    printf "${G}  │${N} %-3b${G}│${N} %-21s${G}│${N}%-6s${G}│${N}%-6s${G}│${N} %-21s${G}│${N}\n" \
        "$_fits" "$(echo "$_n" | xargs)" "$(echo "$_q" | xargs)" "$_vstr" "$(echo "$_note" | xargs)"
done
echo -e "${G}  └────┴─────────────────────┴──────┴──────┴─────────────────────┘${N}"
echo ""

if [[ -n "$_RECOMMEND" ]]; then
    echo -e "  ${G}Recommended for your hardware:${N}"
    echo -e "    ${Y}${_RECOMMEND}${N}"
    echo ""
fi

echo -e "  ${C}Commands:${N}  ${Y}llm-add${N}    download a model from this list"
echo -e "            ${Y}llm-switch${N} change your active model"
echo -e "            ${Y}llm-update${N} upgrade Ollama + Open WebUI + re-pull model"
echo ""
CHECKER_EOF
chmod +x "$BIN_DIR/llm-checker"
info "llm-checker written."

# =============================================================================
# STEP 14 — ALIASES
# =============================================================================
step "Shell aliases"

cat > "$ALIAS_FILE" <<'ALIASES_EOF'
# ── Local LLM (auto-setup) ────────────────────────────────────────────────────
alias ollama-list='ollama list'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'
alias gguf-list='local-models-info'
alias gguf-run='run-gguf'
alias ask='run-model'   # run-model reads config + passes prompt; gguf-run takes a filepath
alias llm-status='local-models-info'
alias llm-checker='llm-checker'
alias chat='llm-chat'
alias webui='$HOME/.local/bin/llm-webui-alt'   # Open WebUI
alias ai='aider'
alias llm-stop='llm-stop'
alias llm-update='llm-update'
alias llm-switch='llm-switch'
alias llm-add='llm-add'
alias llm-setup='bash ~/.config/local-llm/llm-auto-setup.sh'

# clear shows a compact command reference so you never forget a command
alias clear='clear; llm-quick-help'

llm-quick-help() {
    local G='\e[0;32m' Y='\e[1;33m' C='\e[0;36m' M='\e[0;35m' N='\e[0m'
    echo ""
    echo -e "  ${C}+-----------------------------------------------------------------+${N}"
    echo -e "  ${C}|${N}  ${M}Chat${N}                                                           ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}chat${N}          Neural Terminal   → http://localhost:8090       ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}webui${N}         Open WebUI (opt 6)  → http://localhost:8080       ${C}|${N}"
    echo -e "  ${C}|${N}  ${M}Models${N}                                                         ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}run-model${N}     run default GGUF from CLI                       ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}ollama-run${N}    run any Ollama model  (ollama-run <tag>)         ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-add${N}       download more models (hardware-filtered)        ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-switch${N}    change active model                             ${C}|${N}"
    echo -e "  ${C}|${N}  ${M}AI Agents (cloud)${N}                                              ${C}|${N}
  ${C}|${N}   ${Y}claude${N}        Claude Code  (opt 7, ANTHROPIC_API_KEY needed)   ${C}|${N}
  ${C}|${N}   ${Y}codex${N}         OpenAI Codex (opt 8, OPENAI_API_KEY needed)      ${C}|${N}
  ${C}|${N}  ${M}Coworking${N}                                                      ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}cowork${N}        AI writes & runs code, edits files              ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}ai / aider${N}    AI pair programmer with git integration         ${C}|${N}"
    echo -e "  ${C}|${N}  ${M}System${N}                                                         ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}ollama-start${N}  start Ollama backend                            ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-stop${N}      stop Ollama + UIs                               ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-update${N}    upgrade Ollama + Open WebUI, pull latest model  ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-status${N}    show models, disk, config                       ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-checker${N}   hardware scan + ranked model catalog            ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-help${N}      full command reference                          ${C}|${N}"
    echo -e "  ${C}+-----------------------------------------------------------------+${N}"
    echo ""
}

run-model() {
    local cfg=~/.config/local-llm/selected_model.conf
    [[ ! -f "$cfg" ]] && echo "No model configured." && return 1
    # Source in a subshell — positional-arg style handles paths with spaces correctly
    local model_file
    model_file=$(bash -c 'source "$1" 2>/dev/null; printf "%s" "$MODEL_FILENAME"' _ "$cfg")
    [[ -z "$model_file" ]] && echo "MODEL_FILENAME not set in config." && return 1
    run-gguf "$model_file" "$@"
}

llm-help() {
    cat <<'HELP'
Local LLM commands:
  chat                   Open Neural Terminal at http://localhost:8090
  run-model / ask        Run default GGUF model from CLI
  ollama-pull <tag>      Download an Ollama model
  ollama-run  <tag>      Run an Ollama model interactively
  ollama-list            List downloaded Ollama models
  ollama-start           Start the Ollama backend
  gguf-run <file> [txt]  Run a raw GGUF via llama-cpp
    --gpu-layers N         GPU layers
    --threads N            CPU threads
    --batch N              Batch size
    --ctx N                Context window
  gguf-list              List downloaded GGUF files
  llm-status             Show models, disk, and hardware config
  llm-checker            Hardware scan + ranked model catalog + what fits your GPU
  cowork                 Open Interpreter — AI that runs code + manages files
  ai / aider             AI pair programmer with git integration
  webui                  Open WebUI at http://localhost:8080  (optional — run: llm-setup → tool 6)
  llm-stop               Stop Ollama and any running UIs
  llm-update             Upgrade Ollama + Open WebUI (if installed), pull latest model
  llm-switch             Change active model (no full reinstall)
  llm-add                Download more models (hardware-filtered picker)
  llm-setup              Re-run setup from local installed copy
  llm-help               This help
HELP
}
# ─────────────────────────────────────────────────────────────────────────────
ALIASES_EOF

# Bash only — Ubuntu default shell, matches the rest of the script.
if ! grep -q "source $ALIAS_FILE" "$HOME/.bashrc" 2>/dev/null; then
    { echo ""; echo "# Local LLM aliases — llm-auto-setup"
      echo "[ -f $ALIAS_FILE ] && source $ALIAS_FILE"; } >> "$HOME/.bashrc"
    info "Aliases added to ~/.bashrc"
fi

# =============================================================================
# STEP 15 — FINAL VALIDATION
# =============================================================================
step "Final validation"

PASS=0; WARN_COUNT=0

# ── GPU runtime (CUDA or ROCm) ────────────────────────────────────────────────
if (( HAS_NVIDIA )); then
    CUDA_FOUND=0
    find /usr/local /usr/lib /opt -maxdepth 8 \
        \( -name "libcudart.so.12" -o -name "libcudart.so.12.*" \) 2>/dev/null | grep -q . \
        && CUDA_FOUND=1
    (( !CUDA_FOUND )) && ldconfig -p 2>/dev/null | grep -q 'libcudart\.so\.12' && CUDA_FOUND=1
    if (( CUDA_FOUND )); then
        info "✔ CUDA runtime found."
        PASS=$(( PASS + 1 ))
    else
        warn "✘ libcudart.so.12 not found."
        warn "  Fix: sudo ldconfig && exec bash"
        WARN_COUNT=$(( WARN_COUNT + 1 ))
    fi
elif (( HAS_AMD_GPU )); then
    if [[ -d /opt/rocm ]] || command -v rocminfo &>/dev/null; then
        info "✔ ROCm runtime found."
        PASS=$(( PASS + 1 ))
    else
        warn "✘ ROCm not found — AMD GPU won't be used for acceleration."
        warn "  Run the script again to install ROCm, or visit: https://rocm.docs.amd.com"
        WARN_COUNT=$(( WARN_COUNT + 1 ))
    fi
else
    info "✔ CPU-only mode — no GPU runtime needed."
    PASS=$(( PASS + 1 ))
fi

# ── llama-cpp-python ──────────────────────────────────────────────────────────
if "$VENV_DIR/bin/python3" -c "import llama_cpp" 2>/dev/null; then
    info "✔ llama-cpp-python OK."
    PASS=$(( PASS + 1 ))
else
    warn "✘ llama-cpp-python import failed."
    if (( HAS_NVIDIA )); then
        warn "  This may be a CUDA library path issue. Try:"
        warn "    sudo ldconfig && exec bash"
    elif (( HAS_AMD_GPU )); then
        warn "  This may be a ROCm/HIP library path issue. Try:"
        warn "    exec bash  (reloads LD_LIBRARY_PATH with ROCm libs)"
        warn "    hipconfig --version  (checks ROCm install)"
    fi
    warn "    $VENV_DIR/bin/python3 -c 'import llama_cpp'"
    WARN_COUNT=$(( WARN_COUNT + 1 ))
fi

# ── Ollama ────────────────────────────────────────────────────────────────────
if is_wsl2; then
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        info "✔ Ollama running."
        PASS=$(( PASS + 1 ))
    else
        warn "✘ Ollama not running — start with: ollama-start"
        WARN_COUNT=$(( WARN_COUNT + 1 ))
    fi
else
    if systemctl is-active --quiet ollama 2>/dev/null; then
        info "✔ Ollama service active."
        PASS=$(( PASS + 1 ))
    else
        warn "✘ Ollama service not active."
        warn "  Fix: sudo systemctl start ollama"
        warn "  Logs: sudo journalctl -u ollama -n 30"
        WARN_COUNT=$(( WARN_COUNT + 1 ))
    fi
fi

# ── Ollama API reachable ──────────────────────────────────────────────────────
sleep 1
if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    info "✔ Ollama API responding on port 11434."
    PASS=$(( PASS + 1 ))
else
    warn "✘ Ollama API not reachable on port 11434."
    warn "  Neural Terminal and Open WebUI both need this to work."
    warn "  Fix: ollama-start  (then wait 5 sec and try again)"
    WARN_COUNT=$(( WARN_COUNT + 1 ))
fi

# ── Helper scripts ────────────────────────────────────────────────────────────
if [[ -x "$BIN_DIR/run-gguf" ]]; then
    info "✔ run-gguf OK."
    PASS=$(( PASS + 1 ))
else
    warn "✘ run-gguf missing from $BIN_DIR."
    WARN_COUNT=$(( WARN_COUNT + 1 ))
fi

if [[ -x "$BIN_DIR/llm-chat" ]]; then
    info "✔ llm-chat launcher OK."
    PASS=$(( PASS + 1 ))
else
    warn "✘ llm-chat launcher missing."
    WARN_COUNT=$(( WARN_COUNT + 1 ))
fi

if [[ -f "$GUI_DIR/llm-chat.html" ]]; then
    info "✔ HTML UI written."
    PASS=$(( PASS + 1 ))
else
    warn "✘ HTML UI missing from $GUI_DIR."
    WARN_COUNT=$(( WARN_COUNT + 1 ))
fi

if [[ -f "$ALIAS_FILE" ]]; then
    info "✔ Aliases file OK."
    PASS=$(( PASS + 1 ))
else
    warn "✘ Aliases file missing."
    WARN_COUNT=$(( WARN_COUNT + 1 ))
fi

for _tool in llm-stop llm-update llm-switch llm-add; do
    if [[ -x "$BIN_DIR/$_tool" ]]; then
        info "✔ $_tool OK."
        PASS=$(( PASS + 1 ))
    else
        warn "✘ $_tool missing from $BIN_DIR."
        WARN_COUNT=$(( WARN_COUNT + 1 ))
    fi
done

# =============================================================================
# SAVE SCRIPT LOCALLY
# =============================================================================
mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")"
if cp "$0" "$SCRIPT_INSTALL_PATH" 2>/dev/null; then
    chmod +x "$SCRIPT_INSTALL_PATH"
    info "Script saved: $SCRIPT_INSTALL_PATH"
    info "  Re-run anytime: llm-setup"
else
    warn "Could not save to $SCRIPT_INSTALL_PATH (is \$0 a temp file?)"
fi

# =============================================================================
# SUMMARY
# =============================================================================

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
if (( WARN_COUNT == 0 )); then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   🚀  Local LLM Auto-Setup — Installation Complete!         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║   ⚠   Setup complete — ${WARN_COUNT} warning(s) (see below)            ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo -e "    Checks passed : ${GREEN}$PASS${NC}   │   Warnings: ${YELLOW}$WARN_COUNT${NC}   │   Log: $LOG_FILE"

# ── Hardware + model info ─────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}┌─────────────────────────  YOUR SETUP  ──────────────────────────┐${NC}"
printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "CPU"   "$CPU_MODEL"
printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "RAM"   "${TOTAL_RAM_GB} GB"
if (( HAS_NVIDIA )); then
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "GPU" "$GPU_NAME  (${GPU_VRAM_GB} GB VRAM) [CUDA]"
elif (( HAS_AMD_GPU )); then
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "GPU" "$GPU_NAME  (${GPU_VRAM_GB} GB VRAM) [ROCm]"
else
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "GPU" "None (CPU-only)"
fi
if [[ -f "$MODEL_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$MODEL_CONFIG" 2>/dev/null || true
    echo -e "  ${CYAN}├────────────────────────────────────────────────────────────────┤${NC}"
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "Model"      "${MODEL_NAME:-?}"
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "Caps"       "${MODEL_CAPS:-none}"
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "GPU layers" "${GPU_LAYERS:-?} / ${MODEL_LAYERS:-?}   threads: ${HW_THREADS:-?}   batch: ${BATCH:-?}"
fi
echo -e "  ${CYAN}└────────────────────────────────────────────────────────────────┘${NC}"

# ── Command reference ─────────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}┌──────────────────────────  COMMANDS  ───────────────────────────┐${NC}"
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${MAGENTA}── Chat interfaces ─────────────────────────────────────────${NC}  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}chat${NC}          Neural Terminal → http://localhost:8090         ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}webui${NC}         Open WebUI → http://localhost:8080                  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${MAGENTA}── Run models ──────────────────────────────────────────────${NC}  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}run-model${NC}     Run your default model from the command line    ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}ask${NC}           Alias for run-model                            ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}ollama-run${NC}    Run any Ollama model  (ollama-run <tag>)         ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}ollama-pull${NC}   Download a new Ollama model                     ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${MAGENTA}── Autonomous coworking ────────────────────────────────────${NC}  ${CYAN}│${NC}"
if [[ -x "$BIN_DIR/cowork" ]]; then
echo -e "  ${CYAN}│${NC}   ${YELLOW}cowork${NC}        AI that writes & runs code, edits files        ${CYAN}│${NC}"
else
echo -e "  ${CYAN}│${NC}   ${YELLOW}cowork${NC}        ${YELLOW}(not installed — re-run setup to add)${NC}         ${CYAN}│${NC}"
fi
if [[ -x "$BIN_DIR/aider" ]]; then
echo -e "  ${CYAN}│${NC}   ${YELLOW}ai / aider${NC}    AI pair programmer with git integration        ${CYAN}│${NC}"
else
echo -e "  ${CYAN}│${NC}   ${YELLOW}ai / aider${NC}    ${YELLOW}(not installed — re-run setup to add)${NC}         ${CYAN}│${NC}"
fi
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${MAGENTA}── Ollama management ───────────────────────────────────────${NC}  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}ollama-start${NC}  Start the Ollama backend                        ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}ollama-list${NC}   List all downloaded Ollama models               ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-status${NC}    Show models, disk usage, and config             ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-checker${NC}   Hardware scan + ranked model catalog            ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}gguf-run${NC}      Run a raw GGUF file directly via llama-cpp      ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}gguf-list${NC}     List all downloaded GGUF files                  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${MAGENTA}── Maintenance ─────────────────────────────────────────────${NC}  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-add${NC}       Download more models (hardware-filtered)        ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-setup${NC}     Re-run setup from local installed copy          ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-stop${NC}      Stop Ollama backend                             ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-update${NC}    Upgrade Ollama + WebUI + re-pull active model    ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-switch${NC}    Change model (no reinstall needed)              ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${MAGENTA}── AI Coding Agents ────────────────────────────────────────${NC}  ${CYAN}│${NC}"
if command -v claude &>/dev/null; then
echo -e "  ${CYAN}│${NC}   ${YELLOW}claude${NC}        Claude Code AI agent  (cloud — needs API key)  ${CYAN}│${NC}"
else
echo -e "  ${CYAN}│${NC}   ${YELLOW}claude${NC}        ${GREEN}(opt 7 — re-run setup to add Claude Code)${NC}   ${CYAN}│${NC}"
fi
if command -v codex &>/dev/null; then
echo -e "  ${CYAN}│${NC}   ${YELLOW}codex${NC}         OpenAI Codex agent  (cloud — needs API key)    ${CYAN}│${NC}"
else
echo -e "  ${CYAN}│${NC}   ${YELLOW}codex${NC}         ${GREEN}(opt 8 — re-run setup to add OpenAI Codex)${NC}  ${CYAN}│${NC}"
fi
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${MAGENTA}── Help ─────────────────────────────────────────────────────${NC}  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-help${NC}      Show full command reference                     ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}└────────────────────────────────────────────────────────────────┘${NC}"

# ── Activation ───────────────────────────────────────────────────────────────
# exec bash replaces the current shell process in-place: same terminal window,
# same working directory, .bashrc reloaded, all aliases live immediately.
echo ""
echo -e "${GREEN}  ╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║                                                               ║${NC}"
echo -e "${GREEN}  ║   Activate aliases in this terminal:                         ║${NC}"
echo -e "${GREEN}  ║                                                               ║${NC}"
echo -e "${GREEN}  ║          ${YELLOW}exec bash${GREEN}                                          ║${NC}"
echo -e "${GREEN}  ║                                                               ║${NC}"
echo -e "${GREEN}  ║   Same window. Same directory. Zero friction.                ║${NC}"
echo -e "${GREEN}  ╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Then:${NC}"
echo -e "    ${YELLOW}chat${NC}       → Neural Terminal  http://localhost:8090   |  ${YELLOW}webui${NC} → http://localhost:8080"
echo -e "    ${YELLOW}cowork${NC}     → autonomous coding AI (runs code, edits files)"
echo -e "    ${YELLOW}ai${NC}         → aider AI pair programmer (git-integrated)"
echo -e "    ${YELLOW}run-model${NC}  → quick CLI inference from terminal"
echo -e "    ${YELLOW}llm-help${NC}   → full command reference"
is_wsl2 && { echo ""; echo -e "  ${YELLOW}  WSL2:${NC} run ${YELLOW}ollama-start${NC} before using any UI"; }
echo ""

# ── Troubleshooting ───────────────────────────────────────────────────────────
if (( WARN_COUNT > 0 )); then
    echo -e "  ${YELLOW}┌──────────────────────  TROUBLESHOOTING  ────────────────────┐${NC}"
    (( HAS_NVIDIA )) && \
    echo -e "  ${YELLOW}│${NC}  CUDA not found  →  sudo ldconfig && exec bash               ${YELLOW}│${NC}"
    (( HAS_AMD_GPU )) && \
    echo -e "  ${YELLOW}│${NC}  ROCm not found  →  exec bash  (then: hipconfig --version)   ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  Ollama offline  →  ollama-start                             ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  UI won't load   →  ollama-start, wait 5 s, reopen browser   ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  WebUI no output →  model may need more time; check Ollama    ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}                      logs: sudo journalctl -u ollama -n 30    ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  llama-cpp err   →  exec bash && run-model hello              ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  cowork crash    →  re-run setup (setuptools will reinstall)  ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
fi

echo -e "  🚀  Enjoy your local LLM!"
echo ""

# ── Clean up sudo keepalive ───────────────────────────────────────────────────
kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
# Reset trap to default so script exits cleanly
trap - EXIT INT TERM