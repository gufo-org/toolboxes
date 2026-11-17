# Host Configuration Guide for AMD Strix Halo

This document details host-level configuration for running the Gufo Docker and Podman images reliably on AMD Ryzen AI Max ("Strix Halo", `gfx1151` GPU + XDNA2 NPU).

---

## 1. Kernel and Firmware Requirements

### Recommended Setup
- **Linux Kernel**: `>= 6.18.4` (e.g. `6.18.9+`). Kernels older than 6.18.4 exhibit stability bugs and crashes under sustained ROCm compute on gfx1151.
- **Linux Firmware**: `20260110` or later.
- **Avoid**: `linux-firmware-20251125` (breaks ROCm initialization on gfx1151).

### BIOS and Kernel Boot Parameters
In the BIOS, set the GPU's dedicated memory (UMA frame buffer or iGPU memory size) to its minimum, 512 MiB. The GPU then takes its memory from system RAM through the GTT.

Add the following parameters to your bootloader (e.g. GRUB or systemd-boot; on NixOS, `boot.kernelParams`). For 128 GiB of RAM they give the GPU 124 GiB and leave 4 GiB to the system:

```text
amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

For another size, `amdgpu.gttsize` is your RAM in MiB minus 4096, and `ttm.pages_limit` is that value times 256 (4 KiB pages). After rebooting, `/sys/class/drm/card*/device/mem_info_vram_total` reads 512 MiB and `mem_info_gtt_total` about your RAM minus 4 GiB.

With a GTT limit well below RAM, Gufo still runs, but its RAM cache cannot borrow session memory that has not been used yet. See Gufo's [memory settings](https://github.com/gufo-org/gufo/blob/main/docs/install.md#memory-settings).

---

## 2. Device Permissions and User Groups

Ensure your host user account belongs to the required hardware access groups:

```bash
sudo usermod -aG video,render $USER
```

Verify device existence:
```bash
# GPU ROCm / KFD interface
ls -l /dev/kfd /dev/dri/renderD* /dev/accel/accel0

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

Log out and back in (or reboot) so the systemd user manager picks it up, then check what a service gets:

```bash
systemd-run --user --wait --pipe sh -c 'ulimit -l'   # unlimited
```

With systemd's default of 8 MiB, Gufo still runs, but its GPU-visible host buffers fall back to memory the kernel may move, and GPU work can stall for seconds while it compacts memory.

---

## 4. Power Profiles

For sustained LLM inference on Strix Halo laptops or mini PCs, switch power profiles to `throughput-performance`:

```bash
sudo tuned-adm profile throughput-performance
```
*(Or install the provided `systemd/gpu-workload-watch` service to automate this on GPU activity).*
