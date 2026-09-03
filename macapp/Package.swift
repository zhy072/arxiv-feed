// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ArxivFeed",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ArxivFeed", path: "Sources/ArxivFeed")
    ]
)
