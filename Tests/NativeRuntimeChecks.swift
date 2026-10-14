import Foundation
import Darwin

@main struct NativeRuntimeChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "NativeRuntimeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        count += 1
    }
    @MainActor static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { count += 1; return }
        throw NSError(domain: "NativeRuntimeChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor static func rejectsAsync(_ message: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { count += 1; return }
        throw NSError(domain: "NativeRuntimeChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor static func main() async {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe-lock" {
            do {
                let lease = try RuntimeOwnership(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                withExtendedLifetime(lease) { exit(0) }
            } catch RuntimeOwnership.OwnershipError.alreadyRunning { exit(2) }
            catch { exit(3) }
        }
        do { try await run(); print("PASS \(count) isolated native runtime checks") }
        catch { print("FAIL after \(count) checks:", error); exit(1) }
    }
    @MainActor static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("VectaNativeRuntimeChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "VectaNativeRuntimeChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = root.appendingPathComponent("services")
        let exports = root.appendingPathComponent("Exports")
        try fm.createDirectory(at: services, withIntermediateDirectories: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        try exports.path.write(to: services.appendingPathComponent("recordings-root.txt"), atomically: true, encoding: .utf8)
        try Data("synthetic-unresolvable-bookmark".utf8).write(to: services.appendingPathComponent("recordings-folder.bookmark"))
        let resources = root.appendingPathComponent("resources-unused-by-startup-substitute")
        let owner = "synthetic-runtime-owner"
        let hash = VectaRecordingStore.userDirectoryName(for: owner)
        let base = root.appendingPathComponent("selected")
        let user = base.appendingPathComponent("Users/" + hash)
        let store = try VectaRecordingStore(userID: owner, directory: base)
        try check(store.begin(sessionID: 123, serialNumber: "882-synthetic", duration: 2), "Cannot seed library")
        _ = try VectaSummaryFormatStore(userID: owner, directory: base)

        var lease: RuntimeOwnership? = try RuntimeOwnership(directory: services)
        try rejects("A second owner acquired the same runtime") { _ = try RuntimeOwnership(directory: services) }
        func childProbe() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--probe-lock", services.path]
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        try check(childProbe() == 2, "A separate process acquired the model-owned runtime")
        var supplied: NativeAppRuntime? = NativeAppRuntime(resources: resources, servicesDirectory: services,
            ownershipLease: lease, defaults: defaults, cachedSessionReader: { nil })
        try await supplied!.start(expectedUserID: owner, librarySource: .selectedLibrary(base: base))
        try check(supplied!.state == .ready && supplied!.library?.recordingStore.all.count == 1 &&
                  supplied!.processingRoot == base.appendingPathComponent("Exports", isDirectory: true).standardizedFileURL,
                  "Supplied lease caused a second flock or lost library/workspace")
        await supplied!.stop()
        try check(supplied!.processingRoot == nil, "Runtime stop retained a stale processing root")
        try rejects("Runtime stop released model-owned lease") { _ = try RuntimeOwnership(directory: services) }
        try await supplied!.start(expectedUserID: owner, librarySource: .selectedLibrary(base: base))
        await supplied!.stop()
        try await rejectsAsync("Supplied-lease runtime changed owner on selection") {
            try await supplied!.start(expectedUserID: "wrong-owner", librarySource: .selectedLibrary(base: base))
        }
        try rejects("Startup failure released supplied model lease") { _ = try RuntimeOwnership(directory: services) }
        await supplied!.stop()
        supplied = nil
        try rejects("Runtime destruction released parent-retained lease") { _ = try RuntimeOwnership(directory: services) }
        lease = nil
        do { _ = try RuntimeOwnership(directory: services) }
        count += 1
        try check(childProbe() == 0, "Separate process could not acquire released runtime")

        let runtime = NativeAppRuntime(resources: resources, servicesDirectory: services,
            defaults: defaults, cachedSessionReader: { nil })
        try await runtime.start(expectedUserID: owner, librarySource: .selectedLibrary(base: base))
        try rejects("Runtime did not retain its own lease") { _ = try RuntimeOwnership(directory: services) }
        let competitor = NativeAppRuntime(resources: resources, servicesDirectory: services,
            defaults: defaults, cachedSessionReader: { nil })
        let rejectedFresh = root.appendingPathComponent("rejected-fresh")
        try await rejectsAsync("Concurrent runtime started") {
            try await competitor.start(expectedUserID: "other", librarySource: .freshDefault(base: rejectedFresh))
        }
        try check(!fm.fileExists(atPath: rejectedFresh.path), "Concurrent runtime mutated a fresh profile before exclusivity")
        await runtime.stop()
        do { _ = try RuntimeOwnership(directory: services) }
        count += 1

        // A copied library has diverged from its archived migration snapshot.
        // Explicit selection (including the compatibility API) must open it at
        // this location, not run migration against the fixed user destination.
        let archiveBase = root.appendingPathComponent("archive")
        let archive = archiveBase.appendingPathComponent("Users/" + hash)
        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: user, to: archive)
        let migratedBase = root.appendingPathComponent("migrated")
        let migrated = migratedBase.appendingPathComponent("Users/" + hash)
        try VectaMigration.copyVerified(from: archive, to: migrated)
        let manifest = migrated.appendingPathComponent(".vecta-migration.json")
        let manifestBytes = try Data(contentsOf: manifest)
        let updated = try VectaRecordingStore(userID: owner, directory: migratedBase)
        try check(updated.begin(sessionID: 456, serialNumber: "882-synthetic", duration: 3), "Cannot modify migrated library")
        let selectedBytes = try Data(contentsOf: migrated.appendingPathComponent("recordings.json"))
        let selected = NativeAppRuntime(resources: resources, servicesDirectory: services,
            defaults: defaults, cachedSessionReader: { nil })
        try await selected.start(expectedUserID: owner, candidateBases: [archiveBase], selectedBase: migratedBase)
        try check(selected.library?.recordingStore.all.count == 2, "Selected modified library was remigrated or redirected")
        try check(Data(contentsOf: migrated.appendingPathComponent("recordings.json")) == selectedBytes, "Selected library rows were overwritten")
        try check(Data(contentsOf: manifest) == manifestBytes, "Selection changed migration evidence")
        await selected.stop()

        // The default migrated A claims the inherited external history once.
        // Selection of B must use B/Exports, and returning to A must restore
        // its saved external scope rather than falling back to A/Exports.
        let inheritedEvidence = exports.appendingPathComponent("synthetic-external-history")
        let inheritedBytes = Data("history-and-voice-scope-A".utf8)
        try inheritedBytes.write(to: inheritedEvidence)
        let archiveBefore = try VectaMigration.inventory(archive)
        let defaultABase = root.appendingPathComponent("default-A")
        let defaultA = NativeAppRuntime(resources: resources, servicesDirectory: services,
            defaults: defaults, cachedSessionReader: { nil })
        try await defaultA.start(expectedUserID: owner,
            librarySource: .archivedMigration(candidateBases: [archiveBase], destinationBase: defaultABase))
        try check(defaultA.processingRoot?.standardizedFileURL.path == exports.standardizedFileURL.path,
                  "Initial default migration lost inherited external history")
        try check(VectaMigration.inventory(archive) == archiveBefore, "Archived migration mutated predecessor originals")
        await defaultA.stop()
        try await selected.start(expectedUserID: owner, librarySource: .selectedLibrary(base: migratedBase))
        try check(selected.processingRoot?.standardizedFileURL.path == migratedBase.appendingPathComponent("Exports").standardizedFileURL.path &&
                  selected.processingRoot?.standardizedFileURL.path != exports.standardizedFileURL.path,
                  "Selected B reused A's global processing root")
        try check(Data(contentsOf: inheritedEvidence) == inheritedBytes, "Opening B changed A's history")
        await selected.stop()
        try await defaultA.start(expectedUserID: owner, librarySource: .selectedLibrary(base: defaultABase))
        try check(defaultA.processingRoot?.standardizedFileURL.path == exports.standardizedFileURL.path,
                  "Selecting default A did not reopen its bound external root")
        await defaultA.stop()
        let anotherDefault = NativeAppRuntime(resources: resources, servicesDirectory: services,
            defaults: defaults, cachedSessionReader: { nil })
        let anotherBase = root.appendingPathComponent("another-default")
        try await anotherDefault.start(expectedUserID: owner,
            librarySource: .archivedMigration(candidateBases: [archiveBase], destinationBase: anotherBase))
        try check(anotherDefault.processingRoot?.standardizedFileURL.path == anotherBase.appendingPathComponent("Exports").standardizedFileURL.path,
                  "A second migrated library claimed the same inherited root")
        await anotherDefault.stop()
        let bindingFile = services.appendingPathComponent("native-processing-roots.json")
        let bindingAttributes = try fm.attributesOfItem(atPath: bindingFile.path)
        try check((bindingAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  "Processing-root binding is not owner-only")
        let validBindings = try Data(contentsOf: bindingFile)
        let corruptBindings = Data("malformed-processing-root-bindings".utf8)
        try corruptBindings.write(to: bindingFile)
        let unseenBase = root.appendingPathComponent("unseen-library")
        let unseenStore = try VectaRecordingStore(userID: owner, directory: unseenBase)
        try check(unseenStore.begin(sessionID: 789, serialNumber: "882-synthetic", duration: 1), "Cannot seed unseen library")
        try await rejectsAsync("Malformed processing-root map silently defaulted") {
            try await selected.start(expectedUserID: owner, librarySource: .selectedLibrary(base: unseenBase))
        }
        try check(Data(contentsOf: bindingFile) == corruptBindings && !fm.fileExists(atPath: unseenBase.appendingPathComponent("Exports").path),
                  "Corrupt map was overwritten or default root created")
        await selected.stop()
        let corruptMapFresh = root.appendingPathComponent("fresh-with-corrupt-map")
        try await rejectsAsync("Fresh default bypassed malformed processing-root map") {
            try await selected.start(expectedUserID: owner, librarySource: .freshDefault(base: corruptMapFresh))
        }
        try check(!fm.fileExists(atPath: corruptMapFresh.path), "Malformed map created an empty fresh namespace")
        await selected.stop()
        var bindingObject = try JSONSerialization.jsonObject(with: validBindings) as! [String: Any]
        var entries = bindingObject["bindings"] as! [String: [String: Any]]
        for entryKey in Array(entries.keys) { entries[entryKey]!["bookmark"] = Data("invalid-bound-bookmark".utf8).base64EncodedString() }
        bindingObject["bindings"] = entries
        let badBoundBookmarks = try JSONSerialization.data(withJSONObject: bindingObject)
        try badBoundBookmarks.write(to: bindingFile)
        try await rejectsAsync("Damaged bound bookmark silently downgraded to path-only access") {
            try await selected.start(expectedUserID: owner, librarySource: .selectedLibrary(base: migratedBase))
        }
        try check(Data(contentsOf: bindingFile) == badBoundBookmarks, "Damaged bound bookmark was overwritten")
        await selected.stop()
        try validBindings.write(to: bindingFile)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bindingFile.path)

        let legacy = NativeAppRuntime(resources: resources, servicesDirectory: services,
            defaults: defaults, cachedSessionReader: { nil })
        try await legacy.start(expectedUserID: owner,
            librarySource: .archivedMigration(candidateBases: [archiveBase], destinationBase: migratedBase))
        try check(legacy.library?.recordingStore.all.count == 2, "Repeat archived migration overwrote new destination rows")
        await legacy.stop()
        try Data("source-changed".utf8).write(to: archive.appendingPathComponent("new-archive-evidence"))
        try await rejectsAsync("Changed archived snapshot bypassed migration integrity") {
            try await legacy.start(expectedUserID: owner,
                librarySource: .archivedMigration(candidateBases: [archiveBase], destinationBase: migratedBase))
        }
        try check(Data(contentsOf: migrated.appendingPathComponent("recordings.json")) == selectedBytes,
                  "Failed migration altered selected library")
        await legacy.stop()

        // Both production preference decoders must fail safely without the
        // runtime discarding recordings or rewriting malformed preferences.
        let migratedRoot = migratedBase.appendingPathComponent("Exports", isDirectory: true)
        let preferences = migratedRoot.appendingPathComponent("LocalAI")
        try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
        let broken = Data("{malformed-synthetic-preference-private-content".utf8)
        for name in ["summary-model.json", "automatic-processing.json"] {
            let file = preferences.appendingPathComponent(name)
            try broken.write(to: file)
            let libraryOnly = NativeAppRuntime(resources: resources, servicesDirectory: services,
                defaults: defaults, cachedSessionReader: { nil })
            try await libraryOnly.start(expectedUserID: owner, librarySource: .selectedLibrary(base: migratedBase))
            try check(libraryOnly.state == .ready && libraryOnly.library?.recordingStore.all.count == 2 && libraryOnly.localAI == nil &&
                      libraryOnly.processingRoot == migratedRoot.standardizedFileURL,
                      "AI preference failure closed the valid library or lost its processing scope")
            try check(libraryOnly.aiErrorMessage != nil && libraryOnly.message == nil &&
                      libraryOnly.aiErrorMessage?.contains("malformed-synthetic") == false &&
                      libraryOnly.aiErrorMessage?.contains(root.path) == false, "AI failure did not expose a safe recoverable status")
            try check(Data(contentsOf: file) == broken, "Malformed AI preferences were overwritten")
            try rejects("Library-only runtime released exclusivity") { _ = try RuntimeOwnership(directory: services) }
            await libraryOnly.stop()
            try fm.removeItem(at: file)
        }

        let corruptFile = migrated.appendingPathComponent("recordings.json")
        try broken.write(to: corruptFile)
        let corrupt = NativeAppRuntime(resources: resources, servicesDirectory: services,
            defaults: defaults, cachedSessionReader: { nil })
        try await rejectsAsync("Corrupt recording schema was silently recreated") {
            try await corrupt.start(expectedUserID: owner, librarySource: .selectedLibrary(base: migratedBase))
        }
        try check(corrupt.library == nil && corrupt.state == .failed && Data(contentsOf: corruptFile) == broken,
                  "Corrupt recording bytes or failed state were not preserved")
        await corrupt.stop()
        try selectedBytes.write(to: corruptFile)
        let formatsFile = migrated.appendingPathComponent("SummaryFormats/formats.json")
        let formatsBytes = try Data(contentsOf: formatsFile)
        try broken.write(to: formatsFile)
        try await rejectsAsync("Corrupt format schema was silently recreated") {
            try await corrupt.start(expectedUserID: owner, librarySource: .selectedLibrary(base: migratedBase))
        }
        try check(corrupt.library == nil && Data(contentsOf: formatsFile) == broken, "Corrupt formats were overwritten")
        await corrupt.stop()
        try formatsBytes.write(to: formatsFile)
        try await rejectsAsync("Explicit selection silently changed owner") {
            try await corrupt.start(expectedUserID: "other-owner", librarySource: .selectedLibrary(base: migratedBase))
        }
        try check(!fm.fileExists(atPath: migratedBase.appendingPathComponent("Users/" + VectaRecordingStore.userDirectoryName(for: "other-owner")).path),
                  "Wrong-owner selection manufactured a library")
        await corrupt.stop()

        let freshBase = root.appendingPathComponent("fresh")
        let fresh = NativeAppRuntime(resources: resources, servicesDirectory: services,
            defaults: defaults, cachedSessionReader: { nil })
        try await fresh.start(expectedUserID: "known-local-owner", librarySource: .freshDefault(base: freshBase))
        try check(fresh.state == .ready && fresh.library?.recordingStore.all.isEmpty == true, "Explicit fresh default did not initialize known owner")
        await fresh.stop()
        let danglingBase = root.appendingPathComponent("dangling-default")
        try fm.createSymbolicLink(at: danglingBase, withDestinationURL: root.appendingPathComponent("not-present"))
        try rejects("Fresh default followed a dangling symlink") {
            _ = try NativeStorageLayout.resolveFreshDefault(userID: owner, servicesDirectory: services, base: danglingBase)
        }
    }
}
