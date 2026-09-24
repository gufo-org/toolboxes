# Gufo OCI Images Quick Start

These images support Docker and Podman on Linux x86-64. Toolbx and Distrobox
are intentionally unsupported.

## Requirements

- AMD Ryzen AI Max with the `gfx1151` GPU
- Linux kernel 6.18.4 or newer
- Podman or Docker
- `/dev/kfd` and an AMD `/dev/dri/renderD*` node for GPU images

Every container runs as `gufo`, UID/GID `1000:1000`. The Podman examples use
`--userns=keep-id:uid=1000,gid=1000` to map the invoking rootless user to that
account, so writable bind mounts remain usable without changing ownership.

## Choose an image

| Image | Use case |
| :--- | :--- |
| `gufo-runtime` | Inference, model serving, benchmarks, and diagnostics |
| `gufo-dev` | C++/HIP development and profiling |

Pull both with:

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

Docker supports neither flag. Drop `--userns=keep-id:uid=1000,gid=1000` and
pass the numeric group owner of the device nodes instead:

```sh
gpu_gid=$(stat -c '%g' /dev/kfd)

--device /dev/kfd \
--device /dev/dri \
--group-add "$gpu_gid" \
--ulimit memlock=-1
```

On most hosts `/dev/kfd` and `/dev/dri/renderD*` share one group; check both
with `stat -c '%g'` and pass a `--group-add` for each distinct GID. Writable
bind mounts must be accessible to UID 1000, and files the container creates
are owned by `1000:1000` on the host.

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

For Docker, omit `--userns=keep-id:uid=1000,gid=1000`, replace
`--group-add keep-groups` with numeric `--group-add` flags for the GIDs owning
the GPU device nodes, and make writable bind mounts accessible to UID 1000.
