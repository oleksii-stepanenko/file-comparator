// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FileComparator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FileComparator", targets: ["FileComparator"]),
        .library(name: "DiffCore", targets: ["DiffCore"]),
    ],
    targets: [
        .target(
            name: "DiffCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "FileComparator",
            dependencies: ["DiffCore"]
        ),
        .testTarget(
            name: "DiffCoreTests",
            dependencies: ["DiffCore"]
        ),
    ]
)
