# Builder image for the gufo .deb lane.
#
# Two things this image is for: compiling the engine with the ROCm headers it needs, and
# hosting the lifecycle test (real dpkg, real systemd) so the upgrade path is proven against the
# tools that will actually run it rather than against stubs.
#
# The ROCm apt line below is the same line deb/common/gufo-rocm-repo.postinst writes on a
# Debian trixie host — AMD publishes Ubuntu suites only, and trixie maps to noble. The list of
# -dev packages is deliberately LONGER than the runtime dependency list in deb/common/control:
# a builder needs headers the installed service never does. Keep the two in step by hand when
# either changes; that coupling is the price of a build environment that is not the runtime.
#
#   docker build -t gufo-deb-builder -f deb/debian-trixie.Dockerfile deb
#   docker run --rm -v "$PWD/../gufo:/src" -w /src gufo-deb-builder dpkg-buildpackage -b -us -uc
#
# Or let deb/build-deb do both, with --in-container.

ARG APT_IMAGE=debian:trixie
FROM ${APT_IMAGE}

ARG ROCM_SERIES=7.2.4
ARG ROCM_SUITE=noble
ARG DEBIAN_FRONTEND=noninteractive

ENV ROCM_PATH=/opt/rocm \
    HIP_PLATFORM=amd

COPY rocm.gpg /usr/share/keyrings/rocm.gpg
RUN chmod 0644 /usr/share/keyrings/rocm.gpg

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        debhelper dpkg-dev lintian devscripts \
        build-essential cmake ninja-build pkg-config python3 git \
        libicu-dev libcurl4-openssl-dev libssl-dev \
        libpng-dev libjpeg-dev libwebp-dev \
        systemd systemd-container \
    && rm -rf /var/lib/apt/lists/*

RUN echo "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_SERIES} ${ROCM_SUITE} main" \
         > /etc/apt/sources.list.d/rocm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        hip-dev rocm-llvm hipblas-dev hipblaslt-dev rocblas-dev \
        hipcub-dev rocprim-dev rocwmma-dev \
    && rm -rf /var/lib/apt/lists/*

# No architecture is pinned here on purpose. The engine enforces its own target in
# CMakeLists.txt (`Gufo requires Linux x86-64 with an AMD gfx1151 GPU', a FATAL_ERROR, plus the
# ENGINE_ENABLE_HIP option), and the HIP architecture is set by the presets the packaging calls
# through debian/rules. A builder that repeats the constant elsewhere is a second place to be
# wrong, and the second place is always the one that drifts.
WORKDIR /src
CMD ["dpkg-buildpackage", "-b", "-us", "-uc"]
