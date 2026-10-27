// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexDictationLab",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DictationArchiveCore", targets: ["DictationArchiveCore"]),
        .executable(name: "CodexDictationLab", targets: ["CodexDictationLab"]),
        .executable(name: "CodexDictationRecover", targets: ["CodexDictationRecover"]),
        .executable(
            name: "CodexDictationCaptureHelper",
            targets: ["CodexDictationCaptureHelper"]
        )
    ],
    targets: [
        .target(
            name: "DictationArchiveCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CodexDictationLab",
            dependencies: ["DictationArchiveCore"]
        ),
        .executableTarget(
            name: "CodexDictationRecover",
            dependencies: ["DictationArchiveCore"]
        ),
        .executableTarget(
            name: "CodexDictationCaptureHelper",
            dependencies: ["DictationArchiveCore"]
        ),
        .testTarget(
            name: "CodexDictationLabTests",
            dependencies: ["CodexDictationLab", "DictationArchiveCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
