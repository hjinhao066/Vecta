#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-application-settings-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
# Compile a snapshot of the production settings object with only localization and
# a verification-switch stub. The fake adapter prevents SMAppService access; this
# never starts the app/model host, registers a login item, opens System Settings,
# or reads owner preferences.
sources=(
  Domain/VectaLocalization.swift
  App/Lifecycle/NativeApplicationSettings.swift
  Tests/ApplicationSettingsChecks.swift
)
inputs=()
for source in "${sources[@]}"; do
  mkdir -p "$build/sources/$(dirname "$source")"
  cp "$repo/$source" "$build/sources/$source"
  inputs+=("$build/sources/$source")
done
xcrun swiftc -module-cache-path "$build/module-cache" -swift-version 5 -D VECTA_DEVELOPMENT \
  "${inputs[@]}" -o "$build/application-settings-checks"
VECTA_TEST_LANGUAGE=ru "$build/application-settings-checks"
VECTA_TEST_LANGUAGE=ru "$build/application-settings-checks" --verify-application-settings
