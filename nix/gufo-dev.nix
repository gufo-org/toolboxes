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

  # Gufo's hosted PR check configures CMake with these inputs plus the shared
  # libraries it finds with find_package(). The published image carried only the
  # runtime outputs of those libraries, so configuring a source tree inside it
  # stopped at "No CMAKE_CXX_COMPILER could be found" and then at
  # find_package(ICU REQUIRED). Adding them lets a contributor build and test
  # Gufo on a host with no Nix install. If this image is meant to stay a
  # runtime and profiling image, the same lists would be better placed in a
  # separate build image.
  buildPackages = [
    p.stdenv.cc
    p.pkg-config
    p.python3
    p.ccache
    p.diffutils
  ];
  libraryPackages = [
    p.icu
    p.curl
    p.openssl
    p.libpng
    p.libjpeg
  ];
  libraryDevPackages = map p.lib.getDev libraryPackages;

  # Nix exports these search paths through per-package setup hooks, which run in
  # `nix build` and `nix develop` but never inside a started container. The
  # equivalent paths are baked into the image configuration instead.
  buildEnv = [
    "CMAKE_PREFIX_PATH=${p.lib.concatMapStringsSep ":" (drv: "${drv}") libraryDevPackages}"
    "CPATH=${p.lib.makeSearchPath "include" libraryDevPackages}"
    "LIBRARY_PATH=${p.lib.makeSearchPath "lib" (libraryPackages ++ libraryDevPackages)}"
    "PKG_CONFIG_PATH=${p.lib.makeSearchPath "lib/pkgconfig" (libraryPackages ++ libraryDevPackages)}"
  ];

  imageArgs = {
    name = "ghcr.io/gufo-org/toolboxes/gufo-dev";
    tag = imageTag;
    contents = [
      engine
      p.radeontop
      p.git
      p.cmake
      p.ninja
      p.gdb
      p.clang-tools
      p.rocmPackages.rocprofiler-sdk
      p.rocmPackages.clr
      p.rocmPackages.hipblas
      p.rocmPackages.hipblaslt
      p.rocmPackages.hipcub
      p.rocmPackages.rocprim
      p.rocmPackages.rocwmma
    ]
    ++ buildPackages
    ++ libraryPackages
    ++ libraryDevPackages
    ++ commonRuntimePkgs;
    extraCommands = ociFilesystemCommands;
    fakeRootCommands = commonArchiveOwnershipCommands;
    config = {
      Labels = imageLabels;
      Env = gpuEnv ++ buildEnv ++ [
        # nixpkgs ships the device-library path in clr's setup-hook, which only
        # runs inside nix builds; hipcc in the image needs it from the env.
        "HIP_DEVICE_LIB_PATH=${p.rocmPackages.rocm-device-libs}/amdgcn/bitcode"
        "GUFO_HIPCUB_ROOT=${p.rocmPackages.hipcub}"
        "GUFO_ROCPRIM_ROOT=${p.rocmPackages.rocprim}"
        "GUFO_ROCWMMA_ROOT=${p.rocmPackages.rocwmma}"
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
