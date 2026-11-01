// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SabunCopy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SabunCopy",
            path: "Sources/SabunCopy"
        )
    ]
)
