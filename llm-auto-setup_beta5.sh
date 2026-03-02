#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  llm-auto-setup.sh  v4.0.0
#  Zero-cloud local LLM stack installer — Debian/Ubuntu/WSL2
#  Installs: Ollama · llama-cpp-python · Open WebUI · Neural Terminal
#            Open Interpreter · Aider · optional tools
# ─────────────────────────────────────────────────────────────────────────────
#  ██╗      ██████╗  ██████╗ █████╗ ██╗         ██╗     ██╗     ███╗   ███╗
#  ██║     ██╔═══██╗██╔════╝██╔══██╗██║        ██╔╝     ██║     ████╗ ████║
#  ██║     ██║   ██║██║     ███████║██║       ██╔╝      ██║     ██╔████╔██║
#  ██║     ██║   ██║██║     ██╔══██║██║      ██╔╝       ██║     ██║╚██╔╝██║
#  ███████╗╚██████╔╝╚██████╗██║  ██║███████╗██╔╝        ███████╗██║ ╚═╝ ██║
#  ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝         ╚══════╝╚═╝     ╚═╝
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ── Constants & Paths ────────────────────────────────────────────────────────
SCRIPT_VERSION="4.0.0"
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
PKG_CACHE_DIR="$HOME/.cache/llm-setup"

# ── Suppress interactive prompts ─────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1
export PIP_CACHE_DIR="$PKG_CACHE_DIR/pip"
export npm_config_cache="$PKG_CACHE_DIR/npm"

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m';    GREEN='\033[0;32m';   YELLOW='\033[1;33m'
    BLUE='\033[0;34m';   CYAN='\033[0;36m';    MAGENTA='\033[0;35m'
    BOLD='\033[1m';      DIM='\033[2m';         NC='\033[0m'
    ACCENT='\033[38;5;39m'
    ACCENT2='\033[38;5;82m'
    MUTED='\033[38;5;240m'
    WARN_COL='\033[38;5;214m'
    ERR_COL='\033[38;5;196m'
    STEP_COL='\033[38;5;105m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
    ACCENT=''; ACCENT2=''; MUTED=''; WARN_COL=''; ERR_COL=''; STEP_COL=''
fi

_TW=$(( $(tput cols 2>/dev/null || echo 80) ))
(( _TW < 60  )) && _TW=60
(( _TW > 120 )) && _TW=120
_rule() { local ch="${1:-─}" col="${2:-$MUTED}"; printf "${col}%*s${NC}\n" "$_TW" "" | tr ' ' "$ch"; }

# ── Step counter ─────────────────────────────────────────────────────────────
_STEP_N=0
_STEP_TOTAL=21

# ── UI functions ─────────────────────────────────────────────────────────────
info()  { echo -e "  ${ACCENT2}✓${NC}  $*"; }
warn()  { echo -e "  ${WARN_COL}⚠${NC}  ${WARN_COL}$*${NC}"; }
error() {
    echo ""; _rule "═" "${ERR_COL}"
    echo -e "  ${ERR_COL}${BOLD}✗  ERROR${NC}  $*"
    echo -e "  ${MUTED}Log: $LOG_FILE${NC}"
    _rule "═" "${ERR_COL}"; echo ""
    exit 1
}
step() {
    (( _STEP_N++ )) || true
    echo ""; _rule "─" "${STEP_COL}"
    echo -e "${STEP_COL}${BOLD}  STEP ${_STEP_N}/${_STEP_TOTAL}  │  $*${NC}"
    _rule "─" "${STEP_COL}"
}
highlight() { echo -e "\n${BOLD}${ACCENT}  ◆  $*${NC}"; }
ask_yes_no() {
    [[ ! -t 0 ]] && { warn "Non-interactive — treating '$1' as No."; return 1; }
    printf "  ${ACCENT}?${NC}  ${BOLD}%s${NC} ${MUTED}[y/N]${NC} " "$1"
    read -r -n 1 ans; echo
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ── Spinner ───────────────────────────────────────────────────────────────────
_SPIN_PID=""
spin_start() {
    local msg="${1:-Working…}"
    [[ -t 1 ]] || { echo -e "  …  $msg"; _SPIN_PID=""; return; }
    ( local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
      while true; do
          printf "\r  ${ACCENT}%s${NC}  %s " "${frames[$((i % 10))]}" "$msg"
          (( i++ )); sleep 0.08
      done ) &
    _SPIN_PID=$!
}
spin_stop() {
    local rc="${1:-0}"
    [[ -n "${_SPIN_PID:-}" ]] && { kill "$_SPIN_PID" 2>/dev/null; wait "$_SPIN_PID" 2>/dev/null
        _SPIN_PID=""; printf "\r%*s\r" "$_TW" ""; }
    (( rc == 0 )) && echo -e "  ${ACCENT2}✓${NC}  Done" \
                  || echo -e "  ${WARN_COL}⚠${NC}  Finished with warnings (rc=$rc)"
    return "$rc"
}

# ── Logging: tee all output to log file ──────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Welcome banner ───────────────────────────────────────────────────────────
show_banner() {
    clear
    echo ""
    echo -e "${ACCENT}${BOLD}  ██╗      ██████╗  ██████╗ █████╗ ██╗         ██╗     ██╗     ███╗   ███╗${NC}"
    echo -e "${ACCENT}${BOLD}  ██║     ██╔═══██╗██╔════╝██╔══██╗██║        ██╔╝     ██║     ████╗ ████║${NC}"
    echo -e "${ACCENT}${BOLD}  ██║     ██║   ██║██║     ███████║██║       ██╔╝      ██║     ██╔████╔██║${NC}"
    echo -e "${ACCENT}${BOLD}  ██║     ██║   ██║██║     ██╔══██║██║      ██╔╝       ██║     ██║╚██╔╝██║${NC}"
    echo -e "${ACCENT}${BOLD}  ███████╗╚██████╔╝╚██████╗██║  ██║███████╗██╔╝        ███████╗██║ ╚═╝ ██║${NC}"
    echo -e "${ACCENT}${BOLD}  ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝         ╚══════╝╚═╝     ╚═╝${NC}"
    echo ""
    _rule "═"
    printf "  ${BOLD}%-20s${NC}  ${MUTED}%s${NC}\n" \
        "Local LLM Installer" "v${SCRIPT_VERSION} — Zero cloud dependency"
    printf "  ${MUTED}%-20s  %s${NC}\n" \
        "Debian/Ubuntu/WSL2" "100% local inference after install"
    _rule "═"
    echo ""
    echo -e "  ${BOLD}This installer will set up:${NC}"
    echo -e "  ${ACCENT2}•${NC}  Ollama          — Model server + GPU management"
    echo -e "  ${ACCENT2}•${NC}  llama-cpp-python — Direct GGUF inference"
    echo -e "  ${ACCENT2}•${NC}  Open WebUI      — Web chat interface (port 8080)"
    echo -e "  ${ACCENT2}•${NC}  Neural Terminal  — Lightweight HTML chat (port 8090)"
    echo -e "  ${ACCENT2}•${NC}  Open Interpreter — Autonomous AI coding (local)"
    echo -e "  ${ACCENT2}•${NC}  Aider           — Git-integrated pair programmer"
    echo -e "  ${ACCENT2}•${NC}  Helper commands — llm-help, llm-switch, llm-add, …"
    echo ""
    echo -e "  ${MUTED}Log file: $LOG_FILE${NC}"
    echo ""
    _rule "─"
    echo ""
}

# ── Utility functions ─────────────────────────────────────────────────────────
retry() {
    local n="$1" delay="$2"; shift 2
    local i=0
    while (( i < n )); do
        "$@" && return 0
        (( i++ ))
        warn "Retry $i/$n failed. Waiting ${delay}s…"
        sleep "$delay"
    done
    return 1
}

is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

get_distro_id() {
    local _id=""
    [[ -f /etc/os-release ]] && _id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    echo "${_id:-unknown}"
}

get_distro_codename() {
    local _cn=""
    [[ -f /etc/os-release ]] && _cn=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
    echo "${_cn:-unknown}"
}

ollama_running() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }

wait_for_ollama() {
    local max="${1:-20}" i=0
    while (( i < max )); do
        ollama_running && return 0
        sleep 1
        (( i++ ))
    done
    return 1
}

start_ollama_if_needed() {
    ollama_running && return 0
    if is_wsl2; then
        [[ -x "$BIN_DIR/ollama-start" ]] && "$BIN_DIR/ollama-start" \
            || nohup ollama serve >/dev/null 2>&1 &
    else
        sudo systemctl start ollama 2>/dev/null \
            || nohup ollama serve >/dev/null 2>&1 &
    fi
    wait_for_ollama 20 || warn "Ollama didn't respond within 20s"
}

_ver_gt() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]; }
_ver_ge() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }

# ── Package cache dirs ────────────────────────────────────────────────────────
mkdir -p "$PKG_CACHE_DIR/pip" "$PKG_CACHE_DIR/npm"

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN — call show_banner then run steps
# ─────────────────────────────────────────────────────────────────────────────
show_banner

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1 — PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════
step "Pre-flight checks"

# Reject root
(( EUID == 0 )) && error "Do not run this script as root. Run as a regular user with sudo access."

# Require sudo
command -v sudo &>/dev/null || error "'sudo' is required but not found. Install it first."

# Architecture check
_arch=$(uname -m)
case "$_arch" in
    x86_64) info "Architecture: x86_64 ✔" ;;
    aarch64) warn "Architecture: aarch64 (ARM64) — GPU inference may be limited." ;;
    *) warn "Architecture: $_arch — untested, proceeding anyway." ;;
esac

# Distro check
_distro_id=$(get_distro_id)
_distro_cn=$(get_distro_codename)
info "Distro: ${_distro_id} (${_distro_cn})"
case "$_distro_id" in
    ubuntu|debian|linuxmint|pop|kali|parrot) ;;
    *) warn "Distro '$_distro_id' is not officially supported — may still work." ;;
esac

# sudo keepalive
echo ""
echo -e "  ${ACCENT}❯${NC}  ${BOLD}Administrator access required${NC}"
echo -e "  ${MUTED}    apt · systemd · GPU drivers${NC}"
echo ""
sudo -v || error "sudo authentication failed."
( while true; do sleep 50; sudo -v 2>/dev/null; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT INT TERM

# Self-update check
if [[ -f "$SCRIPT_INSTALL_PATH" ]]; then
    _installed_ver=$(grep '^SCRIPT_VERSION=' "$SCRIPT_INSTALL_PATH" 2>/dev/null \
        | head -1 | cut -d'"' -f2 || echo "0.0.0")
    if [[ "$_installed_ver" != "$SCRIPT_VERSION" ]]; then
        warn "Installed version: $_installed_ver | This version: $SCRIPT_VERSION"
        if ask_yes_no "Update installed script to v${SCRIPT_VERSION}?"; then
            mkdir -p "$CONFIG_DIR"
            cp "$0" "$SCRIPT_INSTALL_PATH"
            chmod +x "$SCRIPT_INSTALL_PATH"
            info "Script updated. Re-executing…"
            exec bash "$SCRIPT_INSTALL_PATH" "$@"
        fi
    fi
fi

info "Pre-flight checks passed."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2 — HARDWARE DETECTION
# ═══════════════════════════════════════════════════════════════════════════════
step "Hardware detection"

# ── CPU ───────────────────────────────────────────────────────────────────────
CPU_MODEL=$(grep '^model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ *//' || echo "Unknown")
CPU_THREADS=$(nproc 2>/dev/null || echo 4)
HW_THREADS=$(( CPU_THREADS < 16 ? CPU_THREADS : 16 ))

# ── RAM ───────────────────────────────────────────────────────────────────────
TOTAL_RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)
AVAIL_RAM_GB=$(awk '/MemAvailable/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 2)

# ── GPU ───────────────────────────────────────────────────────────────────────
HAS_GPU=0
HAS_NVIDIA=0
HAS_AMD_GPU=0
HAS_INTEL_GPU=0
GPU_NAME="None"
GPU_VRAM_GB=0
GPU_VRAM_MIB=0
DRIVER_VER=""
CUDA_VER_SMI=""

# NVIDIA detection
if command -v nvidia-smi &>/dev/null; then
    _nv_out=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || true)
    if [[ -n "$_nv_out" ]]; then
        HAS_NVIDIA=1; HAS_GPU=1
        GPU_NAME=$(echo "$_nv_out" | cut -d, -f1 | sed 's/^ *//')
        _vram_str=$(echo "$_nv_out" | cut -d, -f2 | sed 's/^ *//')
        GPU_VRAM_MIB=$(echo "$_vram_str" | grep -oP '[0-9]+' | head -1 || echo 0)
        GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
        CUDA_VER_SMI=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9.]+' | head -1 || echo "")
        DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "")
    fi
fi

# AMD detection
if (( !HAS_NVIDIA )); then
    if command -v rocminfo &>/dev/null && rocminfo 2>/dev/null | grep -qi 'gfx'; then
        HAS_AMD_GPU=1; HAS_GPU=1
        GPU_NAME=$(rocminfo 2>/dev/null | grep 'Marketing Name' | head -1 | cut -d: -f2 | sed 's/^ *//' || echo "AMD GPU")
        GPU_VRAM_MIB=$(rocminfo 2>/dev/null | grep -i 'memory size' | grep -oP '[0-9]+' | head -1 || echo 0)
        GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
    elif lspci 2>/dev/null | grep -iq 'AMD.*Radeon\|Radeon.*AMD'; then
        HAS_AMD_GPU=1; HAS_GPU=1
        GPU_NAME=$(lspci 2>/dev/null | grep -i 'AMD.*Radeon\|Radeon' | head -1 | sed 's/.*: //' || echo "AMD Radeon GPU")
    fi
fi

# Intel Arc detection
if (( !HAS_NVIDIA && !HAS_AMD_GPU )); then
    if lspci 2>/dev/null | grep -iE 'Intel.*Arc|Intel.*Xe' | grep -qi 'arc\|xe'; then
        HAS_INTEL_GPU=1; HAS_GPU=1
        GPU_NAME=$(lspci 2>/dev/null | grep -iE 'Intel.*Arc|Intel.*Xe' | head -1 | sed 's/.*: //' || echo "Intel Arc/Xe GPU")
        warn "Intel Arc detected — using CPU tiers (Arc compute support is WIP)."
        HAS_GPU=0  # treat as CPU-only for model selection
    fi
fi

# Disk free
DISK_FREE_GB=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo 0)

# VRAM headroom
VRAM_HEADROOM_MIB=1400
VRAM_USABLE_MIB=$(( GPU_VRAM_MIB - VRAM_HEADROOM_MIB ))
(( VRAM_USABLE_MIB < 0 )) && VRAM_USABLE_MIB=0

# GPU layers function
gpu_layers_for() {
    local size_gb="$1" num_layers="$2"
    local model_mib=$(( size_gb * 1024 ))
    if (( model_mib <= VRAM_USABLE_MIB )); then
        echo "-1"
        return
    fi
    local mib_per_layer=$(( model_mib / num_layers ))
    (( mib_per_layer < 1 )) && mib_per_layer=1
    local layers=$(( VRAM_USABLE_MIB / mib_per_layer ))
    (( layers > num_layers )) && layers=$num_layers
    (( layers < 0 )) && layers=0
    echo "$layers"
}

# Batch size based on VRAM
if   (( GPU_VRAM_GB >= 24 )); then BATCH=2048
elif (( GPU_VRAM_GB >= 12 )); then BATCH=1024
elif (( GPU_VRAM_GB >=  8 )); then BATCH=512
elif (( GPU_VRAM_GB >=  4 )); then BATCH=256
else                               BATCH=128
fi

# ── Hardware summary ──────────────────────────────────────────────────────────
echo ""
_rule "─"
printf "  ${BOLD}%-18s${NC}  %s\n"  "CPU"  "$CPU_MODEL"
printf "  ${BOLD}%-18s${NC}  %s\n"  "Threads"  "${CPU_THREADS} logical / ${HW_THREADS} used"
printf "  ${BOLD}%-18s${NC}  %s\n"  "RAM"  "${TOTAL_RAM_GB} GB total / ${AVAIL_RAM_GB} GB available"
printf "  ${BOLD}%-18s${NC}  %s\n"  "Disk free"  "${DISK_FREE_GB} GB"
if (( HAS_NVIDIA )); then
    printf "  ${BOLD}%-18s${NC}  %s\n"  "GPU (NVIDIA)" "$GPU_NAME"
    printf "  ${BOLD}%-18s${NC}  %s MiB (%s GB usable)\n"  "VRAM"  "$GPU_VRAM_MIB"  "$(( VRAM_USABLE_MIB / 1024 ))"
    [[ -n "$CUDA_VER_SMI" ]] && printf "  ${BOLD}%-18s${NC}  %s\n"  "CUDA (driver)"  "$CUDA_VER_SMI"
elif (( HAS_AMD_GPU )); then
    printf "  ${BOLD}%-18s${NC}  %s\n"  "GPU (AMD)" "$GPU_NAME"
    printf "  ${BOLD}%-18s${NC}  %s MiB\n"  "VRAM"  "$GPU_VRAM_MIB"
