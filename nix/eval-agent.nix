{
  p,
  evaluationAgent,
  commonRuntimePkgs,
  ociFilesystemCommands,
  evalArchiveOwnershipCommands,
  containerUser,
  commonEnv,
}:
let
  imageArgs = {
    name = "ghcr.io/gufo-org/toolboxes/eval-agent";
    tag = "latest";
    contents = [
      evaluationAgent
      p.nix
    ] ++ commonRuntimePkgs;
    extraCommands = ociFilesystemCommands;
    fakeRootCommands = evalArchiveOwnershipCommands;
    config = {
      Env = commonEnv;
      Cmd = [ "/bin/bash" ];
      User = containerUser;
      WorkingDir = "/home/gufo";
    };
  };

  image = p.dockerTools.buildLayeredImageWithNixDb imageArgs;
  stream = p.dockerTools.streamLayeredImage (imageArgs // { includeNixDB = true; });
in
{
  packages = {
    eval-agent-image = image;
    stream-eval-agent = stream;
  };

  apps.stream-eval-agent = {
    type = "app";
    program = "${stream}";
  };
}
