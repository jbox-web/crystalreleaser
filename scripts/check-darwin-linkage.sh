#!/usr/bin/env bash
# Fails when a macOS binary depends on a dynamic library that does not ship
# with macOS: such a binary only starts on a machine that has that library at
# that path (Homebrew's OpenSSL, typically).
#
#   scripts/check-darwin-linkage.sh <binary>...
#
# Only /usr/lib and /System are accepted. Written against bash 3.2.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <binary>..." >&2
  exit 2
fi

status=0
for binary in "$@"; do
  # The first line of `otool -L` is the name of the binary itself.
  foreign="$(otool -L "$binary" | tail -n +2 | awk '{ print $1 }' | grep -v -e '^/usr/lib/' -e '^/System/' || true)"
  if [ -n "$foreign" ]; then
    echo "$binary depends on libraries macOS does not ship:" >&2
    echo "$foreign" | sed 's/^/  /' >&2
    status=1
  else
    echo "$binary: only system libraries"
  fi
done
exit "$status"
