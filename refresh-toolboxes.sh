#!/usr/bin/env bash
set -euo pipefail

# Pull the published Gufo OCI images with Podman (preferred) or Docker.

declare -A IMAGES
IMAGES["gufo-runtime"]="ghcr.io/gufo-org/toolboxes/gufo-runtime:latest"
IMAGES["gufo-dev"]="ghcr.io/gufo-org/toolboxes/gufo-dev:latest"
IMAGES["eval-agent"]="ghcr.io/gufo-org/toolboxes/eval-agent:latest"
IMAGES["gufo-eval-agent"]="ghcr.io/gufo-org/toolboxes/gufo-eval-agent:latest"

usage() {
  cat <<EOF
Usage: $0 [all|gufo-runtime|gufo-dev|eval-agent|gufo-eval-agent]

Pull Gufo images with Podman or Docker. This repository does not support
Toolbx or Distrobox; run images directly with your container engine.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

target="$1"
selected_images=()
if [[ "$target" == "all" ]]; then
  selected_images=("gufo-runtime" "gufo-dev" "eval-agent" "gufo-eval-agent")
elif [[ -v IMAGES["$target"] ]]; then
  selected_images=("$target")
else
  echo "Unknown image: $target" >&2
  usage >&2
  exit 2
fi

if command -v podman >/dev/null 2>&1; then
  container_engine="podman"
elif command -v docker >/dev/null 2>&1; then
  container_engine="docker"
else
  echo "Neither Podman nor Docker is installed." >&2
  exit 1
fi

for image_name in "${selected_images[@]}"; do
  image_ref="${IMAGES[$image_name]}"
  echo "Pulling $image_ref with $container_engine..."
  "$container_engine" pull "$image_ref"
done

echo "Pulled ${#selected_images[@]} image(s). See README.md for run commands."
