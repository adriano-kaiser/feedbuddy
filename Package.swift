// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FeedBuddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FeedBuddy", path: "Sources/FeedBuddy")
    ]
)
