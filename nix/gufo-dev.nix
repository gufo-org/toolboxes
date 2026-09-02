{
  p,
  engine,
  commonRuntimePkgs,
  ociFilesystemCommands,
  commonArchiveOwnershipCommands,
  containerUser,
  gpuEnv,
}:
let
  imageArgs = {
    name = "ghcr.io/gufo-org/toolboxes/gufo-dev";
    tag = "latest";
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
      Env = gpuEnv ++ [
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
    gufo-dev-image = image;
    stream-gufo-dev = stream;
  };

  apps.stream-gufo-dev = {
    type = "app";
    program = "${stream}";
  };
}
