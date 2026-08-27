{
  description = "Gufo Toolboxes - Reproducible OCI toolboxes for AMD Strix Halo (gfx1151 GPU + XDNA2 NPU)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gufo-engine = {
      url = "git+ssh://git@github.com/francescobozzo/strix-halo.cpp.git";
    };
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

      # Common base packages needed for Toolbx and Distrobox compatibility
      commonToolboxPkgs =
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
          p.shadow
          p.sudo
          p.util-linux
          p.glibcLocales
          p.cacert
          p.radeontop
          p.which
          p.curl
          p.jq
          p.less
          p.ncurses
        ];

      # Common /etc and /bin initialization setup for toolbx/distrobox
      extraSetupCommands =
        system:
        let
          p = pkgs.${system};
        in
        ''
          mkdir -p bin usr/bin usr/sbin usr/lib usr/lib64 tmp etc etc/pam.d var/tmp var/log
          chmod 1777 tmp var/tmp

          # Standard symlinks
          ln -sf /bin/bash bin/sh
          ln -sf /bin/bash usr/bin/sh
          ln -sf /bin/env usr/bin/env

          # Create gufo alias / compatibility wrapper if strix binary is present
          if [ -f bin/strix ]; then
            ln -sf strix bin/gufo
          fi

          # Ensure etc is writable and clean any read-only links from packages
          chmod -R u+w etc 2>/dev/null || true
          rm -f etc/passwd etc/group etc/shadow etc/sudoers etc/os-release

          # Basic /etc files for toolbox user injection & pam
          cat > etc/passwd << 'EOF'
          root:x:0:0:root:/root:/bin/bash
          nobody:x:65534:65534:Nobody:/:/bin/false
          EOF

          cat > etc/group << 'EOF'
          root:x:0:
          video:x:44:
          render:x:107:
          wheel:x:10:
          sudo:x:27:
          users:x:100:
          nogroup:x:65534:
          EOF

          cat > etc/shadow << 'EOF'
          root:!::0:::::
          nobody:!::0:::::
          EOF
          chmod 0640 etc/shadow

          cat > etc/sudoers << 'EOF'
          root ALL=(ALL:ALL) ALL
          %wheel ALL=(ALL:ALL) NOPASSWD: ALL
          %sudo ALL=(ALL:ALL) NOPASSWD: ALL
          EOF
          chmod 0440 etc/sudoers

          # pam.d config for user elevation
          cat > etc/pam.d/other << 'EOF'
          auth        sufficient    pam_permit.so
          account     sufficient    pam_permit.so
          password    sufficient    pam_permit.so
          session     sufficient    pam_permit.so
          EOF

          # os-release to identify as Gufo Toolbox (Toolbx requires ID/NAME)
          cat > etc/os-release << 'EOF'
          NAME="Gufo Toolbox"
          ID=gufo
          ID_LIKE="fedora"
          VERSION_ID="1.0"
          PRETTY_NAME="Gufo Strix Halo Toolbox (gfx1151 + XDNA2)"
          HOME_URL="https://github.com/gufo-org/toolboxes"
          SUPPORT_URL="https://github.com/gufo-org/toolboxes/issues"
          BUG_REPORT_URL="https://github.com/gufo-org/toolboxes/issues"
          EOF
          ln -sf ../etc/os-release usr/lib/os-release
        '';

      commonEnv = system: [
        "PATH=/bin:/usr/bin:/usr/local/bin"
        "LANG=en_US.UTF-8"
        "LC_ALL=en_US.UTF-8"
        "ROCM_PATH=${pkgs.${system}.rocmPackages.clr}"
        "HIP_PLATFORM=amd"
      ];
    in
    {
      packages = forAllSystems (
        system:
        let
          p = pkgs.${system};
          engine = gufo-engine.packages.${system}.default;
        in
        {
          # 1. gufo-runtime: Lightweight serving & inference OCI image
          gufo-runtime-image = p.dockerTools.buildLayeredImage {
            name = "ghcr.io/gufo-org/toolboxes/gufo-runtime";
            tag = "latest";
            contents = [ engine ] ++ (commonToolboxPkgs system);
            extraCommands = extraSetupCommands system;
            config = {
              Env = commonEnv system;
              Cmd = [ "/bin/bash" ];
            };
          };

          # Streamed variant for fast local loading via `nix run .#stream-gufo-runtime | podman load`
          stream-gufo-runtime = p.dockerTools.streamLayeredImage {
            name = "ghcr.io/gufo-org/toolboxes/gufo-runtime";
            tag = "latest";
            contents = [ engine ] ++ (commonToolboxPkgs system);
            extraCommands = extraSetupCommands system;
            config = {
              Env = commonEnv system;
              Cmd = [ "/bin/bash" ];
            };
          };

          # 2. gufo-dev: Development, kernel tuning & profiling OCI image
          gufo-dev-image = p.dockerTools.buildLayeredImage {
            name = "ghcr.io/gufo-org/toolboxes/gufo-dev";
            tag = "latest";
            contents = [
              engine
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
            ] ++ (commonToolboxPkgs system);
            extraCommands = extraSetupCommands system;
            config = {
              Env = commonEnv system ++ [
                "ROCM_PATH=${p.rocmPackages.clr}"
                "STRIX_HIPCUB_ROOT=${p.rocmPackages.hipcub}"
                "STRIX_ROCPRIM_ROOT=${p.rocmPackages.rocprim}"
                "STRIX_ROCWMMA_ROOT=${p.rocmPackages.rocwmma}"
              ];
              Cmd = [ "/bin/bash" ];
            };
          };

          stream-gufo-dev = p.dockerTools.streamLayeredImage {
            name = "ghcr.io/gufo-org/toolboxes/gufo-dev";
            tag = "latest";
            contents = [
              engine
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
            ] ++ (commonToolboxPkgs system);
            extraCommands = extraSetupCommands system;
            config = {
              Env = commonEnv system ++ [
                "ROCM_PATH=${p.rocmPackages.clr}"
                "STRIX_HIPCUB_ROOT=${p.rocmPackages.hipcub}"
                "STRIX_ROCPRIM_ROOT=${p.rocmPackages.rocprim}"
                "STRIX_ROCWMMA_ROOT=${p.rocmPackages.rocwmma}"
              ];
              Cmd = [ "/bin/bash" ];
            };
          };

          default = self.packages.${system}.gufo-runtime-image;
        }
      );

      apps = forAllSystems (
        system:
        let
          p = pkgs.${system};
        in
        {
          stream-gufo-runtime = {
            type = "app";
            program = "${self.packages.${system}.stream-gufo-runtime}";
          };
          stream-gufo-dev = {
            type = "app";
            program = "${self.packages.${system}.stream-gufo-dev}";
          };
        }
      );
    };
}
