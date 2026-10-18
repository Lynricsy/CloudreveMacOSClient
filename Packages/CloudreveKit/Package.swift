// swift-tools-version: 6.1
import PackageDescription

// Linux 上没有 CryptoKit，用 API 一致的 swift-crypto 代替；macOS 不链接它。
let linuxCrypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))

let package = Package(
    name: "CloudreveKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CloudreveAPI", targets: ["CloudreveAPI"]),
        .library(name: "CloudreveSync", targets: ["CloudreveSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.1")
    ],
    targets: [
        .target(name: "CloudreveAPI", dependencies: [linuxCrypto]),
        .target(
            name: "CloudreveSync",
            dependencies: [
                "CloudreveAPI",
                .product(name: "GRDB", package: "GRDB.swift"),
                linuxCrypto
            ]
        ),
        .testTarget(name: "CloudreveAPITests", dependencies: ["CloudreveAPI", linuxCrypto]),
        .testTarget(name: "CloudreveSyncTests", dependencies: ["CloudreveSync", "CloudreveAPI", linuxCrypto])
    ],
    swiftLanguageModes: [.v6]
)
