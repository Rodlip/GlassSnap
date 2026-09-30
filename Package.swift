// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlassSnap",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "GlassSnap", targets: ["GlassSnap"])],
    targets: [
        .target(name: "SnapGeometry"),
        .executableTarget(name: "GlassSnap", dependencies: ["SnapGeometry"]),
        .testTarget(name: "SnapGeometryTests", dependencies: ["SnapGeometry"])
    ],
    swiftLanguageModes: [.v5]
)
