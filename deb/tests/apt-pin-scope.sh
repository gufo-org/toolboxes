#!/usr/bin/env bash
set -uo pipefail

# apt-pin scope — prove the ROCm pin is CONFIGURED *and* IN FORCE, and prove this gate can fail.
#
# Why this exists. The pin shipped in gufo-rocm-repo.postinst once wrote one `Package:` line per
# glob inside a single stanza. apt reads one `Package:` field per stanza: the file installed, dpkg
# reported success, /etc/apt/preferences.d/gufo-rocm-pin sat there looking configured, and the
# priority it asked for was never applied — `apt-cache policy' answered the distribution default
# 500 where the file said 600. Every green pipeline from then on meant nothing.
#
#   deb/tests/apt-pin-scope.sh                      # the packaging source, in a sandbox
#   deb/tests/apt-pin-scope.sh <postinst>         # an explicit postinst to test
#
# Nothing writes to /etc. The postinst runs against a scratch directory with its two write targets
# rewritten, so what apt reads is the file the package would have written.
#
# The negative control is not optional and is not decoration: the old six-line shape is written and
# apt must report it as unpinned in the same run. If that check ever passes at 600, the probe is
# lying and the green result above it is worthless — so the script fails in that case too.
#
# Exit 0 = the shipped stanza produces a pin apt honours. Exit non-zero = it does not, or this
# gate failed to prove itself.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
post="${1:-${script_dir}/../common/gufo-rocm-repo.postinst}"
key_part=Dir::Etc::preferencesparts   # NOT preferences-parts; the hyphenated spelling loads nothing
fail=0

note() { printf '  %-8s %s\n' "$1" "$2"; }
ok()   { note ok "$1"; }
bad()  { note FAIL "$1"; fail=1; }

printf '### apt pin scope: %s\n' "${post}"
[[ -f "${post}" ]] || { bad "postinst not found"; exit 1; }

command -v apt-cache >/dev/null 2>&1 || { printf 'skip: apt-cache is not available here (run this inside deb/debian-trixie.Dockerfile).\n'; exit 0; }

sb="$(mktemp -d "${TMPDIR:-/tmp}/gufo-pin-scope.XXXXXX")"
trap 'rm -rf "${sb}"' EXIT INT TERM
mkdir -p "${sb}/bad/parts" "${sb}/gen/parts" "${sb}/gen/sources.d"

prio() { apt-cache policy "$1" -o Dir::Etc::preferences=/dev/null \
           -o "${key_part}=$2" 2>/dev/null | awk '/^ \*\*\*/{print $3; exit}'; }

# --- the negative control ------------------------------------------------------------------------
{
  printf 'Package: hip*\nPackage: roc*\nPackage: rocm*\n'
  printf 'Package: rdc*\nPackage: *roctracer*\nPackage: *hsa*\n'
  printf 'Pin: release o=repo.radeon.com\nPin-Priority: 600\n'
} > "${sb}/bad/parts/p"
bad_prio="$(prio hipblaslt "${sb}/bad/parts")"
if [[ "${bad_prio}" == "600" ]]; then
  bad "negative control is inert: the six-line stanza reports ${bad_prio}, so this probe cannot detect the bug"
else
  ok "negative control fires: six-line stanza -> ${bad_prio:-none} (no pin applied)"
fi

# --- the shipped script, in a sandbox -----------------------------------------------------------
sed -e "s|/etc/apt/sources.list.d/|${sb}/gen/sources.d/|g" \
    -e "s|/etc/apt/preferences.d/|${sb}/gen/parts/|g" \
    -e "s|mkdir -p /etc/apt/sources.list.d /etc/apt/preferences.d|mkdir -p ${sb}/gen/sources.d ${sb}/gen/parts|g" \
    "${post}" > "${sb}/postinst"
if ! sh "${sb}/postinst" >"${sb}/postinst.log" 2>&1; then
  bad "postinst failed against the sandbox:"; sed 's/^/           /' "${sb}/postinst.log" | head -5
fi
pinfile="${sb}/gen/parts/gufo-rocm-pin"
if [[ ! -f "${pinfile}" ]]; then
  bad "postinst wrote no pin file"
else
  n_pkg="$(grep -c '^Package:' "${pinfile}")"
  if [[ "${n_pkg}" -ne 1 ]]; then
    bad "pin file has ${n_pkg} \`Package:' lines in one stanza; apt honours one — collapse to one line of space-separated globs"
  else
    ok "pin file: one \`Package:' line -> $(sed -n 's/^Package: //p' "${pinfile}" | cut -c1-52)…"
  fi
  grep -q 'Pin-Priority: 600' "${pinfile}" && ok "Pin-Priority 600 present" || bad "no Pin-Priority: 600 in the pin file"
  grep -q 'Package: \*' "${pinfile}" && bad "the pin uses \`Package: *': a wildcard at 600 outranks the distro for every overlapping package" || ok "no \`Package: *' wildcard"
fi

# --- apt's verdict, for the families the package actually depends on -------------------------
# Derived from deb/common/control rather than a hand-written list, so the gate cannot drift from
# the dependency it is supposed to protect.
control="${script_dir}/../common/control"
depends="$(sed -n '/^Depends:/,/^[A-Z]/p' "${control}" 2>/dev/null | tr ',' '\n' | grep -oE '\b(hip|roc|rocm|rdc)[a-z0-9-]*' | sort -u)"
[[ -n "${depends}" ]] || { bad "could not derive the ROCm dependency list from ${control}"; }
checked=0
for pkg in ${depends}; do
  pr="$(prio "${pkg}" "${sb}/gen/parts")"
  [[ -z "${pr}" ]] && { note unknown "${pkg} -> not resolvable here"; continue; }
  checked=$((checked + 1))
  if [[ "${pr}" == "600" ]]; then ok "${pkg} -> ${pr}"; else bad "${pkg} -> ${pr} (expected 600; the pin is inert for this family)"; fi
done
[[ "${checked}" -gt 0 ]] || bad "no dependency family could be resolved against apt; the gate proved nothing"

# --- the pin must not name a person or a machine -----------------------------------------------
# Shipped files reach a public repository. This is the generic form of that rule, not a list of
# one maintainer's hosts.
if grep -nqE '192\.168\.[0-9]+\.[0-9]+|/home/[a-z0-9._-]+/|\.internal\b|\.lan\b' "${post}"; then
  bad "postinst carries a private address, home path or internal hostname"
else
  ok "postinst names no private host or home path"
fi

printf '\napt-pin-scope: %s\n' "$([[ ${fail} -eq 0 ]] && echo PASS || echo FAIL)"
exit "${fail}"
