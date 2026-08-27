# Gufo Toolboxes Quick Start

This guide gets you up and running with **Gufo Toolboxes** on AMD Ryzen AI Max ("Strix Halo") systems featuring the `gfx1151` RDNA 3.5 GPU and XDNA2 NPU.

---

## 1. Prerequisites

- **Host OS**: Fedora 42/43/44, Ubuntu 24.04+, Arch Linux, or openSUSE Tumbleweed.
- **Kernel**: Linux kernel >= `6.18.4` (older kernels have known gfx1151 stability issues).
- **Firmware**: Avoid `linux-firmware-20251125` due to known ROCm regressions.
- **Container Tooling**:
  - Fedora: `toolbox` and `podman`
  - Ubuntu / Debian / Arch: `distrobox` and `podman`

---

## 2. Choosing a Toolbox

| Toolbox | Image | Use Case |
| :--- | :--- | :--- |
| **`gufo-runtime`** | `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` | Lightweight production inference & model serving (`gufo serve`, `gufo prompt`, `gufo bench`) |
| **`gufo-dev`** | `ghcr.io/gufo-org/toolboxes/gufo-dev:latest` | Development, C++/HIP kernel tuning, and profiling (`rocprofv3`, Clang, CMake, Ninja) |

---

## 3. Creating and Entering the Toolbox

### Using `refresh-toolboxes.sh` (Recommended)

The included `refresh-toolboxes.sh` script automatically detects your OS (`toolbox` or `distrobox`) and configures all Strix Halo GPU (`/dev/kfd`, `/dev/dri`) and NPU (`/dev/accel*`) passthroughs:

```bash
# Pull & create gufo-runtime
./refresh-toolboxes.sh gufo-runtime

# Or create the development toolbox
./refresh-toolboxes.sh gufo-dev

# Or build the image locally from Nix without pulling from GHCR
./refresh-toolboxes.sh --local gufo-runtime
```

### Manual Creation

#### Fedora (`toolbox`)
```bash
toolbox create gufo-runtime \
  --image ghcr.io/gufo-org/toolboxes/gufo-runtime:latest \
  -- --device /dev/dri --device /dev/kfd --device /dev/accel/accel0 \
     --group-add video --group-add render --group-add sudo \
     --security-opt seccomp=unconfined --ulimit memlock=-1

toolbox enter gufo-runtime
```

#### Ubuntu / Debian / Arch (`distrobox`)
```bash
distrobox create \
  --name gufo-runtime \
  --image ghcr.io/gufo-org/toolboxes/gufo-runtime:latest \
  --additional-flags "--device /dev/dri --device /dev/kfd --device /dev/accel/accel0 --group-add video --group-add render --group-add sudo --security-opt seccomp=unconfined --ulimit memlock=-1"

distrobox enter gufo-runtime
```

---

## 4. Verifying Hardware Acceleration

Inside the toolbox, run:

```bash
# Verify GPU / NPU hardware diagnostics
gufo diagnose
```

---

## 5. Running Inference & Server

### Interactive Prompt
```bash
gufo prompt --model /path/to/model.gguf -p "Explain quantum computing in simple terms."
```

### Benchmark
```bash
gufo bench --model /path/to/model.gguf -p 512 -n 128
```

### Server
```bash
gufo serve --model /path/to/model.gguf --host 0.0.0.0 --port 8080
```
