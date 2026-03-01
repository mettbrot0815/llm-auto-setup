#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  ██╗      ██████╗  ██████╗ █████╗ ██╗         ██╗     ██╗     ███╗   ███╗
#  ██║     ██╔═══██╗██╔════╝██╔══██╗██║        ██╔╝     ██║     ████╗ ████║
#  ██║     ██║   ██║██║     ███████║██║       ██╔╝      ██║     ██╔████╔██║
#  ██║     ██║   ██║██║     ██╔══██║██║      ██╔╝       ██║     ██║╚██╔╝██║
#  ███████╗╚██████╔╝╚██████╗██║  ██║███████╗██╔╝        ███████╗██║ ╚═╝ ██║
#  ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝         ╚══════╝╚═╝     ╚═╝
# ──────────────────────────────────────────────────────────────────────────────
# llm-auto-setup.sh v4.0.0 — Complete local LLM stack installer
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# Constants & Paths
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

# Suppress apt interactive prompts — set before any apt calls
export DEBIAN_FRONTEND=noninteractive
export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1
export PIP_CACHE_DIR="$PKG_CACHE_DIR/pip"
export npm_config_cache="$PKG_CACHE_DIR/npm"

# Package cache setup
mkdir -p "$PKG_CACHE_DIR/pip" "$PKG_CACHE_DIR/npm"

# Logging setup — tee all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Color palette
if [[ -t 1 ]]; then
    RED='\033[0;31m';    GREEN='\033[0;32m';   YELLOW='\033[1;33m'
    BLUE='\033[0;34m';   CYAN='\033[0;36m';    MAGENTA='\033[0;35m'
    BOLD='\033[1m';      DIM='\033[2m';         NC='\033[0m'
    ACCENT='\033[38;5;39m'     # bright sky-blue   — primary highlight
    ACCENT2='\033[38;5;82m'    # bright green       — success / ok
    MUTED='\033[38;5;240m'     # mid-grey           — secondary text
    WARN_COL='\033[38;5;214m'  # amber              — warnings
    ERR_COL='\033[38;5;196m'   # red                — errors
    STEP_COL='\033[38;5;105m'  # purple             — step headers
else
    # No colors when piped to a file
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
    ACCENT=''; ACCENT2=''; MUTED=''; WARN_COL=''; ERR_COL=''; STEP_COL=''
fi

_TW=$(( $(tput cols 2>/dev/null || echo 80) ))
(( _TW < 60  )) && _TW=60
(( _TW > 120 )) && _TW=120
_rule() { local ch="${1:-─}" col="${2:-$MUTED}"; printf "${col}%*s${NC}\n" "$_TW" "" | tr ' ' "$ch"; }

# Core print functions
_STEP_N=0
_STEP_TOTAL=19

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

# Spinner for silent long-running operations
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

# Utility functions
retry() {
    local n="$1" delay="$2"; shift 2
    for ((i=1; i<=n; i++)); do
        "$@" && return 0 || { (( i < n )) && sleep "$delay"; }
    done
    return 1
}
is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }
get_distro_id() { grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown"; }
get_distro_codename() { grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown"; }
ollama_running() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
wait_for_ollama() {
    local _i=0
    while (( _i < 30 )) && ! ollama_running; do
        sleep 1; (( _i++ ))
    done
    ollama_running
}
start_ollama_if_needed() {
    ollama_running && return 0
    if is_wsl2; then
        nohup "$BIN_DIR/ollama-start" >/dev/null 2>&1 &
    else
        sudo systemctl start ollama.service >/dev/null 2>&1 || ollama serve >/dev/null 2>&1 &
    fi
    wait_for_ollama || warn "Ollama start timeout — check logs"
}
_ver_gt() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]; }
_ver_ge() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }

# Welcome banner
welcome_banner() {
    clear
    echo -e "${ACCENT}${BOLD}"
    cat << 'EOF'
  ██╗      ██████╗  ██████╗ █████╗ ██╗         ██╗     ██╗     ███╗   ███╗
  ██║     ██╔═══██╗██╔════╝██╔══██╗██║        ██╔╝     ██║     ████╗ ████║
  ██║     ██║   ██║██║     ███████║██║       ██╔╝      ██║     ██╔████╔██║
  ██║     ██║   ██║██║     ██╔══██║██║      ██╔╝       ██║     ██║╚██╔╝██║
  ███████╗╚██████╔╝╚██████╗██║  ██║███████╗██╔╝        ███████╗██║ ╚═╝ ██║
  ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝         ╚══════╝╚═╝     ╚═╝
EOF
    echo -e "${NC}"
    _rule "─" "${MUTED}"
    echo -e "${BOLD}  Local LLM Auto-Setup v${SCRIPT_VERSION}${NC}"
    echo -e "  Zero-cloud LLM stack for Ubuntu/Debian/WSL2"
    _rule "─" "${MUTED}"
    echo -e "\n  ${ACCENT}Installs:${NC}"
    echo -e "    • Ollama + llama-cpp-python"
    echo -e "    • Open WebUI + Neural Terminal"
    echo -e "    • Open Interpreter + Aider"
    echo -e "    • Diagnostics + helpers"
    echo -e "\n  ${MUTED}Log: $LOG_FILE${NC}"
    _rule "─" "${MUTED}"
}

# Call welcome banner
welcome_banner

# STEP 1 Pre-flight checks
step "Pre-flight checks"
[[ $EUID -eq 0 ]] && error "Run as regular user, not root"
command -v sudo >/dev/null 2>&1 || error "sudo required"
_arch=$(uname -m)
[[ "$_arch" != "x86_64" ]] && [[ "$_arch" != "aarch64" ]] && warn "Unsupported arch: $_arch — may fail"
[[ "$_arch" == "aarch64" ]] && warn "ARM detected — limited support"
_distro_id=$(get_distro_id)
_distro_code=$(get_distro_codename)
case "$_distro_id" in
    ubuntu|debian|linuxmint|pop|kali|parrot) info "Supported distro: $_distro_id ($_distro_code)";;
    *) warn "Untested distro: $_distro_id — may fail";;
esac
highlight "Administrator access required"
echo -e "  apt · systemd · GPU drivers"
sudo -v || error "sudo failed"
( while true; do sleep 50; sudo -v 2>/dev/null; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT INT TERM
if [[ -f "$SCRIPT_INSTALL_PATH" ]]; then
    _inst_ver=$(grep '^SCRIPT_VERSION=' "$SCRIPT_INSTALL_PATH" | cut -d'"' -f2 || echo "0.0.0")
    if _ver_gt "$SCRIPT_VERSION" "$_inst_ver"; then
        if ask_yes_no "Update script: $_inst_ver → $SCRIPT_VERSION?"; then
            cp -f "$0" "$SCRIPT_INSTALL_PATH"
            exec bash "$SCRIPT_INSTALL_PATH" "$@"
        fi
    fi
fi

# STEP 2 Hardware detection
step "Hardware detection"
CPU_MODEL=$(lscpu 2>/dev/null | grep 'Model name:' | awk -F: '{print $2}' | sed 's/^\s*//; s/\s\+/ /g' || echo "Unknown")
CPU_THREADS=$(nproc --all 2>/dev/null || echo 0)
HW_THREADS=$(( CPU_THREADS < 16 ? CPU_THREADS : 16 ))
TOTAL_RAM_GB=$(( $(free -m 2>/dev/null | awk '/^Mem:/{print $2}') / 1024 )) || TOTAL_RAM_GB=0
AVAIL_RAM_GB=$(( $(free -m 2>/dev/null | awk '/^Mem:/{print $7}') / 1024 )) || AVAIL_RAM_GB=0
HAS_GPU=0; HAS_NVIDIA=0; HAS_AMD_GPU=0; HAS_INTEL_GPU=0; GPU_NAME=""; GPU_VRAM_GB=0; GPU_VRAM_MIB=0; DRIVER_VER=""; CUDA_VER_SMI=""
DISK_FREE_GB=$(( $(df -k "$HOME" 2>/dev/null | awk 'NR>1{print $4/1024/1024}' | cut -d. -f1) )) || DISK_FREE_GB=0
if command -v nvidia-smi >/dev/null 2>&1; then
    HAS_GPU=1; HAS_NVIDIA=1
    _gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | sort -k2 -nr | head -1 || echo "")
    GPU_NAME=$(echo "$_gpu_info" | cut -d, -f1 | sed 's/^\s*//')
    GPU_VRAM_MIB=$(echo "$_gpu_info" | cut -d, -f2 | tr -d ' MiB' || echo 0)
    GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown")
    CUDA_VER_SMI=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' || echo "")
