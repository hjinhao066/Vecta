#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo/.build/tests"
xcrun swiftc -swift-version 5 -D VECTA_VISUAL_STANDALONE \
  -module-cache-path "$repo/.build/tests/module-cache" \
  "$repo/Domain/VectaLocalization.swift" "$repo/Domain/AIProcessing.swift" \
  "$repo/Domain/VectaSummaryModels.swift" "$repo/App/NativeVisualComposition.swift" \
  "$repo/App/NativeVisualCanvas.swift" "$repo/App/NativeVisualPDF.swift" \
  "$repo/App/NativeExportProjection.swift" "$repo/Tests/NativeExportChecks.swift" \
  "$repo/Tests/NativeVisualCompositionChecks.swift" -o "$repo/.build/tests/visual-composition-checks"
# The runner creates a new directory and never touches owner data or installed apps.
VECTA_TEST_LANGUAGE=ru "$repo/.build/tests/visual-composition-checks" \
  "$repo/.build/visual-evidence-$(uuidgen)"
