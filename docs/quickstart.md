# Gufo OCI Images Quick Start

These images support Docker and Podman on Linux x86-64. Toolbx and Distrobox
are intentionally unsupported.

## Requirements

- AMD Ryzen AI Max with the `gfx1151` GPU
- Linux kernel 6.18.4 or newer
- Podman or Docker
- `/dev/kfd` and an AMD `/dev/dri/renderD*` node for GPU images
- unprivileged user namespaces for eval-agent's Bubblewrap sandbox

Every container runs as `gufo`, UID/GID `1000:1000`. The Podman examples use
`--userns=keep-id:uid=1000,gid=1000` to map the invoking rootless user to that
account, so writable bind mounts remain usable without changing ownership. Do
not override the image user for evaluation images: their single-user Nix store
is owned by `gufo` so tasks can be realized without sudo or a Nix daemon.

## Choose an image

| Image | Use case |
| :--- | :--- |
| `gufo-runtime` | Inference, model serving, benchmarks, and diagnostics |
| `gufo-dev` | C++/HIP development and profiling |
| `eval-agent` | Evaluate against an existing OpenAI-compatible endpoint |
| `gufo-eval-agent` | Start Gufo and run the evaluator in one container |

Pull all four with:

```sh
./refresh-toolboxes.sh all
```

## GPU permissions

Pass the host device nodes and their numeric group owners to the container:

```sh
--userns=keep-id:uid=1000,gid=1000 \
--device /dev/kfd \
--device /dev/dri \
--group-add keep-groups \
--ulimit memlock=-1
```

`keep-groups` requires Podman's `crun` OCI runtime and carries the caller's
existing supplementary groups into the container.

## Run Gufo

```sh
podman run --rm -it \
  --userns=keep-id:uid=1000,gid=1000 \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add keep-groups \
  --ulimit memlock=-1 \
  -v /path/to/models:/models:ro \
  ghcr.io/gufo-org/toolboxes/gufo-runtime:latest \
  gufo bench --model /models/model.gguf -p 512 -n 128
```

## Evaluate an endpoint

Use host networking when the endpoint listens on the Linux host's loopback
interface. The relaxed seccomp policy permits Bubblewrap to create its nested
sandbox; it does not give the agent unrestricted networking.

```sh
mkdir -p results

podman run --rm -it \
  --userns=keep-id:uid=1000,gid=1000 \
  --network host \
  --security-opt seccomp=unconfined \
  -v "$PWD/results:/results" \
  ghcr.io/gufo-org/toolboxes/eval-agent:latest \
  eval-agent run sparql-university \
    --base-url http://127.0.0.1:8080/v1 \
    --output /results/result.json \
    --platform strix-halo --engine gufo --backend rocm
```

## Start Gufo and evaluate it

```sh
mkdir -p results

podman run --rm -it \
  --userns=keep-id:uid=1000,gid=1000 \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add keep-groups \
  --security-opt seccomp=unconfined \
  --ulimit memlock=-1 \
  -v /path/to/models:/models:ro \
  -v "$PWD/results:/results" \
  ghcr.io/gufo-org/toolboxes/gufo-eval-agent:latest \
  eval-agent-with-gufo --model /models/model.gguf -- \
    run sparql-university \
    --output /results/result.json \
    --platform strix-halo --engine gufo --backend rocm
```

For Docker, omit `--userns=keep-id:uid=1000,gid=1000`, replace
`--group-add keep-groups` with numeric `--group-add` flags for the GIDs owning
the GPU device nodes, and make writable bind mounts accessible to UID 1000.
