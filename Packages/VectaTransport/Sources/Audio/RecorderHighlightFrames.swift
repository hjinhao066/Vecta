import Foundation

/// NotePin S protocol20, encrypted v1/type5, mono, 80-byte/20ms frames.
/// Controlled owner recording: three B9 flags at14.96/19.84/24.68 seconds
/// match physical presses at~15/20/25. This is recorder metadata, not a
/// general Opus rule. Never apply it to imports, Ogg or unknown profiles.
enum RecorderHighlightFrames {
    static func supports(_ header: EncryptedAudioHeader) -> Bool {
        header.version == 1 && header.fileType == 5 && header.channels == 1 &&
        header.encryptionType == 1 && header.segment == 80
    }
    static func normalize(_ packet: inout Data) -> Bool {
        guard packet.count == 80, packet.first == 0xb9 else { return false }
        packet[packet.startIndex] = 0xb8
        return true
    }
}
