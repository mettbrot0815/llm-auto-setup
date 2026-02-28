
<div align="center">

# llm-auto-setup

**Local LLM stack in one command**  
Ubuntu 22.04 / 24.04 · WSL2 ready · NVIDIA / AMD / CPU

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ubuntu 22.04|24.04](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-orange)](https://ubuntu.com)
[![WSL2](https://img.shields.io/badge/WSL2-supported-blue)](https://learn.microsoft.com/en-us/windows/wsl/)

</div>

## One command to rule them all

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mettbrot0815/llm-auto-setup/main/llm-auto-setup.sh)
```bash

# 🤖 Local LLM Auto-Setup

**Universal one-script local AI stack — v3.0.0**

Automatically detects your hardware (CPU, NVIDIA, AMD, Apple), picks the best GGUF model for your VRAM/RAM, installs Ollama, llama-cpp-python, Neural Terminal UI, Open WebUI, autonomous coding agents (Open Interpreter + Aider), and optional cloud coding agents (Claude Code, OpenAI Codex) — all from a single shell script.

---

## Quick Start

```bash
# Download and run
curl -fsSL https://raw.githubusercontent.com/yourname/llm-auto-setup/main/llm-auto-setup.sh | bash

# Or clone and run
git clone https://github.com/yourname/llm-auto-setup.git
cd llm-auto-setup && bash llm-auto-setup.sh
```

After install, activate aliases in the same terminal:
```bash
exec bash
```

Then chat:
```bash
chat       # Neural Terminal UI → http://localhost:8090
run-model  # Quick CLI inference
```

---

## Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu 22.04 / Debian 12 | Ubuntu 24.04 LTS |
| RAM | 4 GB | 16 GB+ |
| Disk | 10 GB free | 40 GB+ |
| GPU (optional) | — | NVIDIA RTX (CUDA 12+) or AMD RX 7000 (ROCm 6+) |
| Python | 3.10+ | 3.12 |

WSL2 on Windows 10/11 is fully supported.

---

## What Gets Installed

### Core (always)
| Component | Purpose |
|-----------|---------|
| **Ollama** | Model server + REST API |
| **llama-cpp-python** | Native GGUF inference (CPU/GPU) |
| **Neural Terminal** | HTML chat UI served locally on port 8090 |
| **llm-helper scripts** | `llm-stop`, `llm-update`, `llm-switch`, `llm-add`, `llm-checker` |
| **cowork** | Open Interpreter — AI that writes and runs code |
| **aider** | AI pair programmer with git integration |

### Optional (installer menu)
| # | Tool | Notes |
|---|------|-------|
| 1 | tmux | Terminal multiplexer |
| 2 | CLI tools | bat, eza, fzf, ripgrep, btop, ncdu, jq, micro |
| 3 | nvtop | Live GPU monitor |
| 4 | GUI tools | Thunar, Mousepad, Meld (needs display) |
| 5 | neofetch | System info banner |
| 6 | Open WebUI | Full browser chat UI on port 8080 (~500 MB) |
| 7 | Claude Code | Anthropic CLI coding agent (needs `ANTHROPIC_API_KEY`) |
| 8 | OpenAI Codex | OpenAI CLI coding agent (needs `OPENAI_API_KEY`) |

---

## Model Auto-Selection

| VRAM | Model | Capabilities |
|------|-------|--------------|
| ≥48 GB | Llama-3.3-70B Q4_K_M | TOOLS |
| ≥24 GB | Qwen3-32B Q4_K_M | TOOLS + THINK |
| ≥16 GB | Mistral-Small-3.2-24B Q4_K_M | TOOLS + THINK |
| ≥12 GB | Qwen3-14B Q4_K_M | TOOLS + THINK |
| ≥10 GB | Phi-4-14B Q4_K_M | TOOLS |
| ≥8 GB | Qwen3-8B Q6_K | TOOLS + THINK |
| CPU 32 GB+ | Qwen3-14B Q4_K_M | TOOLS + THINK |
| CPU 8 GB+ | Qwen3-4B Q4_K_M | TOOLS + THINK |

Override with the manual picker during install, or `llm-switch` afterward.

---

## Commands

```bash
# Chat
chat          # Neural Terminal → http://localhost:8090
webui         # Open WebUI → http://localhost:8080

# Run models
run-model / ask       # Run default GGUF from CLI
ollama-run <tag>      # Any Ollama model
ollama-pull <tag>     # Download Ollama model

# Coworking  ~/work/
cowork        # Open Interpreter (writes + runs code)
ai / aider    # AI pair programmer (git-integrated)

# Cloud agents (if installed)
claude-code   # Claude Code (ANTHROPIC_API_KEY)
codex         # OpenAI Codex (OPENAI_API_KEY)

# Management
ollama-start  # Start Ollama
llm-stop      # Stop everything
llm-update    # Upgrade + re-pull model
llm-switch    # Change active model
llm-add       # Download more models
llm-setup     # Re-run installer
llm-checker   # Hardware scan + model catalog
llm-help      # Full reference
```

---

## Package Caching

Pip, npm, and apt `.deb` files are cached in `~/.cache/llm-setup/`. CUDA, PyTorch, and Open WebUI are not re-downloaded on subsequent runs.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `webui: command not found` | `exec bash` then retry |
| Open WebUI shows no models | `ollama-start`, then `webui` |
| `cowork` crashes with `pkg_resources` error | `llm-setup` (rebuilds venv) |
| Model download 401 error | `llm-setup` (updated URLs) |
| CUDA not found after install | `sudo ldconfig && exec bash` |
| ROCm not found | `exec bash && hipconfig --version` |

---

## Directory Layout

```
~/.config/local-llm/           Config + selected_model.conf
~/local-llm-models/gguf/       Downloaded GGUF files
~/.local/share/llm-webui/      Neural Terminal HTML UI
~/.local/share/open-webui-data/ Open WebUI data
~/.local/bin/                  Helper scripts (in PATH)
~/.local_llm_aliases           All aliases (sourced in .bashrc)
~/work/                        Coworking workspace
~/.cache/llm-setup/            Package download cache
```

---

## License

MIT — see [LICENSE](LICENSE)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md)
