#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-legacy-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -module-cache-path "$build/module-cache" -swift-version 5 "$repo/Domain/VectaLocalization.swift" \
  "$repo/Domain/AIProcessing.swift" "$repo/Domain/VectaSummaryModels.swift" \
  "$repo/Domain/LocalAIFileStore.swift" "$repo/Tests/LegacyModelChecks.swift" \
  -o "$build/legacy-checks"
VECTA_TEST_LANGUAGE=ru "$build/legacy-checks"
