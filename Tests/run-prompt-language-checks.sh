#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-prompt-language-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -module-cache-path "$build/module-cache" -O -parse-as-library -swift-version 5 \
  "$repo/AI/MLX/Sources/VectaMLX/SummaryPrompt.swift" \
  "$repo/AI/MLX/Sources/VectaMLX/LibraryPrompt.swift" \
  "$repo/AI/MLX/Sources/VectaMLX/SemanticPrompt.swift" \
  "$repo/Tests/PromptLanguageChecks.swift" -o "$build/prompt-language-checks"
"$build/prompt-language-checks"
