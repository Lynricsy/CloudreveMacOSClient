// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CloudreveKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CloudreveAPI", targets: ["CloudreveAPI"]),
        .library(name: "CloudreveSync", targets: ["CloudreveSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .target(name: "CloudreveAPI"),
        .target(
            name: "CloudreveSync",
            dependencies: [
                "CloudreveAPI",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(name: "CloudreveAPITests", dependencies: ["CloudreveAPI"]),
        .testTarget(name: "CloudreveSyncTests", dependencies: ["CloudreveSync", "CloudreveAPI"])
    ],
    swiftLanguageModes: [.v6]
)
