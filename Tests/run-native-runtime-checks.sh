#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-runtime-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
# Deliberately exclude NativeMacApp/NativeExperience and the real inference host.
# No full app/package build, Keychain read, model lookup or worker launch.
sources=(
  Domain/VectaLocalization.swift
  Tests/NativeRuntimeChecks.swift
  Tests/NativeRuntimeCheckSupport.swift
  Domain/AIProcessing.swift
  Domain/VectaSummaryModels.swift
  Domain/VectaRecording.swift
  Domain/VectaDeviceModel.swift
  Domain/LocalAIFileStore.swift
  Storage/VectaRecordingStore.swift
  Storage/VectaSummaryFormatStore.swift
  Storage/VectaLocalAudioExporter.swift
  App/NativeCompatibility.swift
  App/NativeStorageLayout.swift
  App/Lifecycle/RuntimeOwnership.swift
  App/NativeLibraryController.swift
  App/NativeAppRuntime.swift
  App/VectaMigration.swift
  App/VectaAuthorization.swift
)
# Compile a private snapshot so concurrent model/AI edits cannot change a
# compiler input halfway through this isolated check. No app manifest changes.
inputs=()
for source in "${sources[@]}"; do
  mkdir -p "$build/sources/$(dirname "$source")"
  cp "$repo/$source" "$build/sources/$source"
  inputs+=("$build/sources/$source")
done
xcrun swiftc -module-cache-path "$build/module-cache" -swift-version 5 "${inputs[@]}" -o "$build/native-runtime-checks"
VECTA_TEST_LANGUAGE=ru "$build/native-runtime-checks"
