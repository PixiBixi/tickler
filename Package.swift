// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tickler",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TicklerCore", targets: ["TicklerCore"]),
        .executable(name: "tickler", targets: ["tickler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "TicklerCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "TicklerCLI",
            dependencies: [
                "TicklerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "tickler", dependencies: ["TicklerCLI"]),
        .testTarget(name: "TicklerCoreTests", dependencies: ["TicklerCore"]),
        .testTarget(name: "TicklerCLITests", dependencies: ["TicklerCLI", "TicklerCore"]),
    ]
)