elif (( HAS_INTEL_GPU )); then
    printf "  ${BOLD}%-18s${NC}  %s (CPU-only mode)\n"  "GPU (Intel)" "$GPU_NAME"
else
    printf "  ${BOLD}%-18s${NC}  None detected — CPU inference\n"  "GPU"
fi
_rule "─"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3 — MODEL SELECTION
# ═══════════════════════════════════════════════════════════════════════════════
step "Model selection"

# ── Model catalog: live fetch from HuggingFace bartowski, fallback to seed ────
#
# Strategy:
#   1. Query https://huggingface.co/api/models?author=bartowski&limit=100&sort=lastModified
#      to discover all currently-published GGUF repos from bartowski.
#   2. For each tracked repo-slug, hit /api/models/{repo} to find the newest
#      Q4_K_M (or Q8_0 for tiny models) GGUF filename and its size_in_bytes.
#   3. Derive size_gb, estimated layer count, vram tier, and capabilities from
#      the model name automatically — no hardcoded filenames.
#   4. If the network is unreachable (air-gap, proxy, etc.) fall back to the
#      embedded seed catalog so the installer never breaks offline.
#
# The seed catalog doubles as the "known good" tier/caps metadata source:
# when a live fetch succeeds we merge the live filename/URL over the seed's
# tier and caps data, giving us fresh filenames with curated human labels.
# ─────────────────────────────────────────────────────────────────────────────

declare -A _CAT_NAME _CAT_QUANT _CAT_FILE _CAT_URL _CAT_SIZE _CAT_LAYERS \
           _CAT_VRAM _CAT_CAPS _CAT_TIER _CAT_REPO _CAT_PREFER_QUANT
_CAT_COUNT=0   # total entries loaded

# ── Helper: register one entry ────────────────────────────────────────────────
_define_model() {
    # args: idx name quant file repo size_gb layers vram caps tier prefer_quant
    local idx="$1"
    _CAT_NAME[$idx]="$2"
    _CAT_QUANT[$idx]="$3"
    _CAT_FILE[$idx]="$4"
    _CAT_REPO[$idx]="$5"
    _CAT_URL[$idx]="https://huggingface.co/$5/resolve/main/$4"
    _CAT_SIZE[$idx]="$6"
    _CAT_LAYERS[$idx]="$7"
    _CAT_VRAM[$idx]="$8"
    _CAT_CAPS[$idx]="$9"
    _CAT_TIER[$idx]="${10}"
    _CAT_PREFER_QUANT[$idx]="${11:-Q4_K_M}"   # quant to search for when refreshing
    (( idx > _CAT_COUNT )) && _CAT_COUNT=$idx
}

# ── Seed catalog (used offline AND as tier/caps metadata for live merge) ──────
# Format: idx  display_name  quant  filename  hf_repo  size_gb  layers  vram_label  caps  tier  prefer_quant
_define_model  1  "Qwen3-1.7B"              "Q8"  "Qwen_Qwen3-1.7B-Q8_0.gguf"                           "bartowski/Qwen_Qwen3-1.7B-GGUF"                         2   28  "CPU"    "★ TOOLS · THINK"                        "CPU / No GPU"         "Q8_0"
_define_model  2  "Qwen3-4B"                "Q4"  "Qwen_Qwen3-4B-Q4_K_M.gguf"                           "bartowski/Qwen_Qwen3-4B-GGUF"                           3   36  "~3 GB"  "★ TOOLS · THINK"                        "CPU / No GPU"         "Q4_K_M"
_define_model  3  "Phi-4-mini 3.8B"         "Q4"  "Phi-4-mini-instruct-Q4_K_M.gguf"                     "bartowski/Phi-4-mini-instruct-GGUF"                     3   32  "CPU"    "★ TOOLS · THINK · Microsoft"            "CPU / No GPU"         "Q4_K_M"
_define_model  4  "Qwen3-0.6B"              "Q8"  "Qwen_Qwen3-0.6B-Q8_0.gguf"                           "bartowski/Qwen_Qwen3-0.6B-GGUF"                         1   28  "CPU"    "TOOLS · THINK · tiny"                   "CPU / No GPU"         "Q8_0"
_define_model  5  "Qwen3-8B"                "Q4"  "Qwen_Qwen3-8B-Q4_K_M.gguf"                           "bartowski/Qwen_Qwen3-8B-GGUF"                           5   36  "~5 GB"  "★ TOOLS · THINK"                        "6-8 GB VRAM"          "Q4_K_M"
_define_model  6  "Qwen3-8B (Q6)"           "Q6"  "Qwen_Qwen3-8B-Q6_K.gguf"                             "bartowski/Qwen_Qwen3-8B-GGUF"                           6   36  "~6 GB"  "★ TOOLS · THINK · higher quality"        "6-8 GB VRAM"          "Q6_K"
_define_model  7  "DeepSeek-R1-Distill-8B"  "Q4"  "DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"            "bartowski/DeepSeek-R1-Distill-Qwen-8B-GGUF"             5   36  "~5 GB"  "THINK · deep reasoning"                 "6-8 GB VRAM"          "Q4_K_M"
_define_model  8  "Gemma-3-9B"              "Q4"  "google_gemma-3-9b-it-Q4_K_M.gguf"                    "bartowski/google_gemma-3-9b-it-GGUF"                    6   46  "~6 GB"  "TOOLS · Google"                         "6-8 GB VRAM"          "Q4_K_M"
_define_model  9  "Gemma-3-12B"             "Q4"  "google_gemma-3-12b-it-Q4_K_M.gguf"                   "bartowski/google_gemma-3-12b-it-GGUF"                   8   46  "~8 GB"  "TOOLS · Google vision"                  "6-8 GB VRAM"          "Q4_K_M"
_define_model 10  "Dolphin3.0-8B"           "Q4"  "dolphin3.0-qwen2.5-7b-Q4_K_M.gguf"                  "bartowski/dolphin3.0-qwen2.5-7b-GGUF"                   5   28  "~5 GB"  "UNCENSORED"                             "6-8 GB VRAM"          "Q4_K_M"
_define_model 11  "Phi-4-14B"               "Q4"  "phi-4-Q4_K_M.gguf"                                   "bartowski/phi-4-GGUF"                                   9   40  "~9 GB"  "★ TOOLS · top coding + math"             "10-12 GB VRAM"        "Q4_K_M"
_define_model 12  "Qwen3-14B"               "Q4"  "Qwen_Qwen3-14B-Q4_K_M.gguf"                          "bartowski/Qwen_Qwen3-14B-GGUF"                          9   40  "~9 GB"  "★ TOOLS · THINK"                        "10-12 GB VRAM"        "Q4_K_M"
_define_model 13  "DeepSeek-R1-Distill-14B" "Q4"  "DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"           "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF"            9   40  "~9 GB"  "THINK · deep reasoning"                 "10-12 GB VRAM"        "Q4_K_M"
_define_model 14  "Gemma-3-27B"             "Q4"  "google_gemma-3-27b-it-Q4_K_M.gguf"                   "bartowski/google_gemma-3-27b-it-GGUF"                  12   46  "~12 GB" "TOOLS · Google"                         "16 GB VRAM"           "Q4_K_M"
_define_model 15  "Mistral-Small-3.1-24B"   "Q4"  "Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"    "bartowski/Mistral-Small-3.1-24B-Instruct-2503-GGUF"    14   40  "~14 GB" "TOOLS · THINK · 128K context"           "16 GB VRAM"           "Q4_K_M"
_define_model 16  "Mistral-Small-3.2-24B"   "Q4"  "Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"    "bartowski/Mistral-Small-3.2-24B-Instruct-2506-GGUF"    14   40  "~14 GB" "★ TOOLS · THINK · newest Mistral"       "16 GB VRAM"           "Q4_K_M"
_define_model 17  "Qwen3-30B-A3B (MoE)"     "Q4"  "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"                     "bartowski/Qwen_Qwen3-30B-A3B-GGUF"                     16   48  "~16 GB" "★ TOOLS · THINK · 30B quality @ 8B speed" "16 GB VRAM"          "Q4_K_M"
_define_model 18  "Qwen3-32B"               "Q4"  "Qwen_Qwen3-32B-Q4_K_M.gguf"                          "bartowski/Qwen_Qwen3-32B-GGUF"                         19   64  "~19 GB" "★ TOOLS · THINK"                        "24+ GB VRAM"          "Q4_K_M"
_define_model 19  "DeepSeek-R1-Distill-32B" "Q4"  "DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"           "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF"           19   64  "~19 GB" "THINK · deep reasoning"                 "24+ GB VRAM"          "Q4_K_M"
_define_model 20  "Gemma-3-27B (24GB tier)" "Q4"  "google_gemma-3-27b-it-Q4_K_M.gguf"                   "bartowski/google_gemma-3-27b-it-GGUF"                  16   46  "~16 GB" "TOOLS · Google"                         "24+ GB VRAM"          "Q4_K_M"
_define_model 21  "Llama-3.3-70B"           "Q4"  "Llama-3.3-70B-Instruct-Q4_K_M.gguf"                  "bartowski/Llama-3.3-70B-Instruct-GGUF"                 40   80  "~40 GB" "★ TOOLS · flagship"                     "48 GB VRAM (multi-GPU)" "Q4_K_M"

# ── Live catalog refresh from HuggingFace API ─────────────────────────────────
# Queries each seed repo for its current file listing, finds the best-matching
# GGUF for the preferred quant, updates filename + URL + size in-place.
# If HF is unreachable the seed values are used unchanged.

_HF_API="https://huggingface.co/api"
_CATALOG_FRESH=0   # set to 1 if at least one repo refreshed successfully
_CATALOG_CACHE="$CONFIG_DIR/catalog_cache.tsv"
_CATALOG_MAX_AGE=86400   # refresh at most once per day (seconds)

# Check whether the cache is still fresh enough to reuse
_cache_age=999999
if [[ -f "$_CATALOG_CACHE" ]]; then
    _cache_mtime=$(stat -c %Y "$_CATALOG_CACHE" 2>/dev/null || echo 0)
    _now=$(date +%s)
    _cache_age=$(( _now - _cache_mtime ))
fi

_hf_reachable=0
if (( _cache_age >= _CATALOG_MAX_AGE )); then
    # Test network reachability with a fast HEAD request
    if curl -sf --max-time 6 --head "https://huggingface.co" >/dev/null 2>&1; then
        _hf_reachable=1
    fi
fi

# Helper: given a repo slug + preferred quant pattern, return "filename|bytes"
# of the newest matching GGUF file, or empty string on failure.
_hf_best_gguf() {
    local repo="$1" quant_pat="$2"
    local _api_url="${_HF_API}/models/${repo}"
    local _json
    _json=$(curl -sf --max-time 15 "$_api_url" 2>/dev/null) || { echo ""; return; }

    # Use python3 to parse the siblings array — more robust than grep/paste
    echo "$_json" | python3 - "$quant_pat" <<'PYEOF' 2>/dev/null
import sys, json, re
quant_pat = sys.argv[1].lower()
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
siblings = data.get('siblings') or []
best_file, best_bytes = "", 0
for s in siblings:
    f = s.get('rfilename','')
    b = s.get('size',0) or 0
    if not f.endswith('.gguf'):
        continue
    # Skip sharded files
    if re.search(r'-\d{5}-of-\d{5}', f):
        continue
    if quant_pat.lower() not in f.lower():
        continue
    if b > best_bytes:
        best_bytes, best_file = b, f
if best_file:
    print(f"{best_file}|{best_bytes}")
PYEOF
}

# Perform the live refresh (skip if cache is fresh)
if (( _hf_reachable )); then
    spin_start "Refreshing model catalog from HuggingFace bartowski…"
    _refresh_ok=0
    _cache_lines=()

    _i=0
    for _i in $(seq 1 $_CAT_COUNT); do
        _repo="${_CAT_REPO[$_i]}"
        _qpat="${_CAT_PREFER_QUANT[$_i]}"
        _result=""
        _result=$(_hf_best_gguf "$_repo" "$_qpat")
        if [[ -n "$_result" ]]; then
            _live_file=""; _live_bytes=0; _live_gb=0
            _live_file=$(echo "$_result" | cut -d'|' -f1)
            _live_bytes=$(echo "$_result" | cut -d'|' -f2)
            _live_gb=$(( (_live_bytes + 536870912) / 1073741824 ))   # round to nearest GB
            (( _live_gb < 1 )) && _live_gb=1

            # Derive quant label from filename
            _live_quant="Q4"
            echo "$_live_file" | grep -qi 'Q8'     && _live_quant="Q8"
            echo "$_live_file" | grep -qi 'Q6'     && _live_quant="Q6"
            echo "$_live_file" | grep -qi 'Q4_K_M' && _live_quant="Q4_K_M"
            echo "$_live_file" | grep -qi 'IQ4'    && _live_quant="IQ4"
            echo "$_live_file" | grep -qi 'IQ3'    && _live_quant="IQ3"

            # Update in-memory catalog
            _CAT_FILE[$_i]="$_live_file"
            _CAT_URL[$_i]="https://huggingface.co/${_repo}/resolve/main/${_live_file}"
            _CAT_SIZE[$_i]="$_live_gb"
            _CAT_QUANT[$_i]="$_live_quant"

            # Re-derive VRAM label from live size
            if   (( _live_gb <= 3  )); then _CAT_VRAM[$_i]="CPU"
            elif (( _live_gb <= 6  )); then _CAT_VRAM[$_i]="~${_live_gb} GB"
            elif (( _live_gb <= 10 )); then _CAT_VRAM[$_i]="~${_live_gb} GB"
            elif (( _live_gb <= 16 )); then _CAT_VRAM[$_i]="~${_live_gb} GB"
            else                           _CAT_VRAM[$_i]="~${_live_gb} GB"
            fi

            (( _refresh_ok++ ))
            _cache_lines+=("${_i}|${_live_file}|${_live_bytes}|${_live_quant}")
        fi
    done

    spin_stop 0

    if (( _refresh_ok > 0 )); then
        _CATALOG_FRESH=1
        # Write cache so we don't re-fetch for another day
        mkdir -p "$CONFIG_DIR"
        printf '%s\n' "${_cache_lines[@]}" > "$_CATALOG_CACHE"
        info "Catalog refreshed live: ${_refresh_ok}/${_CAT_COUNT} repos updated from HuggingFace."
    else
        warn "HuggingFace reachable but no files matched — using seed catalog."
    fi
elif (( _cache_age < _CATALOG_MAX_AGE )) && [[ -f "$_CATALOG_CACHE" ]]; then
    # ── Apply cached refresh ──────────────────────────────────────────────────
    _cache_age_h=$(( _cache_age / 3600 ))
    info "Applying cached catalog (${_cache_age_h}h old, refreshes after 24h)."
    while IFS='|' read -r _ci _cf _cb _cq; do
        [[ "$_ci" =~ ^[0-9]+$ ]] || continue
        _CAT_FILE[$_ci]="$_cf"
        _CAT_URL[$_ci]="https://huggingface.co/${_CAT_REPO[$_ci]}/resolve/main/${_cf}"
        _live_gb=$(( (_cb + 536870912) / 1073741824 ))
        (( _live_gb < 1 )) && _live_gb=1
        _CAT_SIZE[$_ci]="$_live_gb"
        _CAT_QUANT[$_ci]="$_cq"
        _CAT_VRAM[$_ci]="~${_live_gb} GB"
        _CATALOG_FRESH=1
    done < "$_CATALOG_CACHE"
else
    warn "HuggingFace unreachable — using built-in seed catalog (offline mode)."
fi

# Show catalog source in banner
if (( _CATALOG_FRESH )); then
    echo -e "  ${ACCENT2}●${NC}  ${BOLD}Live catalog${NC}  ${MUTED}— filenames reflect latest bartowski releases${NC}"
else
    echo -e "  ${WARN_COL}●${NC}  ${BOLD}Seed catalog${NC}  ${MUTED}— run again online to pick up newer model releases${NC}"
fi
echo ""

# ── Auto-select based on hardware ─────────────────────────────────────────────
# The tier-to-index mapping still uses catalog indices (1-21) which are stable
# regardless of what filenames live refresh found.
_auto_idx=1
if (( HAS_NVIDIA || HAS_AMD_GPU )); then
    if   (( GPU_VRAM_GB >= 48 )); then _auto_idx=21
    elif (( GPU_VRAM_GB >= 24 )); then _auto_idx=18
    elif (( GPU_VRAM_GB >= 16 )); then _auto_idx=17
    elif (( GPU_VRAM_GB >= 12 )); then _auto_idx=12
    elif (( GPU_VRAM_GB >=  8 )); then _auto_idx=11
    elif (( GPU_VRAM_GB >=  6 )); then _auto_idx=5
    elif (( GPU_VRAM_GB >=  4 )); then _auto_idx=2
    else                               _auto_idx=1
    fi
else
    # CPU-only RAM tiers
    if   (( TOTAL_RAM_GB >= 32 )); then _auto_idx=12
    elif (( TOTAL_RAM_GB >= 16 )); then _auto_idx=5
    elif (( TOTAL_RAM_GB >=  8 )); then _auto_idx=2
    else                                _auto_idx=1
    fi
