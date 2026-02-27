#!/usr/bin/env bash
# =============================================================================
# Local LLM Auto-Setup — Universal Edition v3.1.0
# Scans your hardware and automatically selects the best model.
# No Hugging Face token required — all models are from public repos.
# Supports: Ubuntu 22.04 / 24.04 — CPU-only through high-end GPU.
# Also works on Debian 12, Linux Mint 21+, and Pop!_OS 22.04.
# =============================================================================

# Strict mode: exit on error, treat unset variables as errors, propagate pipe
# failures. We intentionally omit -e at top level because we handle failures
# explicitly with warn/error helpers throughout, but individual sections use
# || warn/|| error to stay safe without aborting on non-critical failures.
set -uo pipefail

# ---------- Version -----------------------------------------------------------
SCRIPT_VERSION="3.1.0"
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
# error(): print message + compact diagnostics, then exit
error() {
    log "${RED}[ERROR]${NC} $1"
    log "${RED}[ERROR]${NC} Log file: $LOG_FILE"
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

# is_wsl2: returns 0 if running inside WSL (1 or 2), 1 otherwise.
# Works without uname -r WSL-specific patterns (they vary by distro/kernel).
is_wsl2() {
    grep -qi microsoft /proc/version 2>/dev/null
}

# get_distro_id: returns lowercase distro ID (ubuntu, debian, linuxmint, pop, …)
get_distro_id() {
    grep -m1 '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "unknown"
}

# get_distro_codename: returns ubuntu-style codename (jammy, noble, bookworm, …)
get_distro_codename() {
    grep -m1 '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || \
    lsb_release -sc 2>/dev/null || echo "unknown"
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
    x86_64)  ARCH_OK=1 ;;
    aarch64) ARCH_OK=1; warn "ARM64 detected — CUDA wheels unavailable; will build from source." ;;
    *)       warn "Untested architecture: $HOST_ARCH. Proceeding anyway." ; ARCH_OK=1 ;;
esac

# ── Distro check ──────────────────────────────────────────────────────────────
DISTRO_ID=$(get_distro_id)
DISTRO_CODENAME=$(get_distro_codename)
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || grep -oP '(?<=^VERSION_ID=")[\d.]+' /etc/os-release 2>/dev/null || echo "unknown")
info "Distro: ${DISTRO_ID} ${UBUNTU_VERSION} (${DISTRO_CODENAME}) on ${HOST_ARCH}"
case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|neon|elementary|zorin) ;;
    *) warn "Distro '${DISTRO_ID}' not officially tested. apt-based install paths will be used." ;;
esac

# ── Single sudo prompt — keep credentials alive for the entire script ─────────
# sudo -v extends the TTY-scoped timestamp every 50 s (Ubuntu 22.04+ ppid mode).
echo -e "${CYAN}[sudo]${NC} This script needs elevated privileges for apt, systemd, and CUDA/ROCm."
sudo -v || error "sudo authentication failed."
( while true; do sleep 50; sudo -v 2>/dev/null; done ) &
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
        printf "${YELLOW}  │${NC}  Update available: v%-10s → v%-10s                 ${YELLOW}│${NC}\n" \
            "$SCRIPT_VERSION" "$_remote_ver"
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
if is_wsl2; then
    info "WSL2 environment detected."
else
    info "Native Linux detected."
fi

# ── Internet connectivity check ───────────────────────────────────────────────
HAVE_INTERNET=0
if curl -fsSL --max-time 5 https://huggingface.co >/dev/null 2>&1; then
    HAVE_INTERNET=1
    info "Internet: reachable (huggingface.co)"
elif curl -fsSL --max-time 5 https://pypi.org >/dev/null 2>&1; then
    HAVE_INTERNET=1
    info "Internet: reachable (pypi.org)"
else
    warn "Internet appears unreachable. Model downloads and pip installs may fail."
    warn "  If behind a proxy, set: export https_proxy=http://proxy:port"
fi

# =============================================================================
# STEP 2 — SYSTEM SCAN
# =============================================================================
step "Hardware detection"

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
TOTAL_RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 4096000)
AVAIL_RAM_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 2048000)
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
AVAIL_RAM_GB=$(( AVAIL_RAM_KB / 1024 / 1024 ))
# Ensure sane minimums in case of weird /proc/meminfo output
(( TOTAL_RAM_GB < 1 )) && TOTAL_RAM_GB=4
(( AVAIL_RAM_GB < 1 )) && AVAIL_RAM_GB=2

# ---------- GPU ---------------------------------------------------------------
# Priority: NVIDIA > AMD > Intel Arc.
# We set unified HAS_GPU / GPU_VRAM_GB so model selection works identically.
HAS_NVIDIA=0
HAS_AMD_GPU=0
HAS_INTEL_GPU=0
HAS_GPU=0          # 1 if any capable dGPU found
GPU_NAME="None"
GPU_VRAM_MIB=0
GPU_VRAM_GB=0
DRIVER_VER="N/A"
CUDA_VER_SMI=""
AMD_ROCM_VER=""
AMD_GFX_VER=""     # gfx1100 etc. — needed for HSA_OVERRIDE_GFX_VERSION

# ── NVIDIA ────────────────────────────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    # For model selection we use the VRAM of the largest single GPU (a model's layers
    # are offloaded to one device; summing across GPUs would overstate capacity).
    # For display we show the count and note the total.
    _nv_vram_max=0
    _nv_vram_total=0
    while IFS= read -r _mib_line; do
        _mib_line="${_mib_line// /}"
        if [[ "$_mib_line" =~ ^[0-9]+$ ]]; then
            _nv_vram_total=$(( _nv_vram_total + _mib_line ))
            (( _mib_line > _nv_vram_max )) && _nv_vram_max=$_mib_line
        fi
    done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true)
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo "Unknown NVIDIA GPU")
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo "N/A")
    CUDA_VER_SMI=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -n1 || echo "")
    _nv_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo 1)
    if (( _nv_count > 1 )); then
        GPU_NAME="${_nv_count}x ${GPU_NAME}"
        # Show total in name; model selection uses per-card max
    fi
    if (( _nv_vram_max > 500 )); then
        HAS_NVIDIA=1; HAS_GPU=1
        # Use largest single GPU VRAM for model tier selection
        GPU_VRAM_MIB=$_nv_vram_max
        GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
    fi
fi

# ── AMD GPU ───────────────────────────────────────────────────────────────────
# Probe AMD only if no NVIDIA found (avoids dual-GPU confusion on Optimus etc.)
if (( !HAS_NVIDIA )); then
    # sysfs mem_info_vram_total works on kernels ≥ 4.15 without ROCm installed.
    # Iterate all drm cards; pick the one with the most VRAM > 512 MiB.
    _best_amd_mib=0
    _best_amd_card=""
    for _sysfs_card in /sys/class/drm/card*/device/mem_info_vram_total; do
        [[ -f "$_sysfs_card" ]] || continue
        _amd_vram_bytes=$(< "$_sysfs_card" 2>/dev/null || echo 0)
        _amd_vram_mib=$(( _amd_vram_bytes / 1024 / 1024 ))
        if (( _amd_vram_mib > _best_amd_mib && _amd_vram_mib > 512 )); then
            _best_amd_mib=$_amd_vram_mib
            _best_amd_card="$_sysfs_card"
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
# Intel Arc uses the i915/xe driver (no dedicated VRAM sysfs like AMD).
# We detect via lspci and flag it — vulkan/SYCL GPU offload is possible
# but llama.cpp SYCL builds are complex; we note it but don't change model tiers.
if (( !HAS_NVIDIA && !HAS_AMD_GPU )); then
    if lspci 2>/dev/null | grep -qiE "Intel.*Arc|Intel.*Xe"; then
        HAS_INTEL_GPU=1
        GPU_NAME=$(lspci 2>/dev/null \
                   | grep -iE "Intel.*Arc|Intel.*Xe" | head -n1 | sed 's/.*: //' | xargs \
                   || echo "Intel Arc GPU")
        # Intel integrated VRAM shared from RAM — approximate from available RAM
        # Intel Arc discrete cards (A770=16GB, A750=8GB, A380=6GB) don't expose sysfs VRAM easily.
        # We treat Intel Arc as CPU-only for model selection to stay safe.
        info "Intel Arc/Xe GPU detected: $GPU_NAME"
        info "  llama.cpp SYCL backend is supported but not auto-configured here."
        info "  CPU-only tiers will be used for model selection."
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
        local_api_str="ROCm $AMD_ROCM_VER"
        [[ -n "$AMD_GFX_VER" ]] && local_api_str+="  (${AMD_GFX_VER})"
        printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "API"  "$local_api_str"
    else
        printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "API"      "ROCm (not yet installed)"
    fi
elif (( HAS_INTEL_GPU )); then
    printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Note"     "Intel Arc — CPU tiers used"
fi
printf "  ${CYAN}│${NC}  %-12s %-30s ${CYAN}│${NC}\n" "Disk free" "${DISK_FREE_GB} GB"
echo -e "  ${CYAN}└─────────────────────────────────────────────┘${NC}"
echo ""

# =============================================================================
# STEP 3 — MODEL SELECTION ENGINE
# All public models (bartowski). Auto-tiers:
#   ≥48GB VRAM → Llama-3.3-70B | ≥24GB → Qwen3-32B | ≥16GB → Qwen3-30B-MoE
#   ≥12GB → Qwen3-14B | ≥10GB → Gemma-3-12B | ≥8GB → Qwen3-8B-Q6
#   ≥6GB → Qwen3-8B-Q4 | ≥4GB → Qwen3-4B | ≥2GB → Phi-3.5-mini
#   CPU: ≥32GB→8B | ≥16GB→8B | ≥8GB→4B | <8GB→1.7B/Phi-mini
# =============================================================================

