// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RAPPVoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RAPPVoice", targets: ["RAPPVoice"]),
        .library(name: "RAPPVoiceCore", targets: ["RAPPVoiceCore"]),
    ],
    dependencies: [.package(path: "../../rapp-tools")],
    targets: [
        .target(name: "RAPPVoiceCore"),
        .executableTarget(
            name: "RAPPVoice",
            dependencies: [
                "RAPPVoiceCore",
                .product(name: "RAPPDesktopSupport", package: "rapp-tools"),
            ],
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "RAPPVoiceCoreTests",
            dependencies: ["RAPPVoiceCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "RAPPVoiceRuntimeTests",
            dependencies: [
                "RAPPVoice",
                "RAPPVoiceCore",
                .product(name: "RAPPDesktopSupport", package: "rapp-tools"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
