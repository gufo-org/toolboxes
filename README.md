# Gufo OCI Images for AMD Strix Halo

[![CI](https://github.com/gufo-org/toolboxes/actions/workflows/build_and_publish.yml/badge.svg)](https://github.com/gufo-org/toolboxes/actions/workflows/build_and_publish.yml)

Reproducible Docker and Podman images for local LLM inference, development,
and serving on AMD Ryzen AI Max (Strix Halo).
Images are built directly from pinned Nix flake derivations for `gfx1151` and
XDNA2.

Toolbx and Distrobox are not supported. The containers run as the dedicated
`gufo` user (UID/GID `1000:1000`) and contain no sudo or PAM stack.

## Images

| Image | Reference | Purpose |
| :--- | :--- | :--- |
| `gufo-runtime` | `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` | Gufo inference, serving, benchmarks, and diagnostics |
| `gufo-dev` | `ghcr.io/gufo-org/toolboxes/gufo-dev:latest` | C++/HIP development, profiling, and kernel tuning |

The examples use rootless Podman with `crun`. `--userns=keep-id:uid=1000,gid=1000`
maps the invoking host user to the image's `gufo` account, so writable bind
mounts work without changing their ownership. `--group-add keep-groups` carries
the caller's supplementary GPU groups into the container.

For Docker, omit `--userns=keep-id:uid=1000,gid=1000`, replace
`--group-add keep-groups` with numeric `--group-add` options for the GIDs owning
`/dev/kfd` and the AMD render node, and ensure writable bind mounts permit UID
1000.

## Pull

```sh
./refresh-toolboxes.sh all

# Or pull one image directly.
podman pull ghcr.io/gufo-org/toolboxes/gufo-runtime:latest
```

## Gufo runtime

The container user needs the supplementary GIDs that own the host GPU device
nodes. On a typical system:

```sh
podman run --rm -it \
  --userns=keep-id:uid=1000,gid=1000 \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add keep-groups \
  --ulimit memlock=-1 \
  -v /path/to/models:/models:ro \
  ghcr.io/gufo-org/toolboxes/gufo-runtime:latest \
  gufo diagnose
```

Replace `renderD128` if the AMD render node has another number. Run a model by
replacing the final command, for example:

```sh
gufo bench --model /models/model.gguf -p 512 -n 128
```

## Development image

Mount a checkout owned by UID 1000 and start the default shell:

```sh
podman run --rm -it \
  --userns=keep-id:uid=1000,gid=1000 \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add keep-groups \
  --ulimit memlock=-1 \
  -v "$PWD:/workspace" \
  -w /workspace \
  ghcr.io/gufo-org/toolboxes/gufo-dev:latest
```

## Build locally with Nix

```sh
nix run .#stream-gufo-runtime | podman load
nix run .#stream-gufo-dev | podman load

nix build .#packages.x86_64-linux.gufo-runtime-image
```

## Host configuration and background serving

- [Host configuration](docs/host-configuration.md)
- [Quick start](docs/quickstart.md)
- [Podman systemd service](docs/systemd.md)

## License

MIT. See [LICENSE](LICENSE).
