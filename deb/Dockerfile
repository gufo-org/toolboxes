# Native Debian build using AMD's ROCm 10.1 packages.
FROM debian:trixie AS base
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && install -d /etc/apt/keyrings \
    && curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg \
    && printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://stable.repo.amd.com/rocm/core/packages/debian13/ stable main\n' > /etc/apt/sources.list.d/amdrocm.list \
    && rm -rf /var/lib/apt/lists/*

# XRT and its amdxdna plugin for the NPU runtime, built with xdna-driver's own
# scripts at the pair Gufo's Nix build pins (.devops/nix/xrt): xdna-driver
# main and the XRT commit it carries as a submodule.
FROM base AS xrt
ARG XDNA_DRIVER_REV=010b7d2fbcb10b5412cdf829e0a53728f43de01d
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git pkg-config python3 sudo file \
    && rm -rf /var/lib/apt/lists/*
RUN git init /src/xdna-driver \
    && git -C /src/xdna-driver remote add origin https://github.com/amd/xdna-driver.git \
    && git -C /src/xdna-driver fetch --depth 1 origin "$XDNA_DRIVER_REV" \
    && git -C /src/xdna-driver checkout FETCH_HEAD \
    && git -C /src/xdna-driver submodule update --init --recursive --depth 1 xrt vtd
# As in the Nix build: populate the 64 MiB device heap instead of locking it,
# so the NPU needs no raised memlock limit.
RUN sed -i 's/MAP_SHARED | MAP_LOCKED | flags/MAP_SHARED | MAP_POPULATE | flags/' \
      /src/xdna-driver/src/shim/buffer.cpp \
    && grep -q 'MAP_SHARED | MAP_POPULATE | flags' /src/xdna-driver/src/shim/buffer.cpp
# -docker: skip kernel headers for the build host's kernel, which Debian need
# not package (the package builds no kernel module).
RUN apt-get update \
    && /src/xdna-driver/xrt/src/runtime_src/tools/scripts/xrtdeps.sh -docker \
    && rm -rf /var/lib/apt/lists/*
RUN cd /src/xdna-driver/xrt/build && ./build.sh -npu -opt -noctest \
    && apt-get update && apt-get install -y --no-install-recommends ./Release/xrt_*.deb \
    && cd /src/xdna-driver/build && ./build.sh -release -nokmod -novxdna \
    && apt-get install -y --no-install-recommends ./Release/xrt_plugin*.deb \
    && rm -rf /var/lib/apt/lists/* /src/xdna-driver/xrt/build/Release /src/xdna-driver/build/Release \
    && test -e /opt/xilinx/xrt/lib/libxrt_driver_xdna.so.2

FROM xrt AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential dpkg-dev cmake ninja-build pkg-config python3 git binutils \
    libicu-dev libcurl4-openssl-dev libssl-dev libpng-dev libjpeg-dev libwebp-dev \
    libsndfile1-dev libsoxr-dev libavformat-dev libavcodec-dev libavutil-dev libswscale-dev \
    amdrocm-runtime-dev10.1 amdrocm-blas-dev10.1 amdrocm-blas10.1-gfx1151 \
    && rm -rf /var/lib/apt/lists/*
ENV PATH="/opt/rocm/core-10.1/bin:/opt/rocm/core-10.1/lib/llvm/bin:${PATH}"
# AMD's Debian SDK omits these header-only libraries. Use the same 10.1
# source release as the existing Nix toolchain and install generated headers.
RUN git init /tmp/rocm-cmake \
    && git -C /tmp/rocm-cmake remote add origin https://github.com/ROCm/rocm-cmake.git \
    && git -C /tmp/rocm-cmake fetch --depth 1 origin 9d46892034841b33d7331f3412aca2a7f3560331 \
    && git -C /tmp/rocm-cmake checkout FETCH_HEAD \
    && cmake -S /tmp/rocm-cmake -B /tmp/cmake-build -DCMAKE_INSTALL_PREFIX=/opt/rocm/core-10.1 \
    && cmake --install /tmp/cmake-build \
    && git init /tmp/rocm-libraries \
    && git -C /tmp/rocm-libraries remote add origin https://github.com/ROCm/rocm-libraries.git \
    && git -C /tmp/rocm-libraries sparse-checkout set projects/rocprim projects/hipcub projects/rocwmma shared \
    && git -C /tmp/rocm-libraries fetch --depth 1 --filter=blob:none origin c7b00f89edef18631f2b405d78e475ddd140459b \
    && git -C /tmp/rocm-libraries checkout FETCH_HEAD \
    && for library in rocprim hipcub rocwmma; do \
         cmake -S "/tmp/rocm-libraries/projects/$library" -B "/tmp/build-$library" -G Ninja \
           -DCMAKE_INSTALL_PREFIX=/opt/rocm/core-10.1 -DCMAKE_PREFIX_PATH=/opt/rocm/core-10.1 \
           -DCMAKE_CXX_COMPILER=/opt/rocm/core-10.1/lib/llvm/bin/clang++ \
           -DCMAKE_HIP_COMPILER_ROCM_ROOT=/opt/rocm/core-10.1 \
           -DROCM_ROOT=/opt/rocm/core-10.1 -DROCM_PATH=/opt/rocm/core-10.1 \
           -DBUILD_TEST=OFF -DBUILD_BENCHMARK=OFF -DROCWMMA_BUILD_TESTS=OFF -DROCWMMA_BUILD_SAMPLES=OFF \
         && cmake --install "/tmp/build-$library" || exit 1; \
       done \
    && rm -rf /tmp/rocm-cmake /tmp/cmake-build /tmp/rocm-libraries /tmp/build-*
# Install rustup without a default toolchain. The release's rust-toolchain.toml
# selects the compiler when build-deb enters the checked-out source directory.
ENV CARGO_HOME=/opt/cargo RUSTUP_HOME=/opt/rustup
ENV PATH="/opt/cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain none --no-modify-path \
    && rm /tmp/rustup-init.sh
WORKDIR /work

FROM base AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends binutils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
