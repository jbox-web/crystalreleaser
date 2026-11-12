#!/usr/bin/env bash
# Assembles static-libs/, the folder the release builds pass to the linker
# with `--link-flags=-Lstatic-libs` (see .crystalreleaser.yml).
#
# WHY THIS EXISTS
#   The mise-installed Crystal embeds libgc, pcre2, libyaml and libffi, but
#   not OpenSSL: on macOS the compiler finds it through pkg-config, in the
#   Homebrew of the machine that builds, and the linker prefers the .dylib it
#   sees there. The released binary then only starts on a Mac that has the
#   very same OpenSSL at the very same prefix.
#
#   The macOS linker has no "static for this library only" switch. It takes
#   the first folder of its search path that holds the library, so a folder
#   that comes first and holds nothing but the .a files is what makes it link
#   them statically.
#
# ON LINUX
#   The folder is created empty: the static builds run in the Alpine image,
#   which links everything statically already, and an empty folder on the
#   search path changes nothing.
#
# Written against bash 3.2, the one macOS ships.
set -euo pipefail

cd "$(dirname "$0")/.."

dir="static-libs"
rm -rf "$dir"
mkdir -p "$dir"

[ "$(uname -s)" = "Darwin" ] || exit 0

# The same lookup as the compiler: pkg-config first.
libdir="$(pkg-config --variable=libdir libssl 2>/dev/null || true)"
if [ -z "$libdir" ] && command -v brew >/dev/null 2>&1; then
  libdir="$(brew --prefix openssl 2>/dev/null || true)/lib"
fi

for lib in libssl.a libcrypto.a; do
  if [ ! -f "$libdir/$lib" ]; then
    echo "static-libs: $lib not found in '${libdir}': install OpenSSL (brew install openssl)" >&2
    exit 1
  fi
  cp "$libdir/$lib" "$dir/$lib"
done

echo "static-libs: libssl.a and libcrypto.a copied from $libdir"
