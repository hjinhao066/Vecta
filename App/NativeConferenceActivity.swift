import AppKit
import CoreAudio
import Foundation

struct NativeConferenceActivity: Equatable, Sendable {
    let bundleID: String
    let application: String
    let pid: Int32
    var inputActive: Bool
    var outputActive: Bool
    var participants: Int? = nil
    var audioActive: Bool { inputActive || outputActive }
    // IO flags are activity hints, never evidence of participant count.
    static let applications: [(id: String, name: String)] = [
        ("us.zoom.xos", "Zoom"), ("ru.yandex.telemost", "Яндекс Телемост"),
        ("com.microsoft.teams2", "Microsoft Teams"), ("com.microsoft.teams", "Microsoft Teams Classic"),
        ("com.apple.FaceTime", "FaceTime"), ("com.webex.meetingmanager", "Webex"),
        ("com.google.Chrome", "Google Chrome"), ("ru.yandex.desktop.yandex-browser", "Яндекс Браузер"),
        ("com.apple.Safari", "Safari"), ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Microsoft Edge"), ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave"), ("com.tdesktop.Telegram", "Telegram"), ("com.hnc.Discord", "Discord")
    ]
    enum Decision { case ignore, ask, start }
    func decision(automaticStart: Bool, ask: Bool, requireParticipants: Bool) -> Decision {
        guard automaticStart, inputActive, outputActive else { return .ignore }
        if requireParticipants, let participants, participants < 2 { return .ignore }
        if ask || (requireParticipants && participants == nil) { return .ask }
        return .start
    }
    static func read(allowed: [String]) -> [Self] { snapshot(allowed: allowed) ?? [] }
    static func snapshot(allowed: [String]) -> [Self]? {
        guard #available(macOS 14.2, *) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size <= 65_536, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        if size == 0 { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return nil }
        func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
            return value
        }
        var result: [String: Self] = [:]
        for object in objects {
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { continue }
            let bundle = value.takeRetainedValue() as String
            guard let parent = allowed.first(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) else { continue }
            let input = integer(object, kAudioProcessPropertyIsRunningInput) != 0
            let output = integer(object, kAudioProcessPropertyIsRunningOutput) != 0
            let pid = Int32(bitPattern: integer(object, kAudioProcessPropertyPID))
            var activity = result[parent] ?? Self(bundleID: parent,
                application: applications.first(where: { $0.id == parent })?.name ?? parent,
                pid: pid, inputActive: false, outputActive: false)
            activity.inputActive = activity.inputActive || input; activity.outputActive = activity.outputActive || output
            result[parent] = activity
        }
        return result.values.sorted { $0.bundleID < $1.bundleID }
    }
    func availableMeetingTitle() -> String? {
        guard CGPreflightScreenCaptureAccess(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }.map(\.processIdentifier) + [pid])
        return windows.compactMap { row -> String? in
            guard let owner = row[kCGWindowOwnerPID as String] as? Int32, pids.contains(owner),
                  let title = row[kCGWindowName as String] as? String else { return nil }
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty || clean == application ? nil : String(clean.prefix(100))
        }.first
    }
}