step "Auto-selecting model"

# Headroom to keep free in VRAM for KV-cache + activations (flash attn = ~1.2 GB)
VRAM_HEADROOM_MIB=1200
VRAM_USABLE_MIB=$(( GPU_VRAM_MIB - VRAM_HEADROOM_MIB ))
(( VRAM_USABLE_MIB < 0 )) && VRAM_USABLE_MIB=0

# Maximum RAM for model layers (leave 4 GB for OS + Python)
RAM_FOR_LAYERS_GB=$(( TOTAL_RAM_GB - 4 ))
(( RAM_FOR_LAYERS_GB < 1 )) && RAM_FOR_LAYERS_GB=1

# gpu_layers_for $size_gb $num_layers → layers that fit in VRAM
# Note: mib_per_layer() was removed — arithmetic is inlined below for clarity.
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
# [TOOLS]=function calling  [THINK]=reasoning via /think  [UNCENS]=uncensored  ★=best pick

declare -A M   # holds the chosen model's fields

select_model() {
    local vram=$GPU_VRAM_GB
    local ram=$TOTAL_RAM_GB

    # ── ≥ 48 GB VRAM (multi-GPU or H100/A100 class) ───────────────────────────
    if (( HAS_GPU && vram >= 48 )); then
        highlight "High-end GPU (${vram} GB VRAM) → Llama-3.3-70B [TOOLS] ★"
        M[name]="Llama-3.3-70B-Instruct Q4_K_M"; M[caps]="TOOLS"
        M[file]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
        M[size_gb]=40; M[layers]=80; M[tier]="70B"; return

    # ── ≥ 24 GB VRAM ─────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 24 )); then
        highlight "High-end GPU (${vram} GB VRAM) → Qwen3-32B [TOOLS+THINK] ★"
        M[name]="Qwen3-32B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
        M[size_gb]=19; M[layers]=64; M[tier]="32B"; return

    # ── ≥ 16 GB VRAM ─────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 16 )); then
        highlight "16 GB VRAM → Qwen3-30B-A3B MoE [TOOLS+THINK] ★"
        M[name]="Qwen3-30B-A3B Q4_K_M (MoE)"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
        M[size_gb]=18; M[layers]=48; M[tier]="30B-A3B (MoE)"; return

    # ── ≥ 12 GB VRAM ─────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 12 )); then
        highlight "12 GB VRAM → Qwen3-14B [TOOLS+THINK] ★"
        M[name]="Qwen3-14B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
        M[size_gb]=9; M[layers]=40; M[tier]="14B"; return

    # ── ≥ 10 GB VRAM ─────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 10 )); then
        highlight "10 GB VRAM → Gemma-3-12B [TOOLS] ★"
        M[name]="Gemma-3-12B Q4_K_M"; M[caps]="TOOLS"
        M[file]="google_gemma-3-12b-it-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/google_gemma-3-12b-it-GGUF/resolve/main/google_gemma-3-12b-it-Q4_K_M.gguf"
        M[size_gb]=8; M[layers]=46; M[tier]="12B"; return

    # ── ≥ 8 GB VRAM ──────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 8 )); then
        highlight "8 GB VRAM → Qwen3-8B Q6 [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q6_K"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q6_K.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
        M[size_gb]=6; M[layers]=36; M[tier]="8B"; return

    # ── ≥ 6 GB VRAM ──────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 6 )); then
        highlight "6 GB VRAM → Qwen3-8B Q4 [TOOLS+THINK] ★"
        M[name]="Qwen3-8B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
        M[size_gb]=5; M[layers]=36; M[tier]="8B"; return

    # ── ≥ 4 GB VRAM ──────────────────────────────────────────────────────────
    elif (( HAS_GPU && vram >= 4 )); then
        highlight "4 GB VRAM → Qwen3-4B Q4 [TOOLS+THINK]"
        M[name]="Qwen3-4B Q4_K_M"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
        M[size_gb]=3; M[layers]=36; M[tier]="4B"; return

    # ── ≥ 2 GB VRAM (partial offload) ────────────────────────────────────────
    elif (( HAS_GPU && vram >= 2 )); then
        highlight "Small GPU (${vram} GB) → Qwen3-1.7B partial offload [TOOLS+THINK]"
        M[name]="Qwen3-1.7B Q8_0"; M[caps]="TOOLS + THINK"
        M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
        M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
        M[size_gb]=2; M[layers]=28; M[tier]="1.7B"; return

    # ── CPU-only ──────────────────────────────────────────────────────────────
    else
        if (( ram >= 32 )); then
            highlight "CPU-only (${ram} GB RAM) → Qwen3-14B Q4 [TOOLS+THINK] ★"
            M[name]="Qwen3-14B Q4_K_M"; M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[size_gb]=9; M[layers]=40; M[tier]="14B"
        elif (( ram >= 16 )); then
            highlight "CPU-only (${ram} GB RAM) → Qwen3-8B Q4 [TOOLS+THINK] ★"
            M[name]="Qwen3-8B Q4_K_M"; M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[size_gb]=5; M[layers]=36; M[tier]="8B"
        elif (( ram >= 8 )); then
            highlight "CPU-only (${ram} GB RAM) → Qwen3-4B Q4 [TOOLS+THINK]"
            M[name]="Qwen3-4B Q4_K_M"; M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[size_gb]=3; M[layers]=36; M[tier]="4B"
        else
            highlight "Low RAM CPU-only (${ram} GB) → Qwen3-1.7B Q8 [TOOLS+THINK]"
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

# Optimal thread count: physical cores × sockets, capped at 16 for inference
LSCPU_OUT=$(lscpu 2>/dev/null || true)
PHYS_ONLY=$(echo "$LSCPU_OUT" | awk '/^Core\(s\) per socket/{print $NF}')
SOCKETS=$(echo   "$LSCPU_OUT" | awk '/^Socket\(s\)/{print $NF}')
if [[ -n "$PHYS_ONLY" && -n "$SOCKETS" && "$PHYS_ONLY" =~ ^[0-9]+$ && "$SOCKETS" =~ ^[0-9]+$ ]]; then
    HW_THREADS=$(( PHYS_ONLY * SOCKETS ))
else
    HW_THREADS=$(awk '/^processor/{n++}END{print (n>0?n:4)}' /proc/cpuinfo 2>/dev/null || echo 4)
fi
(( HW_THREADS < 1 )) && HW_THREADS=1
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
echo -e "  ${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${GREEN}║           RECOMMENDED CONFIGURATION                 ║${NC}"
echo -e "  ${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
printf "  ${GREEN}║${NC}  %-16s %-35s${GREEN}║${NC}\n" "Model"         "${M[name]}"
printf "  ${GREEN}║${NC}  %-16s %-35s${GREEN}║${NC}\n" "Capabilities"  "${M[caps]}"
printf "  ${GREEN}║${NC}  %-16s %-35s${GREEN}║${NC}\n" "Size"          "${M[tier]}  (~${M[size_gb]} GB file)"
printf "  ${GREEN}║${NC}  %-16s %-35s${GREEN}║${NC}\n" "GPU layers"    "${GPU_LAYERS} / ${M[layers]}  (~${VRAM_USED_GB} GB VRAM)"
printf "  ${GREEN}║${NC}  %-16s %-35s${GREEN}║${NC}\n" "CPU layers"    "${CPU_LAYERS}  (~${RAM_USED_GB} GB RAM)"
printf "  ${GREEN}║${NC}  %-16s %-35s${GREEN}║${NC}\n" "Threads"       "${HW_THREADS}"
printf "  ${GREEN}║${NC}  %-16s %-35s${GREEN}║${NC}\n" "Batch size"    "${BATCH}"
echo -e "  ${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

if ! ask_yes_no "Proceed with this configuration?"; then
    echo ""
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━  MODEL PICKER  ━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Capability legend:"
    echo -e "    ${GREEN}[TOOLS]${NC}   tool/function calling — agents, JSON, APIs"
    echo -e "    ${YELLOW}[THINK]${NC}   thinking mode — add /think to prompt for step-by-step reasoning"
    echo -e "                             add /no_think for fast plain answers"
    echo -e "    ${MAGENTA}[UNCENS]${NC}  uncensored — no content restrictions (fine-tuned)"
    echo -e "    ${CYAN}★${NC}         best pick for that VRAM tier"
    echo ""
    echo "  ┌────┬──────────────────────────────────┬──────┬──────┬──────────────────────────┐"
    echo "  │ #  │ Model                            │ Quant│ VRAM │ Capabilities             │"
    echo "  ├────┼──────────────────────────────────┼──────┼──────┼──────────────────────────┤"
    echo "  │  1 │ Qwen3-0.6B                       │ Q8   │ CPU  │ [TOOLS] [THINK]  (tiny)  │"
    echo "  │  2 │ Qwen3-1.7B                       │ Q8   │ CPU  │ ★ [TOOLS] [THINK]        │"
    echo "  │  3 │ Phi-3.5-mini 3.8B                │ Q4   │ CPU  │ (basic chat)             │"
    echo "  │  4 │ Qwen3-4B                         │ Q4   │ ~3GB │ ★ [TOOLS] [THINK]        │"
    echo "  │  5 │ Qwen2.5-3B                       │ Q6   │ ~2GB │ [TOOLS]                  │"
    echo "  │  6 │ Qwen3-8B                         │ Q4   │ ~5GB │ ★ [TOOLS] [THINK]        │"
    echo "  │  7 │ Qwen3-8B                         │ Q6   │ ~6GB │ ★ [TOOLS] [THINK]        │"
    echo "  │  8 │ DeepSeek-R1-Distill-Qwen-7B      │ Q4   │ ~5GB │ ★ [THINK]                │"
    echo "  │  9 │ Dolphin3.0-8B                    │ Q4   │ ~5GB │ [UNCENS]                 │"
    echo "  │ 10 │ Dolphin3.0-8B                    │ Q6   │ ~6GB │ [UNCENS]                 │"
    echo "  │ 11 │ Gemma-3-9B                       │ Q4   │ ~5GB │ [TOOLS] (Google)         │"
    echo "  │ 12 │ Gemma-3-12B                      │ Q4   │ ~8GB │ [TOOLS] ★                │"
    echo "  │ 13 │ Mistral-Nemo-12B                 │ Q4   │ ~7GB │ [TOOLS]                  │"
    echo "  │ 14 │ Mistral-Nemo-12B                 │ Q5   │ ~8GB │ [TOOLS]                  │"
    echo "  │ 15 │ Qwen3-14B                        │ Q4   │ ~9GB │ ★ [TOOLS] [THINK]        │"
    echo "  │ 16 │ DeepSeek-R1-Distill-Qwen-14B     │ Q4   │ ~9GB │ ★ [THINK]                │"
    echo "  │ 17 │ Qwen2.5-14B                      │ Q4   │ ~9GB │ [TOOLS]                  │"
    echo "  │ 18 │ Mistral-Small-22B                │ Q4   │~13GB │ [TOOLS]                  │"
    echo "  │ 19 │ Gemma-3-27B                      │ Q4   │~16GB │ [TOOLS]                  │"
    echo "  │ 20 │ Qwen3-30B-A3B  (MoE ★fast)      │ Q4   │~16GB │ ★ [TOOLS] [THINK]        │"
    echo "  │ 21 │ Qwen3-32B                        │ Q4   │~19GB │ ★ [TOOLS] [THINK]        │"
    echo "  │ 22 │ DeepSeek-R1-Distill-Qwen-32B     │ Q4   │~19GB │ [THINK]                  │"
    echo "  │ 23 │ Qwen2.5-32B                      │ Q4   │~19GB │ [TOOLS]                  │"
    echo "  │ 24 │ Llama-3.3-70B                    │ Q4   │~40GB │ ★ [TOOLS] (multi-GPU)    │"
    echo "  └────┴──────────────────────────────────┴──────┴──────┴──────────────────────────┘"
    echo ""
    echo -e "  ${YELLOW}MoE note (20):${NC}  30B params, only 3B active per token → 30B quality at 8B speed."
    echo -e "  ${YELLOW}Distill (8,16,22):${NC} DeepSeek-R1 reasoning distilled into smaller, fast models."
    echo -e "  ${YELLOW}Gemma-3 (11,12,19):${NC} Google's multimodal-capable models with strong tool calling."
    echo ""
    read -r -p "  Choice [1-24]: " manual_choice
    case "$manual_choice" in
        1)  M[name]="Qwen3-0.6B Q8_0";                             M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-0.6B-Q8_0.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen_Qwen3-0.6B-Q8_0.gguf"
            M[size_gb]=1;  M[layers]=28; M[tier]="0.6B" ;;
        2)  M[name]="Qwen3-1.7B Q8_0";                             M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
            M[size_gb]=2;  M[layers]=28; M[tier]="1.7B" ;;
        3)  M[name]="Phi-3.5-mini-instruct Q4_K_M";                M[caps]="none"
            M[file]="Phi-3.5-mini-instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"
            M[size_gb]=2;  M[layers]=32; M[tier]="3.8B" ;;
        4)  M[name]="Qwen3-4B Q4_K_M";                             M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
            M[size_gb]=3;  M[layers]=36; M[tier]="4B" ;;
        5)  M[name]="Qwen2.5-3B-Instruct Q6_K";                    M[caps]="TOOLS"
            M[file]="Qwen2.5-3B-Instruct-Q6_K.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q6_K.gguf"
            M[size_gb]=2;  M[layers]=36; M[tier]="3B" ;;
        6)  M[name]="Qwen3-8B Q4_K_M";                             M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=36; M[tier]="8B" ;;
        7)  M[name]="Qwen3-8B Q6_K";                               M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-8B-Q6_K.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
            M[size_gb]=6;  M[layers]=36; M[tier]="8B" ;;
        8)  M[name]="DeepSeek-R1-Distill-Qwen-7B Q4_K_M";         M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=28; M[tier]="7B" ;;
        9)  M[name]="Dolphin3.0-Llama3.1-8B Q4_K_M";              M[caps]="UNCENS"
            M[file]="Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
            M[size_gb]=5;  M[layers]=32; M[tier]="8B" ;;
        10) M[name]="Dolphin3.0-Llama3.1-8B Q6_K";                M[caps]="UNCENS"
            M[file]="Dolphin3.0-Llama3.1-8B-Q6_K.gguf"
            M[url]="https://huggingface.co/bartowski/Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q6_K.gguf"
            M[size_gb]=6;  M[layers]=32; M[tier]="8B" ;;
        11) M[name]="Gemma-3-9B Q4_K_M";                           M[caps]="TOOLS"
            M[file]="google_gemma-3-9b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-9b-it-GGUF/resolve/main/google_gemma-3-9b-it-Q4_K_M.gguf"
            M[size_gb]=6;  M[layers]=42; M[tier]="9B" ;;
        12) M[name]="Gemma-3-12B Q4_K_M";                          M[caps]="TOOLS"
            M[file]="google_gemma-3-12b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-12b-it-GGUF/resolve/main/google_gemma-3-12b-it-Q4_K_M.gguf"
            M[size_gb]=8;  M[layers]=46; M[tier]="12B" ;;
        13) M[name]="Mistral-Nemo-12B Q4_K_M";                     M[caps]="TOOLS"
            M[file]="Mistral-Nemo-Instruct-2407-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q4_K_M.gguf"
            M[size_gb]=7;  M[layers]=40; M[tier]="12B" ;;
        14) M[name]="Mistral-Nemo-12B Q5_K_M";                     M[caps]="TOOLS"
            M[file]="Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"
            M[size_gb]=8;  M[layers]=40; M[tier]="12B" ;;
        15) M[name]="Qwen3-14B Q4_K_M";                            M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        16) M[name]="DeepSeek-R1-Distill-Qwen-14B Q4_K_M";        M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=40; M[tier]="14B" ;;
        17) M[name]="Qwen2.5-14B-Instruct Q4_K_M";                 M[caps]="TOOLS"
            M[file]="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf"
            M[size_gb]=9;  M[layers]=48; M[tier]="14B" ;;
        18) M[name]="Mistral-Small-22B Q4_K_M";                    M[caps]="TOOLS"
            M[file]="Mistral-Small-22B-ArliAI-RPMax-v1.1-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Mistral-Small-22B-ArliAI-RPMax-v1.1-GGUF/resolve/main/Mistral-Small-22B-ArliAI-RPMax-v1.1-Q4_K_M.gguf"
            M[size_gb]=13; M[layers]=48; M[tier]="22B" ;;
        19) M[name]="Gemma-3-27B Q4_K_M";                          M[caps]="TOOLS"
            M[file]="google_gemma-3-27b-it-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/google_gemma-3-27b-it-GGUF/resolve/main/google_gemma-3-27b-it-Q4_K_M.gguf"
            M[size_gb]=16; M[layers]=62; M[tier]="27B" ;;
        20) M[name]="Qwen3-30B-A3B Q4_K_M (MoE)";                 M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
            M[size_gb]=18; M[layers]=48; M[tier]="30B-A3B" ;;
        21) M[name]="Qwen3-32B Q4_K_M";                            M[caps]="TOOLS + THINK"
            M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        22) M[name]="DeepSeek-R1-Distill-Qwen-32B Q4_K_M";        M[caps]="THINK"
            M[file]="DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        23) M[name]="Qwen2.5-32B-Instruct Q4_K_M";                 M[caps]="TOOLS"
            M[file]="Qwen2.5-32B-Instruct-Q4_K_M.gguf"
            M[url]="https://huggingface.co/bartowski/Qwen2.5-32B-Instruct-GGUF/resolve/main/Qwen2.5-32B-Instruct-Q4_K_M.gguf"
            M[size_gb]=19; M[layers]=64; M[tier]="32B" ;;
        24) M[name]="Llama-3.3-70B-Instruct Q4_K_M";               M[caps]="TOOLS"
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

