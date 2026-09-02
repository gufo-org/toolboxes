{
  p,
  engine,
  evaluationAgent,
  commonRuntimePkgs,
  ociFilesystemCommands,
  evalArchiveOwnershipCommands,
  containerUser,
  gpuEnv,
}:
let
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

  imageArgs = {
    name = "ghcr.io/gufo-org/toolboxes/gufo-eval-agent";
    tag = "latest";
    contents = [
      engine
      evalAgentWithGufo
      p.radeontop
      evaluationAgent
      p.nix
    ] ++ commonRuntimePkgs;
    extraCommands = ociFilesystemCommands;
    fakeRootCommands = evalArchiveOwnershipCommands;
    config = {
      Env = gpuEnv;
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
    gufo-eval-agent-image = image;
    stream-gufo-eval-agent = stream;
  };

  apps.stream-gufo-eval-agent = {
    type = "app";
    program = "${stream}";
  };
}
