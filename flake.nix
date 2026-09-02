{
  description = "Gufo OCI images for Docker and Podman on AMD Strix Halo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gufo-engine.url = "git+ssh://git@github.com/gufo-org/gufo.git";
    eval-agent = {
      url = "git+ssh://git@github.com/gufo-org/eval-agent.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      gufo-engine,
      eval-agent,
    }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgs = forAllSystems (system: import nixpkgs { inherit system; });
      containerUid = 1000;
      containerGid = 1000;
      containerUser = "${toString containerUid}:${toString containerGid}";

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

      evalArchiveOwnershipCommands = commonArchiveOwnershipCommands + ''
        chown ${toString containerUid}:${toString containerGid} nix/store
        chown -R ${toString containerUid}:${toString containerGid} nix/var/nix
      '';

      commonEnv = [
        "PATH=/bin:/usr/bin:/usr/local/bin"
        "LANG=en_US.UTF-8"
        "LC_ALL=en_US.UTF-8"
        "HOME=/home/gufo"
        "USER=gufo"
        "NIX_REMOTE=local"
        "NIX_PAGER=cat"
      ];

      gpuEnv = system: commonEnv ++ [
        "ROCM_PATH=${pkgs.${system}.rocmPackages.clr}"
        "HIP_PLATFORM=amd"
      ];

      imageModules = forAllSystems (
        system:
        let
          p = pkgs.${system};
          engine = gufo-engine.packages.${system}.default;
          evaluationAgent = eval-agent.packages.${system}.default;
          shared = {
            inherit
              p
              containerUser
              ociFilesystemCommands
              ;
            commonRuntimePkgs = commonRuntimePkgs system;
          };
        in
        [
          (import ./nix/gufo-runtime.nix (shared // {
            inherit engine commonArchiveOwnershipCommands;
            gpuEnv = gpuEnv system;
          }))
          (import ./nix/gufo-dev.nix (shared // {
            inherit engine commonArchiveOwnershipCommands;
            gpuEnv = gpuEnv system;
          }))
          (import ./nix/eval-agent.nix (shared // {
            inherit evaluationAgent evalArchiveOwnershipCommands commonEnv;
          }))
          (import ./nix/gufo-eval-agent.nix (shared // {
            inherit engine evaluationAgent evalArchiveOwnershipCommands;
            gpuEnv = gpuEnv system;
          }))
        ]
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
