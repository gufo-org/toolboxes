{
  description = "Gufo OCI images for Docker and Podman on AMD Strix Halo";

  inputs = {
    gufo-engine.url = "github:gufo-org/gufo";
    # One nixpkgs per image. Resolving the root input independently put a
    # second ROCm, a second clang and a second glibc next to the closure that
    # built the shipped binary, so the development image's cmake, ninja,
    # clang-tools and rocmPackages were not the ones Gufo builds with.
    nixpkgs.follows = "gufo-engine/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      gufo-engine,
    }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgs = forAllSystems (system: import nixpkgs { inherit system; });
      containerUid = 1000;
      containerGid = 1000;
      containerUser = "${toString containerUid}:${toString containerGid}";
      toolboxesRevision = self.rev or self.dirtyRev or "unknown";
      gufoRevision = gufo-engine.rev or "unknown";
      imageMetadata = version: {
        imageTag = version;
        imageLabels = {
          "org.opencontainers.image.version" = version;
          "org.opencontainers.image.revision" = toolboxesRevision;
          "org.opencontainers.image.source" = "https://github.com/gufo-org/toolboxes";
          "org.gufo.engine.revision" = gufoRevision;
        };
      };
      edgeImage = imageMetadata "edge";
      releaseImage = imageMetadata gufo-engine.lib.releaseVersion;

      commonRuntimePkgs =
        system:
        let
          p = pkgs.${system};
        in
        [
          p.bashInteractive
          p.coreutils
          p.findutils
          p.gnugrep
          p.gnused
          p.gawk
          p.procps
          p.glibcLocales
          p.cacert
          p.which
          p.curl
          p.jq
          p.less
          p.ncurses
        ];

      # Minimal conventional filesystem around the immutable Nix closures.
      ociFilesystemCommands = ''
        mkdir -p bin usr/bin usr/lib tmp etc var/tmp var/log home/gufo nix/store
        chmod 1777 tmp var/tmp

        ln -sf /bin/bash bin/sh
        ln -sf /bin/bash usr/bin/sh
        ln -sf /bin/env usr/bin/env

        if [ -f bin/gufo ]; then
          ln -sf gufo bin/strix
        fi

        cat > etc/passwd << 'EOF'
        root:x:0:0:root:/root:/bin/bash
        gufo:x:${toString containerUid}:${toString containerGid}:Gufo:/home/gufo:/bin/bash
        nobody:x:65534:65534:Nobody:/:/bin/false
        EOF

        cat > etc/group << 'EOF'
        root:x:0:
        gufo:x:${toString containerGid}:
        video:x:44:gufo
        render:x:107:gufo
        nogroup:x:65534:
        EOF

        cat > etc/os-release << 'EOF'
        NAME="Gufo OCI Image"
        ID=gufo
        VERSION_ID="1.0"
        PRETTY_NAME="Gufo Docker/Podman Image (gfx1151 + XDNA2)"
        HOME_URL="https://github.com/gufo-org/toolboxes"
        SUPPORT_URL="https://github.com/gufo-org/toolboxes/issues"
        BUG_REPORT_URL="https://github.com/gufo-org/toolboxes/issues"
        EOF
        ln -sf ../etc/os-release usr/lib/os-release
      '';

      # dockerTools applies these to archive metadata under fakeroot. They are
      # never executed by a running container and grant no runtime privilege.
      commonArchiveOwnershipCommands = ''
        chown -R ${toString containerUid}:${toString containerGid} home/gufo
      '';

      commonEnv = system: [
        "PATH=/bin:/usr/bin:/usr/local/bin"
        "LANG=en_US.UTF-8"
        "LC_ALL=en_US.UTF-8"
        # glibcLocales carries the archive; without this pointer the images
        # ship a locale they cannot load and every shell warns about it.
        "LOCALE_ARCHIVE=${pkgs.${system}.glibcLocales}/lib/locale/locale-archive"
        "HOME=/home/gufo"
        "USER=gufo"
        "NIX_REMOTE=local"
        "NIX_PAGER=cat"
      ];

      gpuEnv = system: commonEnv system ++ [
        "ROCM_PATH=${pkgs.${system}.rocmPackages.clr}"
        "HIP_PLATFORM=amd"
      ];

      imageModules = forAllSystems (
        system:
        let
          p = pkgs.${system};
          shared = {
            inherit
              p
              containerUser
              ociFilesystemCommands
              ;
            commonRuntimePkgs = commonRuntimePkgs system;
          };
          modules =
            variant: image: engine:
            [
              (import ./nix/gufo-runtime.nix (shared // image // {
                inherit engine commonArchiveOwnershipCommands variant;
                gpuEnv = gpuEnv system;
              }))
              (import ./nix/gufo-dev.nix (shared // image // {
                inherit engine commonArchiveOwnershipCommands variant;
                gpuEnv = gpuEnv system;
              }))
            ];
        in
        modules null edgeImage gufo-engine.packages.${system}.default
        ++ modules "release" releaseImage gufo-engine.packages.${system}.release
      );
    in
    {
      packages = forAllSystems (
        system:
        nixpkgs.lib.mergeAttrsList (map (module: module.packages) imageModules.${system})
        // {
          default = self.packages.${system}.gufo-runtime-image;
        }
      );

      apps = forAllSystems (
        system: nixpkgs.lib.mergeAttrsList (map (module: module.apps) imageModules.${system})
      );
    };
}
