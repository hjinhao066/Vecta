#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-fast-transcription-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
# Snapshot only compiler inputs. The checks run fake shell workers, never the host,
# application, models, recordings, user defaults, or the shared heavy-AI lease.
sources=(
  Domain/VectaLocalization.swift
  Domain/AIProcessing.swift Domain/VectaSummaryModels.swift Domain/LocalAIFileStore.swift
  Domain/AILibrarySearch.swift AI/Local/LocalAIWarmWorker.swift AI/Local/LocalAISpeechWorker.swift AI/Local/LocalAIResourceManager.swift
  AI/Local/LocalModelRegistry.swift AI/Local/LocalModelDownloader.swift AI/Local/LocalModelManager.swift
  AI/Host/LocalAIHost.swift App/VectaMigration.swift App/VectaAuthorization.swift
  App/NativeStorageLayout.swift App/NativeCompatibility.swift Storage/VectaRecordingStore.swift
  Domain/VectaRecording.swift Domain/VectaDeviceModel.swift Tests/FastTranscriptionChecks.swift
)
inputs=()
for source in "${sources[@]}"; do
  mkdir -p "$build/sources/$(dirname "$source")"
  cp "$repo/$source" "$build/sources/$source"
  inputs+=("$build/sources/$source")
done
# Compile the real host without starting it; preferences use a temporary injected suite.
xcrun swiftc -module-cache-path "$build/module-cache" -swift-version 5 "${inputs[@]}" -o "$build/fast-transcription-checks"
cp "$repo/AI/Resources/models-mlx.json" "$build/models.json"
VECTA_TEST_LANGUAGE=ru "$build/fast-transcription-checks" "$build/models.json"