elif command -v rocminfo >/dev/null 2>&1; then
    HAS_GPU=1; HAS_AMD_GPU=1
    GPU_NAME=$(rocminfo 2>/dev/null | grep 'Name:' | awk '{print $2}' | head -1 || echo "AMD GPU")
    GPU_VRAM_MIB=$(rocminfo 2>/dev/null | grep -oP 'vram_size_bytes: \K[0-9]+' | head -1 || echo 0)
    (( GPU_VRAM_MIB /= 1024 * 1024 ))  # to MiB
    GPU_VRAM_GB=$(( GPU_VRAM_MIB / 1024 ))
elif lspci | grep -iE 'Intel.*Arc|Intel.*Xe' >/dev/null 2>&1; then
    HAS_GPU=1; HAS_INTEL_GPU=1
    GPU_NAME="Intel Arc/Xe"
    GPU_VRAM_MIB=0  # WIP
    warn "Intel Arc detected — using CPU tiers (compute support WIP)"
else
    lspci | grep -i amd >/dev/null 2>&1 && HAS_AMD_GPU=1 && GPU_NAME="AMD GPU (ROCm check failed)"
fi
VRAM_HEADROOM_MIB=1400
VRAM_USABLE_MIB=$(( GPU_VRAM_MIB - VRAM_HEADROOM_MIB ))
(( VRAM_USABLE_MIB < 0 )) && VRAM_USABLE_MIB=0
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
if   (( GPU_VRAM_GB >= 24 )); then BATCH=2048
elif (( GPU_VRAM_GB >= 12 )); then BATCH=1024
elif (( GPU_VRAM_GB >=  8 )); then BATCH=512
elif (( GPU_VRAM_GB >=  4 )); then BATCH=256
else                               BATCH=128
fi
echo -e "  ${ACCENT}Hardware summary:${NC}"
printf "    %-12s %s\n" "CPU:" "$CPU_MODEL ($CPU_THREADS threads)"
printf "    %-12s %d GB total (%d GB avail)\n" "RAM:" "$TOTAL_RAM_GB" "$AVAIL_RAM_GB"
if (( HAS_GPU )); then
    printf "    %-12s %s (%d GB VRAM)\n" "GPU:" "$GPU_NAME" "$GPU_VRAM_GB"
    [[ -n "$DRIVER_VER" ]] && printf "    %-12s %s\n" "Driver:" "$DRIVER_VER"
    [[ -n "$CUDA_VER_SMI" ]] && printf "    %-12s %s\n" "CUDA:" "$CUDA_VER_SMI"
else
    printf "    %-12s %s\n" "GPU:" "None detected — CPU mode"
fi
printf "    %-12s %d GB free\n" "Disk:" "$DISK_FREE_GB"

