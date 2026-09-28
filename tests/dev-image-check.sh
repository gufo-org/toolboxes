#!/usr/bin/env bash
# Check whether the gufo-dev image can build Gufo from source.
#
# A missing package in a dockerTools image is invisible until someone configures
# CMake inside it, which surfaces as "No CMAKE_CXX_COMPILER could be found" or
# "Failed to find all ICU components". This script names the specific gap, so
# the image can be validated from CI or from a host that has no Nix installed.
#
# Run it from the repository root with podman or docker:
#   podman run --rm --userns=keep-id \
#     -v "$PWD:/workspace/toolboxes:ro" -w /workspace/toolboxes \
#     ghcr.io/gufo-org/toolboxes/gufo-dev:edge \
#     bash tests/dev-image-check.sh
set -u

failures=0
report() {
  printf '::error::gufo-dev image lacks %s: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

echo "== compilers, generators and gate interpreters =="
for tool in cc c++ gcc g++ cmake ninja pkg-config python3 git clang-format clang-tidy hipcc; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%-13s %s\n' "$tool" "$("$tool" --version 2>&1 | head -1)"
  else
    report "required tooling" "$tool"
  fi
done

# Gufo's CMakeLists.txt resolves these with find_package(); the image must carry
# the dev outputs, not only the shared libraries that the pinned engine links.
cat > /tmp/gufo-dev-probe.c << 'EOF'
#include <curl/curl.h>
#include <jpeglib.h>
#include <openssl/ssl.h>
#include <png.h>
#include <unicode/ustring.h>
int main(void) { return 0; }
EOF

echo "== headers behind find_package(ICU/CURL/OpenSSL/PNG/JPEG) =="
if cc -fsyntax-only /tmp/gufo-dev-probe.c 2> /tmp/gufo-dev-probe.err; then
  echo "  all five headers compile through CPATH"
else
  report "development headers" "see compiler output"
  sed 's/^/    /' /tmp/gufo-dev-probe.err >&2
fi

echo "== pkg-config modules and link-time libraries =="
if pkg-config --exists icu-uc icu-i18n libcurl openssl libpng libjpeg; then
  echo "  $(pkg-config --modversion icu-uc icu-i18n libcurl openssl libpng libjpeg | tr '\n' ' ')"
else
  report "pkg-config module" "icu-uc icu-i18n libcurl openssl libpng libjpeg"
fi

if cc /tmp/gufo-dev-probe.c $(pkg-config --libs icu-uc icu-i18n libcurl openssl libpng libjpeg 2> /dev/null) \
  -o /tmp/gufo-dev-probe 2> /tmp/gufo-dev-link.err; then
  echo "  links against every Gufo library"
else
  report "link-time libraries" "see linker output"
  sed 's/^/    /' /tmp/gufo-dev-link.err >&2
fi
rm -f /tmp/gufo-dev-probe /tmp/gufo-dev-probe.c /tmp/gufo-dev-probe.err /tmp/gufo-dev-link.err

# Compiling a header and linking a library are both weaker than what Gufo
# actually asks for: find_package() resolves names through CMAKE_PREFIX_PATH, so
# a package can be present in the closure and still be unfindable (the runtime
# output of libjpeg-turbo sits in a different store path than its `bin` output).
# Replaying the find_package() calls from Gufo's CMakeLists.txt is the check that
# predicts whether configure will succeed. Ninja is the generator Gufo's presets
# select, and the only one this image carries (it ships no make).
probe_dir=$(mktemp -d)
cat > "$probe_dir/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.21)
project(gufo_dev_image_probe CXX)
find_package(ICU REQUIRED COMPONENTS uc i18n)
find_package(Threads REQUIRED)
find_package(CURL REQUIRED)
find_package(PNG REQUIRED)
find_package(JPEG REQUIRED)
find_package(OpenSSL REQUIRED COMPONENTS Crypto)
message(STATUS "probe found ICU ${ICU_VERSION}, CURL ${CURL_VERSION_STRING}, "
               "PNG ${PNG_VERSION_STRING}, JPEG ${JPEG_FOUND}, OpenSSL ${OPENSSL_VERSION}")
EOF

if cmake -S "$probe_dir" -B "$probe_dir/build" -G Ninja > "$probe_dir/cmake.log" 2>&1; then
  echo "== find_package() replay =="
  grep -m1 "probe found" "$probe_dir/cmake.log" | sed 's/^-- //' | cut -c1-100
else
  report "a find_package() dependency" "configure failed"
  grep -E "Could NOT find|Failed to find|missing:" "$probe_dir/cmake.log" | head -5 | sed 's/^/    /' >&2
fi
rm -rf "$probe_dir"

if [ "$failures" -ne 0 ]; then
  echo "gufo-dev image cannot build Gufo from source yet ($failures problem(s))." >&2
  exit 1
fi
echo "gufo-dev image carries a complete Gufo build environment."
