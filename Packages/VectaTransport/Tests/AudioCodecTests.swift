import AVFoundation
import XCTest
@testable import NotePinAudio

final class AudioCodecTests: XCTestCase {
    // Test-only fixture: generated from 1s/16kHz mono 440Hz sine PCM using
    // pinned official libopus1.5.2, OPUS_APPLICATION_AUDIO/32kbps/CBR/20ms.
    // This proves codec/storage contracts, never real recorder interoperability.
    private func fixture(ogg: Bool = false) throws -> Data {
        let name = ogg ? "synthetic-mono-opus-1s.ogg" : "synthetic-mono-opus-1s"
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "hex", subdirectory: "Fixtures"))
        let chars = Array(try String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines))
        return try Data(stride(from: 0, to: chars.count, by: 2).map { try XCTUnwrap(UInt8(String(chars[$0...($0 + 1)]), radix: 16)) })
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VectaCodecTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testRealCodecProducesMP3DecodableByMacOS() async throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("tone.raw"), output = dir.appendingPathComponent("tone.mp3")
        try fixture().write(to: raw)
        let value = try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1, expectedDuration: 1)
        XCTAssertEqual(value.decodedSamples, 16000); XCTAssertEqual(value.duration, 1, accuracy: 0.0001)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.95); XCTAssertLessThan(duration, 1.2)
        let decoded = try AVAudioFile(forReading: output)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length)))
        try decoded.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 14000)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let rms = sqrt((0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / Double(buffer.frameLength))
        XCTAssertGreaterThan(rms, 0.03); XCTAssertLessThan(rms, 0.35)
        XCTAssertEqual(try fixture(), try Data(contentsOf: raw))
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testRecorderRecoveryConcealsIsolatedPacketsWithoutShorteningAudio() throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("recorder.raw"), output = dir.appendingPathComponent("recorder.mp3")
        var damaged = Data()
        for _ in 0..<7 { damaged.append(try fixture()) }
        // Same geometry as the observed recorder failure: two invalid 80-byte
        // packets in 350 frames. No owner recording is retained as a fixture.
        damaged[218 * 80] = 0xb9; damaged[280 * 80] = 0xb9
        try damaged.write(to: raw)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1))
        let value = try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1,
            expectedDuration: 7, recoverDamagedRecorderPackets: true)
        XCTAssertEqual(value.concealedPackets, 2)
        XCTAssertEqual(value.decodedSamples, 112000)
        XCTAssertEqual(value.duration, 7, accuracy: 0.0001)
        XCTAssertGreaterThan(try AVAudioFile(forReading: output).length, 110000)
        XCTAssertEqual(try Data(contentsOf: raw), damaged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }
    func testRecorderRecoveryRejectsLeadingDenseBurstAndTruncatedDamage() throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("recorder.raw"), output = dir.appendingPathComponent("recorder.mp3")
        var source = Data()
        for _ in 0..<7 { source.append(try fixture()) }
        for indices in [[0], [10, 11, 12], [10, 30, 50, 70]] {
            var damaged = source
            for index in indices { damaged[index * 80] = 0xb9 }
            try damaged.write(to: raw)
            XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output,
                channels: 1, recoverDamagedRecorderPackets: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["recorder.raw"])
        }
        try source.dropLast().write(to: raw)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output,
            channels: 1, recoverDamagedRecorderPackets: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testRecorderRecoveryKeepsCleanAudioAndOggStrict() throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("recorder.raw"), output = dir.appendingPathComponent("recorder.mp3")
        try fixture().write(to: raw)
        let value = try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1,
            recoverDamagedRecorderPackets: true)
        XCTAssertEqual(value.concealedPackets, 0)
        XCTAssertEqual(value.decodedSamples, 16000)
        let ogg = dir.appendingPathComponent("damaged.ogg"), rejected = dir.appendingPathComponent("rejected.mp3")
        var bytes = try fixture(ogg: true); bytes[bytes.count - 2] ^= 1
        try bytes.write(to: ogg)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: ogg, outputURL: rejected,
            channels: 1, recoverDamagedRecorderPackets: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
    }
    func testScopedRecorderHighlightFrameRestoresOriginalCodecPacket() throws {
        let original = try fixture()
        var flagged = original.subdata(in: 0..<80)
        flagged[0] = 0xb8
        let before = flagged
        flagged[0] = 0xb9
        XCTAssertTrue(RecorderHighlightFrames.normalize(&flagged))
        XCTAssertEqual(flagged, before, "Only the recorder flag may change")
        XCTAssertFalse(RecorderHighlightFrames.normalize(&flagged))
        var unknown = Data(repeating: 0xff, count: 80)
        XCTAssertFalse(RecorderHighlightFrames.normalize(&unknown))
        var short = Data([0xb9])
        XCTAssertFalse(RecorderHighlightFrames.normalize(&short))
        var header = Data(repeating: 0, count: 512)
        header.replaceSubrange(0..<8, with: Data("PLAUD.AI".utf8))
        header[8] = 1; header[11] = 2; header[48] = 5; header[50] = 1; header[52] = 1; header[144] = 80
        XCTAssertTrue(RecorderHighlightFrames.supports(try EncryptedAudioHeader(data: header)))
        for offset in [8,48,50,52,144] {
            var wrong = header; wrong[offset] = 9
            XCTAssertFalse(RecorderHighlightFrames.supports(try EncryptedAudioHeader(data: wrong)))
        }
    }

    func testNeverOverwritesExistingOutput() throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("tone.raw"), output = dir.appendingPathComponent("existing.mp3")
        try fixture().write(to: raw); try Data("preserve".utf8).write(to: output)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1)) { error in
            XCTAssertEqual(error as? NativeAudioError, .outputExists)
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("preserve".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }
    func testTruncatedAndInvalidOpusNeverCommitSuccess() throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("tone.raw"), output = dir.appendingPathComponent("tone.mp3")
        try Data(try fixture().dropLast()).write(to: raw)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try Data(repeating: 0xff, count: 80).write(to: raw)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["tone.raw"])
    }
    func testWrongDurationAndUnsupportedChannelsRejectWithoutOutput() throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("tone.raw"), output = dir.appendingPathComponent("tone.mp3")
        try fixture().write(to: raw)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1, expectedDuration: 8))
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testFileAEADDecryptorMustAuthenticateBeforeCodecOutput() throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("cipher.raw"), output = dir.appendingPathComponent("tone.mp3")
        try Data("not authenticated".utf8).write(to: raw)
        var calls = 0
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1, contentDecryptor: { _ in
            calls += 1; throw NativeAudioError.checksumMismatch
        }))
        XCTAssertEqual(calls, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testOggFixtureHasIndependentCRCAndDecodesAt48kHz() async throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("tone.ogg"), output = dir.appendingPathComponent("tone.mp3")
        let data = try fixture(ogg: true)
        try data.write(to: raw)
        let value = try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1, expectedDuration: 1)
        XCTAssertEqual(value.sampleRate, 48000); XCTAssertEqual(value.decodedSamples, 48000)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.95); XCTAssertLessThan(duration, 1.2)
    }
    func testOggCRCTruncationAndMissingEndNeverProduceSuccess() throws {
        let dir = try temporary(), raw = dir.appendingPathComponent("tone.ogg"), output = dir.appendingPathComponent("tone.mp3")
        var damaged = try fixture(ogg: true); damaged[damaged.count - 2] ^= 1
        try damaged.write(to: raw)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1)) { error in
            XCTAssertEqual(error as? NativeAudioError, .checksumMismatch)
        }
        try fixture(ogg: true).dropLast().write(to: raw)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1))
        // The first complete identification page cannot masquerade as audio.
        try fixture(ogg: true).prefix(47).write(to: raw)
        XCTAssertThrowsError(try NativeAudioConverter.convert(rawURL: raw, outputURL: output, channels: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
