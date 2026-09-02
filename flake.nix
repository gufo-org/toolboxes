{
  description = "Gufo Toolboxes - Reproducible OCI toolboxes for AMD Strix Halo (gfx1151 GPU + XDNA2 NPU)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gufo-engine = {
      url = "git+ssh://git@github.com/gufo-org/gufo.git";
    };
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

          # Create legacy compatibility alias if gufo binary is present
          if [ -f bin/gufo ]; then
            ln -sf gufo bin/strix
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
          evaluationAgent = eval-agent.packages.${system}.default;
          evalNixBuild = p.writeShellApplication {
            name = "nix-build";
            runtimeInputs = [
              p.coreutils
              p.sudo
            ];
            text = ''
              if [[ "$(${p.coreutils}/bin/id -u)" == 0 ]] || \
                 [[ -w /nix/store && -w /nix/var/nix/db ]]; then
                exec ${p.nix}/bin/nix-build "$@"
              fi

              if ${p.sudo}/bin/sudo -n ${p.coreutils}/bin/true 2>/dev/null; then
                exec ${p.sudo}/bin/sudo -n \
                  ${p.coreutils}/bin/env \
                  "NIX_PATH=''${NIX_PATH:-}" \
                  USER=root \
                  ${p.nix}/bin/nix-build "$@"
              fi

              echo "nix-build: the toolbox user cannot write /nix and passwordless sudo is unavailable" >&2
              echo "Enter this image through Toolbx/Distrobox, or run the container as root." >&2
              exit 1
            '';
          };
          evalNixTools = p.symlinkJoin {
            name = "eval-agent-nix-tools";
            paths = [ evalNixBuild ];
            postBuild = ''
              ln -s ${p.nix}/bin/nix "$out/bin/nix"
              ln -s ${p.nix}/bin/nix-store "$out/bin/nix-store"
            '';
          };
          evalAgentWithGufo = p.writeShellApplication {
            name = "eval-agent-with-gufo";
            runtimeInputs = [
              engine
              evaluationAgent
              p.curl
            ];
            text = ''
              usage() {
                cat <<'EOF'
              Usage: eval-agent-with-gufo [launcher options] -- <eval-agent arguments>

              Start a local Gufo server, wait until it is ready, run eval-agent,
              then stop the server.

              Launcher options:
                --model PATH         GGUF model to serve (or set GUFO_MODEL)
                --host IP            Gufo bind address (default: 127.0.0.1)
                --port N             Gufo port (default: 8080)
                --context N          Server context size (default: 32768)
                --max-tokens N       Server generation limit (default: 16384)
                --llm-arg ARG        Extra Gufo LLM argument; may be repeated
                -h, --help           Show this help

              Environment:
                GUFO_MODEL, GUFO_HOST, GUFO_PORT, GUFO_CONTEXT,
                GUFO_MAX_TOKENS, GUFO_STARTUP_TIMEOUT, GUFO_EVAL_BASE_URL

              Example:
                eval-agent-with-gufo --model /models/model.gguf -- \
                  run sparql-university --output /results/result.json \
                  --platform strix-halo --engine gufo --backend rocm
              EOF
              }

              need_value() {
                if (( $# < 2 )); then
                  echo "eval-agent-with-gufo: $1 needs a value" >&2
                  exit 2
                fi
              }

              model="''${GUFO_MODEL:-}"
              host="''${GUFO_HOST:-127.0.0.1}"
              port="''${GUFO_PORT:-8080}"
              context="''${GUFO_CONTEXT:-32768}"
              max_tokens="''${GUFO_MAX_TOKENS:-16384}"
              startup_timeout="''${GUFO_STARTUP_TIMEOUT:-600}"
              llm_args=()
              eval_args=()

              while (( $# > 0 )); do
                case "$1" in
                  --model)
                    need_value "$@"
                    model="$2"
                    shift 2
                    ;;
                  --host)
                    need_value "$@"
                    host="$2"
                    shift 2
                    ;;
                  --port)
                    need_value "$@"
                    port="$2"
                    shift 2
                    ;;
                  --context)
                    need_value "$@"
                    context="$2"
                    shift 2
                    ;;
                  --max-tokens)
                    need_value "$@"
                    max_tokens="$2"
                    shift 2
                    ;;
                  --llm-arg)
                    need_value "$@"
                    llm_args+=("$2")
                    shift 2
                    ;;
                  -h|--help)
                    usage
                    exit 0
                    ;;
                  --)
                    shift
                    eval_args=("$@")
                    break
                    ;;
                  *)
                    echo "eval-agent-with-gufo: unknown launcher option: $1" >&2
                    echo "Put eval-agent arguments after --." >&2
                    usage >&2
                    exit 2
                    ;;
                esac
              done

              if [[ -z "$model" ]]; then
                echo "eval-agent-with-gufo: --model or GUFO_MODEL is required" >&2
                exit 2
              fi
              if (( ''${#eval_args[@]} == 0 )); then
                echo "eval-agent-with-gufo: eval-agent arguments are required after --" >&2
                exit 2
              fi
              if [[ ! "$startup_timeout" =~ ^[1-9][0-9]*$ ]]; then
                echo "eval-agent-with-gufo: GUFO_STARTUP_TIMEOUT must be a positive integer" >&2
                exit 2
              fi

              base_url="''${GUFO_EVAL_BASE_URL:-http://127.0.0.1:$port/v1}"
              gufo serve --host "$host" --port "$port" llm \
                --model "$model" --context "$context" --max-tokens "$max_tokens" \
                "''${llm_args[@]}" &
              server_pid=$!

              cleanup() {
                status=$?
                trap - EXIT INT TERM
                if kill -0 "$server_pid" 2>/dev/null; then
                  kill "$server_pid" 2>/dev/null || true
                  wait "$server_pid" 2>/dev/null || true
                fi
                exit "$status"
              }
              trap cleanup EXIT INT TERM

              echo "Waiting up to ''${startup_timeout}s for $base_url/models ..." >&2
              deadline=$((SECONDS + startup_timeout))
              until curl --fail --silent --show-error "$base_url/models" >/dev/null 2>&1; do
                if ! kill -0 "$server_pid" 2>/dev/null; then
                  wait "$server_pid"
                  echo "eval-agent-with-gufo: Gufo exited before becoming ready" >&2
                  exit 1
                fi
                if (( SECONDS >= deadline )); then
                  echo "eval-agent-with-gufo: Gufo did not become ready within ''${startup_timeout}s" >&2
                  exit 1
                fi
                sleep 1
              done

              if [[ "''${eval_args[0]}" == "run" ]]; then
                has_base_url=false
                for arg in "''${eval_args[@]}"; do
                  if [[ "$arg" == "--base-url" || "$arg" == --base-url=* ]]; then
                    has_base_url=true
                    break
                  fi
                done
                if [[ "$has_base_url" == false ]]; then
                  eval_args+=(--base-url "$base_url")
                fi
              fi

              eval-agent "''${eval_args[@]}"
            '';
          };
          evaluationContents = [
            evaluationAgent
            evalNixTools
          ];
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
                "GUFO_HIPCUB_ROOT=${p.rocmPackages.hipcub}"
                "GUFO_ROCPRIM_ROOT=${p.rocmPackages.rocprim}"
                "GUFO_ROCWMMA_ROOT=${p.rocmPackages.rocwmma}"
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
                "GUFO_HIPCUB_ROOT=${p.rocmPackages.hipcub}"
                "GUFO_ROCPRIM_ROOT=${p.rocmPackages.rocprim}"
                "GUFO_ROCWMMA_ROOT=${p.rocmPackages.rocwmma}"
              ];
              Cmd = [ "/bin/bash" ];
            };
          };

          # 3. eval-agent: Agent evaluation against a caller-selected endpoint
          eval-agent-image = p.dockerTools.buildLayeredImageWithNixDb {
            name = "ghcr.io/gufo-org/toolboxes/eval-agent";
            tag = "latest";
            contents = evaluationContents ++ (commonToolboxPkgs system);
            extraCommands = extraSetupCommands system;
            config = {
              Env = commonEnv system;
              Cmd = [ "/bin/bash" ];
            };
          };

          stream-eval-agent = p.dockerTools.streamLayeredImage {
            name = "ghcr.io/gufo-org/toolboxes/eval-agent";
            tag = "latest";
            contents = evaluationContents ++ (commonToolboxPkgs system);
            includeNixDB = true;
            extraCommands = extraSetupCommands system;
            config = {
              Env = commonEnv system;
              Cmd = [ "/bin/bash" ];
            };
          };

          # 4. gufo-eval-agent: Local Gufo serving plus agent evaluation
          gufo-eval-agent-image = p.dockerTools.buildLayeredImageWithNixDb {
            name = "ghcr.io/gufo-org/toolboxes/gufo-eval-agent";
            tag = "latest";
            contents = [
              engine
              evalAgentWithGufo
            ] ++ evaluationContents ++ (commonToolboxPkgs system);
            extraCommands = extraSetupCommands system;
            config = {
              Env = commonEnv system;
              Cmd = [ "/bin/bash" ];
            };
          };

          stream-gufo-eval-agent = p.dockerTools.streamLayeredImage {
            name = "ghcr.io/gufo-org/toolboxes/gufo-eval-agent";
            tag = "latest";
            contents = [
              engine
              evalAgentWithGufo
            ] ++ evaluationContents ++ (commonToolboxPkgs system);
            includeNixDB = true;
            extraCommands = extraSetupCommands system;
            config = {
              Env = commonEnv system;
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
          stream-eval-agent = {
            type = "app";
            program = "${self.packages.${system}.stream-eval-agent}";
          };
          stream-gufo-eval-agent = {
            type = "app";
            program = "${self.packages.${system}.stream-gufo-eval-agent}";
          };
        }
      );
    };
}
