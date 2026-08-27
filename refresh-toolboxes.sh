#!/usr/bin/env bash
set -euo pipefail

# Gufo Toolboxes Refresh & Provisioning Script
# Target: AMD Ryzen AI Max "Strix Halo" (gfx1151 GPU + XDNA2 NPU)

declare -A IMAGES
IMAGES["gufo-runtime"]="ghcr.io/gufo-org/toolboxes/gufo-runtime:latest"
IMAGES["gufo-dev"]="ghcr.io/gufo-org/toolboxes/gufo-dev:latest"

FORCE_RECREATE=false

usage() {
  cat << EOF
Usage: $0 [options] [all|gufo-runtime|gufo-dev]

A helper script to create and manage Gufo Toolboxes on AMD Strix Halo.
Requires only Podman/Docker and Toolbox/Distrobox (no Nix required).

Options:
  -f, --force    Remove existing toolbox before recreating
  -h, --help     Show this help message

Available Toolboxes:
  - gufo-runtime  Lightweight inference runtime (gufo serve, prompt, bench, diagnose)
  - gufo-dev      Full development, profiling (rocprofv3), and kernel tuning environment
  - all           Create/refresh both toolboxes

Examples:
  $0 gufo-runtime
  $0 gufo-dev
  $0 -f all
EOF
  exit 1
}

# Parse options
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force)
      FORCE_RECREATE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -lt 1 ]]; then
  usage
fi

TARGET="$1"
SELECTED_TOOLBOXES=()

if [[ "$TARGET" == "all" ]]; then
  SELECTED_TOOLBOXES=("gufo-runtime" "gufo-dev")
elif [[ -v IMAGES["$TARGET"] ]]; then
  SELECTED_TOOLBOXES=("$TARGET")
else
  echo "Error: Unknown target '$TARGET'" >&2
  usage
fi

# Detect container runtime (podman vs docker)
CONTAINER_ENGINE=""
if command -v podman >/dev/null 2>&1; then
  CONTAINER_ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_ENGINE="docker"
else
  echo "Error: Neither 'podman' nor 'docker' is installed." >&2
  exit 1
fi

# Detect toolbox CLI (toolbox vs distrobox vs standalone container engine)
TOOLBOX_CMD=""
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" =~ ^(ubuntu|debian)$ ]] && command -v distrobox >/dev/null 2>&1; then
    TOOLBOX_CMD="distrobox"
  fi
fi

if [[ -z "$TOOLBOX_CMD" ]]; then
  if command -v toolbox >/dev/null 2>&1; then
    TOOLBOX_CMD="toolbox"
  elif command -v distrobox >/dev/null 2>&1; then
    TOOLBOX_CMD="distrobox"
  else
    TOOLBOX_CMD="$CONTAINER_ENGINE"
    echo "ℹ️  Neither 'toolbox' nor 'distrobox' found; using '$CONTAINER_ENGINE' directly."
  fi
fi

# Detect Strix Halo Devices
PASSTHROUGH_ARGS=()

# 1. GPU (gfx1151)
if [[ -e /dev/kfd ]]; then
  PASSTHROUGH_ARGS+=("--device" "/dev/kfd")
else
  echo "⚠️ Warning: /dev/kfd not found. ROCm compute might fail without proper kernel driver." >&2
fi

if [[ -d /dev/dri ]]; then
  PASSTHROUGH_ARGS+=("--device" "/dev/dri")
fi

# 2. XDNA2 NPU (/dev/accel* or /dev/amdxdna)
NPU_FOUND=false
for accel in /dev/accel/accel* /dev/amdxdna; do
  if [[ -e "$accel" ]]; then
    PASSTHROUGH_ARGS+=("--device" "$accel")
    NPU_FOUND=true
  fi
done
if [[ "$NPU_FOUND" = true ]]; then
  echo "⚡ XDNA2 NPU device detected and mapped."
else
  echo "ℹ️  Note: No XDNA2 NPU device (/dev/accel/accel* or /dev/amdxdna) detected."
fi

# 3. Optional RDMA / InfiniBand
if [[ -d /dev/infiniband ]]; then
  echo "⚡ InfiniBand/RoCE devices detected."
  PASSTHROUGH_ARGS+=("--device" "/dev/infiniband" "--group-add" "rdma")
fi

# Permissions and capabilities
PASSTHROUGH_ARGS+=(
  "--group-add" "video"
  "--group-add" "render"
  "--security-opt" "seccomp=unconfined"
  "--ulimit" "memlock=-1"
)

# Process each selected toolbox
for TB in "${SELECTED_TOOLBOXES[@]}"; do
  IMG="${IMAGES[$TB]}"

  echo "=================================================="
  echo "📦 Processing Toolbox: $TB"
  echo "=================================================="

  echo "⬇️  Pulling image $IMG..."
  "$CONTAINER_ENGINE" pull "$IMG" || {
    echo "⚠️ Failed to pull $IMG. Please check your network connection or image tag." >&2
    exit 1
  }

  # Check if container already exists
  CONTAINER_EXISTS=false
  if "$CONTAINER_ENGINE" container exists "$TB" 2>/dev/null || "$CONTAINER_ENGINE" inspect "$TB" >/dev/null 2>&1; then
    CONTAINER_EXISTS=true
  fi

  if [[ "$CONTAINER_EXISTS" = true ]]; then
    if [[ "$FORCE_RECREATE" = true ]]; then
      echo "🗑️  Removing existing container '$TB'..."
      if [[ "$TOOLBOX_CMD" == "distrobox" ]]; then
        distrobox rm -f "$TB"
      else
        toolbox rm -f "$TB"
      fi
    else
      echo "ℹ️  Toolbox '$TB' already exists. Use -f or --force to recreate."
      continue
    fi
  fi

  echo "🚀 Creating toolbox '$TB' using $TOOLBOX_CMD..."
  if [[ "$TOOLBOX_CMD" == "distrobox" ]]; then
    distrobox create \
      --name "$TB" \
      --image "$IMG" \
      --additional-flags "${PASSTHROUGH_ARGS[*]}"
  else
    toolbox create "$TB" \
      --image "$IMG" \
      -- "${PASSTHROUGH_ARGS[@]}"
  fi

  echo "✅ Successfully created '$TB'!"
  echo "👉 Enter with: $TOOLBOX_CMD enter $TB"
done

echo ""
echo "🎉 All requested toolboxes are ready."
