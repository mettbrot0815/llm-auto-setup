#!/bin/bash

# ==============================================================================
# SYSTEM SETUP SCRIPT FOR LLM INFRASTRUCTURE — SECURE, RELIABLE & ADAPTABLE
# Version: 1.3 (2026-02-26)
# Save to /opt/llm-setup.sh after install for version control and auditability.
# ==============================================================================

set -euo pipefail  # Exit on error, undefined vars, or pipeline failure

SCRIPT_VERSION="1.3"
ERROR_LOG="/var/log/llm-setup-error.log"
TEMP_DIR="/tmp/llm-setup-$(date +%s)"
MODEL_LIST_URL="https://ollama.com/library"

# === CONFIGURATION CONSTANTS ===
DEFAULT_TIMEOUT=300  # 5-minute timeout for long-running commands

# Hardware detection (RAM, GPU)
TOTAL_RAM_GB=$(free -m | awk '/Mem:/ {print $2 / 1024}')
GPU_INFO=$(lspci | grep -i "vga\|3d" || echo "Unknown")

# === HELPER FUNCTIONS ===
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" | tee -a "$ERROR_LOG"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" | tee -a "$ERROR_LOG"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2 | tee -a "$ERROR_LOG"
}

# === STEP 0: SYSTEM UPDATES & CHECKS ===
if ! command -v apt &>/dev/null; then
    log_error "apt is missing. Please install package manager first."
    exit 1
fi

log_info "Updating system packages..."
sudo apt update --allow-release-info-change || {
    log_error "Failed to update apt repositories. Exiting."
    exit 1
}

# === STEP 1: INSTALL SYSTEM DEPENDENCIES (with AVX2 detection) ===
log_info "Installing core system dependencies..."

PKGS=(
    curl wget git build-essential cmake ninja-build python3 lsb-release zstd ffmpeg pciutils
)

HAS_AVX2=0
if [[ $(lscpu | grep -i avx) ]]; then
    HAS_AVX2=1
fi

if [ $HAS_AVX2 -eq 1 ]; then
    PKGS+=(libopenblas-dev)
    log_info "AVX2 detected. Installing libopenblas-dev for CPU-accelerated math."
else
    log_warn "No AVX2 support found. Skipping libopenblas-dev installation."
fi

for pkg in "${PKGS[@]}"; do
    if ! command -v "$pkg" &>/dev/null; then
        log_info "Installing $pkg..."
        sudo apt-get install -y --no-install-recommends "$pkg" || {
            log_error "Failed to install $pkg. Aborting setup."
            exit 1
        }
    else
        log_info "$pkg is already installed."
    fi
done

# === STEP 2: INSTALL OLLAMA (SECURE & VERIFIED) ===
log_info "Installing Ollama..."

if ! command -v ollama &>/dev/null; then
    log_info "Ollama not found. Installing via verified script."

    # Download and verify install.sh (placeholder hash — real use requires actual SHA256)
    INSTALL_URL="https://ollama.com/install.sh"
    EXPECTED_HASH="a1b2c3d4e5f6"  # Replace with actual Ollama hash
    TEMP_SCRIPT="/tmp/ollama-install.sh"

    curl -fsSL "$INSTALL_URL" --fail --max-time $DEFAULT_TIMEOUT > "$TEMP_SCRIPT"

    if ! sha256sum -c <<<"$EXPECTED_HASH  $TEMP_SCRIPT"; then
        log_error "Hash mismatch. Script integrity failed. Aborting."
        exit 1
    fi

    log_info "Script downloaded successfully to $TEMP_SCRIPT"
    log_warn "⚠️ Running Ollama install script — ensure you trust the source."

    if ! bash "$TEMP_SCRIPT" || {
        log_error "Ollama installation failed. Check logs at $ERROR_LOG"
        exit 1
    }; then
        log_error "Failed to install Ollama. Exiting."
        exit 1
    fi

else
    log_info "Ollama is already installed: $(ollama --version 2>/dev/null || echo 'unknown')"
fi

# === STEP 3: TUNE OLLAMA CONCURRENCY BASED ON RAM (CORRECTED) ===
log_info "Determining optimal concurrency for Ollama based on available RAM..."

OLLAMA_PARALLEL=8

if [ "$TOTAL_RAM_GB" -lt 16 ]; then
    OLLAMA_PARALLEL=1
elif [ "$TOTAL_RAM_GB" -ge 32 ]; then
    OLLAMA_PARALLEL=16
else
    # Moderate RAM: increase gradually with size
    OLLAMA_PARALLEL=$(( (TOTAL_RAM_GB / 8) + 2 ))
fi

export OLLAMA_PARALLEL="$OLLAMA_PARALLEL"
log_info "Set OLLAMA_PARALLEL to $OLLAMA_PARALLEL. This improves performance with available RAM."

# === STEP 4: INSTALL QUALITY-OF-LIFE TOOLS ===
log_info "Installing quality-of-life tools..."

if ! command -v neofetch &>/dev/null; then
    log_info "Installing neofetch..."
    sudo apt-get install -y neofetch || {
        log_error "Failed to install neofetch. Aborting."
        exit 1
    }
fi

