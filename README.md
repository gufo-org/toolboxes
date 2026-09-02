# Gufo Toolboxes for AMD Strix Halo

[![CI](https://github.com/gufo-org/toolboxes/actions/workflows/build_and_publish.yml/badge.svg)](https://github.com/gufo-org/toolboxes/actions/workflows/build_and_publish.yml)

Reproducible container toolboxes for local LLM inference, serving, development, and profiling on **AMD Ryzen AI Max ("Strix Halo")** systems (`gfx1151` RDNA 3.5 GPU + XDNA2 NPU).

Built directly from **Nix flake derivations** to guarantee bit-for-bit reproducibility and optimal layered caching across Fedora (Toolbx), Ubuntu (Distrobox), and Arch Linux hosts.

---

## 📦 Supported Toolboxes

| Container Name | Image (GHCR) | Description |
| :--- | :--- | :--- |
| **`gufo-runtime`** | `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` | Lightweight production inference runtime for `gufo serve`, `gufo prompt`, `gufo bench`, and `gufo diagnose`. Includes ROCm `gfx1151` and XRT/XDNA2 runtimes. |
| **`gufo-dev`** | `ghcr.io/gufo-org/toolboxes/gufo-dev:latest` | Interactive development & profiling container. Includes full ROCm SDK, HIP compiler, `rocprofv3`, Clang tools, CMake, and Ninja for kernel development. |
| **`eval-agent`** | `ghcr.io/gufo-org/toolboxes/eval-agent:latest` | Reproducible coding-agent evaluator. Connect it to any reachable OpenAI-compatible endpoint with `--base-url`. |
| **`gufo-eval-agent`** | `ghcr.io/gufo-org/toolboxes/gufo-eval-agent:latest` | Gufo and eval-agent together, with a launcher that starts a local Gufo server before the evaluation and stops it afterward. |

---

## 🚀 Quick Start

### 1. Requirements
- Linux kernel `>= 6.18.4` (see [Host Configuration](docs/host-configuration.md))
- User in `video` and `render` groups (`sudo usermod -aG video,render $USER`)
- `podman` + `toolbox` (Fedora) or `distrobox` (Ubuntu/Debian/Arch)

### 2. Create and Enter Toolbox

Use the provided `refresh-toolboxes.sh` script, which automatically configures Strix Halo hardware passthroughs (`/dev/kfd`, `/dev/dri`, `/dev/accel*`):

```bash
# Clone the repository
git clone https://github.com/gufo-org/toolboxes.git
cd toolboxes

# Create the runtime toolbox
./refresh-toolboxes.sh gufo-runtime

# Enter the toolbox
toolbox enter gufo-runtime      # on Fedora
# OR
distrobox enter gufo-runtime    # on Ubuntu / Arch
```

### Evaluate an external endpoint

```bash
./refresh-toolboxes.sh eval-agent
toolbox enter eval-agent

eval-agent doctor
eval-agent run sparql-university \
  --base-url http://192.168.1.8:8080/v1
```

Pass credentials through `GUFO_EVAL_API_KEY`; the evaluator never writes the
credential to its result artifact.

### Start Gufo and evaluate it

The combined image provides `eval-agent-with-gufo`. Launcher options go before
`--`; eval-agent arguments go after it. The launcher waits for Gufo's
`/v1/models` endpoint and always terminates the server when the evaluation
finishes or is interrupted.

```bash
./refresh-toolboxes.sh gufo-eval-agent
toolbox enter gufo-eval-agent

eval-agent-with-gufo --model /path/to/model.gguf -- \
  run sparql-university \
  --output /path/to/results/result.json \
  --platform strix-halo \
  --engine gufo \
  --backend rocm
```

The server defaults match eval-agent's agent-loop settings: port `8080`, a
`32768`-token context, and `16384` maximum generated tokens. Use launcher
options or `GUFO_MODEL`, `GUFO_HOST`, `GUFO_PORT`, `GUFO_CONTEXT`, and
`GUFO_MAX_TOKENS` to override them. Repeat `--llm-arg ARG` for additional
Gufo LLM options.

### 3. Verify Hardware & Run Inference

Inside the toolbox:

```bash
# Check GPU and NPU hardware status
gufo diagnose

# Run an interactive prompt
gufo prompt --model /path/to/model.gguf -p "What is AMD Strix Halo unified memory architecture?"

# Benchmark token generation
gufo bench --model /path/to/model.gguf -p 512 -n 128
```

---

## 🛠️ Maintainers: Building Images from Source (Nix)

For maintainers or developers who want to rebuild the container images from source using Nix:

```bash
# Stream the OCI image directly into local Podman/Docker:
nix run .#stream-gufo-runtime | podman load

# Eval-only and combined evaluation images:
nix run .#stream-eval-agent | podman load
nix run .#stream-gufo-eval-agent | podman load

# Or build the image tarball:
nix build .#packages.x86_64-linux.gufo-runtime-image
```

---

## ⚙️ Background Serving (Systemd)

Run `gufo serve` as a persistent background user service:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/gufo-serve.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user start gufo-serve
systemctl --user enable gufo-serve
```

See [docs/systemd.md](docs/systemd.md) for full configuration options.

---

## 📚 Documentation

- [Quick Start Guide](docs/quickstart.md)
- [Host Configuration (Kernel, Firmware, Groups)](docs/host-configuration.md)
- [Systemd Integration](docs/systemd.md)

---

## 📜 License

MIT License. See [LICENSE](LICENSE) for details.
