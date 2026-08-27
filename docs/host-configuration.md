# Host Configuration Guide for AMD Strix Halo

This document details host-level configuration for running Gufo Toolboxes reliably on AMD Ryzen AI Max ("Strix Halo", `gfx1151` GPU + XDNA2 NPU).

---

## 1. Kernel and Firmware Requirements

### Recommended Setup
- **Linux Kernel**: `>= 6.18.4` (e.g. `6.18.9+`). Kernels older than 6.18.4 exhibit stability bugs and crashes under sustained ROCm compute on gfx1151.
- **Linux Firmware**: `20260110` or later.
- **Avoid**: `linux-firmware-20251125` (breaks ROCm initialization on gfx1151).

### Kernel Boot Parameters
Add the following parameters to your bootloader (e.g. GRUB or systemd-boot):

```text
amdgpu.gttsize=65536
```
*(On 128 GiB unified memory systems, this ensures sufficient GTT allocation for large model weights and KV caches).*

---

## 2. Device Permissions and User Groups

Ensure your host user account belongs to the required hardware access groups:

```bash
sudo usermod -aG video,render $USER
```

Verify device existence:
```bash
# GPU ROCm / KFD interface
ls -l /dev/kfd /dev/dri/renderD*

# XDNA2 NPU interface
ls -l /dev/accel/accel* /dev/amdxdna 2>/dev/null || echo "NPU driver not loaded"
```

---

## 3. Ulimits (Locked Memory)

Large unified memory buffers require unlimited memlock limits. In `/etc/security/limits.d/99-gufo.conf`:

```text
* soft memlock unlimited
* hard memlock unlimited
```

---

## 4. Power Profiles

For sustained LLM inference on Strix Halo laptops or mini PCs, switch power profiles to `throughput-performance`:

```bash
sudo tuned-adm profile throughput-performance
```
*(Or install the provided `systemd/gpu-workload-watch` service to automate this on GPU activity).*
