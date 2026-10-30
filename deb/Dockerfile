# Native Debian build using AMD's ROCm 10.1 packages.
FROM debian:trixie AS base
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && install -d /etc/apt/keyrings \
    && curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg \
    && printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://stable.repo.amd.com/rocm/core/packages/debian13/ stable main\n' > /etc/apt/sources.list.d/amdrocm.list \
    && rm -rf /var/lib/apt/lists/*

FROM base AS builder
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
WORKDIR /work

FROM base AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends binutils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
