#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
modules="${1:-$repo/.build/release}"
for input in WhisperKit.swiftmodule ArgmaxCore.swiftmodule WhisperKit.o ArgmaxCore.o; do
  if [ ! -e "$modules/$input" ]; then
    echo "Build the pinned release Speech dependencies first; no downloads are performed by this check." >&2
    exit 1
  fi
done
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-speech-config-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -module-cache-path "$build/module-cache" -O -parse-as-library -swift-version 5 -I "$modules" \
  "$repo/AI/Worker/SpeechModelConfiguration.swift" "$repo/Tests/SpeechModelConfigurationChecks.swift" \
  "$modules/WhisperKit.o" "$modules/ArgmaxCore.o" \
  -framework AVFoundation -framework AVFAudio -framework Accelerate -framework CoreML -framework NaturalLanguage \
  -o "$build/speech-config-checks"
"$build/speech-config-checks"
