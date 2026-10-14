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