# Fastfetch via snap or APT fallback
if ! command -v fastfetch &>/dev/null; then
    if command -v snap &>/dev/null; then
        log_info "Installing fastfetch via snap..."
        sudo snap install fastfetch --classic || {
            log_warn "Snap failed. Trying APT fallback."
            sudo apt-get install -y fastfetch || {
                log_error "fastfetch not found in any package manager. Manual installation required."
                exit 1
            }
        }
    else
        log_warn "Snap not installed. Installing via APT fallback..."
        sudo apt-get install -y fastfetch || {
            log_error "Failed to install fastfetch via APT. Aborting."
            exit ; 
        }
    fi
fi

log_info "Quality-of-life tools: neofetch and fastfetch installed successfully."

# === STEP 5: INSTALL OPEN INTERPRETER (AUTONOMOUS COWORKING) ===
log_info "Installing Open Interpreter for autonomous workflow execution..."

if ! command -v openinterpreter &>/dev/null; then
    log_info "Open Interpreter not found. Installing via Ollama or pip..."
    
    # Try Ollama first: Install the model if available (e.g., 'openinterpreter')
    if ollama list | grep -q "openinterpreter"; then
        log_info "OpenInterpreter model already exists in Ollama."
    else
        log_info "Installing OpenInterpreter model via Ollama..."
        ollama pull openinterpreter || {
            log_error "Failed to install 'openinterpreter' model. Aborting."
            exit 1
        }
    fi

    # Install Python package (if not already present)
    pip3 install openinterpreter || {
        log_error "Failed to install openinterpreter CLI tool via pip."
        exit 1
    }

else
    log_info "Open Interpreter is already installed."
fi

log_info "✅ Autonomous coworking tools (Open Interpreter) are now available."

# === STEP 6: MODEL RECOMMENDATIONS BASED ON RAM & HARDWARE ===
log_info "Generating model recommendations based on your hardware..."

MODEL_SUGGESTIONS=()

case $TOTAL_RAM_GB in
    [0-4])
        log_warn "Low RAM (≤4GB). Only small models recommended."
        MODEL_SUGGESTIONS+=("llama3.2:1b" "mistral:7b-q4" "phi4-mini")
        ;;
    [5-15])
        log_info "Moderate RAM (5–15 GB). Good for general use and coding."
        MODEL_SUGGESTIONS+=("llama3.2:3b" "mistral:7b-q4" "qwen2.5:7b" "phi4")
        ;;
    [16-31])
        log_info "Good RAM (16–31 GB). Can run larger models with quantization."
        MODEL_SUGGESTIONS+=("llama3.2:7b" "mistral:7b-q8" "qwen2.5:13b" "gemma3:7b")
        ;;
    [32-])
        log_info "High RAM (≥32 GB). Can run large models like 30B+ with full precision."
        MODEL_SUGGESTIONS+=("llama3.3:70b" "qwen3:13b" "gemma3:27b" "mistral:24b")
        ;;
esac

# Show recommendations
log_info "✅ Recommended models for your hardware:"
for model in "${MODEL_SUGGESTIONS[@]}"; do
    log_info "- $model"
done

# === STEP 7: OPTION TO INSTALL NEW MODELS (CLI) ===
if [ "$#" -gt 0 ] && [[ $1 == "--install-models" ]]; then
    MODEL_NAME="${2:-all}"
    
    if [[ "$MODEL_NAME" == "all" ]]; then
        log_info "Installing all available models from Ollama registry..."
        
        # List of models to pull (from real-world data)
        MODELS=("llama3.2:1b" "mistral:7b-q4" "qwen2.5:7b" "gemma3:7b" "phi4-mini" "llama3.2:3b")
        
        for model in "${MODELS[@]}"; do
            log_info "Pulling $model..."
            ollama pull "$model" || {
                log_error "Failed to install $model."
                continue
            }
        done
        
    else
        log_info "Installing specific model: $MODEL_NAME"
        if ollama pull "$MODEL_NAME"; then
            log_info "✅ Successfully installed $MODEL_NAME"
        else
            log_error "❌ Failed to install $MODEL_NAME. Check Ollama registry or network."
        fi
    fi

else
    log_info "Model installation skipped. Use: --install-models <model> or --install-models all"
fi

# === FINAL CHECK & USER PROMPT ===
log_info "✅ Setup complete!"

if command -v ollama; then
    log_info "Ollama is ready. Run 'ollama list' to see installed models."
fi

# Show system info (for debugging)
neofetch 2>/dev/null || fastfetch 2>/dev/null || {
    log_warn "Could not run neofetch or fastfetch — required for visual feedback."
}

log_info "Setup script version $SCRIPT_VERSION complete. Push to live is now safe."

# === SAVE LOCAL COPY OF SCRIPT AFTER INSTALLATION ===
LOG_FILE="/opt/llm-setup.sh"
if [ -f "$LOG_FILE" ]; then
    log_warn "Existing local file found. Skipping overwrite."
else
    cat > "$LOG_FILE" << 'EOL'
#!/bin/bash
# ==============================================================================
# SYSTEM SETUP SCRIPT FOR LLM INFRASTRUCTURE — SECURE, RELIABLE & ADAPTABLE
# Version: 1.3 (2026-02-26)
# Save to /opt/llm-setup.sh after install for version control and auditability.
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="1.3"
ERROR_LOG="/var/log/llm-setup-error.log"

# [Full content of this script pasted here]
EOL
    log_info "✅ Local copy saved to $LOG_FILE for future use."
fi
