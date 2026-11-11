// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SlipNative",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SlipNative", targets: ["SideloomNative"])
    ],
    targets: [
        .target(
            name: "DroppyWindowBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "SideloomNative",
            dependencies: ["DroppyWindowBridge"],
            resources: [.copy("Localization/Localizable.xcstrings"), .process("Localization/en.lproj")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(name: "SideloomNativeTests", dependencies: ["SideloomNative"])
    ]
)
