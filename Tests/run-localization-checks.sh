#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
python3 -I "$repo/Tools/check-localization.py"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-localization-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -module-cache-path "$build/module-cache" -O -parse-as-library -swift-version 5 -D VECTA_DEVELOPMENT \
  "$repo/Domain/VectaLocalization.swift" "$repo/Domain/AIProcessing.swift" \
  "$repo/Domain/VectaSummaryModels.swift" "$repo/Tests/LocalizationChecks.swift" \
  -o "$build/localization-checks"
env -u VECTA_TEST_LANGUAGE VECTA_TEST_CATALOG="$repo/App/Resources/Localization/en.json" \
VECTA_VERIFICATION_PREFERENCES="Vecta.Verification.Localization.$(uuidgen)" \
  "$build/localization-checks" --verify-localization
for language in en ru; do
  plutil -lint "$repo/App/Resources/$language.lproj/InfoPlist.strings"
done
