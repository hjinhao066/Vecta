#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo/.build/tools"
xcrun swiftc "$repo/App/VectaAuthorization.swift" "$repo/Tools/ConfigureAuthorization.swift" -o "$repo/.build/tools/configure-auth"
exec "$repo/.build/tools/configure-auth"
