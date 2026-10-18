// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "talktrail",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "talktrail", targets: ["talktrail"]),
        .executable(name: "TalktrailApp", targets: ["TalktrailApp"]),
    ],
    dependencies: [
        // On-device speaker diarization (Core ML). No traits: skips the prebuilt text-normalization
        // binary, which is only needed for its TTS/ASR features.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(
            name: "TalktrailCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "talktrail",
            dependencies: ["TalktrailCore"],
            linkerSettings: [
                // Embed an Info.plist so macOS can show usage descriptions for the microphone
                // and system-audio permission prompts.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "TalktrailApp",
            dependencies: ["TalktrailCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
