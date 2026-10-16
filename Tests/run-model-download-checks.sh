#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/vecta-model-download-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -module-cache-path "$build/module-cache" -swift-version 5 \
  "$repo/Domain/VectaLocalization.swift" \
  "$repo/AI/Local/LocalModelRegistry.swift" \
  "$repo/AI/Local/LocalModelDownloader.swift" \
  "$repo/AI/Local/LocalModelManager.swift" \
  "$repo/Tests/ModelDownloadChecks.swift" -o "$build/model-download-checks"
# Bound a failed concurrency fixture rather than leaving a waiting process alive.
python3 -I - "$build/model-download-checks" <<'PY'
import os, subprocess, sys
subprocess.run([sys.argv[1]], env=dict(os.environ, VECTA_TEST_LANGUAGE='ru'), check=True, timeout=60)
PY
