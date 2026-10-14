#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo/.build/tests"
xcrun swiftc -module-cache-path "$repo/.build/tests/module-cache" -O -swift-version 5 "$repo/Tests/CoreChecks.swift" "$repo/Tests/FactoryResetChecks.swift" "$repo/Domain/VectaLocalization.swift" "$repo/Domain/AIProcessing.swift" "$repo/Domain/VectaSummaryModels.swift" "$repo/Domain/VectaRecording.swift" "$repo/Domain/VectaDeviceModel.swift" "$repo/Storage/VectaRecordingStore.swift" "$repo/App/NativeCompatibility.swift" "$repo/App/NativeStorageLayout.swift" "$repo/App/VectaMigration.swift" "$repo/App/VectaAuthorization.swift" "$repo/Packages/VectaTransport/Sources/Core/ProtocolWireError.swift" "$repo/Packages/VectaTransport/Sources/Core/ProtocolResponses.swift" "$repo/Packages/VectaTransport/Sources/Core/FactoryResetBackupVerifier.swift" "$repo/Packages/VectaTransport/Sources/Core/FactoryResetBackupPublisher.swift" "$repo/Packages/VectaTransport/Sources/Core/FactoryResetBackupCoordinator.swift" -o "$repo/.build/tests/core-checks"
VECTA_TEST_LANGUAGE=ru "$repo/.build/tests/core-checks"
xcrun swiftc -module-cache-path "$repo/.build/tests/module-cache" -swift-version 5 "$repo/Domain/VectaLocalization.swift" "$repo/App/NativeUXPolicy.swift" "$repo/Tests/NativeUIStateChecks.swift" -o "$repo/.build/tests/ui-state-checks"
VECTA_TEST_LANGUAGE=ru "$repo/.build/tests/ui-state-checks"
if grep -REq 'deleteAllRecordings|removeDevice\(confirmedSerial:|onRemovalComplete' "$repo/App"; then
  echo "Recorder deletion must not be reachable from the app" >&2
  exit 1
fi
if grep -REq 'Удалить устройство|Удалить записи и устройство' "$repo/App/Views"; then
  echo "The device screen must not expose recorder deletion" >&2
  exit 1
fi
if grep -Eq 'deleteAllRecordings|onRemovalComplete' "$repo/Packages/VectaTransport/Sources/Bluetooth/NativeBluetoothSession.swift"; then
  echo "The transport session must not expose recorder deletion" >&2
  exit 1
fi

if grep -Rq 'Другие и мои форматы' "$repo/App"; then
  echo "Removed summary format disclosure must not return" >&2
  exit 1
fi
