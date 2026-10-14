// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "VectaLocalAI", platforms: [.macOS("15.0")],
    products: [.executable(name: "VectaSpeech", targets: ["VectaSpeech"])],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", revision: "93a97e32fa8f6cc5ef36ccaf3d139e19f17d0408")],
    targets: [.executableTarget(name: "VectaSpeech", dependencies: [
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
        .product(name: "SpeakerKit", package: "argmax-oss-swift")
    ], path: ".", exclude: ["App", "Packages", "Tools", "Tests", "Licenses", "docs", "AI/MLX", "AI/Resources", "AI/Host"], sources: [
        "AI/Worker/SpeechWorker.swift", "AI/Worker/WholeRecording.swift", "AI/Worker/SpeechModelConfiguration.swift",
        "AI/Local/LocalAudioReader.swift", "Domain/AIStreamingRecognition.swift",
        "Domain/VectaLocalization.swift", "Domain/AIProcessing.swift", "Domain/VectaSummaryModels.swift"
    ])])
