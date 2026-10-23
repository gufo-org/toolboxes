# Quadlet Service for the Gufo Server

Quadlet is Podman's systemd generator: it reads `.container` files and turns
them into user services. [`quadlet/gufo.container`](../quadlet/gufo.container)
is a verified example that serves one text model rootless from the
`gufo-runtime` image. Quadlet needs Podman; for Docker, use the hand-written
unit described in [systemd.md](systemd.md) instead.

Start with the [quick start](quickstart.md) for image tags and GPU
permissions, and [host configuration](host-configuration.md) for kernel,
groups and locked-memory limits.

## Requirements

- Quadlet, shipped with Podman since 4.4; the example here is verified on
  Podman 5.8 with `crun` as the OCI runtime (`keep-groups` needs it).
- Rootless Podman, with the device-group setup from the
  [quick start](quickstart.md).
- A persistent systemd user session: `loginctl enable-linger $USER`.

## 1. Create the host directories

```sh
mkdir -p ~/.config/containers/systemd
mkdir -p ~/.local/share/gufo/models
install -d -m 0700 ~/.cache/gufo
```

The example splits model storage from cache storage on purpose, following the
XDG base directory specification:

| Host path | Container path | Role |
| :--- | :--- | :--- |
| `~/.local/share/gufo/models` | `/models` (`ro`) | `$XDG_DATA_HOME`: model artifacts, real user data |
| `~/.cache/gufo` | `/var/cache/gufo` (`rw`) | `$XDG_CACHE_HOME`: disposable state, safe to delete |

Continuation snapshots and the GGUF digest cache are derived data, so they
belong in the cache root, and that root is `0700` rather than world-readable.
`--cache-disk` creates its own subdirectory, so the only manual step is the
parent directory that the bind mount needs.

Copy model files in as before. The loader discovers sibling shards, so naming
the first shard (`…-00001-of-00004.gguf`) is enough. Hugging Face symlink
layouts have the same constraint as in the [quick start](quickstart.md): mount
the repository root, not an individual snapshot directory.

## 2. Install the unit

```sh
cp quadlet/gufo.container ~/.config/containers/systemd/
systemctl --user daemon-reload
```

Install under `$XDG_CONFIG_HOME/containers/systemd`, not
`$XDG_RUNTIME_DIR/containers/systemd`. Quadlet scans both, but the runtime
directory is tmpfs: the source file and the service disappear on reboot.

The `[Install]` section is applied by the generator itself, so
`systemctl --user enable` is not needed and does not persist. Confirm the
generator claimed the file and wired it into `default.target`:

```sh
systemctl --user show gufo.service -p SourcePath -p UnitFileState
readlink -f /run/user/$(id -u)/systemd/generator/default.target.wants/gufo.service
```

If an earlier hand-written unit exists, retire it first or two servers race for
port 8080:

```sh
rm -f ~/.config/systemd/user/gufo-serve.service \
      ~/.config/systemd/user/default.target.wants/gufo-serve.service
systemctl --user daemon-reload
```

## 3. Start and verify

```sh
systemctl --user start gufo
journalctl --user -u gufo -f
```

`Notify=healthy` postpones systemd's readiness notification until the `/ready`
probe passes, so `systemctl --user start gufo` blocks through model loading and
`systemctl --user is-active gufo` reports `activating` until the backend can
actually serve. Loading the 111 GB Flash-Next shards measured about 15 s with
the files already in the page cache and about 60 s cold (99.7 s on the host this
example was verified on, with two 262 K sessions plus the MTP and vision
sidecars). Probe directly too — that is the check to script:

```sh
curl -fsS http://127.0.0.1:8080/health   # process alive, always 200
curl -fsS http://127.0.0.1:8080/ready    # 503 until a backend is loaded
curl -fsS http://127.0.0.1:8080/v1/models
```

`/healthz` and `/readyz` are aliases. With `--api-key` set, every endpoint
including both probes requires `Authorization: Bearer <key>`.

## 4. Adapt the command

The example runs the Qwen3.8 Flash-Next shard set with the disk tier enabled
and a fixed public model id. Flags worth reviewing before reuse:

