#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-ai-event-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
# Snapshot only compiler sources; never start the host/app or touch a user library.
sources=(
  Domain/VectaLocalization.swift
  Domain/AIProcessing.swift Domain/VectaSummaryModels.swift Domain/LocalAIFileStore.swift
  Domain/AILibrarySearch.swift AI/Local/LocalAIWarmWorker.swift AI/Local/LocalAISpeechWorker.swift AI/Local/LocalAIResourceManager.swift
  AI/Local/LocalModelRegistry.swift AI/Local/LocalModelDownloader.swift AI/Local/LocalModelManager.swift
  AI/Host/LocalAIHost.swift App/VectaMigration.swift App/VectaAuthorization.swift
  App/NativeStorageLayout.swift App/NativeCompatibility.swift Storage/VectaRecordingStore.swift
  Domain/VectaRecording.swift Domain/VectaDeviceModel.swift Tests/LocalAIEventCacheChecks.swift
)
inputs=()
for source in "${sources[@]}"; do
  mkdir -p "$build/sources/$(dirname "$source")"
  cp "$repo/$source" "$build/sources/$source"
  inputs+=("$build/sources/$source")
done
# Swift 5 compatibility, including the real host's suspension/ownership guards.
xcrun swiftc -module-cache-path "$build/module-cache" -swift-version 5 -typecheck "${inputs[@]}"
xcrun swiftc -module-cache-path "$build/module-cache" -swift-version 5 \
  "$build/sources/Domain/VectaLocalization.swift" \
  "$build/sources/Domain/AIProcessing.swift" \
  "$build/sources/Domain/VectaSummaryModels.swift" \
  "$build/sources/Domain/LocalAIFileStore.swift" \
  "$build/sources/Tests/LocalAIEventCacheChecks.swift" -o "$build/event-cache-checks"
VECTA_TEST_LANGUAGE=ru "$build/event-cache-checks"
