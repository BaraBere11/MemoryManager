// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MemoryManager",
            path: "Sources/MemoryManager",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