# STEP 3 Model selection
step "Model selection"
declare -A M
_is_installed() { [[ -f "$GGUF_MODELS/$1" ]] && echo " ✔" || echo "  "; }
select_model() {
    local _tier="$1" _vram_gb="$2"
    if (( HAS_GPU )); then
        if (( _vram_gb >= 48 )); then
            M[name]="Llama-3.3-70B-Instruct"; M[quant]="Q4_K_M"; M[file]="Llama-3.3-70B-Instruct-Q4_K_M.gguf"; M[repo]="bartowski/Llama-3.3-70B-Instruct-GGUF"; M[size_gb]=40; M[layers]=80; M[caps]="★ TOOLS · THINK · flagship"; M[tier]="48GB+"
        elif (( _vram_gb >= 24 )); then
            M[name]="Qwen3-32B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-32B-GGUF"; M[size_gb]=19; M[layers]=64; M[caps]="★ TOOLS · THINK"; M[tier]="24GB+"
        elif (( _vram_gb >= 16 )); then
            M[name]="Qwen3-30B-A3B (MoE)"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-30B-A3B-GGUF"; M[size_gb]=16; M[layers]=60; M[caps]="★ TOOLS · THINK · 30B quality @ 8B speed"; M[tier]="16GB"
        elif (( _vram_gb >= 12 )); then
            M[name]="Qwen3-14B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-14B-GGUF"; M[size_gb]=9; M[layers]=28; M[caps]="★ TOOLS · THINK"; M[tier]="12GB"
        elif (( _vram_gb >= 8 )); then
            M[name]="Phi-4-14B"; M[quant]="Q4_K_M"; M[file]="phi-4-Q4_K_M.gguf"; M[repo]="bartowski/phi-4-GGUF"; M[size_gb]=9; M[layers]=28; M[caps]="★ TOOLS · top coding + math"; M[tier]="8GB"
        elif (( _vram_gb >= 6 )); then
            M[name]="Qwen3-8B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-8B-GGUF"; M[size_gb]=5; M[layers]=16; M[caps]="★ TOOLS · THINK"; M[tier]="6GB"
        elif (( _vram_gb >= 4 )); then
            M[name]="Qwen3-4B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-4B-GGUF"; M[size_gb]=3; M[layers]=8; M[caps]="★ TOOLS · THINK"; M[tier]="4GB"
        else
            M[name]="Qwen3-1.7B"; M[quant]="Q8_0"; M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"; M[repo]="bartowski/Qwen_Qwen3-1.7B-GGUF"; M[size_gb]=2; M[layers]=4; M[caps]="★ TOOLS · THINK"; M[tier]="CPU"
        fi
    else
        if (( TOTAL_RAM_GB >= 32 )); then
            M[name]="Qwen3-14B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-14B-GGUF"; M[size_gb]=9; M[layers]=28; M[caps]="★ TOOLS · THINK"; M[tier]="CPU 32GB+"
        elif (( TOTAL_RAM_GB >= 16 )); then
            M[name]="Qwen3-8B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-8B-GGUF"; M[size_gb]=5; M[layers]=16; M[caps]="★ TOOLS · THINK"; M[tier]="CPU 16GB+"
        elif (( TOTAL_RAM_GB >= 8 )); then
            M[name]="Qwen3-4B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-4B-GGUF"; M[size_gb]=3; M[layers]=8; M[caps]="★ TOOLS · THINK"; M[tier]="CPU 8GB+"
        else
            M[name]="Qwen3-1.7B"; M[quant]="Q8_0"; M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"; M[repo]="bartowski/Qwen_Qwen3-1.7B-GGUF"; M[size_gb]=2; M[layers]=4; M[caps]="★ TOOLS · THINK"; M[tier]="CPU <8GB"
        fi
    fi
    M[url]="https://huggingface.co/${M[repo]}/resolve/main/${M[file]}"
}
select_model "$GPU_VRAM_GB" "$GPU_VRAM_GB"
info "Auto-selected: ${M[name]} (${M[quant]}) — ${M[caps]}"
if ask_yes_no "Override with manual model selection?"; then
    echo -e "\n  ${ACCENT}Model catalog:${NC}"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "#" "Model" "Quant" "VRAM" " " "Capabilities"
    _rule "-" "$YELLOW"
    echo -e "  ${YELLOW}▸  CPU / No GPU needed${NC}"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "1" "Qwen3-1.7B" "Q8_0" "CPU" "$(_is_installed Qwen_Qwen3-1.7B-Q8_0.gguf)" "★ TOOLS · THINK"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "2" "Qwen3-4B" "Q4_K_M" "~3GB" "$(_is_installed Qwen_Qwen3-4B-Q4_K_M.gguf)" "★ TOOLS · THINK"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "3" "Phi-4-mini 3.8B" "Q4_K_M" "CPU" "$(_is_installed phi-4-mini-Q4_K_M.gguf)" "★ TOOLS · THINK"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "4" "Qwen3-0.6B" "Q8_0" "CPU" "$(_is_installed Qwen_Qwen3-0.6B-Q8_0.gguf)" "TOOLS · THINK · tiny"
    echo -e "  ${YELLOW}▸  6–8 GB VRAM${NC}"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "5" "Qwen3-8B" "Q4_K_M" "~5GB" "$(_is_installed Qwen_Qwen3-8B-Q4_K_M.gguf)" "★ TOOLS · THINK"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "6" "Qwen3-8B" "Q6_K" "~6GB" "$(_is_installed Qwen_Qwen3-8B-Q6_K.gguf)" "★ TOOLS · THINK · higher quality"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "7" "DeepSeek-R1-Distill-8B" "Q4_K_M" "~5GB" "$(_is_installed DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf)" "THINK · deep reasoning"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "8" "Gemma-3-9B" "Q4_K_M" "~6GB" "$(_is_installed Gemma-3-9B-Q4_K_M.gguf)" "TOOLS · Google"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "9" "Gemma-3-12B" "Q4_K_M" "~8GB" "$(_is_installed Gemma-3-12B-Q4_K_M.gguf)" "TOOLS · Google vision"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "10" "Dolphin3.0-8B" "Q4_K_M" "~5GB" "$(_is_installed Dolphin3.0-8B-Q4_K_M.gguf)" "UNCENSORED"
    echo -e "  ${YELLOW}▸  10–12 GB VRAM${NC}"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "11" "Phi-4-14B" "Q4_K_M" "~9GB" "$(_is_installed phi-4-Q4_K_M.gguf)" "★ TOOLS · top coding + math"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "12" "Qwen3-14B" "Q4_K_M" "~9GB" "$(_is_installed Qwen_Qwen3-14B-Q4_K_M.gguf)" "★ TOOLS · THINK"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "13" "DeepSeek-R1-Distill-14B" "Q4_K_M" "~9GB" "$(_is_installed DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf)" "THINK · deep reasoning"
    echo -e "  ${YELLOW}▸  16 GB VRAM${NC}"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "14" "Gemma-3-27B" "Q4_K_M" "~12GB" "$(_is_installed Gemma-3-27B-Q4_K_M.gguf)" "TOOLS · Google"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "15" "Mistral-Small-3.1-24B" "Q4_K_M" "~14GB" "$(_is_installed Mistral-Small-3.1-24B-Q4_K_M.gguf)" "TOOLS · THINK · 128K context"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "16" "Mistral-Small-3.2-24B" "Q4_K_M" "~14GB" "$(_is_installed Mistral-Small-3.2-24B-Q4_K_M.gguf)" "★ TOOLS · THINK · newest"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "17" "Qwen3-30B-A3B (MoE)" "Q4_K_M" "~16GB" "$(_is_installed Qwen_Qwen3-30B-A3B-Q4_K_M.gguf)" "★ TOOLS · THINK · 30B quality @ 8B speed"
    echo -e "  ${YELLOW}▸  24+ GB VRAM${NC}"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "18" "Qwen3-32B" "Q4_K_M" "~19GB" "$(_is_installed Qwen_Qwen3-32B-Q4_K_M.gguf)" "★ TOOLS · THINK"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "19" "DeepSeek-R1-Distill-32B" "Q4_K_M" "~19GB" "$(_is_installed DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf)" "THINK · deep reasoning"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "20" "Gemma-3-27B (Google)" "Q4_K_M" "~16GB" "$(_is_installed Gemma-3-27B-Q4_K_M.gguf)" "TOOLS · Google"
    echo -e "  ${YELLOW}▸  48 GB VRAM (multi-GPU)${NC}"
    printf "  %-2s  %-28s  %-5s  %-6s  %-2s  %s\n" "21" "Llama-3.3-70B" "Q4_K_M" "~40GB" "$(_is_installed Llama-3.3-70B-Q4_K_M.gguf)" "★ TOOLS · flagship"
    printf "\n  ${ACCENT}?${NC}  ${BOLD}Select # (Enter to skip):${NC} "
    read -r _sel
    case "$_sel" in
        1) M[name]="Qwen3-1.7B"; M[quant]="Q8_0"; M[file]="Qwen_Qwen3-1.7B-Q8_0.gguf"; M[repo]="bartowski/Qwen_Qwen3-1.7B-GGUF"; M[size_gb]=2; M[layers]=4; M[caps]="★ TOOLS · THINK" ;;
        2) M[name]="Qwen3-4B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-4B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-4B-GGUF"; M[size_gb]=3; M[layers]=8; M[caps]="★ TOOLS · THINK" ;;
        3) M[name]="Phi-4-mini 3.8B"; M[quant]="Q4_K_M"; M[file]="phi-4-mini-Q4_K_M.gguf"; M[repo]="bartowski/phi-4-mini-GGUF"; M[size_gb]=3; M[layers]=8; M[caps]="★ TOOLS · THINK" ;;
        4) M[name]="Qwen3-0.6B"; M[quant]="Q8_0"; M[file]="Qwen_Qwen3-0.6B-Q8_0.gguf"; M[repo]="bartowski/Qwen_Qwen3-0.6B-GGUF"; M[size_gb]=1; M[layers]=2; M[caps]="TOOLS · THINK · tiny" ;;
        5) M[name]="Qwen3-8B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-8B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-8B-GGUF"; M[size_gb]=5; M[layers]=16; M[caps]="★ TOOLS · THINK" ;;
        6) M[name]="Qwen3-8B"; M[quant]="Q6_K"; M[file]="Qwen_Qwen3-8B-Q6_K.gguf"; M[repo]="bartowski/Qwen_Qwen3-8B-GGUF"; M[size_gb]=6; M[layers]=16; M[caps]="★ TOOLS · THINK · higher quality" ;;
        7) M[name]="DeepSeek-R1-Distill-8B"; M[quant]="Q4_K_M"; M[file]="DeepSeek-R1-Distill-Qwen-8B-Q4_K_M.gguf"; M[repo]="bartowski/DeepSeek-R1-Distill-Qwen-8B-GGUF"; M[size_gb]=5; M[layers]=16; M[caps]="THINK · deep reasoning" ;;
        8) M[name]="Gemma-3-9B"; M[quant]="Q4_K_M"; M[file]="Gemma-3-9B-Q4_K_M.gguf"; M[repo]="bartowski/Gemma-3-9B-GGUF"; M[size_gb]=6; M[layers]=18; M[caps]="TOOLS · Google" ;;
        9) M[name]="Gemma-3-12B"; M[quant]="Q4_K_M"; M[file]="Gemma-3-12B-Q4_K_M.gguf"; M[repo]="bartowski/Gemma-3-12B-GGUF"; M[size_gb]=8; M[layers]=24; M[caps]="TOOLS · Google vision" ;;
        10) M[name]="Dolphin3.0-8B"; M[quant]="Q4_K_M"; M[file]="Dolphin3.0-8B-Q4_K_M.gguf"; M[repo]="bartowski/Dolphin3.0-8B-GGUF"; M[size_gb]=5; M[layers]=16; M[caps]="UNCENSORED" ;;
        11) M[name]="Phi-4-14B"; M[quant]="Q4_K_M"; M[file]="phi-4-Q4_K_M.gguf"; M[repo]="bartowski/phi-4-GGUF"; M[size_gb]=9; M[layers]=28; M[caps]="★ TOOLS · top coding + math" ;;
        12) M[name]="Qwen3-14B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-14B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-14B-GGUF"; M[size_gb]=9; M[layers]=28; M[caps]="★ TOOLS · THINK" ;;
        13) M[name]="DeepSeek-R1-Distill-14B"; M[quant]="Q4_K_M"; M[file]="DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"; M[repo]="bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF"; M[size_gb]=9; M[layers]=28; M[caps]="THINK · deep reasoning" ;;
        14) M[name]="Gemma-3-27B"; M[quant]="Q4_K_M"; M[file]="Gemma-3-27B-Q4_K_M.gguf"; M[repo]="bartowski/Gemma-3-27B-GGUF"; M[size_gb]=12; M[layers]=54; M[caps]="TOOLS · Google" ;;
        15) M[name]="Mistral-Small-3.1-24B"; M[quant]="Q4_K_M"; M[file]="Mistral-Small-3.1-24B-Q4_K_M.gguf"; M[repo]="bartowski/Mistral-Small-3.1-24B-GGUF"; M[size_gb]=14; M[layers]=48; M[caps]="TOOLS · THINK · 128K context" ;;
        16) M[name]="Mistral-Small-3.2-24B"; M[quant]="Q4_K_M"; M[file]="Mistral-Small-3.2-24B-Q4_K_M.gguf"; M[repo]="bartowski/Mistral-Small-3.2-24B-GGUF"; M[size_gb]=14; M[layers]=48; M[caps]="★ TOOLS · THINK · newest" ;;
        17) M[name]="Qwen3-30B-A3B (MoE)"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-30B-A3B-GGUF"; M[size_gb]=16; M[layers]=60; M[caps]="★ TOOLS · THINK · 30B quality @ 8B speed" ;;
        18) M[name]="Qwen3-32B"; M[quant]="Q4_K_M"; M[file]="Qwen_Qwen3-32B-Q4_K_M.gguf"; M[repo]="bartowski/Qwen_Qwen3-32B-GGUF"; M[size_gb]=19; M[layers]=64; M[caps]="★ TOOLS · THINK" ;;
        19) M[name]="DeepSeek-R1-Distill-32B"; M[quant]="Q4_K_M"; M[file]="DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"; M[repo]="bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF"; M[size_gb]=19; M[layers]=64; M[caps]="THINK · deep reasoning" ;;
        20) M[name]="Gemma-3-27B (Google)"; M[quant]="Q4_K_M"; M[file]="Gemma-3-27B-Q4_K_M.gguf"; M[repo]="bartowski/Gemma-3-27B-GGUF"; M[size_gb]=16; M[layers]=54; M[caps]="TOOLS · Google" ;;
        21) M[name]="Llama-3.3-70B"; M[quant]="Q4_K_M"; M[file]="Llama-3.3-70B-Q4_K_M.gguf"; M[repo]="bartowski/Llama-3.3-70B-GGUF"; M[size_gb]=40; M[layers]=80; M[caps]="★ TOOLS · flagship" ;;
        *) info "No change — keeping ${M[name]}" ;;
    esac
    [[ -n "${M[file]:-}" ]] && M[url]="https://huggingface.co/${M[repo]}/resolve/main/${M[file]}"
