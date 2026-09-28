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
    name = "ghcr.io/gufo-org/toolboxes/gufo-runtime";
    tag = imageTag;
    contents = [
      engine
      p.radeontop
    ] ++ commonRuntimePkgs;
    extraCommands = ociFilesystemCommands;
    fakeRootCommands = commonArchiveOwnershipCommands;
    config = {
      Labels = imageLabels;
      Env = gpuEnv;
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
    "gufo-runtime${packageSuffix}-image" = image;
    "stream-gufo-runtime${packageSuffix}" = stream;
  };

  apps."stream-gufo-runtime${packageSuffix}" = {
    type = "app";
    program = "${stream}";
  };
}
