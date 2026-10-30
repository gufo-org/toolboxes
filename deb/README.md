# Debian releases

The stable release workflow builds `gufo_<version>-1_amd64.deb` and its SHA-256
checksum from the exact Gufo release tag, tests installation and removal in a
fresh Debian container, and attaches both files to that release in
`gufo-org/gufo`. Publishing uses the same GitHub App as the Windows release.
For a manual Debian-only release, run `Publish Stable Gufo Releases` with
`tag=vX.Y.Z` and `deb-only=true`. To replace existing Debian assets explicitly,
also set `replace-deb-assets=true`. Windows and OCI jobs are skipped in this mode.
Existing release assets are never overwritten automatically.

The package targets Debian 13 (trixie), amd64, and AMD Strix Halo (gfx1151).
It contains the executable, upstream-installed runtime data, and licenses.
It starts no service, downloads no models, and requires no Nix installation.

The native build uses AMD's ROCm 10.1 Debian 13 packages, including the
`gfx1151` BLAS kernel libraries. The builder installs the missing header-only
libraries from the pinned upstream 10.1 source release. It does not include the additional ROCr patch
applied by the Nix build, so it is not identical to the OCI runtime.

## Build and verify locally

```sh
docker build --target builder -t gufo-deb-builder -f deb/Dockerfile deb
docker build --target runtime -t gufo-deb-runtime -f deb/Dockerfile deb
mkdir -p /tmp/gufo-deb-release
docker run --rm --memory 12g --memory-swap 12g -v "$PWD:/work:ro" -v /tmp/gufo-deb-release:/out \
  gufo-deb-builder deb/build-deb v0.27.0 /out
docker run --rm -v "$PWD:/work:ro" -v /tmp/gufo-deb-release:/out:ro gufo-deb-runtime \
  deb/verify-deb /out/gufo_0.27.0-1_amd64.deb 0.27.0
```

The builder defaults to two compiler jobs; pass `-e JOBS=...` to change it.

## Installation

Configure AMD's ROCm apt repository before installing: the package declares
ROCm runtime dependencies rather than bundling them. See the `base` stage in
`Dockerfile` for the repository and signing-key configuration used by the build.
Then run `sudo apt install ./gufo_<version>-1_amd64.deb` and start Gufo manually.

The files here have four responsibilities: `Dockerfile` defines the build and
clean test environments, `build-deb` builds and packages a release,
`verify-deb` checks the installed artifact, and this README documents usage.
Release dispatch and publishing remain in the existing stable release workflow.
