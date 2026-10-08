{
  p,
  engine,
  commonRuntimePkgs,
  ociFilesystemCommands,
  commonArchiveOwnershipCommands,
  containerUser,
  gpuEnv,
  imageTag,
  imageLabels,
  variant ? null,
}:
let
  packageSuffix = if variant == null then "" else "-${variant}";

  # ccache enters the image as its plain binary only. The package also ships
  # cc, c++, gcc and g++ masquerade symlinks, which would collide with the
  # compiler wrapper once dockerTools flattens the image contents.
  ccacheBin = p.runCommand "gufo-dev-ccache-bin" { } ''
    mkdir -p $out/bin
    ln -s ${p.ccache}/bin/ccache $out/bin/ccache
  '';

  # Gufo's CMake build discovers everything below through find_package,
  # find_path or find_program: a host C and C++ compiler with pkg-config, the
  # interpreter the test presets require, the compiler cache, and the
  # development outputs of every library it links against. zlib is not a
  # direct Gufo dependency: CMake's FindPNG searches for it, and a runtime
  # closure never carries its development output. The runtime image ships
  # shared objects only, so this set stays in the development image.
  hostBuildPackages = [
    p.stdenv.cc
    p.pkg-config
    ccacheBin
    p.icu
    p.curl
    p.openssl
    p.zlib
    p.libpng
    p.libjpeg
    p.libwebp
  ];

  rocmBuildPackages = [
    p.rocmPackages.clr
    p.rocmPackages.hipblas
    p.rocmPackages.hipblas-common
    p.rocmPackages.hipblaslt
    p.rocmPackages.rocblas
    p.rocmPackages.hipcub
    p.rocmPackages.rocprim
    p.rocmPackages.rocwmma
    p.rocmPackages.rocprofiler-register
    p.rocmPackages.rocprofiler-sdk
  ];

  # Development tools that belong on PATH but not in the dependency search
  # paths: GNU make for generators other than Ninja, ffmpeg and ffprobe because
  # a source build keeps the bare command names, and a Python with numpy for the
  # CTest-driven reference comparisons. python3 alone is not enough: three of
  # the tests CMake registers import numpy.
  devTools = [
    p.gnumake
    p.ffmpeg-headless
    (p.python3.withPackages (ps: [ ps.numpy ]))
  ];

  # Transitive CMake configuration providers: hip-config-amd.cmake searches for
  # AMDDeviceLibs, amd_comgr and hsa-runtime64, the HSA runtime configuration
  # searches for LibElf, and the rocprofiler-sdk configuration searches for
  # libdw. All of them are already in the image closure as dependencies; this
  # list only puts their cmake directories on the search path.
  rocmTransitives = [
    p.rocmPackages.rocm-device-libs
    p.rocmPackages.rocm-comgr
    p.rocmPackages.rocm-runtime
    p.elfutils
  ];

  buildPackages = hostBuildPackages ++ rocmBuildPackages ++ rocmTransitives;

  # A Nix image has no /opt/rocm and no system /usr/include, so every output
  # that carries headers or libraries has to be in the closure and named in
  # CMAKE_PREFIX_PATH: CMake's find_package, find_path and find_library use
  # that prefix as their search channel.
  buildOutputs =
    (map p.lib.getDev buildPackages) ++ (map p.lib.getLib buildPackages);

  cmakePrefixPath = p.lib.concatMapStringsSep ":" (
    pkg: "${p.lib.getDev pkg}:${p.lib.getLib pkg}"
  ) buildPackages;

  # pkg_check_modules reads only PKG_CONFIG_PATH, because the pkg-config
  # wrapper's built-in search directory belongs to its own store path. Gufo
  # queries one module directly, libwebp; the rest are the .pc providers for
  # its other dependencies. curl stays out of this list on purpose: its
  # libcurl.pc would drag its own Requires chain into every pkg-config probe,
  # while FindCURL resolves curl through CMAKE_PREFIX_PATH regardless. Because
  # FindPkgConfig also mirrors that prefix into pkg-config's search path,
  # configure still prints a few informational "required by 'libcurl', not
  # found" lines; they are harmless, and CMake's FindCURL succeeds.
  pkgConfigPackages = [
    p.libwebp
    p.icu
    p.openssl
    p.zlib
    p.libpng
    p.libjpeg
  ];

  pkgConfigPath = p.lib.concatMapStringsSep ":" (
    pkg: "${p.lib.getDev pkg}/lib/pkgconfig:${pkg}/share/pkgconfig"
  ) pkgConfigPackages;

  imageArgs = {
    name = "ghcr.io/gufo-org/toolboxes/gufo-dev";
    tag = imageTag;
    contents = [
      engine
      p.radeontop
      p.git
      p.jujutsu
      p.ripgrep
      p.cmake
      p.ninja
      p.gdb
      p.clang-tools
    ] ++ devTools ++ buildOutputs ++ commonRuntimePkgs;
    extraCommands = ociFilesystemCommands;
    fakeRootCommands = commonArchiveOwnershipCommands;
    config = {
      Labels = imageLabels;
      Env = gpuEnv ++ [
        # nixpkgs ships the device-library path in clr's setup-hook, which only
        # runs inside nix builds; hipcc in the image needs it from the env.
        "HIP_DEVICE_LIB_PATH=${p.rocmPackages.rocm-device-libs}/amdgcn/bitcode"
        # The compiler wrapper reads its crt and link flags from this path in
        # place of the stdenv setup hook, which never runs in a running image.
        "NIX_CC=${p.stdenv.cc}"
        # Replaces the former GUFO_HIPCUB_ROOT, GUFO_ROCPRIM_ROOT and
        # GUFO_ROCWMMA_ROOT entries, which no build in either repository read.
        "CMAKE_PREFIX_PATH=${cmakePrefixPath}"
        "PKG_CONFIG_PATH=${pkgConfigPath}"
      ];
      Cmd = [ "/bin/bash" ];
      User = containerUser;
      WorkingDir = "/home/gufo";
    };
  };

  image = p.dockerTools.buildLayeredImage imageArgs;
  stream = p.dockerTools.streamLayeredImage imageArgs;
in
{
  packages = {
    "gufo-dev${packageSuffix}-image" = image;
    "stream-gufo-dev${packageSuffix}" = stream;
  };

  apps."stream-gufo-dev${packageSuffix}" = {
    type = "app";
    program = "${stream}";
  };
}
