#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
modules="${1:-$repo/.build/release}"
module_search="$modules"
objects=()
if [ -d "$modules/Modules" ]; then
  module_search="$modules/Modules"
  # SwiftPM separates emitted modules from each target's compiled objects.
  for target in WhisperKit ArgmaxCore; do
    if [ ! -e "$module_search/$target.swiftmodule" ] || [ ! -d "$modules/$target.build" ]; then
      echo "Missing compiled Speech target: $target" >&2
      exit 1
    fi
    count=0
    while IFS= read -r -d '' object; do
      objects+=("$object")
      count=$((count + 1))
    done < <(find "$modules/$target.build" -maxdepth 1 -type f -name '*.o' -print0)
    if [ "$count" = 0 ]; then
      echo "Missing compiled Speech objects: $target" >&2
      exit 1
    fi
  done
else
  for input in WhisperKit.swiftmodule ArgmaxCore.swiftmodule WhisperKit.o ArgmaxCore.o; do
    if [ ! -e "$modules/$input" ]; then
      echo "Build the pinned release Speech dependencies first; no downloads are performed by this check." >&2
      exit 1
    fi
  done
  objects=("$modules/WhisperKit.o" "$modules/ArgmaxCore.o")
fi
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-speech-config-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -module-cache-path "$build/module-cache" -O -parse-as-library -swift-version 5 -I "$module_search" \
  "$repo/AI/Worker/SpeechModelConfiguration.swift" "$repo/Tests/SpeechModelConfigurationChecks.swift" \
  "${objects[@]}" \
  -framework AVFoundation -framework AVFAudio -framework Accelerate -framework CoreML -framework NaturalLanguage \
  -o "$build/speech-config-checks"
"$build/speech-config-checks"
