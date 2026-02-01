// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIMonteer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIMonteer", targets: ["AIMonteer"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AIMonteer",
            dependencies: [],
            path: "Sources"
        )
    ]
)
