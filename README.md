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
| `gufo-runtime` | `ghcr.io/gufo-org/toolboxes/gufo-runtime:edge` | Gufo inference, serving, benchmarks, and diagnostics |
| `gufo-dev` | `ghcr.io/gufo-org/toolboxes/gufo-dev:edge` | Builds Gufo from source, profiling, and kernel tuning |

Stable releases publish immutable `X.Y.Z` tags plus the floating `X.Y` and
`latest` aliases. The rolling `edge` channel follows the Gufo revision pinned
by the daily dependency update and also publishes an immutable
`sha-<full-gufo-revision>` tag. Rolling updates never advance `latest`.

The examples use rootless Podman with `crun`. `--userns=keep-id:uid=1000,gid=1000`
maps the invoking host user to the image's `gufo` account, so writable bind
mounts work without changing their ownership. `--group-add keep-groups` carries
the caller's supplementary GPU groups into the container.

For Docker, omit `--userns=keep-id:uid=1000,gid=1000`, replace
`--group-add keep-groups` with numeric `--group-add` options for the GIDs owning
`/dev/kfd` and the AMD render node, and ensure writable bind mounts permit UID
1000. See [Docker](#docker) for complete commands.

## Pull

```sh
./refresh-toolboxes.sh all

# Or select the stable channel after a Gufo release is published.
./refresh-toolboxes.sh all latest

# Or pull one image directly.
podman pull ghcr.io/gufo-org/toolboxes/gufo-runtime:edge
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
  ghcr.io/gufo-org/toolboxes/gufo-runtime:edge \
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
  ghcr.io/gufo-org/toolboxes/gufo-dev:edge
```

That shell builds Gufo from source. The image carries a host C and C++ compiler,
`pkg-config`, `cmake`, `ninja`, GNU `make`, `python3` with `numpy` for the tests
CMake registers, `ffmpeg` and `ffprobe` for the media path, `gdb`,
`clang-format`, `clang-tidy`, `ccache`, and the development outputs of every
system and ROCm library Gufo discovers with `find_package`. Because a Nix image
has no `/opt/rocm` and no system `/usr/include`, the image configuration exports
`CMAKE_PREFIX_PATH`, `NIX_CC`, `PKG_CONFIG_PATH` and `HIP_DEVICE_LIB_PATH` instead, so
the repository presets configure with no extra flags.

The development tools come from the same nixpkgs that built the `gufo` binary in
the image: the flake follows `gufo-engine/nixpkgs` instead of resolving its own,
so one ROCm, one clang and one glibc are in the closure.

```sh
podman volume create gufo-ccache

podman run --rm -it \
  --userns=keep-id:uid=1000,gid=1000 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ulimit memlock=-1 \
  -v "$PWD:/workspace" -w /workspace \
  -v gufo-ccache:/home/gufo/.cache/ccache \
  ghcr.io/gufo-org/toolboxes/gufo-dev:edge

# Inside the container.
cmake --preset release -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build --preset release --parallel 8
./build/release/gufo diagnose   # reports gfx1151 and the pinned ROCm version
```

Mount `ccache` as a named volume, as above: `~/.cache/ccache` disappears with a
`--rm` container otherwise. On Strix Halo a wiped-tree `gpu-test` rebuild of all
173 registered tests took 112 s cold and 88 s with the cache warm at 313 of 313
C and C++ objects hit: HIP kernels recompile either way, so the cache pays off on
C++ edits and reconfiguration rather than on a full rebuild.

Configure prints eight informational lines about `libidn2` being required by
`libcurl`. CMake's FindPkgConfig mirrors `CMAKE_PREFIX_PATH` into pkg-config's
search path, `libcurl.pc` names requirements whose `.pc` files the image does not
list, and FindCURL resolves curl from that same prefix regardless, so the build is
unaffected. `-DPKG_CONFIG_USE_CMAKE_PREFIX_PATH=OFF` silences the report.

Following `gufo-engine/nixpkgs` also drops the second ROCm, clang and glibc every
image used to carry: measured on Strix Halo the development image is 6.98 GB
against the 10.54 GB published one, compiler, Python, ffmpeg and development
headers included, and the runtime image is 4.39 GB against 5.34 GB.

## Docker

Docker has no `keep-id` user namespace and no `keep-groups`, so pass the
numeric GID that owns the GPU device nodes and make writable bind mounts
accessible to UID 1000:

```sh
gpu_gid=$(stat -c '%g' /dev/kfd)

docker run --rm -it \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add "$gpu_gid" \
  --ulimit memlock=-1 \
  -v /path/to/models:/models:ro \
  ghcr.io/gufo-org/toolboxes/gufo-runtime:edge \
  gufo diagnose
```

`diagnose` should report `gfx1151` and a loaded `amdgpu` driver. Run a prompt
or serve the OpenAI-compatible API with the same flags:

```sh
docker run --rm -it \
  --device /dev/kfd --device /dev/dri --group-add "$gpu_gid" \
  --ulimit memlock=-1 \
  -v /path/to/models:/models:ro \
  ghcr.io/gufo-org/toolboxes/gufo-runtime:edge \
  gufo prompt --model /models/model.gguf --prompt "Hello" --max-tokens 128

docker run --rm -p 8080:8080 \
  --device /dev/kfd --device /dev/dri --group-add "$gpu_gid" \
  --ulimit memlock=-1 \
  -v /path/to/models:/models:ro \
  ghcr.io/gufo-org/toolboxes/gufo-runtime:edge \
  gufo serve --model /models/model.gguf --host 0.0.0.0 --port 8080
```

The served model name comes from the GGUF, not from the file path; read it
from `/v1/models` and send that exact id in chat requests.

Hugging Face cache directories store their GGUFs as symlinks into
`blobs/`, so mount the repository root and reference the model through
`snapshots/<revision>/`. Mounting a snapshot directory alone leaves the
symlinks dangling and the model fails to open:

```sh
docker run --rm \
  --device /dev/kfd --device /dev/dri --group-add "$gpu_gid" \
  --ulimit memlock=-1 \
  -v /path/to/models--org--repo:/models:ro \
  ghcr.io/gufo-org/toolboxes/gufo-runtime:edge \
  gufo prompt --model /models/snapshots/<revision>/model.gguf --prompt "Hello"
```

For the development image, mount the checkout and start the default shell.
`hipcc` and CMake projects using `LANGUAGES HIP` compile for `gfx1151` without
extra flags. The image also carries the complete Gufo build toolchain; see
[Development image](#development-image).

```sh
docker run --rm -it \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add "$gpu_gid" \
  --ulimit memlock=-1 \
  -v "$PWD:/workspace" \
  -w /workspace \
  ghcr.io/gufo-org/toolboxes/gufo-dev:edge
```

Bind mounts written by the container are owned by UID/GID `1000:1000` on the
host, because Docker maps the container user directly.

## Build locally with Nix

```sh
nix run .#stream-gufo-runtime | podman load
nix run .#stream-gufo-dev | podman load

# Docker loads the same streams.
nix run .#stream-gufo-runtime | docker load

nix build .#packages.x86_64-linux.gufo-runtime-image
```

## Host configuration and background serving

- [Host configuration](docs/host-configuration.md)
- [Quick start](docs/quickstart.md)
- [Podman systemd service](docs/systemd.md)

## License

MIT. See [LICENSE](LICENSE).