| Option | Default | Notes |
| :--- | :--- | :--- |
| `--model` | required | First shard of a split file; siblings are discovered. |
| `--served-model-name` | GGUF artifact name | Exact-match id; clients sending the previous name get `404 model_not_found`. Snapshots are unaffected: cache identity comes from artifact digests. |
| `--sessions` | `1` | Requests above one session serialize. Each session reserves context capacity and shrinks the RAM snapshot budget. |
| `--context` | model native | Raises per-session memory and shrinks the RAM snapshot budget (`MemAvailable / 2`, sampled after loading). |
| `--cache-disk` | off | Adds the restart-safe tier. Retention defaults to 8 GiB. |
| `--cache-disk-staging-bytes` | 1 GiB, `MemAvailable / 8`, or the disk budget, whichever is smallest | Must exceed one checkpoint or the tier is a no-op; large contexts need several GiB. |
| `--api-key` | unset | Leave unset on a trusted LAN only; see the commented lines in the unit. |

`Network=pasta:--ipv4-only` publishes through pasta, which adds a userspace hop.
`Network=host` avoids it if LAN throughput matters more than isolation.

## 5. Readiness, liveness and auto-updates

### Readiness

The example probes `/ready` with `curl`, which the runtime image provides.
`HealthStartPeriod=300s` covers model loading, `-m 10` bounds the request
itself, and `HealthTimeout=15s` sits behind curl so that a slow probe is always
reported as curl's exit code rather than as a healthcheck timeout killing it.
`Notify=healthy` then turns that probe into systemd's startup signal, and the
pairing is what makes the rest of this section work:

- `systemctl --user start gufo` blocks until the model serves, and units that
  order after it wait for the same moment.
- a build that never passes `/ready` becomes a **failed start job** at
  `TimeoutStartSec`. That failure is the only signal `podman auto-update` has
  for deciding that a new image is bad.
- both halves are required. `Notify=healthy` with `TimeoutStartSec=infinity`
  makes "READY never arrived" indistinguishable from "still loading".

### Liveness

`READY` is one-shot. A later `healthy → unhealthy` transition sends systemd
nothing, so without `HealthOnFailure=` a wedged server keeps its listener open,
answers nothing, and stays `active (running)` forever. The example sets
`HealthOnFailure=stop`, which stops the container on the transition and lets
`Restart=always` start a fresh one.