fi
OLLAMA_TAG=$(echo "${M[file]}" | sed 's/\.gguf$//' | tr '[:upper:]' '[:lower:]' | sed 's/_/-/g; s/[^a-z0-9:-]//g; s/--*/-/g' | cut -c1-60)
GPU_LAYERS=$(gpu_layers_for "${M[size_gb]}" "${M[layers]}")
if [[ "$GPU_LAYERS" == "-1" ]]; then
    CPU_LAYERS=0
else
    CPU_LAYERS=$(( M[layers] - GPU_LAYERS ))
    (( CPU_LAYERS < 0 )) && CPU_LAYERS=0
fi

# STEP 3b Python environment detection
step "Python environment detection"
PYTHON_BIN=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
[[ -z "$PYTHON_BIN" ]] && error "Python not found"
_py_ver=$("$PYTHON_BIN" -V 2>&1 | grep -oP '[0-9]+\.[0-9]+' || echo "0.0")
if ! _ver_ge "$_py_ver" "3.10"; then
    warn "Python $_py_ver detected — need 3.10+"
    sudo apt-get install -y -qq python3 python3-venv python3-pip || warn "Python install failed"
    PYTHON_BIN=$(command -v python3)
fi
info "Python: $PYTHON_BIN ($("$PYTHON_BIN" -V 2>&1))"

# STEP 4 System dependencies
step "System dependencies"
spin_start "Updating packages"
sudo apt-get update -y -qq >/dev/null
spin_stop $?
_pkgs_base="curl wget git zstd python3 python3-venv python3-pip python3-dev build-essential libopenblas-dev pkg-config cmake libssl-dev libclang-dev"
_pkgs_gpu=""
(( HAS_NVIDIA )) && _pkgs_gpu+=" nvidia-cuda-toolkit"  # fallback, but we install proper toolkit later
(( HAS_AMD_GPU )) && _pkgs_gpu+=" rocm-hip-sdk"
_pkgs_extra="jq micro tmux bat eza fzf ripgrep btop ncdu"
[[ -n "${DISPLAY:-}" ]] && _pkgs_extra+=" thunar mousepad meld"
(( HAS_GPU )) && _pkgs_extra+=" nvtop"
spin_start "Installing: $_pkgs_base $_pkgs_gpu $_pkgs_extra"
sudo apt-get install -y -qq $_pkgs_base $_pkgs_gpu $_pkgs_extra || warn "Some packages failed — continuing"
spin_stop $?

# STEP 5 Directories & PATH
step "Directories & PATH"
mkdir -p "$VENV_DIR" "$OWUI_VENV" "$OI_VENV" "$AI_VENV" "$MODEL_BASE" "$OLLAMA_MODELS" "$GGUF_MODELS" "$TEMP_DIR" "$BIN_DIR" "$CONFIG_DIR" "$GUI_DIR" "$WORK_DIR"
export PATH="$BIN_DIR:$PATH"
grep -q "$BIN_DIR" "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

# STEP 6 Save model config to disk
step "Save model config to disk"
cat > "$MODEL_CONFIG.tmp" << EOF
MODEL_NAME="${M[name]}"
MODEL_FILE="${M[file]}"
MODEL_URL="${M[url]}"
MODEL_CAPS="${M[caps]}"
OLLAMA_TAG="$OLLAMA_TAG"
GPU_LAYERS="$GPU_LAYERS"
CPU_LAYERS="$CPU_LAYERS"
BATCH_SIZE="$BATCH"
HW_THREADS="$HW_THREADS"
VENV_DIR="$VENV_DIR"
GGUF_MODELS="$GGUF_MODELS"
OLLAMA_MODELS="$OLLAMA_MODELS"
EOF
mv -f "$MODEL_CONFIG.tmp" "$MODEL_CONFIG"
info "Config saved: $MODEL_CONFIG"

