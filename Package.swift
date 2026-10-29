// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Storager",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Storager", targets: ["Storager"]),
        .library(name: "StoragerCore", targets: ["StoragerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "StoragerCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "Storager",
            dependencies: ["StoragerCore"]
        ),
        .testTarget(
            name: "StoragerCoreTests",
            dependencies: ["StoragerCore"]
        ),
    ]
)