# ── apt-get update first ───────────────────────────────────────────────────────
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
_PYVER_REFRESH=$("$PYTHON_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -n1 || echo "$PYVER_RAW")
PYVER_MAJOR=$(echo "$_PYVER_REFRESH" | cut -d. -f1)
PYVER_MINOR=$(echo "$_PYVER_REFRESH" | cut -d. -f2)
unset _PYVER_REFRESH

# ── Install pip + venv ────────────────────────────────────────────────────────
# Ubuntu 24.04 requires the version-specific python3.12-venv package (not just python3-venv).
info "Installing python3-pip, python3-venv, python${PYVER_MAJOR}.${PYVER_MINOR}-venv…"
sudo apt-get install -y \
    python3-pip \
    python3-venv \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-venv" \
    "python${PYVER_MAJOR}.${PYVER_MINOR}-dev" \
    2>/dev/null \
    || warn "Some Python packages failed — will attempt to continue."

# ── Detect whether pip needs --break-system-packages ─────────────────────────
# Ubuntu 23.04+ / Debian 12+ enforce PEP 668: pip refuses to install into the
# system site-packages. We always use venvs, so we only need this flag if
# somehow using the system python directly (e.g. during get-pip bootstrap).
PIP_BSP_FLAG=""
# PEP 668: detect externally-managed environments (Ubuntu 23.04+, Debian 12+).
# Check for the marker file that pip uses to detect this — more reliable than
# running pip --dry-run, which requires pip >= 22.1 and may not exist yet.
_py_lib_dir=$("$PYTHON_BIN" -c "import sysconfig; print(sysconfig.get_path('stdlib'))" 2>/dev/null || true)
if [[ -f "${_py_lib_dir}/EXTERNALLY-MANAGED" ]] 2>/dev/null; then
    PIP_BSP_FLAG="--break-system-packages"
    info "PEP 668 system-managed env detected — using --break-system-packages for bootstrap only."
fi
unset _py_lib_dir

# If pip still not available, bootstrap it
if ! "$PYTHON_BIN" -m pip --version &>/dev/null 2>&1; then
    info "pip not found — bootstrapping via get-pip.py…"
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$TEMP_DIR/get-pip.py" \
        && "$PYTHON_BIN" "$TEMP_DIR/get-pip.py" --quiet ${PIP_BSP_FLAG:+"$PIP_BSP_FLAG"} \
        && rm -f "$TEMP_DIR/get-pip.py" \
        || warn "get-pip.py bootstrap failed — pip may be unavailable."
fi

# Upgrade pip; use BSP flag only if needed
"$PYTHON_BIN" -m pip install --upgrade pip --quiet ${PIP_BSP_FLAG:+"$PIP_BSP_FLAG"} 2>/dev/null \
    || warn "pip upgrade failed — using whatever version is installed."
PIP_VER=$("$PYTHON_BIN" -m pip --version 2>/dev/null | awk '{print $2}' || echo "unknown")
info "pip $PIP_VER ✔"

# ── Verify venv works before proceeding ───────────────────────────────────────
TEST_VENV="$TEMP_DIR/.test_venv_$$"
if "$PYTHON_BIN" -m venv "$TEST_VENV" 2>/dev/null; then
    rm -rf "$TEST_VENV"
    info "Python venv: OK  ($("$PYTHON_BIN" --version 2>&1))"
else
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

# Core build + runtime packages required for every install path
CORE_PKGS=(curl wget git build-essential cmake ninja-build
           python3 lsb-release zstd pciutils)

# Optional but highly recommended
OPT_PKGS=(ffmpeg bat grc source-highlight)

# CPU inference acceleration (AVX2 path for llama.cpp BLAS)
(( HAS_AVX2 )) && CORE_PKGS+=(libopenblas-dev)

sudo apt-get install -y "${CORE_PKGS[@]}" || warn "Some core packages may have failed."
# Optional packages: failures are non-fatal
sudo apt-get install -y "${OPT_PKGS[@]}" 2>/dev/null \
    || info "Some optional packages unavailable (bat/grc) — will skip syntax highlighting."

for cmd in curl wget git python3; do
    command -v "$cmd" &>/dev/null || error "Critical dependency missing: $cmd"
done
"$PYTHON_BIN" -m pip --version &>/dev/null || error "pip not available — check Python environment step above."
info "System dependencies OK."

# =============================================================================
# STEP 5 — DIRECTORIES + PATH
# =============================================================================
step "Directories"
mkdir -p "$OLLAMA_MODELS" "$GGUF_MODELS" "$TEMP_DIR" "$BIN_DIR" "$CONFIG_DIR" "$GUI_DIR"
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
        # Map uname -m → NVIDIA repo arch string
        # x86_64 → x86_64 | aarch64 → sbsa (NVIDIA's arm64 server arch name)
        case "$HOST_ARCH" in
            x86_64)  _cuda_repo_arch="x86_64" ;;
            aarch64) _cuda_repo_arch="sbsa" ;;
            *)       _cuda_repo_arch="x86_64"
                     warn "Unknown arch $HOST_ARCH — defaulting CUDA repo to x86_64." ;;
        esac
        KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION//./}/${_cuda_repo_arch}/cuda-keyring_1.1-1_all.deb"
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
        # Add ROCm lib path to LD_LIBRARY_PATH and persist it in ~/.bashrc
        local rocm_lib=""
        for _rp in /opt/rocm/lib /opt/rocm-*/lib /usr/lib/x86_64-linux-gnu; do
            if [[ -f "$_rp/libhipblas.so" || -f "$_rp/librocblas.so" ]]; then
                rocm_lib="$_rp"; break
            fi
        done
        [[ -z "$rocm_lib" ]] && rocm_lib="/opt/rocm/lib"   # best guess
        export LD_LIBRARY_PATH="$rocm_lib:${LD_LIBRARY_PATH:-}"
        export PATH="/opt/rocm/bin:$PATH"

        # Detect gfx target now (after ROCm installed) if not detected earlier
        if [[ -z "$AMD_GFX_VER" ]] && command -v rocminfo &>/dev/null; then
            AMD_GFX_VER=$(rocminfo 2>/dev/null | grep -oP 'gfx\d+[a-z]*' | head -n1 || echo "")
        fi

        _RC="$HOME/.bashrc"
        if ! grep -q "# ROCm — llm-auto-setup" "$_RC" 2>/dev/null; then
            printf '\n# ROCm — llm-auto-setup\n' >> "$_RC"
            printf 'export PATH="/opt/rocm/bin:$PATH"\n' >> "$_RC"
            printf 'export LD_LIBRARY_PATH="%s:${LD_LIBRARY_PATH:-}"\n' "$rocm_lib" >> "$_RC"
            # Persist HSA_OVERRIDE_GFX_VERSION for cards not yet in ROCm whitelist
            # (e.g. RX 6600/6700/6800/7600/7700/7900). Only write if detected.
            if [[ -n "$AMD_GFX_VER" ]]; then
                # Convert gfxNNNN[x] → major.minor.patch dot-notation for HSA_OVERRIDE_GFX_VERSION.
                # Handles all known formats:
                #   gfx803   → 8.0.3    (Fiji/Tonga,    3-digit)
                #   gfx906   → 9.0.6    (Vega20,        3-digit)
                #   gfx90a   → 9.0.10   (Arcturus,      2-digit base + letter suffix)
                #   gfx1010  → 10.1.0   (Navi10,        4-digit)
                #   gfx1100  → 11.0.0   (Navi31/RX7900, 4-digit)
                #   gfx1103  → 11.0.3   (RDNA3 iGPU,    4-digit)
                # Strategy: check for letter suffix first, then split by digit count.
                _gfx_raw="${AMD_GFX_VER#gfx}"
                _gfx_patch_suffix=""
                _gfx_digits="$_gfx_raw"
                if [[ "$_gfx_raw" =~ ^([0-9]+)([a-f])$ ]]; then
                    _gfx_digits="${BASH_REMATCH[1]}"
                    case "${BASH_REMATCH[2]}" in
                        a) _gfx_patch_suffix="10" ;; b) _gfx_patch_suffix="11" ;;
                        c) _gfx_patch_suffix="12" ;; d) _gfx_patch_suffix="13" ;;
                        e) _gfx_patch_suffix="14" ;; f) _gfx_patch_suffix="15" ;;
                    esac
                fi
                _gfx_len="${#_gfx_digits}"
                if (( _gfx_len == 2 && ${#_gfx_patch_suffix} > 0 )); then
                    # e.g. gfx90a: digits=90, patch_suffix=10 → 9.0.10
                    _hsa_ver="${_gfx_digits:0:1}.${_gfx_digits:1:1}.${_gfx_patch_suffix}"
                elif (( _gfx_len == 3 )); then
                    _patch="${_gfx_patch_suffix:-${_gfx_digits:2:1}}"
                    _hsa_ver="${_gfx_digits:0:1}.0.${_patch}"
                elif (( _gfx_len >= 4 )); then
                    _patch="${_gfx_patch_suffix:-${_gfx_digits:3}}"
                    _hsa_ver="${_gfx_digits:0:2}.${_gfx_digits:2:1}.${_patch}"
                else
                    _hsa_ver="$_gfx_raw"   # unexpected format — pass through as-is
                fi
                printf '# HSA_OVERRIDE_GFX_VERSION: allows RDNA2/3 cards not in ROCm whitelist\n' >> "$_RC"
                printf 'export HSA_OVERRIDE_GFX_VERSION="%s"\n' "$_hsa_ver" >> "$_RC"
                printf 'export ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-0}\n' >> "$_RC"
                export HSA_OVERRIDE_GFX_VERSION="$_hsa_ver"
                export ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}"
                info "HSA_OVERRIDE_GFX_VERSION=$_hsa_ver written to ~/.bashrc (${AMD_GFX_VER})"
            fi
        fi
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
            # Fallback: direct apt install of minimal ROCm components.
            # Discover the latest ROCm release tag from the repo index instead of
            # hardcoding a version number that will go stale.
            _rocm_apt_arch="amd64"
            [[ "$HOST_ARCH" == "aarch64" ]] && _rocm_apt_arch="arm64"
            _rocm_latest=$(wget -qO- "https://repo.radeon.com/rocm/apt/" 2>/dev/null \
                | grep -oP '(?<=href=")[0-9]+\.[0-9]+(?=/)' | sort -V | tail -1 || echo "6.3")
            wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key 2>/dev/null \
                | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/rocm.gpg || true
            echo "deb [arch=${_rocm_apt_arch}] https://repo.radeon.com/rocm/apt/${_rocm_latest} ${DISTRO_CODENAME} main" \
                | sudo tee /etc/apt/sources.list.d/rocm.list >/dev/null
            sudo apt-get update -qq || true
            sudo apt-get install -y rocm-hip-sdk rocm-opencl-sdk \
                || warn "ROCm apt install failed — check https://rocm.docs.amd.com"
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

# ── Build flags tuned to detected CPU + GPU features ─────────────────────────
CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release"
(( HAS_NVIDIA ))  && CMAKE_ARGS+=" -DGGML_CUDA=ON -DLLAMA_CUBLAS=ON"
(( HAS_AMD_GPU )) && CMAKE_ARGS+=" -DGGML_HIPBLAS=ON"
(( HAS_AVX512 ))  && CMAKE_ARGS+=" -DGGML_AVX512=ON -DGGML_AVX2=ON -DGGML_FMA=ON"
(( !HAS_AVX512 && HAS_AVX2 )) && CMAKE_ARGS+=" -DGGML_AVX2=ON -DGGML_FMA=ON"
(( !HAS_AVX2 && HAS_AVX ))    && CMAKE_ARGS+=" -DGGML_AVX=ON"
(( HAS_NEON ))                 && CMAKE_ARGS+=" -DGGML_NEON=ON"
export SOURCE_BUILD_CMAKE_ARGS="$CMAKE_ARGS"

LLAMA_INSTALLED=0

# ── NVIDIA CUDA wheels ────────────────────────────────────────────────────────
if (( HAS_NVIDIA )); then
    CUDA_VER=""
    CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -n1 || true)
    [[ -z "$CUDA_VER" ]] && CUDA_VER="$CUDA_VER_SMI"
    [[ -z "$CUDA_VER" ]] && CUDA_VER="12.4"   # default to latest stable
    CUDA_TAG="cu$(echo "$CUDA_VER" | tr -d '.')"
    info "CUDA $CUDA_VER → wheel tag $CUDA_TAG"
    # Try exact match first, then fallback tags in order of recency
    for wheel_url in \
        "https://abetlen.github.io/llama-cpp-python/whl/${CUDA_TAG}" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu125" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu124" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu123" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu122" \
        "https://abetlen.github.io/llama-cpp-python/whl/cu121"; do
        info "Trying CUDA wheel: $wheel_url"
        if pip install llama-cpp-python \
                --index-url "$wheel_url" \
                --extra-index-url https://pypi.org/simple \
                --quiet 2>&1; then
            info "CUDA wheel installed from $wheel_url"
            LLAMA_INSTALLED=1
            break
        fi
        warn "Failed — trying next."
    done
fi

# ── AMD ROCm/HIP wheels ───────────────────────────────────────────────────────
if (( HAS_AMD_GPU && !HAS_NVIDIA && LLAMA_INSTALLED == 0 )); then
    info "Trying ROCm pre-built wheels for llama-cpp-python…"
    for wheel_url in \
        "https://abetlen.github.io/llama-cpp-python/whl/rocm620" \
        "https://abetlen.github.io/llama-cpp-python/whl/rocm610" \
        "https://abetlen.github.io/llama-cpp-python/whl/rocm600" \
        "https://abetlen.github.io/llama-cpp-python/whl/rocm550"; do
        info "Trying ROCm wheel: $wheel_url"
        if pip install llama-cpp-python \
                --index-url "$wheel_url" \
                --extra-index-url https://pypi.org/simple \
                --quiet 2>&1; then
            info "ROCm wheel installed from $wheel_url"
            LLAMA_INSTALLED=1
            break
        fi
        warn "Failed — trying next."
    done
fi

# ── Source build fallback ─────────────────────────────────────────────────────
if (( LLAMA_INSTALLED == 0 )); then
    if (( HAS_NVIDIA )); then
        warn "No pre-built CUDA wheel found — building from source (~5–10 min)…"
        MAKE_JOBS="$HW_THREADS" CMAKE_ARGS="$SOURCE_BUILD_CMAKE_ARGS" \
        pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python CUDA build failed. Check logs."
    elif (( HAS_AMD_GPU )); then
        warn "No pre-built ROCm wheel found — building from source (~8–15 min)…"
        # Auto-detect ROCm gfx target for HSA_OVERRIDE_GFX_VERSION
        # Needed for RDNA2/3 cards not yet in ROCm's whitelist (e.g. RX 6000/7000 series)
        if [[ -n "$AMD_GFX_VER" ]]; then
            # Convert gfxNNNN[x] → major.minor.patch (same logic as setup_rocm_env above)
            _gfx_raw="${AMD_GFX_VER#gfx}"
            _gfx_patch_suffix="" _gfx_digits="$_gfx_raw"
            if [[ "$_gfx_raw" =~ ^([0-9]+)([a-f])$ ]]; then
                _gfx_digits="${BASH_REMATCH[1]}"
                case "${BASH_REMATCH[2]}" in
                    a) _gfx_patch_suffix="10" ;; b) _gfx_patch_suffix="11" ;;
                    c) _gfx_patch_suffix="12" ;; d) _gfx_patch_suffix="13" ;;
                    e) _gfx_patch_suffix="14" ;; f) _gfx_patch_suffix="15" ;;
                esac
            fi
            _gfx_len="${#_gfx_digits}"
            if (( _gfx_len == 2 && ${#_gfx_patch_suffix} > 0 )); then
                _hsa_ver="${_gfx_digits:0:1}.${_gfx_digits:1:1}.${_gfx_patch_suffix}"
            elif (( _gfx_len == 3 )); then
                _patch="${_gfx_patch_suffix:-${_gfx_digits:2:1}}"
                _hsa_ver="${_gfx_digits:0:1}.0.${_patch}"
            elif (( _gfx_len >= 4 )); then
                _patch="${_gfx_patch_suffix:-${_gfx_digits:3}}"
                _hsa_ver="${_gfx_digits:0:2}.${_gfx_digits:2:1}.${_patch}"
            else
                _hsa_ver="$_gfx_raw"
            fi
            export HSA_OVERRIDE_GFX_VERSION="$_hsa_ver"
            info "Set HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION} for ${AMD_GFX_VER}"
        fi
        MAKE_JOBS="$HW_THREADS" \
        CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DGGML_HIPBLAS=ON" \
        pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python ROCm build failed. Check logs."
    else
        info "CPU-only build — compiling llama-cpp-python (~3–5 min)…"
        MAKE_JOBS="$HW_THREADS" CMAKE_ARGS="$SOURCE_BUILD_CMAKE_ARGS" \
        pip install llama-cpp-python --no-cache-dir \
            || warn "llama-cpp-python CPU build failed. Check logs."
    fi
    # Mark that a source build was attempted (regardless of success).
    # LLAMA_INSTALLED will be validated by check_python_module immediately below.
    LLAMA_INSTALLED=1
fi

if check_python_module llama_cpp; then
    _lcp_ver=$("$VENV_DIR/bin/python3" -c "import llama_cpp; print(getattr(llama_cpp,'__version__','?'))" 2>/dev/null || echo "?")
    info "llama-cpp-python ${_lcp_ver} ✔"
else
    warn "llama-cpp-python import failed — run-gguf won't work."
    if (( HAS_NVIDIA )); then
        warn "  Try: sudo ldconfig && exec bash"
    elif (( HAS_AMD_GPU )); then
        warn "  Try: exec bash  (reloads LD_LIBRARY_PATH with ROCm libs)"
    fi
fi

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
# llm-auto-setup config — generated $(date '+%Y-%m-%d %H:%M:%S') by v${SCRIPT_VERSION}
# Format: KEY="value"  (grep-compatible; sections are comments only)

# [model]
MODEL_NAME="${M[name]}"
MODEL_URL="${M[url]}"
MODEL_FILENAME="${M[file]}"
MODEL_SIZE="${M[tier]}"
MODEL_CAPS="${M[caps]}"
MODEL_LAYERS="${M[layers]}"

# [hardware]
GPU_LAYERS="$GPU_LAYERS"
CPU_LAYERS="$CPU_LAYERS"
HW_THREADS="$HW_THREADS"
BATCH="$BATCH"

# [hardware.info]
GPU_NAME="$GPU_NAME"
GPU_VRAM_GB="$GPU_VRAM_GB"
TOTAL_RAM_GB="$TOTAL_RAM_GB"
HOST_ARCH="$HOST_ARCH"
DISTRO_ID="$DISTRO_ID"
DISTRO_VERSION="$UBUNTU_VERSION"
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
        # Register GGUF with Ollama so it appears in Open WebUI and Neural Terminal.
        # Without this, directly downloaded GGUFs won't show up in the Ollama model list.
        if command -v ollama &>/dev/null; then
            # Derive a clean Ollama model tag from the filename.
            # Ollama requires lowercase tags. We separate the quant suffix with ':'
            # e.g. Qwen_Qwen3-8B-Q4_K_M.gguf → qwen_qwen3-8b:q4_k_m
            # sed: case-insensitive match on -Q or -q followed by digit → replace hyphen with colon
            OLLAMA_TAG=$(basename "${M[file]}" .gguf                 | sed -E 's/-([Qq][0-9].*)$/:\1/'                 | tr '[:upper:]' '[:lower:]')

            info "Registering model with Ollama as: $OLLAMA_TAG"
            info "  This lets Open WebUI, Neural Terminal, and 'ollama run' use it."

            MODELFILE_PATH="$TEMP_DIR/Modelfile.$$"
            mkdir -p "$TEMP_DIR"
            cat > "$MODELFILE_PATH" <<MODELFILE
FROM $GGUF_MODELS/${M[file]}
# 999 = Ollama sentinel: "put as many layers on GPU as VRAM allows"
# This is always better than a pre-calculated value because Ollama measures
# actual free VRAM at load time, accounting for driver/CUDA overhead.
PARAMETER num_gpu 999
PARAMETER num_thread $HW_THREADS
# 8192 context — larger than 4096 but still safe for 12 GB VRAM.
# Flash attention + q8_0 KV cache make this affordable even on 6-8 GB cards.
PARAMETER num_ctx 8192
MODELFILE

            if ollama create "$OLLAMA_TAG" -f "$MODELFILE_PATH"; then
                info "✔ Model registered: $OLLAMA_TAG"
                info "  Now available in Open WebUI and llm-chat. Run: ollama run $OLLAMA_TAG"
                # Save tag to config so other tools can reference it
                echo "OLLAMA_TAG=\"$OLLAMA_TAG\"" >> "$MODEL_CONFIG"
            else
                warn "ollama create failed — model won't appear in Open WebUI or Neural Terminal."
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

# ── llm-doctor ────────────────────────────────────────────────────────────────
# Comprehensive diagnostics: checks every component and prints fix instructions
cat > "$BIN_DIR/llm-doctor" <<'DOCTOR_EOF'
#!/usr/bin/env bash
# llm-doctor — diagnose local LLM stack problems
# Run this when something isn't working. Checks and prints fix instructions.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; PASS=$(( PASS+1 )); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; WARN=$(( WARN+1 )); }
fail() { echo -e "  ${RED}✘${NC}  $1"; FAIL=$(( FAIL+1 )); }

_is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

echo ""
echo -e "${CYAN}═══════════════  LLM DOCTOR  ═══════════════${NC}"
echo ""

# ── GPU ──────────────────────────────────────────────────────────────────────
echo -e "${CYAN}[ GPU ]${NC}"
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "?")
    VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
    ok "NVIDIA GPU: $GPU_NAME  (${VRAM} MiB VRAM)"
    if ldconfig -p 2>/dev/null | grep -q 'libcudart\.so\.12'; then
        ok "libcudart.so.12 in ldconfig"
    else
        fail "libcudart.so.12 NOT found → sudo ldconfig && exec bash"
    fi
    if command -v nvcc &>/dev/null; then
        ok "nvcc: $(nvcc --version 2>/dev/null | grep release | head -1 | xargs)"
    else
        warn "nvcc not in PATH — try: exec bash (after setup baked CUDA path in ~/.bashrc)"
    fi
elif command -v rocminfo &>/dev/null || [[ -d /opt/rocm ]]; then
    GFX=$(rocminfo 2>/dev/null | grep -oP 'gfx\d+[a-z]*' | head -1 || echo "?")
    ok "AMD ROCm installed (gfx target: $GFX)"
    [[ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]] && ok "HSA_OVERRIDE_GFX_VERSION=$HSA_OVERRIDE_GFX_VERSION" \
        || warn "HSA_OVERRIDE_GFX_VERSION not set — some RDNA2/3 cards need this"
    if ldconfig -p 2>/dev/null | grep -q 'libhipblas'; then
        ok "libhipblas in ldconfig"
    else
        warn "libhipblas not in ldconfig → exec bash (to reload LD_LIBRARY_PATH)"
    fi
else
    warn "No GPU acceleration detected (CPU-only mode)"
fi
echo ""

# ── Ollama ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}[ Ollama ]${NC}"
if command -v ollama &>/dev/null; then
    ok "ollama binary: $(ollama --version 2>/dev/null || echo 'present')"
else
    fail "ollama not found → curl -fsSL https://ollama.com/install.sh | sh"
fi
if _is_wsl2; then
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        ok "Ollama process running (WSL2)"
    else
        fail "Ollama not running → ollama-start"
    fi
else
    if systemctl is-active --quiet ollama 2>/dev/null; then
        ok "Ollama systemd service: active"
    else
        fail "Ollama service not active → sudo systemctl start ollama"
    fi
fi
if curl -sf --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    N=$(curl -sf http://127.0.0.1:11434/api/tags 2>/dev/null | grep -o '"name"' | wc -l || echo 0)
    ok "Ollama API reachable (${N} model(s) registered)"
else
    fail "Ollama API not reachable on port 11434 → ollama-start"
fi
echo ""

# ── Python / venv ────────────────────────────────────────────────────────────
echo -e "${CYAN}[ Python ]${NC}"
VENV="$HOME/.local/share/llm-venv"
if [[ -f "$VENV/bin/python3" ]]; then
    ok "venv: $VENV  ($("$VENV/bin/python3" --version 2>&1))"
else
    fail "venv missing → re-run llm-setup"
fi
if "$VENV/bin/python3" -c "import llama_cpp" 2>/dev/null; then
    _lcp_ver=$("$VENV/bin/python3" -c "import llama_cpp; print(getattr(llama_cpp,'__version__','?'))" 2>/dev/null || echo "?")
    ok "llama-cpp-python $( echo $_lcp_ver)"
else
    fail "llama-cpp-python import failed → exec bash && run-gguf"
fi
echo ""

# ── Helper tools ─────────────────────────────────────────────────────────────
echo -e "${CYAN}[ Tools ]${NC}"
BIN="$HOME/.local/bin"
for t in llm-web llm-chat llm-stop llm-update llm-switch llm-add run-gguf local-models-info; do
    [[ -x "$BIN/$t" ]] && ok "$t" || fail "$t missing → re-run llm-setup"
done
OWUI_VENV_DR="$HOME/.local/share/open-webui-venv"
if [[ -x "$OWUI_VENV_DR/bin/open-webui" ]]; then
    OWUI_VER_DR=$("$OWUI_VENV_DR/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?")
    ok "Open WebUI $OWUI_VER_DR  ($OWUI_VENV_DR)"
else
    fail "Open WebUI not installed → re-run llm-setup"
fi
[[ -x "$BIN/cowork" ]] && ok "cowork (Open Interpreter)" || warn "cowork not installed"
[[ -x "$BIN/aider" ]]  && ok "aider"                     || warn "aider not installed"
echo ""

# ── Models ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}[ Models ]${NC}"
GGUF_DIR="$HOME/local-llm-models/gguf"
if ls "$GGUF_DIR"/*.gguf &>/dev/null 2>&1; then
    while IFS= read -r f; do
        ok "GGUF: $(basename "$f")  ($(du -sh "$f" 2>/dev/null | cut -f1))"
    done < <(ls "$GGUF_DIR"/*.gguf 2>/dev/null)
else
    warn "No GGUF files in $GGUF_DIR → llm-add"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "${CYAN}═══════════════  SUMMARY  ═══════════════${NC}"
echo -e "  ${GREEN}OK${NC}:   $PASS    ${YELLOW}Warn${NC}: $WARN    ${RED}Fail${NC}: $FAIL"
echo ""
(( FAIL > 0 )) && echo -e "  Fix failures above, then run ${YELLOW}llm-doctor${NC} again." || \
    echo -e "  ${GREEN}Everything looks good!${NC}"
echo ""
DOCTOR_EOF
chmod +x "$BIN_DIR/llm-doctor"

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

# ── Open WebUI ────────────────────────────────────────────────────────────────
if pgrep -f "open-webui" >/dev/null 2>&1; then
    pkill -f "open-webui" 2>/dev/null && echo "✔ Open WebUI stopped." || true
else
    echo "  Open WebUI: not running."
fi
STOP_EOF
chmod +x "$BIN_DIR/llm-stop"

# ── llm-update ────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/llm-update" <<'UPDATE_EOF'
#!/usr/bin/env bash
# llm-update — upgrade Ollama, Open WebUI, and pull latest model
set -uo pipefail

CONFIG="$HOME/.config/local-llm/selected_model.conf"
OWUI_VENV="$HOME/.local/share/open-webui-venv"

echo ""
echo "═══════════════  LLM Stack Updater  ═══════════════"
echo ""

echo "[ 1/3 ] Updating Ollama…"
curl -fsSL https://ollama.com/install.sh | sh     && echo "  ✔ Ollama: $(ollama --version 2>/dev/null || echo ok)"     || echo "  ✘ Ollama update failed."

echo ""
echo "[ 2/3 ] Updating Open WebUI…"
if [[ -d "$OWUI_VENV" ]]; then
    OLD_VER=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?")
    "$OWUI_VENV/bin/pip" install --upgrade open-webui --quiet \
        && NEW_VER=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | awk '/^Version:/{print $2}' || echo "?") \
        && echo "  ✔ Open WebUI: $OLD_VER → $NEW_VER" \
        || echo "  ✘ Open WebUI update failed."
else
    echo "  Open WebUI not installed — run setup script to install."
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
    "Qwen3-0.6B|Q8_0|0|TOOLS+THINK|1|28|Qwen_Qwen3-0.6B-Q8_0.gguf|Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen_Qwen3-0.6B-Q8_0.gguf"
    "Qwen3-1.7B|Q8_0|0|TOOLS+THINK|2|28|Qwen_Qwen3-1.7B-Q8_0.gguf|Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q8_0.gguf"
    "Phi-3.5-mini 3.8B|Q4_K_M|0|basic chat|2|32|Phi-3.5-mini-instruct-Q4_K_M.gguf|Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"
    "Qwen3-4B|Q4_K_M|3|TOOLS+THINK|3|36|Qwen_Qwen3-4B-Q4_K_M.gguf|Qwen_Qwen3-4B-GGUF/resolve/main/Qwen_Qwen3-4B-Q4_K_M.gguf"
    "Qwen2.5-3B|Q6_K|2|TOOLS|2|36|Qwen2.5-3B-Instruct-Q6_K.gguf|Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q6_K.gguf"
    "Qwen3-8B|Q4_K_M|5|TOOLS+THINK|5|36|Qwen_Qwen3-8B-Q4_K_M.gguf|Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q4_K_M.gguf"
    "Qwen3-8B|Q6_K|6|TOOLS+THINK|6|36|Qwen_Qwen3-8B-Q6_K.gguf|Qwen_Qwen3-8B-GGUF/resolve/main/Qwen_Qwen3-8B-Q6_K.gguf"
    "DeepSeek-R1-Distill-7B|Q4_K_M|5|THINK|5|28|DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf"
    "Dolphin3.0-8B|Q4_K_M|5|UNCENS|5|32|Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf|Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q4_K_M.gguf"
    "Dolphin3.0-8B|Q6_K|6|UNCENS|6|32|Dolphin3.0-Llama3.1-8B-Q6_K.gguf|Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q6_K.gguf"
    "Gemma-3-9B|Q4_K_M|6|TOOLS|6|42|google_gemma-3-9b-it-Q4_K_M.gguf|google_gemma-3-9b-it-GGUF/resolve/main/google_gemma-3-9b-it-Q4_K_M.gguf"
    "Gemma-3-12B|Q4_K_M|8|TOOLS|8|46|google_gemma-3-12b-it-Q4_K_M.gguf|google_gemma-3-12b-it-GGUF/resolve/main/google_gemma-3-12b-it-Q4_K_M.gguf"
    "Mistral-Nemo-12B|Q4_K_M|7|TOOLS|7|40|Mistral-Nemo-Instruct-2407-Q4_K_M.gguf|Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q4_K_M.gguf"
    "Mistral-Nemo-12B|Q5_K_M|8|TOOLS|8|40|Mistral-Nemo-Instruct-2407-Q5_K_M.gguf|Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"
    "Qwen3-14B|Q4_K_M|9|TOOLS+THINK|9|40|Qwen_Qwen3-14B-Q4_K_M.gguf|Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf"
    "DeepSeek-R1-Distill-14B|Q4_K_M|9|THINK|9|40|DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
    "Qwen2.5-14B|Q4_K_M|9|TOOLS|9|48|Qwen2.5-14B-Instruct-Q4_K_M.gguf|Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf"
    "Mistral-Small-22B|Q4_K_M|13|TOOLS|13|48|Mistral-Small-22B-ArliAI-RPMax-v1.1-Q4_K_M.gguf|Mistral-Small-22B-ArliAI-RPMax-v1.1-GGUF/resolve/main/Mistral-Small-22B-ArliAI-RPMax-v1.1-Q4_K_M.gguf"
    "Gemma-3-27B|Q4_K_M|16|TOOLS|16|62|google_gemma-3-27b-it-Q4_K_M.gguf|google_gemma-3-27b-it-GGUF/resolve/main/google_gemma-3-27b-it-Q4_K_M.gguf"
    "Qwen3-30B-A3B MoE|Q4_K_M|16|TOOLS+THINK|18|48|Qwen_Qwen3-30B-A3B-Q4_K_M.gguf|Qwen_Qwen3-30B-A3B-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
    "Qwen3-32B|Q4_K_M|19|TOOLS+THINK|19|64|Qwen_Qwen3-32B-Q4_K_M.gguf|Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf"
    "DeepSeek-R1-Distill-32B|Q4_K_M|19|THINK|19|64|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"
    "Qwen2.5-32B|Q4_K_M|19|TOOLS|19|64|Qwen2.5-32B-Instruct-Q4_K_M.gguf|Qwen2.5-32B-Instruct-GGUF/resolve/main/Qwen2.5-32B-Instruct-Q4_K_M.gguf"
    "Llama-3.3-70B|Q4_K_M|40|TOOLS|40|80|Llama-3.3-70B-Instruct-Q4_K_M.gguf|Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q4_K_M.gguf"
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
  // Tables (simple) — cell content is HTML-escaped to prevent XSS
  t = t.replace(/(\|.+\|\n\|[-| :]+\|\n(?:\|.+\|\n?)+)/g, tbl => {
    const rows = tbl.trim().split('\n');
    const header = rows[0].split('|').filter(c=>c.trim()).map(c=>`<th>${escHtml(c.trim())}</th>`).join('');
    const body = rows.slice(2).map(r=>'<tr>'+r.split('|').filter(c=>c.trim()).map(c=>`<td>${escHtml(c.trim())}</td>`).join('')+'</tr>').join('');
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
# Prefer ss (iproute2, always present on Ubuntu) over lsof (optional package).
# fuser is a POSIX fallback if ss somehow isn't available.
OLD_PID=""
if command -v ss &>/dev/null; then
    OLD_PID=$(ss -tlnp "sport = :$HTTP_PORT" 2>/dev/null \
        | awk '/LISTEN/{match($0,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1 || true)
fi
if [[ -z "$OLD_PID" ]] && command -v fuser &>/dev/null; then
    OLD_PID=$(fuser "${HTTP_PORT}/tcp" 2>/dev/null | tr -d ' ' || true)
fi
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
# OPEN WEBUI — Primary Web UI
# =============================================================================
step "Open WebUI (primary browser UI)"

OWUI_VENV="$HOME/.local/share/open-webui-venv"
OWUI_INSTALLED=0

info "Installing Open WebUI (browser-based chat UI for Ollama, ~500 MB)…"
[[ ! -d "$OWUI_VENV" ]] && "${PYTHON_BIN:-python3}" -m venv "$OWUI_VENV"
"$OWUI_VENV/bin/pip" install --upgrade pip --quiet || true
if "$OWUI_VENV/bin/pip" install open-webui; then
    OWUI_VER=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null \
        | awk '/^Version:/{print $2}' || echo "unknown")
    info "Open WebUI $OWUI_VER installed."
    OWUI_INSTALLED=1
else
    warn "Open WebUI pip install failed — check output above."
fi

# ── Write llm-web launcher ────────────────────────────────────────────────────
# llm-web / webui — starts Ollama if needed, then serves Open WebUI on :8080.
# On WSL2 the server binds to 0.0.0.0 so the Windows browser can reach it.
if is_wsl2; then OWUI_HOST="0.0.0.0"; else OWUI_HOST="127.0.0.1"; fi

cat > "$BIN_DIR/llm-web" <<OWUI_LAUNCHER
#!/usr/bin/env bash
# llm-web / webui — Open WebUI browser interface backed by Ollama
# Open http://localhost:8080 in your browser after running this.

export DATA_DIR="$GUI_DIR/open-webui-data"
mkdir -p "\$DATA_DIR"
export OLLAMA_BASE_URL="http://127.0.0.1:11434"
export ENABLE_OPENAI_API=false
export OPENAI_API_BASE_URL="http://127.0.0.1:11434/v1"
export OPENAI_API_KEY="ollama"
export PYTHONWARNINGS="ignore::RuntimeWarning"
export USER_AGENT="open-webui/local"
export CORS_ALLOW_ORIGIN="http://localhost:8080"

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

# Kill any process already holding port 8080
OLD=\$(lsof -ti tcp:8080 2>/dev/null || true)
[[ -n "\$OLD" ]] && kill "\$OLD" 2>/dev/null && sleep 1

echo "→ Open WebUI starting on http://localhost:8080"
echo "  Press Ctrl+C to stop."
"$OWUI_VENV/bin/open-webui" serve --host $OWUI_HOST --port 8080
OWUI_LAUNCHER
chmod +x "$BIN_DIR/llm-web"

if (( OWUI_INSTALLED )); then
    info "Open WebUI ready → run: webui  (http://localhost:8080)"
else
    info "Open WebUI not installed — re-run setup or install manually:"
    info "  pip install open-webui"
fi

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
echo ""
if [[ -t 0 ]]; then
    read -r -p "  > " _tool_sel
else
    _tool_sel=""
fi
[[ "${_tool_sel:-}" == "all" ]] && _tool_sel="1 2 3 4 5"

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

[[ -n "${_tool_sel:-}" ]] && info "Optional tools step complete." || info "Optional tools: skipped."

# =============================================================================
# STEP 13b — AUTONOMOUS COWORKING (Open Interpreter + Aider)
# =============================================================================
step "Autonomous coworking tools"
# cowork (Open Interpreter) + aider are core tools — always installed.
OI_VENV="$HOME/.local/share/open-interpreter-venv"
AI_VENV="$HOME/.local/share/aider-venv"

# ── Open Interpreter ──────────────────────────────────────────────────────
info "Installing Open Interpreter…"
    [[ ! -d "$OI_VENV" ]] && "${PYTHON_BIN:-python3}" -m venv "$OI_VENV"
    "$OI_VENV/bin/pip" install --upgrade pip --quiet || true
    # setuptools must be installed explicitly — Python 3.12 no longer bundles it
    # in venvs, so open-interpreter's use of pkg_resources raises ModuleNotFoundError.
    "$OI_VENV/bin/pip" install --upgrade setuptools --quiet         || warn "setuptools install failed — cowork may crash on Python 3.12."
    "$OI_VENV/bin/pip" install open-interpreter         || warn "Open Interpreter install failed — check output above."

    # Write cowork launcher — reads OLLAMA_TAG from config at runtime
    cat > "$BIN_DIR/cowork" <<'COWORK_EOF'
#!/usr/bin/env bash
# cowork — autonomous AI coworker via Open Interpreter + local Ollama
# The AI can run code, browse the web, manage files — fully local, no cloud.
set -uo pipefail

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
echo "  ║  The AI can run code, browse web, manage files  ║"
echo "  ║  Type 'exit' or Ctrl-D to quit                  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""

# Open Interpreter talks to Ollama via its OpenAI-compatible /v1 shim.
# OPENAI_API_KEY can be any non-empty string — Ollama doesn't validate it.
export OPENAI_API_KEY="ollama"
export OPENAI_API_BASE="http://127.0.0.1:11434/v1"

"$OI_VENV/bin/interpreter"     --model "openai/$OLLAMA_TAG"     --context_window 8192     --max_tokens 4096     --api_base "http://127.0.0.1:11434/v1"     --api_key "ollama"     "$@"
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

export OPENAI_API_KEY="ollama"

"$AI_VENV/bin/aider"     --model "openai/$OLLAMA_TAG"     --openai-api-base "http://127.0.0.1:11434/v1"     --no-auto-commits     "$@"
AIDER_EOF
chmod +x "$BIN_DIR/aider"
info "aider launcher written: $BIN_DIR/aider"

info "Autonomous coworking tools installed."
info "  cowork  — Open Interpreter (code execution, file ops, web browsing)"
info "  aider   — AI pair programmer (git-integrated, edit files directly)"

# =============================================================================
# STEP 14 — ALIASES
# =============================================================================
step "Shell aliases"

cat > "$ALIAS_FILE" <<'ALIASES_EOF'
# ── Local LLM (auto-setup v3.1) ──────────────────────────────────────────────
alias ollama-list='ollama list'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'
alias gguf-list='local-models-info'
alias gguf-run='run-gguf'
alias ask='run-model'       # run-model reads config + passes prompt
alias llm-status='local-models-info'
alias chat='llm-chat'
alias webui='llm-web'       # Open WebUI browser UI (http://localhost:8080)
alias ai='aider'
alias doctor='llm-doctor'   # run diagnostics
alias llm-setup='bash ~/.config/local-llm/llm-auto-setup.sh'

# ── Override clear to show quick-help (opt-out: unalias clear) ────────────────
# We use a function so it can call the builtin clear without infinite recursion.
llm-clear() {
    command clear
    llm-quick-help
}
alias clear='llm-clear'

llm-quick-help() {
    local G='\e[0;32m' Y='\e[1;33m' C='\e[0;36m' M='\e[0;35m' N='\e[0m'
    echo ""
    echo -e "  ${C}+-----------------------------------------------------------------+${N}"
    echo -e "  ${C}|${N}  ${M}Chat${N}                                                           ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}webui${N}         Open WebUI        -> http://localhost:8080       ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}chat${N}          Neural Terminal   -> http://localhost:8090       ${C}|${N}"
    echo -e "  ${C}|${N}  ${M}Models${N}                                                         ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}run-model${N}     run default GGUF from CLI                       ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}ollama-run${N}    run any Ollama model  (ollama-run <tag>)         ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-add${N}       download more models (hardware-filtered)        ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-switch${N}    change active model                             ${C}|${N}"
    echo -e "  ${C}|${N}  ${M}Coworking${N}                                                      ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}cowork${N}        AI writes & runs code, edits files              ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}ai / aider${N}    AI pair programmer with git integration         ${C}|${N}"
    echo -e "  ${C}|${N}  ${M}System${N}                                                         ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}ollama-start${N}  start Ollama backend                            ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-stop${N}      stop Ollama + Open WebUI                        ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-update${N}    upgrade Ollama + Open WebUI, pull latest model  ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}llm-status${N}    show models, disk, config                       ${C}|${N}"
    echo -e "  ${C}|${N}   ${Y}doctor${N}        diagnose issues (llm-doctor)                    ${C}|${N}"
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
Local LLM commands (v3):
  webui                  Open WebUI browser UI at http://localhost:8080
  chat                   Open Neural Terminal at http://localhost:8090
  run-model / ask        Run default GGUF model from CLI
  ollama-pull <tag>      Download an Ollama model
  ollama-run  <tag>      Run an Ollama model interactively
  ollama-list            List downloaded Ollama models
  ollama-start           Start the Ollama backend
  gguf-run <file> [txt]  Run a raw GGUF via llama-cpp
    --gpu-layers N         GPU layers (default from config)
    --threads N            CPU threads
    --batch N              Batch size
    --ctx N                Context window (default 8192)
    --max-tokens N         Max output tokens (default 512)
  gguf-list              List downloaded GGUF files + sizes
  llm-status             Show models, disk, and hardware config
  cowork                 Open Interpreter — AI that runs code + manages files
  ai / aider             AI pair programmer with git integration
  llm-stop               Stop Ollama and Open WebUI
  llm-update             Upgrade Ollama + Open WebUI, pull latest model
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
    warn "  Open WebUI and the Neural Terminal both need this to work."
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

if [[ -x "$BIN_DIR/llm-web" ]]; then
    info "✔ llm-web (Open WebUI launcher) OK."
    PASS=$(( PASS + 1 ))
else
    warn "✘ llm-web launcher missing."
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

for _tool in llm-stop llm-update llm-switch llm-add llm-doctor; do
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
    echo -e "${GREEN}║   Local LLM Auto-Setup v${SCRIPT_VERSION} — Complete!               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║   Setup complete — ${WARN_COUNT} warning(s). Run: llm-doctor          ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo -e "    Checks passed : ${GREEN}$PASS${NC}   │   Warnings: ${YELLOW}$WARN_COUNT${NC}   │   Log: $LOG_FILE"

# ── Hardware + model info ─────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}┌─────────────────────────  YOUR SETUP  ──────────────────────────┐${NC}"
printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "Distro"  "${DISTRO_ID} ${UBUNTU_VERSION} (${DISTRO_CODENAME})"
printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "Arch"    "${HOST_ARCH}"
printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "CPU"     "$CPU_MODEL"
printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "RAM"     "${TOTAL_RAM_GB} GB"
if (( HAS_NVIDIA )); then
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "GPU" "$GPU_NAME  (${GPU_VRAM_GB} GB VRAM) [CUDA]"
elif (( HAS_AMD_GPU )); then
    _rocm_line="$GPU_NAME  (${GPU_VRAM_GB} GB VRAM) [ROCm]"
    [[ -n "$AMD_GFX_VER" ]] && _rocm_line+="  ${AMD_GFX_VER}"
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "GPU" "$_rocm_line"
elif (( HAS_INTEL_GPU )); then
    printf "  ${CYAN}│${NC}  %-16s  %-43s${CYAN}│${NC}\n" "GPU" "$GPU_NAME [Intel — CPU tiers]"
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
echo -e "  ${CYAN}│${NC}   ${YELLOW}webui${NC}         Open WebUI → http://localhost:8080              ${CYAN}│${NC}"
if (( OWUI_INSTALLED )); then
    printf "  ${CYAN}│${NC}   ${GREEN}%-10s${NC}  %-49s${CYAN}│${NC}\n" "  ✔ installed" "$OWUI_VENV"
else
    echo -e "  ${CYAN}│${NC}   ${YELLOW}  ✘ Open WebUI not installed${NC} — run: llm-setup to retry     ${CYAN}│${NC}"
fi
echo -e "  ${CYAN}│${NC}   ${YELLOW}chat${NC}          Neural Terminal → http://localhost:8090         ${CYAN}│${NC}"
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
echo -e "  ${CYAN}│${NC}   ${YELLOW}gguf-run${NC}      Run a raw GGUF file directly via llama-cpp      ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}gguf-list${NC}     List all downloaded GGUF files                  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}                                                                ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${MAGENTA}── Maintenance ─────────────────────────────────────────────${NC}  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-add${NC}       Download more models (hardware-filtered)        ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-setup${NC}     Re-run setup from local installed copy          ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-stop${NC}      Stop Ollama + Open WebUI                        ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-update${NC}    Upgrade Ollama + Open WebUI, pull latest model  ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}   ${YELLOW}llm-switch${NC}    Change model (no reinstall needed)              ${CYAN}│${NC}"
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
echo -e "    ${YELLOW}webui${NC}      → Open WebUI  http://localhost:8080  (browser)"
echo -e "    ${YELLOW}chat${NC}       → Neural Terminal  http://localhost:8090  (browser, no X needed)"
echo -e "    ${YELLOW}run-model${NC}  → quick CLI test"
echo -e "    ${YELLOW}doctor${NC}     → diagnose issues (llm-doctor)"
echo -e "    ${YELLOW}llm-help${NC}   → all commands"
is_wsl2 && { echo ""; echo -e "  ${YELLOW}  WSL2:${NC} run ${YELLOW}exec bash${NC} first, then ${YELLOW}ollama-start${NC} before launching any UI"; }
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
    echo -e "  ${YELLOW}│${NC}  llama-cpp err   →  exec bash && run-model hello              ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  cowork crash    →  re-run setup (setuptools will reinstall)  ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  Full diagnosis  →  llm-doctor                               ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
fi

echo -e "  Enjoy your local LLM! — v${SCRIPT_VERSION}"
echo ""