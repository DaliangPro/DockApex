// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockFoldersCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DockLayoutCore", targets: ["DockLayoutCore"])],
    targets: [
        .target(name: "DockLayoutCore"),
        .testTarget(name: "DockLayoutCoreTests", dependencies: ["DockLayoutCore"])
    ]
)
