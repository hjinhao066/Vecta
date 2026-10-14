// swift-tools-version: 5.9
import PackageDescription
import Foundation
let codecRoot = ProcessInfo.processInfo.environment["VECTA_CODEC_BUILD_ROOT"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/native-codecs").path
let package = Package(
 name: "VectaTransport",
 platforms: [.macOS(.v13)],
 products: [.library(name: "NotePinTransport", targets: ["NotePinTransport"]),
            .library(name: "NotePinAudio", targets: ["NotePinAudio"])],
 targets: [
  .target(name: "NotePinTransport", path: "Sources/Core"),
  .target(name: "CNativeAudio", path: "Sources/CNativeAudio", publicHeadersPath: "include",
          cSettings: [.unsafeFlags(["-I" + codecRoot + "/install/include"])],
          linkerSettings: [.unsafeFlags([codecRoot + "/install/lib/libopus.a", codecRoot + "/install/lib/libmp3lame.a", codecRoot + "/install/lib/libvorbisfile.a", codecRoot + "/install/lib/libvorbis.a", codecRoot + "/install/lib/libogg.a"])]),
  .target(name: "NotePinAudio", dependencies: ["NotePinTransport", "CNativeAudio"], path: "Sources/Audio"),
  .testTarget(name: "NotePinTransportTests", dependencies: ["NotePinTransport", "NotePinAudio"], path: "Tests",
              resources: [.copy("Fixtures")])
 ]
)