fi

_sel_idx=$_auto_idx

highlight "Auto-selected: ${_CAT_NAME[$_auto_idx]} (${_CAT_QUANT[$_auto_idx]}) — ${_CAT_CAPS[$_auto_idx]}"
echo -e "  ${MUTED}File: ${_CAT_FILE[$_auto_idx]}${NC}"
echo -e "  ${MUTED}Based on: VRAM=${GPU_VRAM_GB}GB  RAM=${TOTAL_RAM_GB}GB${NC}"
echo ""

# ── Interactive picker ────────────────────────────────────────────────────────
_is_installed() { [[ -f "$GGUF_MODELS/$1" ]] && echo " ✔" || echo "  "; }

_show_model_picker() {
    echo ""
    _rule "─"
    printf "  ${BOLD}%-4s  %-32s  %-7s  %-8s  %-2s  %s${NC}\n" "#" "Model" "Quant" "VRAM" "" "Capabilities"
    _rule "─"
    local _last_tier=""
    _i=0
    for _i in $(seq 1 $_CAT_COUNT); do
        if [[ "${_CAT_TIER[$_i]}" != "$_last_tier" ]]; then
            echo ""
            echo -e "  ${YELLOW}▸  ${_CAT_TIER[$_i]}${NC}"
            _last_tier="${_CAT_TIER[$_i]}"
        fi
        local _chk
        _chk=$(_is_installed "${_CAT_FILE[$_i]}")
        printf "  %-4s  %-32s  %-7s  %-8s  %-2s  %s\n" \
            "$_i" "${_CAT_NAME[$_i]}" "${_CAT_QUANT[$_i]}" "${_CAT_VRAM[$_i]}" \
            "$_chk" "${_CAT_CAPS[$_i]}"
    done
    echo ""
    _rule "─"
    echo -e "  ${MUTED}✔ = already downloaded to $GGUF_MODELS${NC}"
}

if ask_yes_no "Override with manual model selection?"; then
    _show_model_picker
    while true; do
        printf "  ${ACCENT}?${NC}  ${BOLD}Enter model number [1-%s, default: %s]:${NC} " \
            "$_CAT_COUNT" "$_auto_idx"
        read -r _input
        [[ -z "$_input" ]] && _input="$_auto_idx"
        if [[ "$_input" =~ ^[0-9]+$ ]] && (( _input >= 1 && _input <= _CAT_COUNT )); then
            _sel_idx="$_input"
            break
        fi
        warn "Please enter a number between 1 and ${_CAT_COUNT}."
    done
fi

# ── Store selected model in declare -A M ──────────────────────────────────────
declare -A M
M[name]="${_CAT_NAME[$_sel_idx]}"
M[quant]="${_CAT_QUANT[$_sel_idx]}"
M[file]="${_CAT_FILE[$_sel_idx]}"
M[url]="${_CAT_URL[$_sel_idx]}"
M[size_gb]="${_CAT_SIZE[$_sel_idx]}"
M[layers]="${_CAT_LAYERS[$_sel_idx]}"
M[caps]="${_CAT_CAPS[$_sel_idx]}"

# Compute GPU/CPU layers
GPU_LAYERS=$(gpu_layers_for "${M[size_gb]}" "${M[layers]}")
if [[ "$GPU_LAYERS" == "-1" ]]; then
    CPU_LAYERS=0
else
    CPU_LAYERS=$(( M[layers] - GPU_LAYERS ))
    (( CPU_LAYERS < 0 )) && CPU_LAYERS=0
fi

# Derive Ollama tag
OLLAMA_TAG=$(echo "${M[file]}" | sed 's/\.gguf$//' | tr '[:upper:]' '[:lower:]' \
    | sed 's/_/-/g; s/[^a-z0-9:-]//g; s/--*/-/g' | cut -c1-60)

highlight "Selected: ${M[name]} | Tag: ${OLLAMA_TAG} | GPU layers: ${GPU_LAYERS}"
echo -e "  ${MUTED}File:  ${M[file]}${NC}"
echo -e "  ${MUTED}URL:   ${M[url]}${NC}"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3b — PYTHON ENVIRONMENT DETECTION
# ═══════════════════════════════════════════════════════════════════════════════
step "Python environment detection (pre-apt scan)"

# Quick scan before apt runs — just to detect what's already present
PYTHON3=""
for _p in python3.12 python3.11 python3.10 python3; do
    if command -v "$_p" &>/dev/null; then
        _pver=$("$_p" --version 2>&1 | grep -oP '[0-9]+\.[0-9]+' | head -1)
        _pmaj=$(echo "$_pver" | cut -d. -f1)
        _pmin=$(echo "$_pver" | cut -d. -f2)
        if (( _pmaj >= 3 && _pmin >= 10 )); then
            PYTHON3="$_p"
            info "Pre-installed Python detected: $("$_p" --version)"
            break
        fi
    fi
done
[[ -z "$PYTHON3" ]] && info "Python 3.10+ not found yet — will install via apt."

# Placeholder; re-detected after apt in STEP 4
PYVER_SHORT="312"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4 — SYSTEM DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════
step "System dependencies"

spin_start "Updating apt cache…"
sudo apt-get update -qq >/dev/null 2>&1 || warn "apt-get update had warnings"
spin_stop $?

# ── Detect distro Python version to install the right -full / -venv package ──
_distro_py_ver="3.11"   # safe default
_distro_id_lc=$(get_distro_id | tr '[:upper:]' '[:lower:]')
_codename_lc=$(get_distro_codename | tr '[:upper:]' '[:lower:]')
case "$_codename_lc" in
    noble|oracular|plucky)   _distro_py_ver="3.12" ;;  # Ubuntu 24.04+
    jammy|kinetic|lunar)     _distro_py_ver="3.11" ;;  # Ubuntu 22.04
    bookworm)                _distro_py_ver="3.11" ;;  # Debian 12
    bullseye)                _distro_py_ver="3.9"  ;;  # Debian 11
    *) _distro_py_ver="3.12" ;;                        # assume modern
esac
_py_pkg="python${_distro_py_ver}"

# Install zstd early so Ollama installer can extract (it uses zstd internally)
spin_start "Installing zstd (required by Ollama installer)…"
sudo apt-get install -y -qq zstd libzstd-dev >/dev/null 2>&1 || warn "zstd install had warnings"
spin_stop $?

# ── Main package list ────────────────────────────────────────────────────────
_pkgs=(
    # Build tools — needed for llama-cpp-python source build
    build-essential g++ clang cmake pkg-config
    # SSL / compression
    libssl-dev libffi-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev
    # Network / download
    git curl wget ca-certificates
    # Python — distro-version-specific full install with venv support
    "${_py_pkg}" "${_py_pkg}-venv" "${_py_pkg}-dev" "${_py_pkg}-full"
    python3 python3-pip python3-venv python3-dev python3-setuptools python3-wheel
    # Apt infrastructure
    software-properties-common apt-transport-https gnupg lsb-release
    # Hardware info
    pciutils lshw
    # Misc
    unzip jq
)

spin_start "Installing system packages…"
sudo apt-get install -y -qq "${_pkgs[@]}" >/dev/null 2>&1 || warn "Some packages may have failed — continuing"
spin_stop $?

# ── Install Node.js 20 LTS via NodeSource (distro nodejs is too old) ─────────
_node_ok=0
if command -v node &>/dev/null; then
    _nv=$(node --version 2>/dev/null | grep -oP '[0-9]+' | head -1 || echo 0)
    (( _nv >= 18 )) && _node_ok=1
fi
if (( !_node_ok )); then
    spin_start "Installing Node.js 20 LTS (NodeSource)…"
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1 \
        && sudo apt-get install -y -qq nodejs >/dev/null 2>&1 \
        || warn "Node.js 20 install failed — Claude Code / Codex may not work"
    spin_stop $?
else
    info "Node.js $(node --version) already installed."
fi

# ── Re-detect Python after apt ────────────────────────────────────────────────
PYTHON3=""
for _p in "python${_distro_py_ver}" python3.12 python3.11 python3.10 python3; do
    if command -v "$_p" &>/dev/null; then
        _pver=$("$_p" --version 2>&1 | grep -oP '[0-9]+\.[0-9]+' | head -1)
        _pmaj=$(echo "$_pver" | cut -d. -f1)
        _pmin=$(echo "$_pver" | cut -d. -f2)
        if (( _pmaj >= 3 && _pmin >= 10 )); then
            PYTHON3=$(command -v "$_p")
            break
        fi
    fi
done
[[ -z "$PYTHON3" ]] && error "Python 3.10+ not found after apt install. Please install python3.12-full manually."

