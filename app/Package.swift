// swift-tools-version:6.0
import PackageDescription

// The notchide GUI package.
//
// Split into two targets so the *meaningful* verification (all SwiftUI/AppKit UI
// code) compiles even on a machine that only has the Command Line Tools:
//   • `NotchideApp` — a LIBRARY holding every view, controller, design token,
//     and the socket↔broker↔UI wiring. This is where all real code lives.
//   • `notchide`    — a thin executable entry point that just boots the library.
//
// Dependencies are deliberately minimal — only DynamicNotchKit (the notch shell)
// and the local, dependency-free NotchideKit core. The planned syntax-highlighting
// stack (Neon + SwiftTreeSitter + CodeEditLanguages) is intentionally NOT added
// yet so the app resolves and compiles reliably.
let package = Package(
    name: "notchide-app",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "notchide", targets: ["notchide"]),
        .library(name: "NotchideApp", targets: ["NotchideApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", exact: "1.1.0"),
        // The local offline core (root package identity: "notchide").
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "NotchideApp",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
                .product(name: "NotchideKit", package: "notchide"),
            ]
        ),
        .executableTarget(
            name: "notchide",
            dependencies: ["NotchideApp"]
        ),
    ]
)
