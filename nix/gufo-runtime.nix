{
  p,
  engine,
  commonRuntimePkgs,
  ociFilesystemCommands,
  commonArchiveOwnershipCommands,
  containerUser,
  gpuEnv,
  imageTag,
  imageCreated,
  imageLabels,
  variant ? null,
}:
let
  packageSuffix = if variant == null then "" else "-${variant}";
  # The extension SDK (gufo-org/gufo#1075) pins the engine's toolchain, so
  # `gufo extension install` can build modules inside the image. Older engine
  # pins have no `sdk` output.
  sdk = engine.sdk or null;
  imageArgs = {
    name = "ghcr.io/gufo-org/toolboxes/gufo-runtime";
    tag = imageTag;
    created = imageCreated;
    contents = [
      engine
      p.radeontop
    ]
    ++ p.lib.optionals (sdk != null) [
      sdk
      p.git
    ]
    ++ commonRuntimePkgs;
    extraCommands = ociFilesystemCommands;
    fakeRootCommands = commonArchiveOwnershipCommands;
    config = {
      Labels = imageLabels;
      Env = gpuEnv ++ p.lib.optional (sdk != null) "GUFO_SDK_DIR=${sdk}/lib/gufo/sdk";
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