# STEP 7 CUDA toolkit (NVIDIA only)
if (( HAS_NVIDIA )); then
    step "CUDA toolkit"
    setup_cuda_env() {
        for _p in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
            [[ -d "$_p" ]] && export PATH="$_p:$PATH"
        done
        nvcc_path=$(command -v nvcc 2>/dev/null || find /usr/local/cuda*/bin -name nvcc 2>/dev/null | head -1 || true)
        [[ -n "$nvcc_path" ]] && export PATH="$(dirname "$nvcc_path"):$PATH"
    }
    setup_cuda_env
    if ! command -v nvcc >/dev/null 2>&1; then
        spin_start "Installing CUDA toolkit"
        wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb
        sudo dpkg -i /tmp/cuda-keyring.deb
        sudo apt-get update -y -qq
        sudo apt-get install -y -qq cuda-toolkit-12-4 || warn "CUDA install failed"
        spin_stop $?
        setup_cuda_env
    fi
    _cuda_found=0
    ldconfig -p 2>/dev/null | grep -q "libcudart\.so\.12" && _cuda_found=1
    if (( !_cuda_found )); then
        _cuda_lib_path=""
        for _d in /usr/local/lib/ollama/cuda_v12 /usr/local/lib/ollama/cuda_v11 /usr/local/cuda/lib64 /usr/local/cuda-1[23]/lib64 /usr/local/cuda-1[23].*/lib64 /usr/lib/x86_64-linux-gnu; do
            [[ -f "$_d/libcudart.so.12" || -f "$_d/libcudart.so" ]] && { _cuda_lib_path="$_d"; _cuda_found=1; break; }
        done
        if [[ -n "$_cuda_lib_path" ]]; then
            echo "$_cuda_lib_path" | sudo tee /etc/ld.so.conf.d/ollama-cuda.conf >/dev/null
            sudo ldconfig
            grep -q "# ollama-cuda-ld" "$HOME/.bashrc" 2>/dev/null || printf '\n# ollama-cuda-ld\nexport LD_LIBRARY_PATH="%s:${LD_LIBRARY_PATH:-}"\n' "$_cuda_lib_path" >> "$HOME/.bashrc"
            export LD_LIBRARY_PATH="$_cuda_lib_path:${LD_LIBRARY_PATH:-}"
            info "libcudart registered via ldconfig ✔"
        else
            warn "libcudart.so.12 not found — GPU inference may fail"
        fi
    fi
fi

# STEP 7b ROCm toolkit (AMD only)
if (( HAS_AMD_GPU )); then
    step "ROCm toolkit"
    if ! command -v rocminfo >/dev/null 2>&1; then
        spin_start "Installing ROCm"
        wget https://repo.radeon.com/amdgpu-install/6.2/ubuntu/jammy/amdgpu-install_6.2.60200-1_all.deb -O /tmp/amdgpu-install.deb
        sudo dpkg -i /tmp/amdgpu-install.deb
        sudo apt-get update -y -qq
        sudo amdgpu-install -y --usecase=hip,rocm --no-dkms || warn "ROCm install failed"
        spin_stop $?
    fi
    export PATH="/opt/rocm/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH:-}"
    grep -q "# rocm-ld" "$HOME/.bashrc" || printf '\n# rocm-ld\nexport LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH:-}"\n' >> "$HOME/.bashrc"
fi

# STEP 8 Python venv
step "Python venv"
if [[ -d "$VENV_DIR" ]]; then
    info "Venv exists — upgrading"
    "$VENV_DIR/bin/python3" -m pip install --upgrade pip >/dev/null 2>&1
else
    spin_start "Creating venv"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
    spin_stop $?
fi

# STEP 9 llama-cpp-python
step "llama-cpp-python"
_llama_ver="0.2.89"  # example, use latest
_cuda_short="${CUDA_VER_SMI//./}"  # e.g., 124
if (( HAS_NVIDIA )); then
    _wheel_url="https://github.com/abetlen/llama-cpp-python/releases/download/v$_llama_ver-cu${_cuda_short}/llama_cpp_python-$_llama_ver-cp312-cp312-linux_x86_64.whl"
    spin_start "Trying pre-built wheel"
    if ! "$VENV_DIR/bin/pip" install "$_wheel_url" --quiet; then
        warn "Wheel failed — building from source"
        CMAKE_ARGS="-DLLAMA_CUDA=on" "$VENV_DIR/bin/pip" install llama-cpp-python --quiet
    fi
    spin_stop $?
elif (( HAS_AMD_GPU )); then
    CMAKE_ARGS="-DGGML_HIPBLAS=on" "$VENV_DIR/bin/pip" install llama-cpp-python --quiet
else
    "$VENV_DIR/bin/pip" install llama-cpp-python --quiet
fi
"$VENV_DIR/bin/python3" -c "from llama_cpp import Llama; print('llama-cpp-python OK')" || warn "llama-cpp-python import failed"

