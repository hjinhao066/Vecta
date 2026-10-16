#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo/.build/tests"
python3 - "$repo" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])


def braced_region(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"Unclosed source region after {marker!r}")


recording = (root / "App/NativeMacRecording.swift").read_text()
conferences = (root / "App/NativeConferences.swift").read_text()
screen = conferences[conferences.index("struct NativeConferencesScreen"):]
task = braced_region(screen, "}.task {")
for forbidden in ("prepareConferenceAccess", "requestAccess", "requestAuthorization", "CGRequestScreenCaptureAccess"):
    assert forbidden not in task, f"NativeConferencesScreen.task must not call {forbidden}"
assert "CGRequestScreenCaptureAccess" not in recording, "Recording setup must not explicitly request screen capture access"

helper = braced_region(recording, "enum NativeMacMicrophoneAuthorization")
assert "status()" in helper and "case .notDetermined" in helper and "return await request()" in helper
assert not any(token in helper for token in ("UserDefaults", "@AppStorage", "static var", "static let")), \
    "Microphone authorization helper must not persist a granted flag"
start = braced_region(recording, "func start(")
assert "if mode.needsMicrophone" in start and "NativeMacMicrophoneAuthorization.requestIfNeeded" in start, \
    "Only microphone modes may invoke explicit microphone authorization"
monitor = (root / "App/NativeConferenceMonitor.swift").read_text()
automatic = monitor[monitor.index("            case .start:"):monitor.index("            case .ask:")]
assert automatic.index("guard automaticRecordingAllowed(settings.mode)") < automatic.index("startRecording(activity)"), \
    "Automatic capture must check existing permission without making a request"
assert "requestAccess" not in automatic and "CGRequest" not in automatic
print("PASS source policy: conference entry is permission-inert; no explicit screen request; microphone setup is stateless; unattended capture is permission-gated.")
PY
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path "$repo/.build/tests/module-cache" \
    "$repo/Domain/VectaLocalization.swift" "$repo/App/NativeMacRecording.swift" "$repo/App/NativeMicrophoneCapture.swift" "$repo/App/NativeConferenceActivity.swift" \
    "$repo/Tests/NativeMacRecordingChecks.swift" -o "$repo/.build/tests/mac-recording-checks"
VECTA_TEST_LANGUAGE=ru "$repo/.build/tests/mac-recording-checks"