PYVER_SHORT=$("$PYTHON3" -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')" 2>/dev/null || echo "312")
info "Using Python: $PYTHON3 ($(${PYTHON3} --version 2>&1))  →  cp${PYVER_SHORT}"

# ── Verify venv module works ──────────────────────────────────────────────────
if ! "$PYTHON3" -m venv --help >/dev/null 2>&1; then
    warn "python3-venv not working — trying to fix…"
    sudo apt-get install -y -qq "${_py_pkg}-venv" python3-venv >/dev/null 2>&1 || true
    "$PYTHON3" -m venv --help >/dev/null 2>&1 \
        || error "Cannot create venvs. Run: sudo apt install ${_py_pkg}-venv"
fi
info "venv module working ✔"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5 — DIRECTORIES & PATH
# ═══════════════════════════════════════════════════════════════════════════════
step "Directories & PATH"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$GUI_DIR" \
         "$GGUF_MODELS" "$OLLAMA_MODELS" "$TEMP_DIR" \
         "$WORK_DIR" "$PKG_CACHE_DIR"

# Add BIN_DIR to PATH if not already there
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    export PATH="$BIN_DIR:$PATH"
fi

# Persist PATH in .bashrc idempotently
if ! grep -q "# llm-auto-setup PATH" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<EOF

# llm-auto-setup PATH
export PATH="\$HOME/.local/bin:\$PATH"
EOF
fi

info "Directories created."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6 — SAVE MODEL CONFIG
# ═══════════════════════════════════════════════════════════════════════════════
step "Save model config"

mkdir -p "$CONFIG_DIR"
cat > "${MODEL_CONFIG}.tmp" <<EOF
MODEL_NAME="${M[name]}"
MODEL_FILE="${M[file]}"
MODEL_URL="${M[url]}"
MODEL_CAPS="${M[caps]}"
OLLAMA_TAG="${OLLAMA_TAG}"
GPU_LAYERS="${GPU_LAYERS}"
CPU_LAYERS="${CPU_LAYERS}"
BATCH_SIZE="${BATCH}"
HW_THREADS="${HW_THREADS}"
VENV_DIR="${VENV_DIR}"
GGUF_MODELS="${GGUF_MODELS}"
OLLAMA_MODELS="${OLLAMA_MODELS}"
EOF
mv "${MODEL_CONFIG}.tmp" "$MODEL_CONFIG"
info "Config saved: $MODEL_CONFIG"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7 — CUDA TOOLKIT (NVIDIA only)
# ═══════════════════════════════════════════════════════════════════════════════
step "CUDA toolkit"

if (( HAS_NVIDIA )); then
    setup_cuda_env() {
        for _p in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
            [[ -d "$_p" ]] && export PATH="$_p:$PATH"
        done
        local _nvcc
        _nvcc=$(command -v nvcc 2>/dev/null \
            || find /usr/local/cuda*/bin -name nvcc 2>/dev/null | head -1 \
            || true)
        [[ -n "$_nvcc" ]] && export PATH="$(dirname "$_nvcc"):$PATH"
    }

    # Check if nvcc exists
    _cuda_found=0
    _cuda_installed_method=""

    command -v nvcc &>/dev/null && { _cuda_found=1; _cuda_installed_method="nvcc in PATH"; }

    if (( !_cuda_found )); then
        for _d in /usr/local/cuda*/bin; do
            [[ -f "$_d/nvcc" ]] && { _cuda_found=1; _cuda_installed_method="found in $_d"; break; }
        done
    fi

    if (( !_cuda_found )); then
        ldconfig -p 2>/dev/null | grep -q "libcudart\.so\.12" && { _cuda_found=1; _cuda_installed_method="libcudart.so.12 in ldconfig"; }
    fi

    if (( !_cuda_found )); then
        dpkg -l 'cuda-toolkit-*' 2>/dev/null | grep -q '^ii' && { _cuda_found=1; _cuda_installed_method="cuda-toolkit dpkg"; }
    fi

    if (( _cuda_found )); then
        info "CUDA already present ($_cuda_installed_method)"
        setup_cuda_env
    else
        info "CUDA toolkit not found — installing from NVIDIA keyring…"
        _codename=$(get_distro_codename)
        # Build numeric form: noble→2404, jammy→2204, focal→2004
        _ubuntu_num=$(lsb_release -rs 2>/dev/null | tr -d '.' || echo "2204")
        _cuda_keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${_ubuntu_num}/x86_64/cuda-keyring_1.1-1_all.deb"
        _cuda_keyring_fallback="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb"

        spin_start "Downloading CUDA keyring (Ubuntu ${_ubuntu_num})…"
        wget -q -O "/tmp/cuda-keyring.deb" "$_cuda_keyring_url" 2>/dev/null \
            || wget -q -O "/tmp/cuda-keyring.deb" "$_cuda_keyring_fallback" 2>/dev/null \
            || warn "Could not download CUDA keyring — trying nvidia-cuda-toolkit fallback"
        spin_stop $?

        if [[ -f /tmp/cuda-keyring.deb ]]; then
            sudo dpkg -i /tmp/cuda-keyring.deb >/dev/null 2>&1 || warn "dpkg cuda-keyring failed"
            sudo apt-get update -qq >/dev/null 2>&1 || true
            spin_start "Installing CUDA toolkit…"
            # Try newest first, fall back to older versions
            sudo apt-get install -y -qq "cuda-toolkit-12-8" >/dev/null 2>&1 \
                || sudo apt-get install -y -qq "cuda-toolkit-12-6" >/dev/null 2>&1 \
                || sudo apt-get install -y -qq "cuda-toolkit-12-4" >/dev/null 2>&1 \
                || sudo apt-get install -y -qq "cuda-toolkit-12-2" >/dev/null 2>&1 \
                || sudo apt-get install -y -qq "cuda-toolkit-12-0" >/dev/null 2>&1 \
                || warn "cuda-toolkit install failed via keyring — trying nvidia-cuda-toolkit…"
            spin_stop $?
            setup_cuda_env
        fi

        # Final fallback: distro's nvidia-cuda-toolkit (older but works for many cases)
        if ! command -v nvcc &>/dev/null; then
            spin_start "Trying nvidia-cuda-toolkit (distro fallback)…"
            sudo apt-get install -y -qq nvidia-cuda-toolkit >/dev/null 2>&1 || warn "nvidia-cuda-toolkit also failed"
            spin_stop $?
            setup_cuda_env
        fi

        # Write CUDA PATH to bashrc regardless of install method
        if command -v nvcc &>/dev/null; then
            _nvcc_dir=$(dirname "$(command -v nvcc)")
            _cuda_base=$(dirname "$_nvcc_dir")
            grep -q "# cuda-path-llm" "$HOME/.bashrc" 2>/dev/null || cat >> "$HOME/.bashrc" <<CUDA_EOF

# cuda-path-llm
export PATH="${_nvcc_dir}:\$PATH"
export LD_LIBRARY_PATH="${_cuda_base}/lib64:\${LD_LIBRARY_PATH:-}"
CUDA_EOF
            export PATH="${_nvcc_dir}:$PATH"
            export LD_LIBRARY_PATH="${_cuda_base}/lib64:${LD_LIBRARY_PATH:-}"
            info "CUDA PATH written to ~/.bashrc ✔"
        fi
    fi

    # Fix libcudart.so.12 for Ollama
    _cuda_found=0
    ldconfig -p 2>/dev/null | grep -q "libcudart\.so\.12" && _cuda_found=1

    if (( !_cuda_found )); then
        _cuda_lib_path=""
        for _d in \
            /usr/local/lib/ollama/cuda_v12 \
            /usr/local/lib/ollama/cuda_v11 \
            /usr/local/cuda/lib64 \
            /usr/local/cuda-12*/lib64 \
            /usr/local/cuda-11*/lib64 \
            /usr/lib/x86_64-linux-gnu; do
            [[ -f "$_d/libcudart.so.12" || -f "$_d/libcudart.so" ]] \
                && { _cuda_lib_path="$_d"; _cuda_found=1; break; }
        done

        if [[ -n "$_cuda_lib_path" ]]; then
            echo "$_cuda_lib_path" | sudo tee /etc/ld.so.conf.d/ollama-cuda.conf >/dev/null
            sudo ldconfig
            grep -q "# ollama-cuda-ld" "$HOME/.bashrc" 2>/dev/null || \
                printf '\n# ollama-cuda-ld\nexport LD_LIBRARY_PATH="%s:${LD_LIBRARY_PATH:-}"\n' \
                    "$_cuda_lib_path" >> "$HOME/.bashrc"
            export LD_LIBRARY_PATH="$_cuda_lib_path:${LD_LIBRARY_PATH:-}"
            info "libcudart registered via ldconfig ✔ (persists across reboots)"
        else
            warn "libcudart.so.12 not found — GPU inference may fail."
            warn "  Try: sudo apt-get install cuda-libraries-12-0"
        fi
    else
        info "libcudart.so.12 found in ldconfig ✔"
    fi
else
    info "Skipping CUDA setup (no NVIDIA GPU detected)."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7b — ROCm TOOLKIT (AMD only)
# ═══════════════════════════════════════════════════════════════════════════════
step "ROCm toolkit"

if (( HAS_AMD_GPU )); then
    if command -v rocminfo &>/dev/null; then
        info "ROCm already installed: $(rocminfo 2>/dev/null | grep 'ROCm Runtime' | head -1 || echo 'version unknown')"
    else
        info "Installing ROCm hip SDK…"
        spin_start "Adding ROCm apt repo…"
        wget -q -O /tmp/amdgpu-install.deb \
            "https://repo.radeon.com/amdgpu-install/6.1.3/ubuntu/$(get_distro_codename)/amdgpu-install_6.1.60103-1_all.deb" \
            2>/dev/null || warn "Could not download amdgpu-install"
        spin_stop $?

        if [[ -f /tmp/amdgpu-install.deb ]]; then
            sudo dpkg -i /tmp/amdgpu-install.deb >/dev/null 2>&1 || warn "dpkg amdgpu-install failed"
            sudo apt-get update -qq >/dev/null 2>&1 || true
            spin_start "Installing rocm-hip-sdk…"
            sudo apt-get install -y -qq rocm-hip-sdk >/dev/null 2>&1 || warn "rocm-hip-sdk install failed"
            spin_stop $?
        fi
    fi

    # Add user to render/video groups
    for _g in render video; do
        getent group "$_g" &>/dev/null && sudo usermod -aG "$_g" "$USER" 2>/dev/null || true
    done
else
    info "Skipping ROCm setup (no AMD GPU detected)."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8 — OLLAMA  (installed BEFORE venv — needs zstd which we just installed)
# ═══════════════════════════════════════════════════════════════════════════════
step "Ollama"

_installed_ver=$(ollama --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
_latest_ver=$(curl -sf --max-time 8 \
    "https://api.github.com/repos/ollama/ollama/releases/latest" \
    | grep '"tag_name"' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")

if ! command -v ollama &>/dev/null; then
    info "Installing Ollama (requires zstd — just installed)…"
    curl -fsSL https://ollama.com/install.sh | sh 2>&1 | tee -a "$LOG_FILE" | tail -5 \
        || error "Ollama installation failed. Check $LOG_FILE"
elif _ver_gt "$_latest_ver" "$_installed_ver"; then
    info "Upgrading Ollama: $_installed_ver → $_latest_ver"
    curl -fsSL https://ollama.com/install.sh | sh 2>&1 | tee -a "$LOG_FILE" | tail -3 \
        || warn "Ollama upgrade failed"
else
    info "Ollama ${_installed_ver} is up to date."
fi

# Configure OLLAMA_MODELS
mkdir -p "$OLLAMA_MODELS"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 9 — PYTHON VENV (main inference venv)
# ═══════════════════════════════════════════════════════════════════════════════
step "Python venv (main inference)"

_ensure_venv() {
    local _vdir="$1"
    if [[ ! -d "$_vdir/bin" ]] || [[ ! -x "$_vdir/bin/python3" ]]; then
        spin_start "Creating venv at $_vdir…"
        "$PYTHON3" -m venv "$_vdir" 2>&1 | tee -a "$LOG_FILE" | tail -3
        local _rc=${PIPESTATUS[0]}
        spin_stop $_rc
        if (( _rc != 0 )); then
            warn "venv creation failed for $_vdir — trying --without-pip…"
            "$PYTHON3" -m venv --without-pip "$_vdir" || error "Cannot create venv at $_vdir"
            curl -sS https://bootstrap.pypa.io/get-pip.py | "$_vdir/bin/python3" >/dev/null 2>&1 || warn "pip bootstrap failed"
        fi
    else
        info "Venv exists: $_vdir"
    fi
    # Upgrade pip/setuptools/wheel in this venv
    "$_vdir/bin/python3" -m pip install --upgrade pip setuptools wheel --quiet 2>/dev/null \
        || warn "pip upgrade had warnings in $_vdir"
}

_ensure_venv "$VENV_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 10 — LLAMA-CPP-PYTHON
# ═══════════════════════════════════════════════════════════════════════════════
step "llama-cpp-python"

_install_llama_cpp_python() {
    if (( HAS_NVIDIA )); then
        # Try pre-built wheel first — attempt multiple CUDA version matches
        local _lcpp_ver="0.3.4"
        local _cuda_short=""
        _cuda_short=$(nvcc --version 2>/dev/null | grep -oP 'release [0-9]+\.[0-9]+' | grep -oP '[0-9]+\.[0-9]+' | head -1 \
            || echo "${CUDA_VER_SMI:-12.6}")
        local _cu="${_cuda_short//./}"
        local _cuda_tag="cu${_cu}"

        local _wheel_url="https://github.com/abetlen/llama-cpp-python/releases/download/v${_lcpp_ver}-${_cuda_tag}/llama_cpp_python-${_lcpp_ver}-cp${PYVER_SHORT}-cp${PYVER_SHORT}-linux_x86_64.whl"
        info "Trying pre-built CUDA wheel (${_cuda_tag}, cp${PYVER_SHORT})…"

        if "$VENV_DIR/bin/pip" install --quiet "$_wheel_url" 2>/dev/null; then
            info "Pre-built CUDA wheel installed ✔"
            return 0
        fi

        # Try cu121 fallback (widely available)
        local _fallback_url="https://github.com/abetlen/llama-cpp-python/releases/download/v${_lcpp_ver}-cu121/llama_cpp_python-${_lcpp_ver}-cp${PYVER_SHORT}-cp${PYVER_SHORT}-linux_x86_64.whl"
        if "$VENV_DIR/bin/pip" install --quiet "$_fallback_url" 2>/dev/null; then
            info "Pre-built CUDA wheel (cu121 fallback) installed ✔"
            return 0
        fi

        warn "Pre-built wheel failed — source build (5-15 min, needs build-essential + CUDA headers)…"
        spin_start "Building llama-cpp-python from source (CUDA)…"
        CMAKE_ARGS="-DGGML_CUDA=on" \
            FORCE_CMAKE=1 \
            "$VENV_DIR/bin/pip" install llama-cpp-python --no-cache-dir \
            2>&1 | tee -a "$LOG_FILE" | tail -5
        spin_stop ${PIPESTATUS[0]}

    elif (( HAS_AMD_GPU )); then
        spin_start "Building llama-cpp-python from source (ROCm/HIP)…"
        CMAKE_ARGS="-DGGML_HIPBLAS=on" \
            "$VENV_DIR/bin/pip" install llama-cpp-python --no-cache-dir \
            2>&1 | tee -a "$LOG_FILE" | tail -5
        spin_stop ${PIPESTATUS[0]}

    else
        spin_start "Installing llama-cpp-python (CPU-only)…"
        "$VENV_DIR/bin/pip" install llama-cpp-python --quiet 2>/dev/null
        spin_stop $?
    fi
}

# Check if already installed and working
if ! "$VENV_DIR/bin/python3" -c "from llama_cpp import Llama" 2>/dev/null; then
    _install_llama_cpp_python
else
    info "llama-cpp-python already installed ✔"
fi

# Verify
if "$VENV_DIR/bin/python3" -c "from llama_cpp import Llama; print('llama-cpp-python OK')" 2>/dev/null; then
    info "llama-cpp-python import OK ✔"
else
    warn "llama-cpp-python import failed — run-gguf will not work, but Ollama inference still works."
    warn "  To fix: sudo apt install build-essential g++ clang, then re-run this script."
fi

# Systemd service (non-WSL)
if ! is_wsl2 && command -v systemctl &>/dev/null; then
    _svc_dir="/etc/systemd/system"
    _svc_file="$_svc_dir/ollama.service"
    if [[ ! -f "$_svc_file" ]] || ! grep -q "OLLAMA_NUM_PARALLEL" "$_svc_file" 2>/dev/null; then
        info "Writing Ollama systemd service…"
        sudo tee "$_svc_file" >/dev/null <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
Type=simple
User=${USER}
ExecStart=/usr/local/bin/ollama serve
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_MODELS=${OLLAMA_MODELS}"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload 2>/dev/null || true
        sudo systemctl enable ollama 2>/dev/null || true
        sudo systemctl restart ollama 2>/dev/null || true
    fi
fi

# WSL2 launcher
cat > "${BIN_DIR}/ollama-start" <<EOF
#!/usr/bin/env bash
# WSL2 has no systemd by default — start Ollama in the background
export OLLAMA_MODELS="${OLLAMA_MODELS}"
export OLLAMA_HOST="0.0.0.0:11434"
export OLLAMA_KEEP_ALIVE="30m"
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_MAX_LOADED_MODELS=1
mkdir -p "\$HOME/.ollama"
nohup ollama serve >"\$HOME/.ollama/ollama.log" 2>&1 &
echo "Ollama started (PID \$!). Log: ~/.ollama/ollama.log"
EOF
chmod +x "${BIN_DIR}/ollama-start"

start_ollama_if_needed

info "Ollama ready."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 11 — MODEL DOWNLOAD
# ═══════════════════════════════════════════════════════════════════════════════
step "Model download"

_model_path="$GGUF_MODELS/${M[file]}"
_needs_download=1

if [[ -f "$_model_path" ]]; then
    _expected_size=$(( M[size_gb] * 900 * 1024 * 1024 ))
    _actual_size=$(stat -c%s "$_model_path" 2>/dev/null || echo 0)
    if (( _actual_size >= _expected_size )); then
        info "Model already downloaded: ${M[file]} ($(( _actual_size / 1024 / 1024 / 1024 ))GB)"
        _needs_download=0
    else
        warn "Partial download detected (${_actual_size} bytes) — re-downloading."
        rm -f "$_model_path"
    fi
fi

if (( _needs_download )); then
    highlight "Downloading ${M[name]} (${M[size_gb]}GB) — this may take a while…"
    echo -e "  ${MUTED}URL: ${M[url]}${NC}"
    echo ""
    wget --progress=bar:force:noscroll \
         --retry-connrefused --tries=3 \
         -O "$_model_path" "${M[url]}" \
        || error "Model download failed: ${M[url]}"
    info "Download complete: $_model_path"
fi

# Register model with Ollama via Modelfile
start_ollama_if_needed

# Determine chat template based on model family
_template=""
case "${M[file]}" in
    *Qwen3*|*Qwen2*|*qwen*)
        _template='{{ if .System }}<|im_start|>system\n{{ .System }}<|im_end|>\n{{ end }}{{ range .Messages }}<|im_start|>{{ .Role }}\n{{ .Content }}<|im_end|>\n{{ end }}<|im_start|>assistant\n'
        ;;
    *Llama-3*|*llama-3*)
        _template='{{ if .System }}<|start_header_id|>system<|end_header_id|>\n\n{{ .System }}<|eot_id|>{{ end }}{{ range .Messages }}<|start_header_id|>{{ .Role }}<|end_header_id|>\n\n{{ .Content }}<|eot_id|>{{ end }}<|start_header_id|>assistant<|end_header_id|>\n\n'
        ;;
    *Phi-4*|*phi-4*)
        _template='{{ if .System }}<|system|>{{ .System }}<|end|>{{ end }}{{ range .Messages }}<|{{ .Role }}|>{{ .Content }}<|end|>{{ end }}<|assistant|>'
        ;;
    *gemma*|*Gemma*)
        _template='<start_of_turn>user\n{{ .Prompt }}<end_of_turn>\n<start_of_turn>model\n'
        ;;
    *Mistral*|*mistral*)
        _template='[INST] {{ if .System }}{{ .System }}\n\n{{ end }}{{ .Prompt }} [/INST]'
        ;;
    *DeepSeek*)
        _template='{{ if .System }}<|begin▁of▁sentence|>{{ .System }}{{ end }}{{ range .Messages }}<|User|>{{ if eq .Role "user" }}{{ .Content }}{{ else }}{{ .Content }}<|Assistant|>{{ end }}{{ end }}'
        ;;
    *)
        _template='{{ if .System }}### System:\n{{ .System }}\n\n{{ end }}### Human:\n{{ .Prompt }}\n### Assistant:\n'
        ;;
esac

_modelfile_path="$TEMP_DIR/Modelfile.${OLLAMA_TAG}"
cat > "$_modelfile_path" <<EOF
FROM ${_model_path}
TEMPLATE "${_template}"
PARAMETER num_gpu ${GPU_LAYERS}
PARAMETER num_thread ${HW_THREADS}
PARAMETER num_batch ${BATCH}
EOF

info "Registering model with Ollama as '${OLLAMA_TAG}'…"
ollama create "$OLLAMA_TAG" -f "$_modelfile_path" 2>&1 | tail -3 || warn "ollama create had warnings"
info "Model registered: $OLLAMA_TAG"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 12 — HELPER SCRIPTS
# ═══════════════════════════════════════════════════════════════════════════════
step "Helper scripts"

# ── llm-show-config ──────────────────────────────────────────────────────────
cat > "${BIN_DIR}/llm-show-config" <<'SCRIPT_EOF'
#!/usr/bin/env bash
CONFIG="$HOME/.config/local-llm/selected_model.conf"
[[ -f "$CONFIG" ]] && source "$CONFIG"
C='\033[0;36m'; Y='\033[1;33m'; G='\033[0;32m'; M='\033[38;5;240m'; N='\033[0m'; B='\033[1m'
_TW=$(( $(tput cols 2>/dev/null || echo 80) < 120 ? $(tput cols 2>/dev/null || echo 80) : 120 ))
_rule() { printf "${M}%*s${N}\n" "$_TW" "" | tr ' ' "─"; }

echo ""
_rule
echo -e "${B}${C}  LOCAL LLM — Configuration & Status${N}"
_rule
echo ""
echo -e "  ${B}Paths${N}"
printf "  ${Y}%-22s${N}  %s\n" "GGUF models"     "${GGUF_MODELS:-$HOME/local-llm-models/gguf}"
printf "  ${Y}%-22s${N}  %s\n" "Ollama models"   "${OLLAMA_MODELS:-$HOME/local-llm-models/ollama}"
printf "  ${Y}%-22s${N}  %s\n" "Config"          "${CONFIG}"
printf "  ${Y}%-22s${N}  %s\n" "Main venv"       "${VENV_DIR:-$HOME/.local/share/llm-venv}"
printf "  ${Y}%-22s${N}  %s\n" "WebUI venv"      "$HOME/.local/share/open-webui-venv"
echo ""
echo -e "  ${B}Active Model${N}"
printf "  ${Y}%-22s${N}  %s\n" "Name"            "${MODEL_NAME:-not set}"
printf "  ${Y}%-22s${N}  %s\n" "Ollama tag"      "${OLLAMA_TAG:-not set}"
printf "  ${Y}%-22s${N}  %s\n" "GPU layers"      "${GPU_LAYERS:-?}"
printf "  ${Y}%-22s${N}  %s\n" "Batch size"      "${BATCH_SIZE:-?}"
printf "  ${Y}%-22s${N}  %s\n" "HW threads"      "${HW_THREADS:-?}"
echo ""
echo -e "  ${B}Service Status${N}"
if curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo -e "  ${G}✓${N}  Ollama  running at http://127.0.0.1:11434"
    _models=$(curl -sf http://127.0.0.1:11434/api/tags 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); [print('      '+m['name']) for m in d.get('models',[])]" 2>/dev/null || true)
    [[ -n "$_models" ]] && echo -e "${M}  Loaded models:${N}" && echo "$_models"
else
    echo -e "  ${Y}○${N}  Ollama  stopped"
fi
if curl -sf --max-time 2 http://127.0.0.1:8080 >/dev/null 2>&1; then
    echo -e "  ${G}✓${N}  Open WebUI  running at http://127.0.0.1:8080"
else
    echo -e "  ${Y}○${N}  Open WebUI  stopped"
fi
echo ""
_rule
SCRIPT_EOF
chmod +x "${BIN_DIR}/llm-show-config"

# ── llm-stop ─────────────────────────────────────────────────────────────────
cat > "${BIN_DIR}/llm-stop" <<'SCRIPT_EOF'
#!/usr/bin/env bash
G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
echo -e "\n  Stopping LLM services…\n"

# Ollama
if pgrep -x ollama >/dev/null 2>&1; then
    pkill -TERM -x ollama 2>/dev/null && sleep 1 || true
    pgrep -x ollama >/dev/null 2>&1 && pkill -KILL -x ollama 2>/dev/null || true
    echo -e "  ${G}✓${N}  Ollama stopped."
else
    echo -e "  ${Y}○${N}  Ollama was not running."
fi

# Open WebUI (port 8080)
_pid=$(ss -lptn 'sport = :8080' 2>/dev/null \
    | awk 'NR>1{match($NF,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1 || true)
if [[ -n "$_pid" ]]; then
    kill "$_pid" 2>/dev/null && echo -e "  ${G}✓${N}  Open WebUI stopped (pid $_pid)." || true
else
    echo -e "  ${Y}○${N}  Open WebUI was not running."
fi

# Neural Terminal (port 8090)
pkill -f "python.*8090" 2>/dev/null && echo -e "  ${G}✓${N}  Neural Terminal stopped." || true

echo ""
SCRIPT_EOF
chmod +x "${BIN_DIR}/llm-stop"

# ── llm-update ───────────────────────────────────────────────────────────────
cat > "${BIN_DIR}/llm-update" <<'SCRIPT_EOF'
#!/usr/bin/env bash
G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; B='\033[1m'
echo -e "\n  ${B}Updating local LLM stack…${N}\n"

_ver_gt() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]; }

