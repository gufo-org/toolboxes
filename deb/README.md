# deb — the host (.deb) lane

Debian packaging for gufo, outside the engine repository. `deb/common/` is the packaging
source; `deb/build-deb` assembles it into `debian/` of an engine checkout and builds there,
because that is the layout `debian/rules` expects.

```
deb/
├── build-deb                    # the entrypoint. Defaults below; every default is overridable
├── gen-deb-ver                # version, derived from the checkout's version.txt + tag
├── debian-trixie.Dockerfile   # builder image (ROCm headers) and the real-dpkg test env
├── common/                    # becomes <checkout>/debian/ verbatim
│   ├── control rules copyright changelog source/format
│   ├── gufo.{install,env,service,@.service,postinst,postrm,prerm}
│   ├── gufo-rocm-repo.{install,postinst,postrm} rocm.conf rocm.gpg
│   ├── gufo-launch.sh gufo-upgrade-units.sh gen-changelog.sh get-revision.sh
│   └── tests/               # autopkgtest: the lifecycle matrix + the container test
└── tests/
    └── apt-pin-scope.sh          # apt pin: proves it is in force, and proves it can fail
```

## Defaults, and how a downstream clone changes them

Nothing in here is a policy you have to edit files to escape. The defaults are the ones that
work on a clean machine and produce a portable artifact; each one is an environment variable.

| variable | default | what it decides |
| --- | --- | --- |
| `GUFO_REPO` | `https://github.com/gufo-org/gufo.git` | which engine remote to build |
| `GUFO_SRC` / `--src DIR` | a shallow clone into `$TMPDIR` | build a checkout you already have |
| `CPU_FLAGS` | **empty** — dpkg's portable baseline | your own codegen target, e.g. `-march=znver5 -falign-functions=32 -pipe` |
| `CPP_FLAGS` | empty | preprocessor companion to `CPU_FLAGS` |
| `DEBIAN_REVISION` | `1` | bump for a packaging-only rebuild; the only thing that stops `apt` answering "0 upgraded" on a build that differs |
| `DISTRO` | the build host's codename | changelog suite |
| `CHANGELOG_MODE` | `regen` for a scratch clone, `verify` for `--src` | generate the changelog entry, or refuse when it no longer names the version |
| `SNAPSHOT` | `0` | allow an untagged checkout, stamped `<ver>+git<sha>-1` instead of a release version it does not carry |
| `APT_IMAGE` | `debian:trixie` | builder base |

The portable default for codegen is deliberate. A package built for one machine's
instruction set crashes on another, and the crash arrives as `SIGILL` under load rather than as
a build error. Ship the baseline; override where you own the fleet.

```sh
deb/build-deb v<tag>                                    # defaults: portable, tag-derived
deb/build-deb --src ../gufo --assemble-only          # assemble + gates, no compiler
CPU_FLAGS=-march=znver5\
  deb/build-deb --in-container v<tag>                # tuned build, in the builder image
deb/build-deb --dry-run v<tag>                       # prints the plan, writes nothing
```

`--dry-run` creates no scratch directory and moves nothing — not "skips the delete step",
but stops before there is anything to delete.

## The gates, and where they belong

These run in CI on every pull request, because they are properties of the packaging and not
of any one deployment:

| gate | what it proves |
| --- | --- |
| `common/tests/upgrade-units` | 19 systemd lifecycle scenarios against stubs — disabled-and-stopped must never be started, a bare template must never be touched, a failing restart must exit non-zero, `--dry-run` mutates nothing |
| `common/tests/test_deb_package_in_container.sh` | the same lifecycle against real dpkg and real systemd, in a container, against the built artifact |
| `tests/apt-pin-scope.sh` | the ROCm pin resolves to 600 for every family `control` depends on, with a **negative control**: the old six-`Package:`-line shape must report unpinned in the same run, or the gate is declared inert and fails |
| version alignment | `debian/changelog` must name the version `version.txt` says; refuse early rather than after a compile |
| `lintian`, `dpkg-deb -f` | the artifact's own fields: version, conffiles, dependency floors |

What stays with whoever deploys this, and is therefore **not** here: machine-specific codegen
assertions, host inventories, port allocations, artifact retention, service lifecycle on live
hosts, and performance history. Those are facts about one estate, and a public lane that
carries them becomes a policy somebody else has to inherit.

## Provenance

The build prints the sha256 of every artifact it produced and refuses to report success when
it produced none. Keep the `.buildinfo` next to the `.deb`: a rate measured against a binary
whose hash is not recorded is an anecdote about a mystery file, and this project has spent real
time un-attributing numbers like that.

Supersedes `gufo-org/gufo#372`.
