{
  description = "Gufo OCI images for Docker and Podman on AMD Strix Halo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gufo-engine.url = "github:gufo-org/gufo";
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
      # Older engine pins expose ROCm 10.1 as rocm10; newer pins use default.
      # Build both image variants from the same engine/toolchain selection.
      engines = forAllSystems (system:
        let
          upstream = gufo-engine.packages.${system};
          engine = upstream.rocm10 or upstream.default;
        in
        assert nixpkgs.lib.versions.majorMinor engine.toolchain.rocmVersion == "10.1";
        {
          default = engine;
          release = engine.override { releaseVersion = gufo-engine.lib.releaseVersion; };
        });
      pkgs = forAllSystems (system: import nixpkgs {
        inherit system;
        overlays = [ (_final: _prev: {
          rocmPackages = engines.${system}.default.rocmPackages;
        }) ];
      });
      containerUid = 1000;
      containerGid = 1000;
      containerUser = "${toString containerUid}:${toString containerGid}";
      toolboxesRevision = self.rev or self.dirtyRev or "unknown";
      gufoRevision = gufo-engine.rev or "unknown";
      # Use the source timestamp instead of dockerTools' epoch default, while
      # keeping image metadata reproducible for a given source revision.
      sourceDate = self.lastModifiedDate;
      datePart = offset: length: builtins.substring offset length sourceDate;
      imageCreated = "${datePart 0 4}-${datePart 4 2}-${datePart 6 2}T${datePart 8 2}:${datePart 10 2}:${datePart 12 2}Z";
      imageMetadata = version: {
        imageTag = version;
        imageLabels = {
          "org.opencontainers.image.created" = imageCreated;
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

      gpuEnv =
        system:
        commonEnv system
        ++ [
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
              imageCreated
              ociFilesystemCommands
              ;
            commonRuntimePkgs = commonRuntimePkgs system;
          };
          modules = variant: image: engine: [
            (import ./nix/gufo-runtime.nix (
              shared
              // image
              // {
                inherit engine commonArchiveOwnershipCommands variant;
                gpuEnv = gpuEnv system;
              }
            ))
            (import ./nix/gufo-dev.nix (
              shared
              // image
              // {
                inherit engine commonArchiveOwnershipCommands variant;
                gpuEnv = gpuEnv system;
              }
            ))
          ];
        in
        modules null edgeImage engines.${system}.default
        ++ modules "release" releaseImage engines.${system}.release
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
