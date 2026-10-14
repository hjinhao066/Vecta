#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/vecta-offline-auth.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
swiftc "$root"/Packages/VectaTransport/Sources/Core/*.swift \
  "$root/Research/OfflineAuthorization/main.swift" -o "$build/probe"
"$build/probe"
