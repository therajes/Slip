// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SlipNative",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SlipNative", targets: ["SideloomNative"])
    ],
    targets: [
        .executableTarget(
            name: "SideloomNative",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security")
            ]
        )
    ]
)
