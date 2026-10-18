// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProxmarkUI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ProxmarkUI", targets: ["ProxmarkUI"]),
        .library(name: "ProxmarkKit", targets: ["ProxmarkKit"]),
    ],
    targets: [
        // Everything that talks to the Proxmark client or parses its output.
        // No UI, so it is unit-testable and reusable.
        .target(name: "ProxmarkKit", path: "Sources/ProxmarkKit"),
        .executableTarget(
            name: "ProxmarkUI",
            dependencies: ["ProxmarkKit"],
            path: "Sources/ProxmarkUI"
        ),
        .testTarget(
            name: "ProxmarkKitTests",
            dependencies: ["ProxmarkKit"],
            path: "Tests/ProxmarkKitTests"
        ),
    ]
)
