// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "notchide",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NotchideKit", targets: ["NotchideKit"]),
        .executable(name: "notchide-hook", targets: ["notchide-hook"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "NotchideKit",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "notchide-hook",
            dependencies: ["NotchideKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NotchideKitTests",
            dependencies: ["NotchideKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