# STEP 10 Ollama
step "Ollama"
_installed_ver=$(ollama --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
_latest_ver=$(curl -sf --max-time 5 "https://api.github.com/repos/ollama/ollama/releases/latest" | grep '"tag_name"' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
if ! command -v ollama &>/dev/null; then
    info "Installing Ollama"
    curl -fsSL https://ollama.com/install.sh | sh
elif _ver_gt "$_latest_ver" "$_installed_ver"; then
    info "Upgrading Ollama: $_installed_ver → $_latest_ver"
    curl -fsSL https://ollama.com/install.sh | sh
else
    info "Ollama $_installed_ver up to date"
fi
if ! is_wsl2; then
    cat > /tmp/ollama.service.tmp << 'EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
Type=simple
User=%USER%
ExecStart=/usr/local/bin/ollama serve
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sed -i "s/%USER%/$USER/g" /tmp/ollama.service.tmp
    sed -i "s|^Environment=\"OLLAMA_MODELS=.*\"|Environment=\"OLLAMA_MODELS=$OLLAMA_MODELS\"|" /tmp/ollama.service.tmp
    sudo mv -f /tmp/ollama.service.tmp /etc/systemd/system/ollama.service
    sudo systemctl daemon-reload
    sudo systemctl enable ollama.service
else
    cat > "$BIN_DIR/ollama-start" << 'EOF'
#!/usr/bin/env bash
_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
_ollama_up || nohup ollama serve >/dev/null 2>&1 &
for i in {1..20}; do _ollama_up && break; sleep 1; done
EOF
    chmod +x "$BIN_DIR/ollama-start"
fi

# STEP 11 Model download
step "Model download"
_model_path="$GGUF_MODELS/${M[file]}"
if [[ -f "$_model_path" ]]; then
    info "Model exists: ${_model_path}"
    _expected_size=${M[size_gb]}000000000  # approx bytes
    _actual_size=$(stat -c %s "$_model_path" 2>/dev/null || echo 0)
    if (( _actual_size < _expected_size / 2 )); then
        warn "Partial file detected — re-downloading"
        rm -f "$_model_path"
    else
        info "Size OK"
    fi
fi
if [[ ! -f "$_model_path" ]]; then
    spin_start "Downloading ${M[name]} (${M[size_gb]} GB)"
    wget -O "$_model_path.tmp" "${M[url]}" || { rm -f "$_model_path.tmp"; warn "Download failed"; }
    mv -f "$_model_path.tmp" "$_model_path"
    spin_stop $?
fi
ollama create "$OLLAMA_TAG" -f <(echo "FROM $_model_path")

# STEP 12 Helper scripts
step "Helper scripts"
cat > "$BIN_DIR/llm-show-config" << 'EOF'
#!/usr/bin/env bash
source ~/.config/local-llm/selected_model.conf 2>/dev/null || { echo "Config not found"; exit 1; }
echo "Paths:"
echo "  GGUF: $GGUF_MODELS"
echo "  Ollama: $OLLAMA_MODELS"
echo "  Config: $MODEL_CONFIG"
echo "  Venv: $VENV_DIR"
echo "  WebUI: $GUI_DIR"
echo "Model:"
echo "  Name: $MODEL_NAME"
echo "  Tag: $OLLAMA_TAG"
echo "  GPU layers: $GPU_LAYERS"
echo "  Batch: $BATCH_SIZE"
echo "  Threads: $HW_THREADS"
_ollama_status=$(ollama_running && echo "running" || echo "stopped")
_webui_status=$(ss -lptn 'sport = :8080' >/dev/null 2>&1 && echo "running" || echo "stopped")
echo "Services:"
echo "  Ollama: $_ollama_status"
echo "  WebUI: $_webui_status"
EOF
chmod +x "$BIN_DIR/llm-show-config"

cat > "$BIN_DIR/llm-stop" << 'EOF'
#!/usr/bin/env bash
pkill -f "ollama serve" 2>/dev/null
pkill -f "open-webui serve" 2>/dev/null
sudo systemctl stop ollama.service 2>/dev/null
echo "Services stopped"
EOF
chmod +x "$BIN_DIR/llm-stop"

cat > "$BIN_DIR/llm-update" << 'EOF'
#!/usr/bin/env bash
_installed_ver=$(ollama --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
_latest_ver=$(curl -sf --max-time 5 "https://api.github.com/repos/ollama/ollama/releases/latest" | grep '"tag_name"' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
if _ver_gt "$_latest_ver" "$_installed_ver"; then
    curl -fsSL https://ollama.com/install.sh | sh
fi
"$OWUI_VENV/bin/pip" install --upgrade open-webui >/dev/null 2>&1
ollama pull "${OLLAMA_TAG:-qwen3:14b}"
echo "Update complete"
EOF
chmod +x "$BIN_DIR/llm-update"

cat > "$BIN_DIR/llm-switch" << 'EOF'
#!/usr/bin/env bash
# Reuse the picker from setup, update config
# ... (implement similar to STEP 3 interactive picker, then update MODEL_CONFIG)
echo "llm-switch WIP"
EOF
chmod +x "$BIN_DIR/llm-switch"

cat > "$BIN_DIR/llm-add" << 'EOF'
#!/usr/bin/env bash
# Show not-downloaded models, download selected
# ... (similar picker, filter ! -f, download and ollama create)
echo "llm-add WIP"
EOF
chmod +x "$BIN_DIR/llm-add"

cat > "$BIN_DIR/local-models-info" << 'EOF'
#!/usr/bin/env bash
echo "Ollama loaded:"
ollama ps
echo "GGUF files:"
ls -lh "$GGUF_MODELS"/*.gguf
echo "Venv status:"
"$VENV_DIR/bin/python3" -V
EOF
chmod +x "$BIN_DIR/local-models-info"

cat > "$BIN_DIR/run-gguf" << 'EOF'
#!/usr/bin/env bash
source ~/.config/local-llm/selected_model.conf 2>/dev/null
_model="${1:-$MODEL_FILE}"
shift
"$VENV_DIR/bin/python3" -c "from llama_cpp import Llama; llm = Llama('$GGUF_MODELS/$_model', n_gpu_layers=$GPU_LAYERS, n_threads=$HW_THREADS, n_batch=$BATCH_SIZE); print(llm(' $@ '))"
EOF
chmod +x "$BIN_DIR/run-gguf"

# STEP 13 Web UI
step "Web UI"
"$PYTHON_BIN" -m venv "$OWUI_VENV"
"$OWUI_VENV/bin/pip" install open-webui --quiet
cat > "$BIN_DIR/llm-webui" << 'EOF'
#!/usr/bin/env bash
OWUI_VENV="$HOME/.local/share/open-webui-venv"
OWUI_DATA="$HOME/.local/share/llm-webui/open-webui-data"
BIN_DIR="$HOME/.local/bin"
_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
if ! _ollama_up; then
    [[ -x "$BIN_DIR/ollama-start" ]] && "$BIN_DIR/ollama-start" || nohup ollama serve >/dev/null 2>&1 &
    for i in {1..20}; do _ollama_up && break; sleep 1; done
fi
_stale=$(ss -lptn 'sport = :8080' 2>/dev/null | awk 'NR>1{match($NF,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1 || true)
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
source "$OWUI_VENV/bin/activate"
exec open-webui serve --host 0.0.0.0 --port 8080
EOF
chmod +x "$BIN_DIR/llm-webui"

# Neural Terminal HTML
mkdir -p "$GUI_DIR"
cat > "$GUI_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Neural Terminal</title>
    <style>
        body { background: #0d1117; color: #c9d1d9; font-family: monospace; margin: 0; padding: 10px; }
        #history { background: #0d1117; border: 1px solid #30363d; padding: 10px; height: 70vh; overflow-y: auto; }
        #input { width: 100%; background: #0d1117; color: #c9d1d9; border: 1px solid #30363d; padding: 10px; font-family: monospace; }
        #model-select { background: #0d1117; color: #c9d1d9; border: 1px solid #30363d; }
        pre { background: #161b22; padding: 10px; border-radius: 5px; }
        .user { color: #58a6ff; }
        .ai { color: #39d353; }
    </style>
</head>
<body>
    <select id="model-select"></select>
    <div id="history"></div>
    <input id="input" placeholder="Type your message..." onkeypress="if(event.keyCode==13) sendMessage();">
    <script>
        const historyDiv = document.getElementById('history');
        const input = document.getElementById('input');
        const modelSelect = document.getElementById('model-select');
        async function loadModels() {
            const res = await fetch('http://localhost:11434/api/tags');
            const data = await res.json();
            data.models.forEach(m => {
                const opt = document.createElement('option');
                opt.value = m.name;
                opt.text = m.name;
                modelSelect.add(opt);
            });
        }
        async function sendMessage() {
            const prompt = input.value;
            input.value = '';
            historyDiv.innerHTML += `<div class="user">User: ${prompt}</div>`;
            historyDiv.scrollTop = historyDiv.scrollHeight;
            const model = modelSelect.value;
            const res = await fetch('http://localhost:11434/api/generate', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ model, prompt, stream: true })
            });
            const reader = res.body.getReader();
            let aiResponse = '<div class="ai">AI: ';
            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                const chunk = new TextDecoder().decode(value);
                const lines = chunk.split('\n');
                for (const line of lines) {
                    if (line) {
                        const json = JSON.parse(line);
                        aiResponse += json.response;
                    }
                }
                historyDiv.innerHTML = historyDiv.innerHTML.replace(/<div class="ai">[^<]*$/, aiResponse);
                historyDiv.scrollTop = historyDiv.scrollHeight;
            }
            aiResponse += '</div>';
            historyDiv.innerHTML += aiResponse;
        }
        loadModels();
    </script>
</body>
</html>
EOF

cat > "$BIN_DIR/llm-chat" << 'EOF'
#!/usr/bin/env bash
PORT=8090
pkill -f "python.*$PORT" 2>/dev/null || true
cd "$HOME/.local/share/llm-webui"
python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1 &
xdg-open "http://localhost:$PORT" 2>/dev/null || explorer.exe "http://localhost:$PORT" 2>/dev/null || echo "Open: http://localhost:$PORT"
EOF
chmod +x "$BIN_DIR/llm-chat"

# STEP 14 Optional tools
step "Optional tools"
echo -e "\n  ${ACCENT}Optional tools menu:${NC} (space-separated numbers or 'all')"
echo "── System utilities ─────────────────────────────────────────────"
echo "  1   tmux          Terminal multiplexer"
echo "  2   CLI tools     bat · eza · fzf · ripgrep · btop · ncdu · jq · micro"
echo "  3   nvtop         GPU monitor"
echo "  4   GUI tools     Thunar · Mousepad · Meld"
echo "  5   neofetch      System info banner + fastfetch"
echo "── AI coding agents ─────────────────────────────────────────────"
echo "  6   Claude Code   Anthropic CLI agent"
echo "  7   OpenAI Codex  OpenAI CLI agent"
echo "── Security / Pentesting ────────────────────────────────────────"
echo "  8   PentestAgent  AI pentesting framework"
printf "  ${ACCENT}?${NC}  Select: "
read -r _tool_sel
[[ -z "$_tool_sel" ]] && { info "Skipping all"; } || :
[[ "${_tool_sel}" == "all" ]] && _tool_sel="1 2 3 4 5 6 7 8"
if [[ " $_tool_sel " == *" 1 "* ]]; then sudo apt-get install -y -qq tmux; fi
if [[ " $_tool_sel " == *" 2 "* ]]; then sudo apt-get install -y -qq bat eza fzf ripgrep btop ncdu jq micro; fi
if [[ " $_tool_sel " == *" 3 "* ]] && (( HAS_GPU )); then sudo apt-get install -y -qq nvtop; fi
if [[ " $_tool_sel " == *" 4 "* ]] && [[ -n "${DISPLAY:-}" ]]; then sudo apt-get install -y -qq thunar mousepad meld; fi
if [[ " $_tool_sel " == *" 5 "* ]]; then sudo apt-get install -y -qq neofetch fastfetch; fi
if [[ " $_tool_sel " == *" 6 "* ]]; then
    command -v node >/dev/null || sudo apt-get install -y -qq nodejs
    npm install -g @anthropic/claude-code
fi
if [[ " $_tool_sel " == *" 7 "* ]]; then
    command -v node >/dev/null || sudo apt-get install -y -qq nodejs
    npm install -g openai-codex-agent
fi
if [[ " $_tool_sel " == *" 8 "* ]]; then
    PA_DIR="$HOME/pentestagent"
    GIT_TERMINAL_PROMPT=0 git clone --depth=1 "https://github.com/vishnupriyavr/pentest-agent.git" "$PA_DIR" || warn "Clone failed"
    for _f in "$PA_DIR/pentestagent/knowledge/rag.py" "$PA_DIR/pentestagent/knowledge/embeddings.py"; do
        [[ -f "$_f" ]] && sed -i 's|"text-embedding-3-small"|"ollama/nomic-embed-text"|g; s|embedding_model: str = "text-embedding-3-small"|embedding_model: str = "ollama/nomic-embed-text"|g' "$_f"
    done
    ollama pull nomic-embed-text
    cat > "$PA_DIR/.env" << EOF
OPENAI_API_KEY="ollama-local"
OPENAI_BASE_URL="http://localhost:11434/v1"
PENTESTAGENT_MODEL="ollama/qwen3:4b-q4_k_m"
PENTESTAGENT_EMBEDDING_MODEL="ollama/nomic-embed-text"
PENTESTAGENT_EMBEDDING_PROVIDER="ollama"
RAG_EMBEDDING_MODEL="ollama/nomic-embed-text"
RAG_EMBEDDING_PROVIDER="ollama"
LITELLM_FORCE_PROVIDER="ollama"
EOF
    cat > "$BIN_DIR/pentestagent-start" << 'EOF'
#!/usr/bin/env bash
rm -rf ~/.cache/pentestagent "$HOME/pentestagent/knowledge/vector_store"
start_ollama_if_needed
cd "$HOME/pentestagent"
source .env
exec pentestagent "$@"
EOF
    chmod +x "$BIN_DIR/pentestagent-start"
fi

# STEP 15 Autonomous coworking
step "Autonomous coworking"
rm -rf "$OI_VENV"
"$PYTHON_BIN" -m venv "$OI_VENV"
"$OI_VENV/bin/pip" install --upgrade pip --quiet
"$OI_VENV/bin/pip" install --upgrade "setuptools>=70" wheel --no-cache-dir --quiet
"$OI_VENV/bin/python3" -c "import pkg_resources" || "$OI_VENV/bin/pip" install --force-reinstall setuptools --no-cache-dir
"$OI_VENV/bin/pip" install open-interpreter --quiet
cat > "$BIN_DIR/cowork" << 'EOF'
#!/usr/bin/env bash
OI_VENV="$HOME/.local/share/open-interpreter-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"
OLLAMA_TAG="qwen3:14b"
[[ -f "$CONFIG" ]] && { _t=$(grep ^OLLAMA_TAG= "$CONFIG" | cut -d'"' -f2); [[ -n "$_t" ]] && OLLAMA_TAG="$_t"; }
_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
_ollama_up || { nohup ollama serve >/dev/null 2>&1 &; sleep 3; }
export OPENAI_API_KEY="local"
export OPENAI_API_BASE="http://127.0.0.1:11434/v1"
source "$OI_VENV/bin/activate"
exec interpreter --model "openai/$OLLAMA_TAG" "$@"
EOF
chmod +x "$BIN_DIR/cowork"

"$PYTHON_BIN" -m venv "$AI_VENV"
"$AI_VENV/bin/pip" install aider-chat --quiet
cat > "$BIN_DIR/aider" << 'EOF'
#!/usr/bin/env bash
AI_VENV="$HOME/.local/share/aider-venv"
CONFIG="$HOME/.config/local-llm/selected_model.conf"
OLLAMA_TAG="qwen3:14b"
[[ -f "$CONFIG" ]] && { _t=$(grep ^OLLAMA_TAG= "$CONFIG" | cut -d'"' -f2); [[ -n "$_t" ]] && OLLAMA_TAG="$_t"; }
_ollama_up() { curl -sf --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; }
_ollama_up || nohup ollama serve >/dev/null 2>&1 &
source "$AI_VENV/bin/activate"
exec aider --model "ollama/$OLLAMA_TAG" --no-fancy-input --no-show-release-notes --no-check-update "$@"
EOF
chmod +x "$BIN_DIR/aider"

# STEP 16 llm-checker
step "llm-checker"
cat > "$BIN_DIR/llm-checker" << 'EOF'
#!/usr/bin/env bash
watch -n 1 "nvidia-smi; ollama ps; echo 'Model config:'; cat $MODEL_CONFIG"
EOF
chmod +x "$BIN_DIR/llm-checker"

# STEP 17 llm-help
step "llm-help"
cat > "$BIN_DIR/llm-help" << 'EOF'
#!/usr/bin/env bash
C="${CYAN}"; Y="${YELLOW}"; M="${MUTED}"; NC="${NC}"
echo -e "${C}── Chat interfaces ──────────────────────────────────────────────${NC}"
echo -e "   ${Y}webui${NC}        → Open WebUI   http://localhost:8080  (primary)"
echo -e "   ${Y}chat${NC}         → Neural Terminal   http://localhost:8090"
echo -e "${C}── CLI inference ────────────────────────────────────────────────${NC}"
echo -e "   ${Y}run-model / ask / gguf-run${NC}    Direct llama.cpp inference"
echo -e "   ${Y}ollama-run${NC}                    Ollama CLI"
echo -e "   ${Y}ollama-start${NC}                  Start the Ollama backend"
echo -e "${C}── Model management ─────────────────────────────────────────────${NC}"
echo -e "   ${Y}llm-add${NC}      Download additional models from catalog"
echo -e "   ${Y}llm-switch${NC}   Change the active model"
echo -e "   ${Y}llm-status${NC}   Show loaded models and GGUF files"
echo -e "   ${Y}llm-checker${NC}  Live hardware + model diagnostics dashboard"
echo -e "   ${Y}gguf-list${NC}    List downloaded GGUF files"
echo -e "   ${Y}ollama-list${NC}  List Ollama models"
echo -e "${C}── Service control ──────────────────────────────────────────────${NC}"
echo -e "   ${Y}llm-stop${NC}     Stop Ollama + WebUI"
echo -e "   ${Y}llm-update${NC}   Upgrade Ollama + Open WebUI + re-pull model"
echo -e "${C}── Info & diagnostics ───────────────────────────────────────────${NC}"
echo -e "   ${Y}llm-show-config${NC}   All paths, model config, service status"
echo -e "   ${Y}llm-help${NC}          This screen"
echo -e "${C}── AI coding  (local — no API key needed) ──────────────────────${NC}"
echo -e "   ${Y}cowork${NC}        Open Interpreter — autonomous AI (local model)"
echo -e "   ${Y}ai / aider${NC}    Aider pair programmer — git-integrated"
echo -e "   ${Y}run-model${NC}     Direct terminal chat with active local model"
echo -e "${C}── AI coding  (cloud — optional installs via setup) ────────────${NC}"
echo -e "   ${Y}claude${NC}        Claude Code  ${M}(ANTHROPIC_API_KEY required)${NC}"
echo -e "   ${Y}codex-agent${NC}   OpenAI Codex ${M}(OPENAI_API_KEY required)${NC}"
echo -e "${C}── Security / Pentesting ────────────────────────────────────────${NC}"
echo -e "   ${Y}pentest${NC}       PentestAgent AI — RAG + multi-agent (fully local)"
echo -e "${C}── WSL2 quickstart ──────────────────────────────────────────────${NC}"
echo -e "   Run ${Y}webui${NC} — it starts Ollama automatically"
EOF
chmod +x "$BIN_DIR/llm-help"

# STEP 18 Self-install + aliases
step "Self-install + aliases"
cp -f "$0" "$SCRIPT_INSTALL_PATH"
cat > "$ALIAS_FILE" << 'EOF'
alias llm-setup='bash "$HOME/.config/local-llm/llm-auto-setup.sh"'
alias webui='$HOME/.local/bin/llm-webui'
alias chat='$HOME/.local/bin/llm-chat'
alias run-model='$HOME/.local/bin/run-gguf'
alias ask='$HOME/.local/bin/run-gguf'
alias gguf-run='$HOME/.local/bin/run-gguf'
alias gguf-list='ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null || echo "(no GGUF files)"'
alias ollama-run='ollama run'
alias ollama-pull='ollama pull'
alias ollama-list='ollama list'
alias ollama-start='$HOME/.local/bin/ollama-start'
alias llm-status='$HOME/.local/bin/local-models-info'
alias llm-stop='$HOME/.local/bin/llm-stop'
alias llm-update='$HOME/.local/bin/llm-update'
alias llm-switch='$HOME/.local/bin/llm-switch'
alias llm-add='$HOME/.local/bin/llm-add'
alias llm-checker='$HOME/.local/bin/llm-checker'
alias llm-help='$HOME/.local/bin/llm-help'
alias llm-show-config='$HOME/.local/bin/llm-show-config'
alias ai='$HOME/.local/bin/aider'
alias aider='$HOME/.local/bin/aider'
alias cowork='$HOME/.local/bin/cowork'
alias pentest='$HOME/.local/bin/pentestagent-start'
EOF
_marker="# llm-auto-setup aliases"
grep -q "$_marker" "$HOME/.bashrc" || echo "$_marker; source $ALIAS_FILE" >> "$HOME/.bashrc"
if is_wsl2; then
    _wsl_marker="# WSL2 welcome — llm-auto-setup"
    grep -q "$_wsl_marker" "$HOME/.bash_profile" || cat >> "$HOME/.bash_profile" << 'EOF'
# WSL2 welcome — llm-auto-setup
if grep -qi microsoft /proc/version 2>/dev/null; then
    source "$HOME/.bashrc" 2>/dev/null || true
    [[ -x "$HOME/.local/bin/llm-help" ]] && "$HOME/.local/bin/llm-help"
fi
EOF
fi

# STEP 19 Final checks + summary
step "Final checks + summary"
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
_check "Ollama binary" "$(command -v ollama >/dev/null 2>&1 && echo 1 || echo 0)"
_check "Ollama responding" "$(ollama_running && echo 1 || echo 0)"
_check "llama-cpp-python" "$("$VENV_DIR/bin/python3" -c "import llama_cpp 2>/dev/null; echo \$?" | grep -q 0 && echo 1 || echo 0)"
_check "Open WebUI venv" "$( [[ -d "$OWUI_VENV" ]] && echo 1 || echo 0 )" "$("$OWUI_VENV/bin/pip" show open-webui 2>/dev/null | grep Version || echo "")"
_check "GGUF model file" "$( [[ -f "$GGUF_MODELS/${M[file]}" ]] && echo 1 || echo 0 )"
_check "Ollama tag registered" "$(ollama list | grep -q "$OLLAMA_TAG" && echo 1 || echo 0)"
_check "cowork launcher" "$( [[ -x "$BIN_DIR/cowork" ]] && echo 1 || echo 0 )"
_check "aider launcher" "$( [[ -x "$BIN_DIR/aider" ]] && echo 1 || echo 0 )"
_check "Open Interpreter health" "$("$OI_VENV/bin/python3" -c "import pkg_resources 2>/dev/null; echo \$?" | grep -q 0 && echo 1 || echo 0)"
_check "Neural Terminal HTML" "$( [[ -f "$GUI_DIR/index.html" ]] && echo 1 || echo 0 )"
_check "Alias file" "$( [[ -f "$ALIAS_FILE" ]] && echo 1 || echo 0 )"
_check "Script installed" "$( [[ -f "$SCRIPT_INSTALL_PATH" ]] && echo 1 || echo 0 )"

echo -e "${GREEN}${BOLD}"
cat << 'EOF'
  ██████╗  ██████╗ ███╗   ██╗███████╗
  ██╔══██╗██╔═══██╗████╗  ██║██╔════╝
  ██║  ██║██║   ██║██╔██╗ ██║█████╗  
  ██║  ██║██║   ██║██║╚██╗██║██╔══╝  
  ██████╔╝╚██████╔╝██║ ╚████║███████╗
  ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝
EOF
echo -e "${NC}"
echo -e "  Installation complete!  Local LLM stack is ready."
_rule "═"
echo -e "  Hardware"
echo -e "    CPU      $CPU_MODEL"
echo -e "    RAM      $TOTAL_RAM_GB GB"
echo -e "    GPU      $GPU_NAME  ($GPU_VRAM_GB GB VRAM)  [${HAS_NVIDIA:+CUDA}${HAS_AMD_GPU:+ROCm}]"
echo -e "  Model"
echo -e "    Selected     ${M[name]}"
echo -e "    Ollama tag   $OLLAMA_TAG"
echo -e "    Layers       GPU: $GPU_LAYERS  CPU: $CPU_LAYERS  Batch: $BATCH"
echo -e "  Next step — reload your shell"
echo -e "      exec bash"
echo -e "    Aliases become active. Same window. Same directory."
_rule "─"
echo -e "  webui           →  Open WebUI  http://localhost:8080  ← start here"
echo -e "  cowork          →  Autonomous AI coder"
echo -e "  llm-help        →  All commands"
_rule "─"
"$BIN_DIR/llm-help" || true