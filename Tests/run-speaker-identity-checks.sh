#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-speaker-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -module-cache-path "$build/module-cache" -swift-version 5 "$repo/Domain/VectaLocalization.swift" "$repo/Domain/AIProcessing.swift" "$repo/Domain/VectaSummaryModels.swift" "$repo/Tests/SpeakerIdentityChecks.swift" -o "$build/checks"
VECTA_TEST_LANGUAGE=ru "$build/checks"
