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
    ] ++ commonRuntimePkgs;
    extraCommands = ociFilesystemCommands;
    fakeRootCommands = commonArchiveOwnershipCommands;
    config = {
      Labels = imageLabels;
      Env = gpuEnv ++ [
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
