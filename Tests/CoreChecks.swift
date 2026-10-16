import Foundation
import CryptoKit

@main struct CoreChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "VectaChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        count += 1
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { count += 1;return }
        throw NSError(domain: "VectaChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func jwt(_ claims: [String: Any]) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: claims)
        return "header." + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
    }
    static func main() async {
        do { try await runTests() } catch {
            print("FAIL after \(count) checks:", error)
            exit(1)
        }
    }
    static func runTests() async throws {
        let windows = VectaHighlights.ranges(points: [30, 5, 30, 45, -1, .nan, .infinity, 200], duration: 100)
        try check(windows == [.init(start: 0, end: 15), .init(start: 20, end: 55)], "Highlight clipping/merging changed")
        try check(VectaHighlights.ranges(points: [95], duration: 100) == [.init(start: 85, end: 100)], "Highlight end must clip")
        try check(VectaHighlights.ranges(points: [0], duration: 0).isEmpty, "Empty duration must not divide by zero")
        try check(VectaHighlights.ranges(points: [0], duration: .nan).isEmpty, "Invalid duration must not render")
        try check(windows[1].overlaps(start: 19.9, end: 20.1), "Boundary-crossing words must highlight")
        try check(!windows[1].overlaps(start: 55, end: 56), "Half-open Highlight boundary changed")
        try check(!windows[1].overlaps(start: .nan, end: 22), "Invalid word time accepted")
        try check(VectaHighlights.contains(30, ranges: windows), "Highlight must stay independent of playhead")
        let reservationCases: [(Double,UInt64)] = [(0.001,2_147_491_844),(1,2_147_875_460),(30,2_159_011_460),(30.001,2_159_035_532),(51,2_167_099_148),(51.001,2_167_139_096),(3_600,3_761_977_160),(21_600,18_846_833_852)]
        for (duration,expected) in reservationCases {
            try check(AIAudioPolicy.diarizationReservation(duration:duration) == expected,"Diarization reservation parity changed")
        }
        for duration in [Double.nan,Double.infinity,-1,0,21_600.001] {
            try check(AIAudioPolicy.diarizationReservation(duration:duration) == UInt64.max,"Invalid duration admission changed")
        }
        let gib: UInt64 = 1_073_741_824
        try check(!AISummaryModelID.qwen4b.compatible(memory:7*gib),"4B must reject below8GB")
        try check(AISummaryModelID.qwen4b.compatible(memory:8*gib),"4B must accept8GB")
        try check(!AISummaryModelID.qwen9b.compatible(memory:15*gib),"9B must reject below16GB")
        try check(AISummaryModelID.qwen9b.compatible(memory:16*gib),"9B must accept16GB")
        try check(VectaLegacyAuthorization.identity(secret: "fixture-secret-with-at-least-32-bytes") == "pinpoint_fjilu3j6wjqj2udia3viyvpenoincx44", "Archived local identity changed") // gitleaks:allow — fixed synthetic compatibility vector, not a credential
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("VectaCoreChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy")
        try fm.createDirectory(at: source.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        try Data([1,2,3,4]).write(to: source.appendingPathComponent("Audio/sample.mp3"))
        let target = root.appendingPathComponent("new/library")
        try VectaMigration.copyVerified(from: source, to: target)
        try check(Data(contentsOf: target.appendingPathComponent("Audio/sample.mp3")) == Data([1,2,3,4]), "Migration lost audio")
        try VectaMigration.copyVerified(from: source, to: target)
        try check(fm.fileExists(atPath: source.appendingPathComponent("Audio/sample.mp3").path), "Migration deleted source")
        try Data([9]).write(to: target.appendingPathComponent("new-state.json"))
        try VectaMigration.copyVerified(from: source, to: target)
        try check(Data(contentsOf: target.appendingPathComponent("new-state.json")) == Data([9]), "Repeat migration overwrote new state")
        try Data([5]).write(to: source.appendingPathComponent("Audio/sample.mp3"))
        try rejects("Changed legacy snapshot must not overwrite destination") { try VectaMigration.copyVerified(from: source, to: target) }
        let unsafe = root.appendingPathComponent("unsafe")
        try fm.createDirectory(at: unsafe, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: unsafe.appendingPathComponent("escape"), withDestinationURL: source)
        try rejects("Migration followed a symlink") { try VectaMigration.copyVerified(from: unsafe, to: root.appendingPathComponent("unsafe-copy")) }
        let occupied = root.appendingPathComponent("occupied")
        try fm.createDirectory(at: occupied, withIntermediateDirectories: true)
        try rejects("Unmarked destination accepted") { try VectaMigration.copyVerified(from: source, to: occupied) }

        let services = root.appendingPathComponent("services")
        try fm.createDirectory(at: services, withIntermediateDirectories: true)
        let badBookmark = Data("predecessor-bound-bookmark-fixture".utf8)
        try badBookmark.write(to: services.appendingPathComponent("native-library.bookmark"))
        try check(NativeLibraryFolderAccess.restore(servicesDirectory: services) == nil, "Invalid legacy bookmark must use owner-based discovery")
        try badBookmark.write(to: services.appendingPathComponent("recordings-folder.bookmark"))
        try source.path.write(to: services.appendingPathComponent("recordings-root.txt"), atomically: true, encoding: .utf8)
        let ordinaryAccess = try NativeRecordingsFolderAccess(servicesDirectory: services)
        try check(ordinaryAccess.root.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path, "Readable export path must survive an unusable predecessor bookmark")
        try check(Data(contentsOf: services.appendingPathComponent("recordings-folder.bookmark")) == badBookmark, "Original bookmark must be preserved")
        try root.appendingPathComponent("missing").path.write(to: services.appendingPathComponent("recordings-root.txt"), atomically: true, encoding: .utf8)
        try rejects("Unusable bookmark must not manufacture folder access") { _ = try NativeRecordingsFolderAccess(servicesDirectory: services) }

        let libraryBase = root.appendingPathComponent("recordings")
        let store = try VectaRecordingStore(userID: "fixture", directory: libraryBase)
        try check(store.begin(sessionID: 123, serialNumber: "882-fixture", duration: 10), "Begin failed")
        let audio = store.audioDirectory(serialNumber: "882-fixture").appendingPathComponent("123.mp3")
        try Data([1,2,3]).write(to: audio)
        try check(store.markLocal(sessionID: 123, serialNumber: "882-fixture", outputPath: audio.path, verifiedDuration: 11), "Publish failed")
        try check(store.saveHighlights(sessionID: 123, serialNumber: "882-fixture", seconds: [5,5,10]), "Highlight save failed")
        try check(store.saveDeviceMarkings(sessionID: 123, serialNumber: "882-fixture", points: [12345, .max]), "Raw SDK marks lost")
        try check(!store.saveHighlights(sessionID: 123, serialNumber: "882-fixture", seconds: [.nan]), "Invalid Highlight persisted")
        try check(store.saveRecorderHighlights(sessionID: 123, serialNumber: "882-fixture", seconds: [1,2,3]), "Recorder marks save failed")
        let reopened = try VectaRecordingStore(userID: "fixture", directory: libraryBase)
        try check(reopened.all.count == 1 && reopened.all[0].duration == 11 && reopened.all[0].status == .local, "Restart lost metadata")
        try check(reopened.all[0].highlightSeconds == [5,10] && reopened.all[0].deviceMarkings == [12345,.max], "Restart lost Highlight annotations")
        try check(reopened.all[0].recorderHighlightSeconds == [1,2,3] && reopened.all[0].highlightSeconds == [5,10], "Hardware marks must not replace manual marks")
        try check(reopened.audioURL(for: reopened.all[0]) == audio, "Restart lost audio path")
        try check(!store.markLocal(sessionID: 123, serialNumber: "882-fixture", outputPath: source.appendingPathComponent("Audio/sample.mp3").path), "Escaped audio accepted")
        let link = audio.deletingLastPathComponent().appendingPathComponent("link.mp3")
        try fm.createSymbolicLink(at: link, withDestinationURL: audio)
        try check(!store.markLocal(sessionID: 123, serialNumber: "882-fixture", outputPath: link.path), "Symlink audio accepted")
        try check(!store.begin(sessionID: -1, serialNumber: "x", duration: 1), "Invalid identity accepted")
        try check(!store.begin(sessionID: 1, serialNumber: "x", duration: .nan), "NaN duration accepted")
        let digest = String(repeating: "a", count: 64)
        let imported = store.audioDirectory(serialNumber: "local-audio-" + digest).appendingPathComponent("import.mp3")
        try Data([8,9]).write(to: imported)
        try check(store.commitImportedAudio(digest: digest, outputURL: imported, duration: 2, title: "Fixture"), "Import failed")
        try check(!store.commitImportedAudio(digest: digest, outputURL: imported, duration: 2, title: "Fixture"), "Duplicate import accepted")
        let conferenceTitle = "Планирование конференции и задач"
        try check(store.saveGeneratedTitle(sessionID: 1, serialNumber: "local-audio-" + digest, title: conferenceTitle), "Conference AI title was not saved")
        let renamed = try VectaRecordingStore(userID: "fixture", directory: libraryBase).recording(sessionID: 1, serialNumber: "local-audio-" + digest)
        try check(renamed?.title == conferenceTitle && renamed?.importedTitle == "Fixture", "AI title must replace the initial Mac title without losing history")
        try check(!store.saveGeneratedTitle(sessionID: 1, serialNumber: "local-audio-" + digest, title: "Другое название после обработки"), "Existing generated title was overwritten")
        let metadata = libraryBase.appendingPathComponent("Users/" + VectaRecordingStore.userDirectoryName(for: "fixture") + "/recordings.json")
        let saved = try Data(contentsOf: metadata)
        try Data("invalid".utf8).write(to: metadata)
        try rejects("Corrupt metadata silently replaced") { _ = try VectaRecordingStore(userID: "fixture", directory: libraryBase) }
        try check(Data(contentsOf: metadata) == Data("invalid".utf8), "Corrupt metadata destroyed")
        try saved.write(to: metadata)
        try check(VectaRecordingStore.cloudSourceIdentifier(sessionID: 123, serialNumber: "882-fixture", duration: 10) == VectaRecordingStore.cloudSourceIdentifier(sessionID: 123, serialNumber: "882-fixture", duration: 11), "Rounded duration changed request lineage")
        try check(VectaDeviceModel(serialNumber: "unknown") == nil, "Unknown device accepted")
        try check(VectaDeviceModel(serialNumber: "882-fixture") == .notePinS, "NotePin S family lost")

        let credentials = VectaPartnerCredentials(clientID: "fixture-client", clientSecret: "fixture-secret", domain: "platform-us.plaud.ai", userID: "fixture-user")
        try rejects("Credential redirect domain accepted") { try VectaPartnerCredentials(clientID: "x", clientSecret: "y", domain: "evil.example", userID: "z").validate() }
        var requests: [URLRequest] = []
        let token = try jwt(["sub": "fixture-user", "user_id": "fixture-user", "client_id": "fixture-client", "exp": Date().timeIntervalSince1970 + 3600])
        let provider = try VectaPartnerAuthorization(credentials: credentials, exchange: { request in
            requests.append(request)
            let value = requests.count == 1 ? "partner-fixture" : token
            return (try JSONSerialization.data(withJSONObject: ["data": ["access_token": value]]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let session = try await provider.authorize(expectedUserID: "fixture-user")
        try check(session.userID == "fixture-user" && session.canResumeWithoutRefresh, "Authorization identity/expiry lost")
        try check(requests.count == 2 && requests[0].url!.path == "/developer/api/oauth/partner/access-token" && requests[1].url!.path == "/developer/api/open/partner/users/access-token", "Auth used an unexpected endpoint")
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        try check(body["user_id"] as? String == "fixture-user" && body.count == 2, "Auth request included unexpected content")
        do { _ = try await provider.authorize(expectedUserID: "different");throw NSError(domain: "check",code: 1) }
        catch VectaAuthorizationError.identityMismatch { count += 1 }
        let malformed = try VectaPartnerAuthorization(credentials: credentials, exchange: { request in
            (Data("{\"access_token\":\"bad\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await malformed.authorize(expectedUserID: "fixture-user");throw NSError(domain: "check",code: 1) }
        catch VectaAuthorizationError.invalidResponse { count += 1 }
        try FactoryResetChecks.run(root: root)
        print("PASS: \(count) storage, migration, device, authorization and reset-backup checks. Synthetic fixtures only.")
    }
}