# Ollama
_cur=$(ollama --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
_new=$(curl -sf --max-time 8 "https://api.github.com/repos/ollama/ollama/releases/latest" \
    | grep '"tag_name"' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
if _ver_gt "$_new" "$_cur"; then
    echo -e "  Upgrading Ollama: $_cur → $_new"
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo -e "  ${G}✓${N}  Ollama $_cur is current."
fi

# Open WebUI
_owui_venv="$HOME/.local/share/open-webui-venv"
if [[ -f "$_owui_venv/bin/pip" ]]; then
    echo -e "  Upgrading Open WebUI…"
    "$_owui_venv/bin/pip" install --upgrade open-webui --quiet \
        && echo -e "  ${G}✓${N}  Open WebUI upgraded." \
        || echo -e "  ${Y}⚠${N}  Open WebUI upgrade had warnings."
fi

# Re-pull active Ollama model
CONFIG="$HOME/.config/local-llm/selected_model.conf"
if [[ -f "$CONFIG" ]]; then
    _tag=$(grep ^OLLAMA_TAG= "$CONFIG" | cut -d'"' -f2)
    if [[ -n "$_tag" ]]; then
        echo -e "  Pulling latest ollama model: $_tag"
        ollama pull "$_tag" || echo -e "  ${Y}⚠${N}  ollama pull had warnings."
    fi
fi

echo -e "\n  ${G}✓${N}  Update complete.\n"
SCRIPT_EOF
chmod +x "${BIN_DIR}/llm-update"

# ── llm-switch ───────────────────────────────────────────────────────────────
cat > "${BIN_DIR}/llm-switch" <<'HEREDOC'
#!/usr/bin/env bash
# llm-switch — change the active model without re-running setup
CONFIG="$HOME/.config/local-llm/selected_model.conf"
GGUF_MODELS="$HOME/local-llm-models/gguf"
C='\033[0;36m'; Y='\033[1;33m'; G='\033[0;32m'; N='\033[0m'; B='\033[1m'; M='\033[38;5;240m'
_TW=$(( $(tput cols 2>/dev/null || echo 80) < 120 ? $(tput cols 2>/dev/null || echo 80) : 120 ))
_rule() { printf "${M}%*s${N}\n" "$_TW" "" | tr ' ' "─"; }
_is_installed() { [[ -f "$GGUF_MODELS/$1" ]] && echo " ✔" || echo "  "; }

declare -A _N _Q _F _U _S _L _V _CP _T
_define_model() {
    local i="$1"; _N[$i]="$2"; _Q[$i]="$3"; _F[$i]="$4"
    _U[$i]="https://huggingface.co/$5/resolve/main/$4"
    _S[$i]="$6"; _L[$i]="$7"; _V[$i]="$8"; _CP[$i]="$9"; _T[$i]="${10}"
}
_define_model  1  "Qwen3-1.7B"           "Q8"  "Qwen_Qwen3-1.7B-Q8_0.gguf"         "bartowski/Qwen_Qwen3-1.7B-GGUF"           2   28  "CPU"   "★ TOOLS · THINK"                "CPU / No GPU needed"
_define_model  2  "Qwen3-4B"             "Q4"  "Qwen_Qwen3-4B-Q4_K_M.gguf"         "bartowski/Qwen_Qwen3-4B-GGUF"             3   36  "~3GB"  "★ TOOLS · THINK"                "CPU / No GPU needed"
_define_model  3  "Phi-4-mini 3.8B"      "Q4"  "Phi-4-mini-instruct-Q4_K_M.gguf"   "bartowski/Phi-4-mini-instruct-GGUF"       3   32  "CPU"   "★ TOOLS · THINK"                "CPU / No GPU needed"
_define_model  4  "Qwen3-0.6B"           "Q8"  "Qwen_Qwen3-0.6B-Q8_0.gguf"         "bartowski/Qwen_Qwen3-0.6B-GGUF"           1   28  "CPU"   "TOOLS · THINK · tiny"           "CPU / No GPU needed"
_define_model  5  "Qwen3-8B"             "Q4"  "Qwen_Qwen3-8B-Q4_K_M.gguf"         "bartowski/Qwen_Qwen3-8B-GGUF"             5   36  "~5GB"  "★ TOOLS · THINK"                "6-8 GB VRAM"
_define_model  6  "Qwen3-8B"             "Q6"  "Qwen_Qwen3-8B-Q6_K.gguf"           "bartowski/Qwen_Qwen3-8B-GGUF"             6   36  "~6GB"  "★ TOOLS · THINK · higher quality" "6-8 GB VRAM"
_define_model  7  "DeepSeek-R1-Distill-8B"  "Q4"  "DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"  "bartowski/DeepSeek-R1-Distill-Qwen-8B-GGUF"  5  36  "~5GB"  "THINK · deep reasoning"  "6-8 GB VRAM"
_define_model  8  "Gemma-3-9B"           "Q4"  "google_gemma-3-9b-it-Q4_K_M.gguf"  "bartowski/google_gemma-3-9b-it-GGUF"      6   46  "~6GB"  "TOOLS · Google"                 "6-8 GB VRAM"
_define_model  9  "Gemma-3-12B"          "Q4"  "google_gemma-3-12b-it-Q4_K_M.gguf" "bartowski/google_gemma-3-12b-it-GGUF"     8   46  "~8GB"  "TOOLS · Google vision"          "6-8 GB VRAM"
_define_model 10  "Dolphin3.0-8B"        "Q4"  "dolphin3.0-qwen2.5-7b-Q4_K_M.gguf" "bartowski/dolphin3.0-qwen2.5-7b-GGUF"    5   28  "~5GB"  "UNCENSORED"                     "6-8 GB VRAM"
_define_model 11  "Phi-4-14B"            "Q4"  "phi-4-Q4_K_M.gguf"                 "bartowski/phi-4-GGUF"                     9   40  "~9GB"  "★ TOOLS · top coding + math"    "10-12 GB VRAM"
_define_model 12  "Qwen3-14B"            "Q4"  "Qwen_Qwen3-14B-Q4_K_M.gguf"        "bartowski/Qwen_Qwen3-14B-GGUF"            9   40  "~9GB"  "★ TOOLS · THINK"                "10-12 GB VRAM"
_define_model 13  "DeepSeek-R1-Distill-14B" "Q4" "DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf" "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF" 9 40 "~9GB" "THINK · deep reasoning"  "10-12 GB VRAM"
_define_model 14  "Gemma-3-27B"          "Q4"  "google_gemma-3-27b-it-Q4_K_M.gguf" "bartowski/google_gemma-3-27b-it-GGUF"    12   46  "~12GB" "TOOLS · Google"                 "16 GB VRAM"
_define_model 15  "Mistral-Small-3.1-24B" "Q4" "Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf" "bartowski/Mistral-Small-3.1-24B-Instruct-2503-GGUF" 14 40 "~14GB" "TOOLS · THINK · 128K context" "16 GB VRAM"
_define_model 16  "Mistral-Small-3.2-24B" "Q4" "Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf" "bartowski/Mistral-Small-3.2-24B-Instruct-2506-GGUF" 14 40 "~14GB" "★ TOOLS · THINK · newest" "16 GB VRAM"
_define_model 17  "Qwen3-30B-A3B (MoE)"  "Q4"  "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"   "bartowski/Qwen_Qwen3-30B-A3B-GGUF"       16   48  "~16GB" "★ TOOLS · THINK · 30B@8B speed" "16 GB VRAM"
_define_model 18  "Qwen3-32B"            "Q4"  "Qwen_Qwen3-32B-Q4_K_M.gguf"        "bartowski/Qwen_Qwen3-32B-GGUF"           19   64  "~19GB" "★ TOOLS · THINK"                "24+ GB VRAM"
_define_model 19  "DeepSeek-R1-Distill-32B" "Q4" "DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf" "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF" 19 64 "~19GB" "THINK · deep reasoning" "24+ GB VRAM"
_define_model 20  "Gemma-3-27B (Google)" "Q4"  "google_gemma-3-27b-it-Q4_K_M.gguf" "bartowski/google_gemma-3-27b-it-GGUF"    16   46  "~16GB" "TOOLS · Google"                 "24+ GB VRAM"
_define_model 21  "Llama-3.3-70B"        "Q4"  "Llama-3.3-70B-Instruct-Q4_K_M.gguf" "bartowski/Llama-3.3-70B-Instruct-GGUF"  40   80  "~40GB" "★ TOOLS · flagship"             "48 GB VRAM (multi-GPU)"

echo ""
_rule
printf "  ${B}%-4s  %-32s  %-6s  %-7s  %-2s  %s${N}\n" "#" "Model" "Quant" "VRAM" "" "Capabilities"
_rule
_last_tier=""
for _i in $(seq 1 21); do
    if [[ "${_T[$_i]}" != "$_last_tier" ]]; then
        echo ""
        echo -e "  ${Y}▸  ${_T[$_i]}${N}"
        _last_tier="${_T[$_i]}"
    fi
    _chk=$(_is_installed "${_F[$_i]}")
    printf "  %-4s  %-32s  %-6s  %-7s  %-2s  %s\n" \
        "$_i" "${_N[$_i]}" "${_Q[$_i]}" "${_V[$_i]}" "$_chk" "${_CP[$_i]}"
done
echo ""
_rule

printf "  ${C}?${N}  ${B}Enter model number [1-21]:${N} "
read -r _inp
[[ ! "$_inp" =~ ^[0-9]+$ ]] || (( _inp < 1 || _inp > 21 )) && { echo "Invalid selection."; exit 1; }

_new_file="${_F[$_inp]}"
_new_path="$GGUF_MODELS/$_new_file"

if [[ ! -f "$_new_path" ]]; then
    echo -e "\n  ${Y}⚠${N}  Model not downloaded. Downloading now…\n"
    wget --progress=bar:force:noscroll --retry-connrefused --tries=3 \
        -O "$_new_path" "${_U[$_inp]}" || { echo "Download failed."; exit 1; }
fi

_new_tag=$(echo "${_F[$_inp]}" | sed 's/\.gguf$//' | tr '[:upper:]' '[:lower:]' \
    | sed 's/_/-/g; s/[^a-z0-9:-]//g; s/--*/-/g' | cut -c1-60)

# Update config
sed -i "s|^MODEL_NAME=.*|MODEL_NAME=\"${_N[$_inp]}\"|" "$CONFIG"
sed -i "s|^MODEL_FILE=.*|MODEL_FILE=\"${_F[$_inp]}\"|" "$CONFIG"
sed -i "s|^MODEL_URL=.*|MODEL_URL=\"${_U[$_inp]}\"|" "$CONFIG"
sed -i "s|^OLLAMA_TAG=.*|OLLAMA_TAG=\"${_new_tag}\"|" "$CONFIG"

# Register with Ollama
_mf="$HOME/local-llm-models/temp/Modelfile.switch"
mkdir -p "$HOME/local-llm-models/temp"
cat > "$_mf" <<MF_EOF
FROM ${_new_path}
PARAMETER num_gpu -1
PARAMETER num_thread 8
PARAMETER num_batch 512
MF_EOF

if curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    ollama create "$_new_tag" -f "$_mf" 2>&1 | tail -2 || echo "ollama create had warnings"
    echo -e "\n  ${G}✓${N}  Switched to: ${_N[$_inp]} (${_new_tag})\n"
else
    echo -e "\n  ${Y}⚠${N}  Ollama not running. Start it with: ollama-start\n"
fi
HEREDOC
chmod +x "${BIN_DIR}/llm-switch"

# ── llm-add ──────────────────────────────────────────────────────────────────
cat > "${BIN_DIR}/llm-add" <<'HEREDOC'
#!/usr/bin/env bash
# llm-add — download additional models from catalog
GGUF_MODELS="$HOME/local-llm-models/gguf"
Y='\033[1;33m'; G='\033[0;32m'; N='\033[0m'; B='\033[1m'; M='\033[38;5;240m'

declare -A _N _F _U _S _V _CP _T
_define_model() {
    local i="$1"; _N[$i]="$2"; _F[$i]="$4"
    _U[$i]="https://huggingface.co/$5/resolve/main/$4"
    _S[$i]="$6"; _V[$i]="$8"; _CP[$i]="$9"; _T[$i]="${10}"
}
_define_model  1  "Qwen3-1.7B"           "Q8"  "Qwen_Qwen3-1.7B-Q8_0.gguf"         "bartowski/Qwen_Qwen3-1.7B-GGUF"           2   28  "CPU"   "★ TOOLS · THINK"                "CPU"
_define_model  2  "Qwen3-4B"             "Q4"  "Qwen_Qwen3-4B-Q4_K_M.gguf"         "bartowski/Qwen_Qwen3-4B-GGUF"             3   36  "~3GB"  "★ TOOLS · THINK"                "CPU"
_define_model  3  "Phi-4-mini 3.8B"      "Q4"  "Phi-4-mini-instruct-Q4_K_M.gguf"   "bartowski/Phi-4-mini-instruct-GGUF"       3   32  "CPU"   "★ TOOLS · THINK"                "CPU"
_define_model  4  "Qwen3-0.6B"           "Q8"  "Qwen_Qwen3-0.6B-Q8_0.gguf"         "bartowski/Qwen_Qwen3-0.6B-GGUF"           1   28  "CPU"   "tiny"                           "CPU"
_define_model  5  "Qwen3-8B Q4"          "Q4"  "Qwen_Qwen3-8B-Q4_K_M.gguf"         "bartowski/Qwen_Qwen3-8B-GGUF"             5   36  "~5GB"  "★ TOOLS · THINK"                "6GB"
_define_model  6  "Qwen3-8B Q6"          "Q6"  "Qwen_Qwen3-8B-Q6_K.gguf"           "bartowski/Qwen_Qwen3-8B-GGUF"             6   36  "~6GB"  "higher quality"                 "6GB"
_define_model  7  "DeepSeek-R1-8B"       "Q4"  "DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"  "bartowski/DeepSeek-R1-Distill-Qwen-8B-GGUF"  5  36  "~5GB"  "reasoning"         "6GB"
_define_model  8  "Gemma-3-9B"           "Q4"  "google_gemma-3-9b-it-Q4_K_M.gguf"  "bartowski/google_gemma-3-9b-it-GGUF"      6   46  "~6GB"  "Google"                         "6GB"
_define_model  9  "Gemma-3-12B"          "Q4"  "google_gemma-3-12b-it-Q4_K_M.gguf" "bartowski/google_gemma-3-12b-it-GGUF"     8   46  "~8GB"  "Google vision"                  "8GB"
_define_model 10  "Dolphin3.0-8B"        "Q4"  "dolphin3.0-qwen2.5-7b-Q4_K_M.gguf" "bartowski/dolphin3.0-qwen2.5-7b-GGUF"    5   28  "~5GB"  "UNCENSORED"                     "6GB"
_define_model 11  "Phi-4-14B"            "Q4"  "phi-4-Q4_K_M.gguf"                 "bartowski/phi-4-GGUF"                     9   40  "~9GB"  "coding + math"                  "10GB"
_define_model 12  "Qwen3-14B"            "Q4"  "Qwen_Qwen3-14B-Q4_K_M.gguf"        "bartowski/Qwen_Qwen3-14B-GGUF"            9   40  "~9GB"  "★ TOOLS · THINK"                "10GB"
_define_model 13  "DeepSeek-R1-14B"      "Q4"  "DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf" "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF" 9 40 "~9GB" "reasoning"           "10GB"
_define_model 14  "Gemma-3-27B"          "Q4"  "google_gemma-3-27b-it-Q4_K_M.gguf" "bartowski/google_gemma-3-27b-it-GGUF"    12   46  "~12GB" "Google"                         "16GB"
_define_model 15  "Mistral-Small-3.1-24B" "Q4" "Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf" "bartowski/Mistral-Small-3.1-24B-Instruct-2503-GGUF" 14 40 "~14GB" "128K context" "16GB"
_define_model 16  "Mistral-Small-3.2-24B" "Q4" "Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf" "bartowski/Mistral-Small-3.2-24B-Instruct-2506-GGUF" 14 40 "~14GB" "newest" "16GB"
_define_model 17  "Qwen3-30B-A3B"        "Q4"  "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"   "bartowski/Qwen_Qwen3-30B-A3B-GGUF"       16   48  "~16GB" "MoE 30B@8B speed"               "16GB"
_define_model 18  "Qwen3-32B"            "Q4"  "Qwen_Qwen3-32B-Q4_K_M.gguf"        "bartowski/Qwen_Qwen3-32B-GGUF"           19   64  "~19GB" "★ TOOLS · THINK"                "24GB"
_define_model 19  "DeepSeek-R1-32B"      "Q4"  "DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf" "bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF" 19 64 "~19GB" "reasoning"          "24GB"
_define_model 20  "Gemma-3-27B (24GB)"   "Q4"  "google_gemma-3-27b-it-Q4_K_M.gguf" "bartowski/google_gemma-3-27b-it-GGUF"    16   46  "~16GB" "Google"                         "24GB"
_define_model 21  "Llama-3.3-70B"        "Q4"  "Llama-3.3-70B-Instruct-Q4_K_M.gguf" "bartowski/Llama-3.3-70B-Instruct-GGUF"  40   80  "~40GB" "flagship"                       "48GB"

echo ""
echo -e "  ${B}Available models to download:${N}"
echo ""
_last_tier=""
for _i in $(seq 1 21); do
    [[ -f "$GGUF_MODELS/${_F[$_i]}" ]] && continue
    if [[ "${_T[$_i]}" != "$_last_tier" ]]; then
        echo -e "  ${Y}▸  ${_T[$_i]}${N}"
        _last_tier="${_T[$_i]}"
    fi
    printf "  %-4s  %-32s  %-7s  %s\n" "$_i" "${_N[$_i]}" "${_V[$_i]}" "${_CP[$_i]}"
done

echo ""
printf "  ${Y}?${N}  ${B}Enter numbers to download (space-separated) or Enter to cancel:${N} "
read -r _sel
[[ -z "$_sel" ]] && { echo "  No models selected."; exit 0; }

for _n in $_sel; do
    [[ ! "$_n" =~ ^[0-9]+$ ]] || (( _n < 1 || _n > 21 )) && continue
    _fp="$GGUF_MODELS/${_F[$_n]}"
    [[ -f "$_fp" ]] && { echo -e "  ${G}✓${N}  ${_N[$_n]} already downloaded."; continue; }
    echo -e "\n  Downloading ${_N[$_n]}…"
    wget --progress=bar:force:noscroll --retry-connrefused --tries=3 \
        -O "$_fp" "${_U[$_n]}" \
        && echo -e "  ${G}✓${N}  ${_N[$_n]} downloaded." \
        || echo -e "  ${Y}⚠${N}  ${_N[$_n]} download failed."
done
HEREDOC
chmod +x "${BIN_DIR}/llm-add"

# ── local-models-info (llm-status) ───────────────────────────────────────────
cat > "${BIN_DIR}/local-models-info" <<'SCRIPT_EOF'
#!/usr/bin/env bash
G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'; B='\033[1m'; M='\033[38;5;240m'; C='\033[0;36m'
echo ""
echo -e "  ${B}${C}Local LLM Status${N}"
echo ""

echo -e "  ${B}Ollama loaded models:${N}"
if curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    ollama list 2>/dev/null | head -20 || echo "    (none)"
    echo ""
    echo -e "  ${B}Running:${N}"
    ollama ps 2>/dev/null || echo "    (none)"
else
    echo -e "  ${Y}○${N}  Ollama not running. Run: ollama-start"
fi

echo ""
echo -e "  ${B}Downloaded GGUF files:${N}"
_gguf_dir="$HOME/local-llm-models/gguf"
if ls "$_gguf_dir"/*.gguf 2>/dev/null | head -1 &>/dev/null; then
    ls -lh "$_gguf_dir"/*.gguf 2>/dev/null | awk '{printf "  %-60s  %s\n", $NF, $5}'
else
    echo "  (none)"
fi

echo ""
echo -e "  ${B}Python venvs:${N}"
for _v in "$HOME/.local/share/llm-venv" \
          "$HOME/.local/share/open-webui-venv" \
          "$HOME/.local/share/open-interpreter-venv" \
          "$HOME/.local/share/aider-venv"; do
    [[ -d "$_v" ]] \
        && echo -e "  ${G}✓${N}  $(basename "$_v")" \
        || echo -e "  ${M}○${N}  $(basename "$_v") (not installed)"
done
echo ""
SCRIPT_EOF
chmod +x "${BIN_DIR}/local-models-info"
ln -sf "${BIN_DIR}/local-models-info" "${BIN_DIR}/llm-status" 2>/dev/null || cp "${BIN_DIR}/local-models-info" "${BIN_DIR}/llm-status"
chmod +x "${BIN_DIR}/llm-status"

# ── run-gguf ─────────────────────────────────────────────────────────────────
cat > "${BIN_DIR}/run-gguf" <<'SCRIPT_EOF'
#!/usr/bin/env bash
# Direct llama-cpp-python inference — bypasses Ollama
# Usage: run-gguf [--model path.gguf] "your prompt"
VENV_DIR="$HOME/.local/share/llm-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"

# Auto-recreate venv if missing (e.g. first boot after setup)
if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
    echo "  ⚠  llm-venv missing — rebuilding…"
    _py=$(command -v python3.12 || command -v python3.11 || command -v python3)
    [[ -z "$_py" ]] && { echo "ERROR: python3 not found"; exit 1; }
    "$_py" -m venv "$VENV_DIR" || { echo "ERROR: cannot create venv"; exit 1; }
    "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel --quiet 2>/dev/null
    "$VENV_DIR/bin/pip" install llama-cpp-python --quiet 2>/dev/null \
        || echo "  ⚠  llama-cpp-python install failed — GPU inference won't work"
fi

if ! "$VENV_DIR/bin/python3" -c "from llama_cpp import Llama" 2>/dev/null; then
    echo "  ⚠  llama-cpp-python not installed in venv."
    echo "  To fix: re-run llm-auto-setup.sh (it will rebuild llama-cpp-python)."
    exit 1
fi

_model=""
_prompt=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) _model="$2"; shift 2 ;;
        *) _prompt="${_prompt} $1"; shift ;;
    esac
done

if [[ -z "$_model" ]] && [[ -f "$CONFIG" ]]; then
    _file=$(grep ^MODEL_FILE= "$CONFIG" | cut -d'"' -f2)
    _dir=$(grep ^GGUF_MODELS= "$CONFIG" | cut -d'"' -f2)
    _model="${_dir:-$HOME/local-llm-models/gguf}/${_file}"
fi

[[ -z "$_model" || ! -f "$_model" ]] && { echo "No model found. Use --model /path/to/model.gguf"; exit 1; }
[[ -z "$_prompt" ]] && { printf "Prompt: "; read -r _prompt; }

source "$VENV_DIR/bin/activate"
python3 - "$_model" "${_prompt}" <<'PYEOF'
import sys
from llama_cpp import Llama
model_path, prompt = sys.argv[1], " ".join(sys.argv[2:])
llm = Llama(model_path=model_path, n_ctx=4096, verbose=False)
output = llm(prompt, max_tokens=512, stop=["</s>", "<|im_end|>"], echo=False)
print(output["choices"][0]["text"].strip())
PYEOF
SCRIPT_EOF
chmod +x "${BIN_DIR}/run-gguf"

info "Helper scripts installed."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 13 — WEB UI
# ═══════════════════════════════════════════════════════════════════════════════
step "Web UI (Open WebUI + Neural Terminal)"

# ── 13a. Open WebUI ───────────────────────────────────────────────────────────
OWUI_DATA="$GUI_DIR/open-webui-data"
mkdir -p "$OWUI_DATA"

_ensure_venv "$OWUI_VENV"

spin_start "Installing / upgrading Open WebUI (may take a few minutes)…"
"$OWUI_VENV/bin/pip" install open-webui --quiet 2>/dev/null \
    && info "Open WebUI installed: $("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | grep ^Version | awk '{print $2}' || echo 'ok')" \
    || warn "Open WebUI install had warnings — run llm-webui to check"
spin_stop $?

# Launcher — checks venv and auto-recreates if missing
cat > "${BIN_DIR}/llm-webui" <<'SCRIPT_EOF'
#!/usr/bin/env bash
OWUI_VENV="$HOME/.local/share/open-webui-venv"
OWUI_DATA="$HOME/.local/share/llm-webui/open-webui-data"
BIN_DIR="$HOME/.local/bin"

# Auto-recreate venv if missing
if [[ ! -x "$OWUI_VENV/bin/python3" ]]; then
    echo "  ⚠  open-webui-venv missing — rebuilding…"
    _py=$(command -v python3.12 || command -v python3.11 || command -v python3)
    [[ -z "$_py" ]] && { echo "ERROR: python3 not found"; exit 1; }
    "$_py" -m venv "$OWUI_VENV" || { echo "ERROR: cannot create venv"; exit 1; }
    "$OWUI_VENV/bin/pip" install --upgrade pip setuptools wheel --quiet 2>/dev/null
    "$OWUI_VENV/bin/pip" install open-webui --quiet \
        || { echo "ERROR: open-webui install failed"; exit 1; }
fi

if ! "$OWUI_VENV/bin/python3" -c "import open_webui" 2>/dev/null \
   && ! "$OWUI_VENV/bin/which" open-webui >/dev/null 2>/dev/null; then
    echo "  ⚠  open-webui not found in venv. Installing…"
    "$OWUI_VENV/bin/pip" install open-webui --quiet \
        || { echo "ERROR: open-webui install failed"; exit 1; }
fi

_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
if ! _ollama_up; then
    [[ -x "$BIN_DIR/ollama-start" ]] && "$BIN_DIR/ollama-start" \
        || nohup ollama serve >/dev/null 2>&1 &
    for i in {1..20}; do _ollama_up && break; sleep 1; done
fi

_stale=$(ss -lptn 'sport = :8080' 2>/dev/null \
    | awk 'NR>1{match($NF,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1 || true)
[[ -n "$_stale" ]] && { kill "$_stale" 2>/dev/null; sleep 1; }

mkdir -p "$OWUI_DATA"

export OLLAMA_BASE_URL="http://127.0.0.1:11434"
export OLLAMA_API_BASE_URL="http://127.0.0.1:11434"
export ENABLE_OLLAMA_API="true"
export WEBUI_AUTH="false"
export ENABLE_LOGIN_FORM="false"
export ENABLE_SIGNUP="false"
export DEFAULT_USER_ROLE="admin"
export CORS_ALLOW_ORIGIN="*"
export AIOHTTP_CLIENT_TIMEOUT=900
export AIOHTTP_CLIENT_TIMEOUT_TOTAL=900
export OLLAMA_REQUEST_TIMEOUT=900
export OLLAMA_CLIENT_TIMEOUT=900
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_FLASH_ATTENTION=1
export DATA_DIR="$OWUI_DATA"
export PYTHONWARNINGS="ignore::RuntimeWarning"

echo "  Starting Open WebUI at http://localhost:8080 …"
source "$OWUI_VENV/bin/activate"
exec open-webui serve --host 0.0.0.0 --port 8080
SCRIPT_EOF
chmod +x "${BIN_DIR}/llm-webui"

# ── 13b. Neural Terminal HTML ─────────────────────────────────────────────────
mkdir -p "$GUI_DIR"
cat > "$GUI_DIR/index.html" <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Neural Terminal</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg: #0d1117; --bg2: #161b22; --bg3: #21262d;
    --accent: #58a6ff; --accent2: #3fb950; --warn: #f78166;
    --text: #e6edf3; --muted: #8b949e; --border: #30363d;
    --code-bg: #1c2128;
  }
  body { background: var(--bg); color: var(--text); font-family: 'Cascadia Code', 'Fira Code', 'Consolas', monospace; font-size: 14px; height: 100vh; display: flex; flex-direction: column; overflow: hidden; }
  header { background: var(--bg2); border-bottom: 1px solid var(--border); padding: 12px 20px; display: flex; align-items: center; gap: 16px; flex-shrink: 0; }
  header h1 { font-size: 16px; color: var(--accent); font-weight: 600; letter-spacing: 1px; }
  header h1 span { color: var(--muted); }
  select { background: var(--bg3); color: var(--text); border: 1px solid var(--border); border-radius: 6px; padding: 4px 10px; font-family: inherit; font-size: 13px; cursor: pointer; outline: none; }
  select:focus { border-color: var(--accent); }
  #status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); flex-shrink: 0; transition: background 0.3s; }
  #status-dot.online { background: var(--accent2); }
  #status-dot.error { background: var(--warn); }
  #messages { flex: 1; overflow-y: auto; padding: 20px; display: flex; flex-direction: column; gap: 16px; scroll-behavior: smooth; }
  #messages::-webkit-scrollbar { width: 6px; } #messages::-webkit-scrollbar-track { background: transparent; } #messages::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
  .msg { display: flex; flex-direction: column; gap: 4px; max-width: 85%; }
  .msg.user { align-self: flex-end; }
  .msg.assistant { align-self: flex-start; }
  .msg-role { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
  .msg.user .msg-role { color: var(--accent); text-align: right; }
  .msg-content { background: var(--bg2); border: 1px solid var(--border); border-radius: 8px; padding: 12px 16px; line-height: 1.6; white-space: pre-wrap; word-break: break-word; }
  .msg.user .msg-content { background: var(--bg3); border-color: var(--accent); }
  .msg.assistant .msg-content { border-color: var(--border); }
  .msg-content code { background: var(--code-bg); border-radius: 3px; padding: 1px 5px; font-size: 13px; color: #79c0ff; }
  .msg-content pre { background: var(--code-bg); border: 1px solid var(--border); border-radius: 6px; padding: 14px; overflow-x: auto; margin: 8px 0; }
  .msg-content pre code { background: none; padding: 0; color: var(--text); }
  .msg.thinking .msg-content { color: var(--muted); font-style: italic; border-style: dashed; }
  footer { background: var(--bg2); border-top: 1px solid var(--border); padding: 14px 20px; display: flex; gap: 10px; flex-shrink: 0; }
  #input { flex: 1; background: var(--bg3); color: var(--text); border: 1px solid var(--border); border-radius: 8px; padding: 10px 14px; font-family: inherit; font-size: 14px; resize: none; outline: none; max-height: 180px; min-height: 42px; transition: border-color 0.2s; }
  #input:focus { border-color: var(--accent); }
  #input::placeholder { color: var(--muted); }
  button { background: var(--accent); color: var(--bg); border: none; border-radius: 8px; padding: 10px 18px; font-family: inherit; font-size: 13px; font-weight: 600; cursor: pointer; transition: opacity 0.2s; flex-shrink: 0; }
  button:hover { opacity: 0.85; }
  button:disabled { opacity: 0.4; cursor: not-allowed; }
  #clear-btn { background: var(--bg3); color: var(--muted); border: 1px solid var(--border); }
  .typing { display: flex; align-items: center; gap: 6px; padding: 10px 16px; }
  .typing span { width: 6px; height: 6px; border-radius: 50%; background: var(--accent); animation: bounce 1s infinite; }
  .typing span:nth-child(2) { animation-delay: 0.15s; }
  .typing span:nth-child(3) { animation-delay: 0.3s; }
  @keyframes bounce { 0%,80%,100%{transform:translateY(0)} 40%{transform:translateY(-8px)} }
  .empty-state { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; color: var(--muted); gap: 12px; }
  .empty-state h2 { color: var(--text); font-size: 20px; }
  .empty-state p { font-size: 13px; }
</style>
</head>
<body>
<header>
  <div id="status-dot"></div>
  <h1>NEURAL <span>TERMINAL</span></h1>
  <select id="model-select"><option value="">Loading models…</option></select>
  <button id="clear-btn" onclick="clearChat()">Clear</button>
</header>
<div id="messages">
  <div class="empty-state">
    <h2>⚡ Neural Terminal</h2>
    <p>Local LLM inference via Ollama · Streaming responses</p>
    <p id="empty-hint" style="color:var(--muted);font-size:12px;">Connecting to Ollama on port 11434…</p>
  </div>
</div>
<footer>
  <textarea id="input" placeholder="Type a message… (Enter to send, Shift+Enter for newline)" rows="1"></textarea>
  <button id="send-btn" onclick="sendMessage()">Send ▶</button>
</footer>
<script>
const OLLAMA = 'http://localhost:11434';
let messages = [];
let streaming = false;

const dot = document.getElementById('status-dot');
const modelSel = document.getElementById('model-select');
const input = document.getElementById('input');
const msgDiv = document.getElementById('messages');
const sendBtn = document.getElementById('send-btn');

async function loadModels() {
  try {
    const r = await fetch(OLLAMA + '/api/tags', {signal: AbortSignal.timeout(4000)});
    const d = await r.json();
    const models = d.models || [];
    modelSel.innerHTML = models.length
      ? models.map(m => `<option value="${m.name}">${m.name}</option>`).join('')
      : '<option value="">No models found</option>';
    dot.className = 'online';
    document.getElementById('empty-hint').textContent = models.length
      ? `${models.length} model(s) available. Start chatting!`
      : 'No Ollama models found. Run: ollama pull qwen3:8b';
  } catch(e) {
    dot.className = 'error';
    modelSel.innerHTML = '<option value="">Ollama offline</option>';
    document.getElementById('empty-hint').textContent = 'Ollama not running. Run: ollama-start';
  }
}

function escapeHtml(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function renderContent(text) {
  // Code blocks
  text = text.replace(/```(\w+)?\n([\s\S]*?)```/g, (_,lang,code) =>
    `<pre><code>${escapeHtml(code.trim())}</code></pre>`);
  // Inline code
  text = text.replace(/`([^`]+)`/g, (_,c) => `<code>${escapeHtml(c)}</code>`);
  // Bold
  text = text.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  return text;
}

function addMessage(role, content, isStreaming) {
  const empty = document.querySelector('.empty-state');
  if (empty) empty.remove();

  const div = document.createElement('div');
  div.className = `msg ${role}`;
  const label = role === 'user' ? 'You' : 'Assistant';
  div.innerHTML = `<div class="msg-role">${label}</div>
    <div class="msg-content">${isStreaming ? '' : renderContent(content)}</div>`;
  if (isStreaming) {
    div.querySelector('.msg-content').innerHTML =
      '<div class="typing"><span></span><span></span><span></span></div>';
  }
  msgDiv.appendChild(div);
  msgDiv.scrollTop = msgDiv.scrollHeight;
  return div;
}

async function sendMessage() {
  if (streaming) return;
  const text = input.value.trim();
  if (!text) return;
  const model = modelSel.value;
  if (!model) { alert('Select a model first.'); return; }

  messages.push({role: 'user', content: text});
  addMessage('user', text, false);
  input.value = '';
  input.style.height = 'auto';

  streaming = true;
  sendBtn.disabled = true;
  const aMsg = addMessage('assistant', '', true);
  const aContent = aMsg.querySelector('.msg-content');
  let fullText = '';

  try {
    const resp = await fetch(OLLAMA + '/api/chat', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        model, stream: true,
        messages: messages.map(m => ({role: m.role, content: m.content}))
      })
    });

    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const reader = resp.body.getReader();
    const dec = new TextDecoder();

    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      const chunk = dec.decode(value, {stream: true});
      for (const line of chunk.split('\n').filter(Boolean)) {
        try {
          const j = JSON.parse(line);
          if (j.message?.content) {
            fullText += j.message.content;
            aContent.innerHTML = renderContent(fullText);
            msgDiv.scrollTop = msgDiv.scrollHeight;
          }
        } catch {}
      }
    }
    messages.push({role: 'assistant', content: fullText});
  } catch(e) {
    aContent.innerHTML = `<span style="color:var(--warn)">Error: ${e.message}</span>`;
  } finally {
    streaming = false;
    sendBtn.disabled = false;
  }
}

function clearChat() {
  messages = [];
  msgDiv.innerHTML = `<div class="empty-state"><h2>⚡ Neural Terminal</h2>
    <p>Chat cleared.</p><p id="empty-hint" style="color:var(--muted);font-size:12px;">Ready.</p></div>`;
}

input.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});
input.addEventListener('input', () => {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 180) + 'px';
});

loadModels();
setInterval(loadModels, 30000);
</script>
</body>
</html>
HTML_EOF

# Neural Terminal launcher
cat > "${BIN_DIR}/llm-chat" <<SCRIPT_EOF
#!/usr/bin/env bash
PORT=8090
pkill -f "python.*$PORT" 2>/dev/null || true
_gui_dir="\$HOME/.local/share/llm-webui"
cd "\$_gui_dir" || exit 1
python3 -m http.server \$PORT --bind 127.0.0.1 >/dev/null 2>&1 &
echo "Neural Terminal started at http://localhost:\$PORT"
xdg-open "http://localhost:\$PORT" 2>/dev/null \
    || explorer.exe "http://localhost:\$PORT" 2>/dev/null \
    || echo "Open: http://localhost:\$PORT"
SCRIPT_EOF
chmod +x "${BIN_DIR}/llm-chat"

info "Web UI components installed."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 14 — OPTIONAL TOOLS (interactive menu)
# ═══════════════════════════════════════════════════════════════════════════════
step "Optional tools"

echo ""
_rule "─"
echo -e "  ${BOLD}Optional tools — enter numbers (space-separated) or Enter to skip${NC}"
_rule "─"
echo ""
echo -e "  ${CYAN}── System utilities ──────────────────────────────────────────────${NC}"
echo -e "  ${YELLOW}1${NC}   tmux          Terminal multiplexer"
echo -e "  ${YELLOW}2${NC}   CLI tools     bat · eza · fzf · ripgrep · btop · ncdu · jq · micro"
(( HAS_GPU )) && echo -e "  ${YELLOW}3${NC}   nvtop         GPU monitor" || echo -e "  ${MUTED}3${NC}   nvtop         GPU monitor  ${MUTED}(no GPU detected — will skip)${NC}"
[[ -n "${DISPLAY:-}" ]] && echo -e "  ${YELLOW}4${NC}   GUI tools     Thunar · Mousepad · Meld" || echo -e "  ${MUTED}4${NC}   GUI tools     Thunar · Mousepad · Meld  ${MUTED}(no DISPLAY — will skip)${NC}"
echo -e "  ${YELLOW}5${NC}   neofetch      System info banner + fastfetch"
echo ""
echo -e "  ${CYAN}── AI coding agents ──────────────────────────────────────────────${NC}"
echo -e "  ${YELLOW}6${NC}   Claude Code   Anthropic CLI agent  ${MUTED}(needs ANTHROPIC_API_KEY)${NC}"
echo -e "  ${YELLOW}7${NC}   OpenAI Codex  OpenAI CLI agent  ${MUTED}(needs Node ≥22, OPENAI_API_KEY)${NC}"
echo ""
_rule "─"
printf "  ${ACCENT}?${NC}  ${BOLD}Select tools [1 2 3… / all / Enter to skip]:${NC} "
if [[ -t 0 ]]; then
    read -r _tool_sel
else
    _tool_sel=""
    warn "Non-interactive mode — skipping optional tools."
fi

[[ "${_tool_sel:-}" == "all" ]] && _tool_sel=" 1 2 3 4 5 6 7 "
_tool_sel=" ${_tool_sel} "

# ── Tool 1: tmux ──────────────────────────────────────────────────────────────
if [[ " ${_tool_sel} " == *" 1 "* ]]; then
    spin_start "Installing tmux…"
    sudo apt-get install -y -qq tmux >/dev/null 2>&1 || warn "tmux install failed"
    spin_stop $?
fi

# ── Tool 2: CLI tools ─────────────────────────────────────────────────────────
if [[ " ${_tool_sel} " == *" 2 "* ]]; then
    spin_start "Installing CLI tools (bat, fzf, ripgrep, btop, ncdu, jq, micro)…"
    sudo apt-get install -y -qq bat fzf ripgrep btop ncdu jq >/dev/null 2>&1 || warn "Some CLI tools failed"
    # eza (newer ls replacement)
    if ! command -v eza &>/dev/null; then
        wget -q "https://github.com/eza-community/eza/releases/latest/download/eza_x86_64-unknown-linux-gnu.tar.gz" \
            -O /tmp/eza.tar.gz 2>/dev/null \
            && tar xzf /tmp/eza.tar.gz -C /tmp/ 2>/dev/null \
            && mv /tmp/eza "${BIN_DIR}/eza" 2>/dev/null \
            && chmod +x "${BIN_DIR}/eza" \
            || warn "eza install failed"
    fi
    # micro editor
    if ! command -v micro &>/dev/null; then
        curl -fsSL https://getmic.ro | bash 2>/dev/null \
            && mv micro "${BIN_DIR}/micro" 2>/dev/null \
            || sudo apt-get install -y -qq micro >/dev/null 2>&1 \
            || warn "micro install failed"
    fi
    spin_stop $?
fi

# ── Tool 3: nvtop ─────────────────────────────────────────────────────────────
if [[ " ${_tool_sel} " == *" 3 "* ]]; then
    if (( HAS_GPU )); then
        spin_start "Installing nvtop…"
        sudo apt-get install -y -qq nvtop >/dev/null 2>&1 || warn "nvtop install failed"
        spin_stop $?
    else
        warn "No GPU detected — skipping nvtop."
    fi
fi

# ── Tool 4: GUI tools ─────────────────────────────────────────────────────────
if [[ " ${_tool_sel} " == *" 4 "* ]]; then
    if [[ -n "${DISPLAY:-}" ]]; then
        spin_start "Installing GUI tools (Thunar, Mousepad, Meld)…"
        sudo apt-get install -y -qq thunar mousepad meld >/dev/null 2>&1 || warn "Some GUI tools failed"
        spin_stop $?
    else
        warn "No DISPLAY set — skipping GUI tools."
    fi
fi

# ── Tool 5: neofetch ─────────────────────────────────────────────────────────
if [[ " ${_tool_sel} " == *" 5 "* ]]; then
    spin_start "Installing neofetch + fastfetch…"
    sudo apt-get install -y -qq neofetch >/dev/null 2>&1 || warn "neofetch failed"
    command -v fastfetch &>/dev/null || \
        sudo apt-get install -y -qq fastfetch >/dev/null 2>&1 || true
    spin_stop $?
fi

# ── Tool 6: Claude Code ───────────────────────────────────────────────────────
if [[ " ${_tool_sel} " == *" 6 "* ]]; then
    if command -v node &>/dev/null && _ver_ge "$(node --version | grep -oP '[0-9]+' | head -1).0.0" "18.0.0"; then
        spin_start "Installing Claude Code (npm)…"
        npm install -g @anthropic-ai/claude-code --quiet 2>/dev/null || warn "Claude Code install failed"
        spin_stop $?
        info "Claude Code installed. Set ANTHROPIC_API_KEY to use."
    else
        warn "Node.js ≥18 required for Claude Code."
        info "Install Node.js 18+ then run: npm install -g @anthropic-ai/claude-code"
    fi
fi

# ── Tool 7: OpenAI Codex ─────────────────────────────────────────────────────
if [[ " ${_tool_sel} " == *" 7 "* ]]; then
    if command -v node &>/dev/null && _ver_ge "$(node --version | grep -oP '[0-9]+' | head -1).0.0" "22.0.0"; then
        spin_start "Installing OpenAI Codex CLI…"
        npm install -g @openai/codex --quiet 2>/dev/null || warn "codex install failed"
        spin_stop $?
        info "OpenAI Codex installed. Set OPENAI_API_KEY to use."
    else
        warn "Node.js ≥22 required for OpenAI Codex."
        info "Install Node.js 22+ then run: npm install -g @openai/codex"
    fi
fi

info "Optional tools step complete."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 15 — AUTONOMOUS COWORKING (Open Interpreter + Aider)
# ═══════════════════════════════════════════════════════════════════════════════
step "Autonomous coworking (Open Interpreter + Aider)"

# ── Open Interpreter ──────────────────────────────────────────────────────────
info "Setting up Open Interpreter (cowork)…"

# ALWAYS rebuild from scratch to avoid pkg_resources corruption
[[ -d "$OI_VENV" ]] && rm -rf "$OI_VENV"
"$PYTHON3" -m venv "$OI_VENV" 2>&1 | tail -2 \
    || error "Cannot create OI venv at $OI_VENV"

spin_start "Installing Open Interpreter…"
"$OI_VENV/bin/python3" -m pip install --upgrade pip setuptools wheel --quiet 2>/dev/null
"$OI_VENV/bin/python3" -m pip install --upgrade "setuptools>=70" --no-cache-dir --quiet 2>/dev/null
# Verify pkg_resources before proceeding
"$OI_VENV/bin/python3" -c "import pkg_resources" 2>/dev/null \
    || { "$OI_VENV/bin/python3" -m pip install --force-reinstall setuptools --no-cache-dir --quiet 2>/dev/null; }
"$OI_VENV/bin/python3" -m pip install open-interpreter --quiet 2>/dev/null \
    || warn "Open Interpreter install had warnings"
spin_stop $?

# Launcher — uses single-quotes to avoid variable expansion during setup
cat > "${BIN_DIR}/cowork" <<'SCRIPT_EOF'
#!/usr/bin/env bash
# cowork — Open Interpreter backed by local Ollama
OI_VENV="$HOME/.local/share/open-interpreter-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"
OLLAMA_TAG="qwen3:14b"
[[ -f "$CONFIG" ]] && { _t=$(grep ^OLLAMA_TAG= "$CONFIG" | cut -d'"' -f2); [[ -n "$_t" ]] && OLLAMA_TAG="$_t"; }

# Auto-rebuild venv if broken
if [[ ! -x "$OI_VENV/bin/python3" ]]; then
    echo "  ⚠  open-interpreter-venv missing — rebuilding…"
    _py=$(command -v python3.12 || command -v python3.11 || command -v python3)
    "$_py" -m venv "$OI_VENV" || { echo "ERROR: cannot create venv"; exit 1; }
    "$OI_VENV/bin/python3" -m pip install --upgrade pip "setuptools>=70" open-interpreter --quiet 2>/dev/null \
        || echo "  ⚠  open-interpreter install failed"
fi

_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
_ollama_up || { nohup ollama serve >/dev/null 2>&1 & sleep 3; }

export OPENAI_API_KEY="local"
export OPENAI_API_BASE="http://127.0.0.1:11434/v1"

source "$OI_VENV/bin/activate"
exec interpreter --model "openai/$OLLAMA_TAG" "$@"
SCRIPT_EOF
chmod +x "${BIN_DIR}/cowork"

# ── Aider ─────────────────────────────────────────────────────────────────────
info "Setting up Aider…"
_ensure_venv "$AI_VENV"
spin_start "Installing Aider…"
"$AI_VENV/bin/python3" -m pip install aider-chat --quiet 2>/dev/null \
    || warn "Aider install had warnings"
spin_stop $?

cat > "${BIN_DIR}/aider" <<'SCRIPT_EOF'
#!/usr/bin/env bash
AI_VENV="$HOME/.local/share/aider-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"
OLLAMA_TAG="qwen3:14b"
[[ -f "$CONFIG" ]] && { _t=$(grep ^OLLAMA_TAG= "$CONFIG" | cut -d'"' -f2); [[ -n "$_t" ]] && OLLAMA_TAG="$_t"; }

# Auto-rebuild venv if broken
if [[ ! -x "$AI_VENV/bin/python3" ]]; then
    echo "  ⚠  aider-venv missing — rebuilding…"
    _py=$(command -v python3.12 || command -v python3.11 || command -v python3)
    "$_py" -m venv "$AI_VENV" || { echo "ERROR: cannot create venv"; exit 1; }
    "$AI_VENV/bin/python3" -m pip install --upgrade pip aider-chat --quiet 2>/dev/null \
        || echo "  ⚠  aider install failed"
fi

_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
_ollama_up || { nohup ollama serve >/dev/null 2>&1 & sleep 3; }

source "$AI_VENV/bin/activate"
exec aider \
    --model "ollama/$OLLAMA_TAG" \
    --no-fancy-input \
    --no-show-release-notes \
    --no-check-update \
    "$@"
SCRIPT_EOF
chmod +x "${BIN_DIR}/aider"

info "Coworking tools installed."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 16 — LLM-CHECKER
# ═══════════════════════════════════════════════════════════════════════════════
step "llm-checker (diagnostics dashboard)"

cat > "${BIN_DIR}/llm-checker" <<'SCRIPT_EOF'
#!/usr/bin/env bash
C='\033[0;36m'; Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'; B='\033[1m'
M='\033[38;5;240m'; A='\033[38;5;39m'; A2='\033[38;5;82m'; W='\033[38;5;214m'
_TW=$(( $(tput cols 2>/dev/null || echo 80) < 110 ? $(tput cols 2>/dev/null || echo 80) : 110 ))
_rule() { printf "${M}%*s${N}\n" "$_TW" "" | tr ' ' "${1:-─}"; }
CONFIG="$HOME/.config/local-llm/selected_model.conf"
[[ -f "$CONFIG" ]] && source "$CONFIG"

clear
echo ""
_rule "═"
echo -e "${B}${A}  LOCAL LLM — DIAGNOSTICS DASHBOARD${N}"
_rule "═"
echo ""

# Hardware
echo -e "  ${B}Hardware${N}"
printf "  ${C}%-20s${N}  %s\n" "CPU" "$(grep '^model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ *//' || echo unknown)"
printf "  ${C}%-20s${N}  %s\n" "RAM" "$(awk '/MemTotal/{printf "%d GB total",int($2/1024/1024)}' /proc/meminfo 2>/dev/null) / $(awk '/MemAvailable/{printf "%d GB avail",int($2/1024/1024)}' /proc/meminfo 2>/dev/null)"
if command -v nvidia-smi &>/dev/null; then
    _gpu=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    printf "  ${C}%-20s${N}  %s\n" "GPU (NVIDIA)" "$_gpu"
    printf "  ${C}%-20s${N}  %s\n" "CUDA driver" "$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9.]+' | head -1 || echo unknown)"
elif command -v rocminfo &>/dev/null; then
    printf "  ${C}%-20s${N}  %s\n" "GPU (AMD)" "$(rocminfo 2>/dev/null | grep 'Marketing Name' | head -1 | cut -d: -f2 | sed 's/^ *//' || echo AMD GPU)"
else
    printf "  ${C}%-20s${N}  %s\n" "GPU" "None detected"
fi
echo ""

# Services
echo -e "  ${B}Services${N}"
if curl -sf --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    printf "  ${A2}✓${N}  %-20s  %s\n" "Ollama" "running on :11434"
    _loaded=$(curl -sf http://127.0.0.1:11434/api/tags 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('models',[]))); [print('      '+m['name']) for m in d.get('models',[])]" 2>/dev/null || echo "?")
else
    printf "  ${W}○${N}  %-20s  %s\n" "Ollama" "stopped"
fi

if curl -sf --max-time 2 http://127.0.0.1:8080 >/dev/null 2>&1; then
    printf "  ${A2}✓${N}  %-20s  %s\n" "Open WebUI" "running on :8080"
else
    printf "  ${W}○${N}  %-20s  %s\n" "Open WebUI" "stopped"
fi

if curl -sf --max-time 2 http://127.0.0.1:8090 >/dev/null 2>&1; then
    printf "  ${A2}✓${N}  %-20s  %s\n" "Neural Terminal" "running on :8090"
else
    printf "  ${W}○${N}  %-20s  %s\n" "Neural Terminal" "stopped"
fi
echo ""

# Active model
echo -e "  ${B}Active Model${N}"
printf "  ${C}%-20s${N}  %s\n" "Name"       "${MODEL_NAME:-not set}"
printf "  ${C}%-20s${N}  %s\n" "Ollama tag" "${OLLAMA_TAG:-not set}"
printf "  ${C}%-20s${N}  %s\n" "GPU layers" "${GPU_LAYERS:-?}"
printf "  ${C}%-20s${N}  %s\n" "Batch size" "${BATCH_SIZE:-?}"
printf "  ${C}%-20s${N}  %s\n" "HW threads" "${HW_THREADS:-?}"
echo ""

# GGUF files
echo -e "  ${B}Downloaded GGUFs${N}"
_gdir="${GGUF_MODELS:-$HOME/local-llm-models/gguf}"
if ls "$_gdir"/*.gguf 2>/dev/null | head -1 &>/dev/null; then
    ls -lh "$_gdir"/*.gguf 2>/dev/null | awk '{printf "  %-55s  %s\n", $NF, $5}'
else
    echo -e "  ${M}(none)${N}"
fi
echo ""

# Installed tools
echo -e "  ${B}Tools${N}"
for _t in ollama wget curl python3 git node; do
    command -v "$_t" &>/dev/null \
        && printf "  ${A2}✓${N}  %-16s  %s\n" "$_t" "$(command -v $_t)" \
        || printf "  ${W}✗${N}  %-16s  %s\n" "$_t" "not found"
done
echo ""

# Python venvs
echo -e "  ${B}Python venvs${N}"
for _v in "$HOME/.local/share/llm-venv" \
          "$HOME/.local/share/open-webui-venv" \
          "$HOME/.local/share/open-interpreter-venv" \
          "$HOME/.local/share/aider-venv"; do
    [[ -d "$_v" ]] \
        && printf "  ${A2}✓${N}  %s\n" "$(basename $_v)" \
        || printf "  ${W}○${N}  ${M}%s (not installed)${N}\n" "$(basename $_v)"
done
echo ""
_rule "─"
echo -e "  ${M}Run: llm-help for command reference  |  webui to start Open WebUI${N}"
_rule "─"
echo ""
SCRIPT_EOF
chmod +x "${BIN_DIR}/llm-checker"

info "llm-checker installed."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 17 — LLM-HELP
# ═══════════════════════════════════════════════════════════════════════════════
step "llm-help (command reference)"

cat > "${BIN_DIR}/llm-help" <<'SCRIPT_EOF'
#!/usr/bin/env bash
_C='\033[0;36m'; _Y='\033[1;33m'; _G='\033[0;32m'; _N='\033[0m'; _B='\033[1m'
_M='\033[38;5;240m'; _A='\033[38;5;39m'; _R='\033[38;5;214m'
_TW=$(( $(tput cols 2>/dev/null || echo 80) < 100 ? $(tput cols 2>/dev/null || echo 80) : 100 ))
_rule() { printf "${_M}%*s${_N}\n" "$_TW" "" | tr ' ' "─"; }

clear
echo ""
_rule
echo -e "${_B}${_A}  LOCAL LLM — COMMAND REFERENCE${_N}"
_rule
echo ""

echo -e "  ${_C}── Chat interfaces ──────────────────────────────────────────────${_N}"
printf "  ${_Y}%-16s${_N}  %s\n" "webui"    "Open WebUI   http://localhost:8080  (primary)"
printf "  ${_Y}%-16s${_N}  %s\n" "chat"     "Neural Terminal   http://localhost:8090"
echo ""

echo -e "  ${_C}── CLI inference ─────────────────────────────────────────────────${_N}"
printf "  ${_Y}%-16s${_N}  %s\n" "run-model / ask"  "Direct llama.cpp inference"
printf "  ${_Y}%-16s${_N}  %s\n" "gguf-run"         "Direct llama.cpp inference (alias)"
printf "  ${_Y}%-16s${_N}  %s\n" "ollama-run"       "Ollama CLI inference"
printf "  ${_Y}%-16s${_N}  %s\n" "ollama-start"     "Start the Ollama backend"
echo ""

echo -e "  ${_C}── Model management ──────────────────────────────────────────────${_N}"
printf "  ${_Y}%-16s${_N}  %s\n" "llm-add"      "Download additional models from catalog"
printf "  ${_Y}%-16s${_N}  %s\n" "llm-switch"   "Change the active model"
printf "  ${_Y}%-16s${_N}  %s\n" "llm-status"   "Show loaded models and GGUF files"
printf "  ${_Y}%-16s${_N}  %s\n" "llm-checker"  "Live hardware + model diagnostics"
printf "  ${_Y}%-16s${_N}  %s\n" "gguf-list"    "List downloaded GGUF files"
printf "  ${_Y}%-16s${_N}  %s\n" "ollama-list"  "List Ollama models"
echo ""

echo -e "  ${_C}── Service control ───────────────────────────────────────────────${_N}"
printf "  ${_Y}%-16s${_N}  %s\n" "llm-stop"    "Stop Ollama + WebUI"
printf "  ${_Y}%-16s${_N}  %s\n" "llm-update"  "Upgrade Ollama + Open WebUI + re-pull model"
echo ""

echo -e "  ${_C}── Info & diagnostics ────────────────────────────────────────────${_N}"
printf "  ${_Y}%-16s${_N}  %s\n" "llm-show-config"  "All paths, model config, service status"
printf "  ${_Y}%-16s${_N}  %s\n" "llm-help"         "This screen"
echo ""

echo -e "  ${_C}── AI coding  ${_G}(local — no API key needed)${_N} ──────────────────────${_N}"
printf "  ${_Y}%-16s${_N}  %s\n" "cowork"     "Open Interpreter — autonomous AI (local model)"
printf "  ${_Y}%-16s${_N}  %s\n" "ai / aider" "Aider pair programmer — git-integrated"
printf "  ${_Y}%-16s${_N}  %s\n" "run-model"  "Direct terminal chat with active local model"
echo ""

echo -e "  ${_C}── AI coding  ${_M}(cloud — optional installs via setup)${_N} ──────────────${_N}"
printf "  ${_M}%-16s${_N}  %s\n" "claude"       "Claude Code  (ANTHROPIC_API_KEY required)"
printf "  ${_M}%-16s${_N}  %s\n" "codex-agent"  "OpenAI Codex (OPENAI_API_KEY required)"
echo ""

echo -e "  ${_C}── WSL2 quickstart ───────────────────────────────────────────────${_N}"
echo -e "  ${_M}  Run webui — it starts Ollama automatically${_N}"
echo ""
_rule
echo ""
SCRIPT_EOF
chmod +x "${BIN_DIR}/llm-help"

info "llm-help installed."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 18 — ALIASES + SELF-INSTALL
# ═══════════════════════════════════════════════════════════════════════════════
step "Aliases + self-install"

# Write alias file
cat > "$ALIAS_FILE" <<EOF
# ── llm-auto-setup aliases ────────────────────────────────────────────────────
alias llm-setup='bash "${SCRIPT_INSTALL_PATH}"'
alias webui='${BIN_DIR}/llm-webui'
alias chat='${BIN_DIR}/llm-chat'
alias run-model='${BIN_DIR}/run-gguf'
alias ask='${BIN_DIR}/run-gguf'
alias gguf-run='${BIN_DIR}/run-gguf'
alias gguf-list='ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null || echo "(no GGUF files)"'
alias ollama-run='ollama run'
alias ollama-pull='ollama pull'
alias ollama-list='ollama list'
alias ollama-start='${BIN_DIR}/ollama-start'
alias llm-status='${BIN_DIR}/local-models-info'
alias llm-stop='${BIN_DIR}/llm-stop'
alias llm-update='${BIN_DIR}/llm-update'
alias llm-switch='${BIN_DIR}/llm-switch'
alias llm-add='${BIN_DIR}/llm-add'
alias llm-checker='${BIN_DIR}/llm-checker'
alias llm-help='${BIN_DIR}/llm-help'
alias llm-show-config='${BIN_DIR}/llm-show-config'
alias ai='${BIN_DIR}/aider'
alias aider='${BIN_DIR}/aider'
alias cowork='${BIN_DIR}/cowork'
EOF

# Source alias file from .bashrc idempotently
if ! grep -q "# llm-auto-setup aliases" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<EOF

# llm-auto-setup aliases
[[ -f "$ALIAS_FILE" ]] && source "$ALIAS_FILE"
EOF
fi

# WSL2 welcome (login shell, run once per session)
if is_wsl2; then
    if ! grep -q "# WSL2 welcome — llm-auto-setup" "$HOME/.bash_profile" 2>/dev/null; then
        cat >> "$HOME/.bash_profile" <<'EOF'

# WSL2 welcome — llm-auto-setup
if grep -qi microsoft /proc/version 2>/dev/null; then
    source "$HOME/.bashrc" 2>/dev/null || true
    [[ -x "$HOME/.local/bin/llm-help" ]] && "$HOME/.local/bin/llm-help"
fi
EOF
    fi
fi

# Self-install
mkdir -p "$CONFIG_DIR"
cp "$0" "$SCRIPT_INSTALL_PATH"
chmod +x "$SCRIPT_INSTALL_PATH"
info "Script installed to $SCRIPT_INSTALL_PATH"
info "Aliases written to $ALIAS_FILE"

# Source aliases now
# shellcheck disable=SC1090
source "$ALIAS_FILE" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 19 — FINAL CHECKS
# ═══════════════════════════════════════════════════════════════════════════════
step "Final checks"

PASS=0; WARN_COUNT=0
_check() {
    local label="$1" ok="$2" detail="${3:-}"
    if (( ok )); then
        printf "  ${ACCENT2}✓${NC}  %-34s ${MUTED}%s${NC}\n" "$label" "$detail"
        (( PASS++ ))
    else
        printf "  ${WARN_COL}✗${NC}  %-34s ${WARN_COL}%s${NC}\n" "$label" "${detail:-not found}"
        (( WARN_COUNT++ ))
    fi
}

# 1. Ollama binary
command -v ollama &>/dev/null && _c1=1 || _c1=0
_check "Ollama binary" $_c1 "$(command -v ollama 2>/dev/null || echo '')"

# 2. Ollama service responding
ollama_running && _c2=1 || _c2=0
_check "Ollama service responding" $_c2 "http://127.0.0.1:11434"

# 3. llama-cpp-python importable
"$VENV_DIR/bin/python3" -c "from llama_cpp import Llama" 2>/dev/null && _c3=1 || _c3=0
_check "llama-cpp-python importable" $_c3 "$VENV_DIR"

# 4. Open WebUI venv + version
[[ -d "$OWUI_VENV" ]] && _owui_ver=$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | grep ^Version | cut -d' ' -f2 || echo "?") && _c4=1 || { _c4=0; _owui_ver="not installed"; }
_check "Open WebUI venv" $_c4 "v${_owui_ver}"

# 5. GGUF model file exists
[[ -f "$GGUF_MODELS/${M[file]}" ]] && _c5=1 || _c5=0
_check "GGUF model file on disk" $_c5 "${M[file]}"

# 6. Ollama tag registered
_c6=0
if ollama_running; then
    ollama list 2>/dev/null | grep -q "$OLLAMA_TAG" && _c6=1
fi
_check "Ollama tag registered" $_c6 "$OLLAMA_TAG"

# 7. cowork launcher executable
[[ -x "$BIN_DIR/cowork" ]] && _c7=1 || _c7=0
_check "cowork launcher executable" $_c7 "$BIN_DIR/cowork"

# 8. aider launcher executable
[[ -x "$BIN_DIR/aider" ]] && _c8=1 || _c8=0
_check "aider launcher executable" $_c8 "$BIN_DIR/aider"

# 9. Open Interpreter pkg_resources health
"$OI_VENV/bin/python3" -c "import pkg_resources" 2>/dev/null && _c9=1 || _c9=0
_check "Open Interpreter pkg_resources" $_c9 "$OI_VENV"

# 10. Neural Terminal HTML exists
[[ -f "$GUI_DIR/index.html" ]] && _c10=1 || _c10=0
_check "Neural Terminal HTML" $_c10 "$GUI_DIR/index.html"

# 11. Alias file exists
[[ -f "$ALIAS_FILE" ]] && _c11=1 || _c11=0
_check "Alias file" $_c11 "$ALIAS_FILE"

# 12. Script self-installed
[[ -f "$SCRIPT_INSTALL_PATH" ]] && _c12=1 || _c12=0
_check "Script self-installed" $_c12 "$SCRIPT_INSTALL_PATH"

echo ""
printf "  ${BOLD}%-20s${NC}  ${ACCENT2}%s passed${NC}  ${WARN_COL}%s warnings${NC}\n" \
    "Results:" "$PASS" "$WARN_COUNT"

# ═══════════════════════════════════════════════════════════════════════════════
# COMPLETION SCREEN
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
_rule "═"
echo -e "${ACCENT2}${BOLD}"
echo "  ██████╗  ██████╗ ███╗   ██╗███████╗"
echo "  ██╔══██╗██╔═══██╗████╗  ██║██╔════╝"
echo "  ██║  ██║██║   ██║██╔██╗ ██║█████╗  "
echo "  ██║  ██║██║   ██║██║╚██╗██║██╔══╝  "
echo "  ██████╔╝╚██████╔╝██║ ╚████║███████╗"
echo "  ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Installation complete!  Local LLM stack is ready.${NC}"
_rule "═"
echo ""
echo -e "  ${BOLD}Hardware${NC}"
printf "  ${CYAN}%-12s${NC}  %s\n"  "CPU"  "$CPU_MODEL"
printf "  ${CYAN}%-12s${NC}  %s GB\n"  "RAM"  "$TOTAL_RAM_GB"
if (( HAS_NVIDIA )); then
    printf "  ${CYAN}%-12s${NC}  %s  (%s GB VRAM)  [CUDA]\n"  "GPU"  "$GPU_NAME"  "$GPU_VRAM_GB"
elif (( HAS_AMD_GPU )); then
    printf "  ${CYAN}%-12s${NC}  %s  (%s GB VRAM)  [ROCm]\n"  "GPU"  "$GPU_NAME"  "$GPU_VRAM_GB"
else
    printf "  ${CYAN}%-12s${NC}  CPU-only inference\n"  "GPU"
fi
echo ""
echo -e "  ${BOLD}Model${NC}"
printf "  ${CYAN}%-12s${NC}  %s\n"  "Selected"    "${M[name]}"
printf "  ${CYAN}%-12s${NC}  %s\n"  "Ollama tag"  "$OLLAMA_TAG"
printf "  ${CYAN}%-12s${NC}  GPU: %s  CPU: %s  Batch: %s\n"  "Layers"  "$GPU_LAYERS"  "$CPU_LAYERS"  "$BATCH"
echo ""
echo -e "  ${BOLD}Next step — reload your shell${NC}"
echo ""
echo -e "      ${ACCENT}exec bash${NC}"
echo ""
echo -e "    ${MUTED}Aliases become active. Same window. Same directory.${NC}"
echo ""
_rule "─"
printf "  ${ACCENT2}%-16s${NC}  %s\n"  "webui"      "→  Open WebUI  http://localhost:8080  ← start here"
printf "  ${ACCENT2}%-16s${NC}  %s\n"  "cowork"     "→  Autonomous AI coder"
printf "  ${ACCENT2}%-16s${NC}  %s\n"  "llm-help"   "→  All commands"
_rule "─"
echo ""

# Final llm-help call
[[ -x "$BIN_DIR/llm-help" ]] && "$BIN_DIR/llm-help" || true