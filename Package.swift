// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlueBubblesDaemon",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "bluebubbles-daemon", targets: ["BlueBubblesDaemon"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.90.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "BlueBubblesDaemon",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)