import Foundation

/// Synthetic policy checks only: no app launch, recordings, devices or Keychain.
@main enum NativeUIStateChecks {
    static func main() throws { try run() }
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) throws {
            assertions += 1
            if !value { throw Failure(description: message) }
        }
        let original = NativeTranscriptSelectionScope(recordingID: "recording-A", conversationKey: "transcript-1")
        let summaryVersion = NativeTranscriptSelectionScope(recordingID: "recording-A", conversationKey: "transcript-1")
        let retranscribed = NativeTranscriptSelectionScope(recordingID: "recording-A", conversationKey: "transcript-2")
        let otherRecording = NativeTranscriptSelectionScope(recordingID: "recording-B", conversationKey: "transcript-1")
        let selected: Set<Int> = [1, 2]
        let available: Set<Int> = [1, 2, 3]
        func canSubmit(_ captured: NativeTranscriptSelectionScope<String>?, _ current: NativeTranscriptSelectionScope<String>?, _ ids: Set<Int> = selected) -> Bool {
            NativeUIStatePolicy.canSubmit(captured: captured, current: current, selected: ids, available: available)
        }
        try check(canSubmit(original, original), "Current transcript selection is accepted")
        try check(canSubmit(original, summaryVersion), "Summary-only versions preserve selection")
        try check(!canSubmit(original, retranscribed), "Retranscription rejects reused numeric segment IDs before invalidation")
        try check(!canSubmit(original, otherRecording), "Recording identity must match even when transcript keys match")
        try check(!canSubmit(nil, original), "Unscoped selection is rejected")
        try check(!canSubmit(original, nil), "Unavailable transcript is rejected")
        try check(!canSubmit(nil, nil), "Two absent scopes do not authorize mutation")
        try check(!canSubmit(original, original, []), "Empty selection is rejected")
        try check(!canSubmit(original, original, [1, 99]), "Missing segments reject the entire submission")
        try check(canSubmit(retranscribed, retranscribed), "Fresh selection on retranscription is accepted")
        var requested = true
        try check(NativeUIStatePolicy.consumeExportRequest(&requested), "Pre-mount export request is consumed")
        try check(!requested, "Consumed request is cleared")
        try check(!NativeUIStatePolicy.consumeExportRequest(&requested), "Subsequent appearance/change does not redeliver")
        requested = true
        try check(NativeUIStatePolicy.consumeExportRequest(&requested), "A new explicit request is delivered")
        try check(!NativeUIStatePolicy.consumeExportRequest(&requested), "New request is delivered only once")
        try check(NativeFactoryResetCopy.confirmation.contains("Все записи на устройстве PLAUD будут удалены"), "Reset explicitly names device recordings as deleted")
        try check(NativeFactoryResetCopy.explanation.contains("Резервная копия не создаётся"), "Reset does not require backup")
        try check(NativeFactoryResetCopy.explanation.contains("на Mac аудио, расшифровки и саммари останутся"), "Reset preserves Mac results")
        try check(NativeFactoryResetCopy.confirmation == "Все записи на устройстве PLAUD будут удалены. Устройство будет отвязано.", "Reset warning matches the owner wording")
        try check(!NativeFactoryResetCopy.explanation.contains("Отвязка"), "Device card omits the two owner-rejected sentences")
        let libraryA = NSObject(), libraryB = NSObject(), hostA = NSObject(), hostB = NSObject()
        let generation = UUID()
        let scope = NativeLibraryOperationScope(library: libraryA, host: hostA, generation: generation)
        try check(scope.isCurrent(library: libraryA, host: hostA, generation: generation), "Current operation owner is accepted")
        try check(!scope.isCurrent(library: libraryB, host: hostA, generation: generation), "Identical recording IDs cannot substitute a library owner")
        try check(!scope.isCurrent(library: libraryA, host: hostB, generation: generation), "Processing host replacement invalidates work")
        try check(!scope.isCurrent(library: libraryA, host: hostA, generation: UUID()), "Generation retirement invalidates work")
        try check(!scope.isCurrent(library: libraryA, host: hostA, generation: generation, cancelled: true), "Cancellation invalidates work")
        try check(!scope.isCurrent(library: nil, host: hostA, generation: generation), "Missing library rejects work")
        try check(!scope.isCurrent(library: libraryA, host: nil, generation: generation), "Missing processing host rejects work")
        for mask in 0..<32 {
            let supported = mask & 1 != 0, transferring = mask & 2 != 0, recording = mask & 4 != 0
            let switching = mask & 8 != 0, ready = mask & 16 != 0
            let action = NativeFastTransferAvailability(supportedDevice: supported, transferring: transferring,
                                                        hasRecording: recording, switching: switching, transportReady: ready)
            let visible = supported && transferring && recording && !switching
            try check(action.isVisible == visible, "Fast-transfer visibility matches supported active-file state")
            try check(action.isEnabled == (visible && ready), "Fast-transfer readiness never silently hides a visible action")
        }
        for (key, action) in [(UInt16(49), NativeRecordingKeyboardPolicy.Action.toggle), (123, .previous), (126, .previous), (124, .next), (125, .next)] {
            try check(NativeRecordingKeyboardPolicy.action(keyCode: key, editing: false, modified: false, modal: false) == action, "Recording key mapping")
            try check(NativeRecordingKeyboardPolicy.action(keyCode: key, editing: true, modified: false, modal: false) == nil, "Typing must not control playback")
            try check(NativeRecordingKeyboardPolicy.action(keyCode: key, editing: false, modified: true, modal: false) == nil, "Modified keys and VoiceOver shortcuts pass through")
            try check(NativeRecordingKeyboardPolicy.action(keyCode: key, editing: false, modified: false, modal: true) == nil, "Modal controls own their keys")
        }
        try check(NativeRecordingKeyboardPolicy.action(keyCode: 0, editing: false, modified: false, modal: false) == nil, "Unrelated keys pass through")
        let starts: [Double] = [2, 5, 9]
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: starts, position: 0, focused: nil, direction: 1) == 0, "Next before speech goes to first phrase")
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: starts, position: 6, focused: nil, direction: 1) == 2, "Next during phrase goes forward")
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: starts, position: 6, focused: nil, direction: -1) == 0, "Previous during phrase goes backward")
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: starts, position: 2, focused: 0, direction: -1) == 0, "First phrase boundary is clamped")
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: starts, position: 12, focused: nil, direction: 1) == 2, "Last phrase boundary is clamped")
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: [2, 2, 5], position: 2, focused: 0, direction: 1) == 1, "Overlapping phrases remain individually navigable")
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: [], position: 0, focused: nil, direction: 1) == nil, "No transcript does not consume arrows")
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: [5, 2], position: 3, focused: nil, direction: 1) == nil, "Unordered phrase timeline is rejected")
        try check(NativeRecordingKeyboardPolicy.phraseIndex(starts: [.nan], position: 0, focused: nil, direction: 1) == nil, "Nonfinite phrase time is rejected")
        print("Native UI state checks passed: \(assertions) assertions")
    }
}
