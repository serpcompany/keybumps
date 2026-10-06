// swift-tools-version:5.9
import PackageDescription

// whisper.cpp's official release framework (v1.9.4 is build b5130), pinned by checksum.
// Dictation runs it on the GPU (ADR 0008).
let package = Package(
    name: "WhisperCpp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperCpp", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        )
    ]
)
