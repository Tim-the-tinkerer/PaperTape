// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaperTape",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PaperTape", targets: ["PaperTape"]),
    ],
    targets: [
        .executableTarget(
            name: "PaperTape",
            path: "Sources/PaperTape"
        ),
    ]
)