Prefer `stop` over `kill`: `stop` follows `StopSignal=SIGTERM` and therefore the
cancel-and-drain path in [section 6](#6-stop-and-restart-behaviour), while
`kill` skips it. A process wedged badly enough to ignore `SIGTERM` is SIGKILLed
after `StopTimeout` either way, so the gentle path costs at most that much.
A real wedge is therefore detected after three failed probes (roughly 60–70 s),
then stopped, then reloaded: budget about five minutes to a recovered server.
Recovery is cheaper in prompt terms than that, because `--cache-disk` rebuilds
conversations from snapshots instead of re-prefilling them.

Because recovery and a human tuning the unit both restart the service, and each
attempt costs a full load, `[Unit]` lowers the start-rate limit from the systemd
default (5 starts in 10 s, which cannot fire when each attempt runs for minutes)
to 5 starts in 30 min, so a systemic failure stops instead of looping.

### Auto-updates

`AutoUpdate=registry` reacts to the Podman auto-update timer:

```sh
systemctl --user enable --now podman-auto-update.timer
systemctl --user list-timers podman-auto-update.timer
```

The stock user timer is `OnCalendar=daily` with a 15-minute random delay, so the
cutover lands at an unpredictable time and restarts a warm server, and it can
promote an untested engine build. Three ways to live with it:

- **Gate it.** Keep `AutoUpdate=registry`, which is what declares the policy,
  but drive the update yourself:

  ```sh
  systemctl --user disable --now podman-auto-update.timer
  podman auto-update --dry-run --format '{{.Image}} {{.Updated}} {{.Unit}}'
  systemctl --user start podman-auto-update.service
  ```

- **Narrow the range.** The policy resolves the tag recorded on the container, so
  the tag has to float. `:latest` takes every release; the minor tags in the
  image repository float over patches only. List them with
  `skopeo list-tags docker://ghcr.io/gufo-org/toolboxes/gufo-runtime`.
- **Move the window.** Override the timer with a quiet-hour `OnCalendar=`.

Pinning does *not* soften this — it disables it. `AutoUpdate=registry` compares
the remote digest **of a tag**, so a digest reference or a `sha-*` tag resolves
to itself forever and the policy quietly stops updating. Pin that way only when
no updates at all is the intent.

Rolling back is cheap, because the published patch tags are retained:

```sh
podman pull ghcr.io/gufo-org/toolboxes/gufo-runtime:0.9.0  # last known good
# set Image=ghcr.io/gufo-org/toolboxes/gufo-runtime:0.9.0, then
systemctl --user daemon-reload && systemctl --user restart gufo
```

A named tag also survives `podman image prune`; the dangling image that the old
`latest` used to point at does not, so do not prune between an update and the
rollback you may want. Podman's own `--rollback` is best effort: it judges the
restart by the READY it receives over sdnotify — another reason for
`Notify=healthy` — and `Restart=always` relaunches every `RestartSec`, which can
race that check. Watch the first restart after any update.

## 6. Stop and restart behaviour

`gufo serve` handles `SIGTERM` and `SIGINT`, and the unit keeps Podman's default
`StopSignal=SIGTERM`. On stop it:

1. closes the listener, so new connections are refused;
2. shuts down every accepted socket, which the generation loop reads as a client
   disconnect and uses to cancel that request;
3. waits for in-flight requests to unwind;
4. drains accepted disk-cache writes while backend objects destruct;
5. exits with status 0.

This is cancellation, not connection draining: there is no mode that finishes
in-flight requests while refusing new ones, so clients see truncated or reset
responses and should retry. Consequences for the unit:

- `StopTimeout` (Podman's `--stop-timeout`) bounds the drain, and systemd's
  `TimeoutStopSec` must be larger, otherwise systemd cuts the stop job short.
  Some distributions also escalate an over-run stop to `SIGABRT` with a core
  dump instead of a quiet `SIGKILL`.
- A second `SIGTERM` during a stuck request does not force an exit; only the
  `SIGKILL` after `StopTimeout` does.
- Signal handlers are installed after the model loads. A stop during loading
  exits immediately with the default action and logs nothing.
- Because shutdown exits 0, `Restart=always` restarts crashes only, never a
  deliberate `systemctl --user stop`.
- Video jobs do not survive a restart. Queued and running jobs are cancelled on
  stop, and the next start recovers only jobs recorded as completed, deleting the
  rest of their storage; re-submit them.

## Troubleshooting

- `crun` missing or `--group-add keep-groups` unsupported: check
  `podman info --format '{{.Host.OCIRuntime.Name}}'`.
- ROCm finds no device, or reports a misleading `Memory critical` while GPU
  enumeration succeeds: on SELinux hosts the container may be denied `map` on
  `/dev/kfd`. Check the host audit log, then allow device mapping if the policy
  scope is acceptable — it applies to every container on the host:

  ```sh
  sudo ausearch -m avc -ts recent | grep -E '/dev/kfd|hsa_device_t'
  sudo setsebool -P container_use_devices true
  ```
- `event=load_phase phase=artifact_identity` for a long time: the first launch
  hashes every shard. Keeping `$XDG_CACHE_HOME` on a persistent volume, as the
  example does, makes later launches reuse that digest.
- Container marked unhealthy during startup: `HealthStartPeriod` is shorter
  than the model load.
- `activating` for a long time and then a failed start at `TimeoutStartSec`: the
  readiness gate working, not a new failure mode — `/ready` never passed. Read
  the load log, and pre-pull the image if the start also included a slow pull.
- "Start request repeated too quickly": the `[Unit]` start-rate limit. Fix the
  cause, then `systemctl --user reset-failed gufo.service`.
- Permission denied on a bind mount: the runtime writes as UID/GID `1000:1000`.
  On SELinux hosts, `:z` relabels the whole host tree for shared access and
  `:Z` gives it a private label; after the first start
  `ls -dZ ~/.cache/gufo` reports `container_file_t`.
