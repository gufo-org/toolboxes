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
    name = "ghcr.io/gufo-org/toolboxes/gufo-runtime";
    tag = "latest";
    contents = [
      engine
      p.radeontop
    ] ++ commonRuntimePkgs;
    extraCommands = ociFilesystemCommands;
    fakeRootCommands = commonArchiveOwnershipCommands;
    config = {
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/gufo-org/toolboxes";
      };
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
    gufo-runtime-image = image;
    stream-gufo-runtime = stream;
  };

  apps.stream-gufo-runtime = {
    type = "app";
    program = "${stream}";
  };
}
