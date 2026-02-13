// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mth",
    products: [
        .library(name: "MTH", targets: ["MTH"]),
        .library(name: "MTHColor", targets: ["MTHColor"]),
        // C targets retained as oracle for testing
        .library(name: "Cmth", targets: ["Cmth"]),
        .library(name: "CmthColor", targets: ["CmthColor"]),
    ],
    targets: [
        // Thin C wrapper exposing system zlib to Swift.
        // zlib is present on macOS (SDK) and Linux (Swift toolchain dependency).
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Existing C targets (renamed)
        .target(
            name: "Cmth",
            dependencies: [],
            path: "Sources/cmth",
            sources: ["msdp.c", "mth.c", "telopt.c", "mud.c"],
            publicHeadersPath: "./",
            cSettings: [.define("MTH_LIBRARY")]
        ),
        .target(
            name: "CmthColor",
            dependencies: [],
            path: "Sources/cmthcolor",
            sources: ["color.c"],
            publicHeadersPath: "./",
            cSettings: [.define("MTH_LIBRARY")]
        ),
        // New Swift targets
        .target(
            name: "MTH",
            dependencies: ["CZlib"],
            path: "Sources/SwiftMTH"
        ),
        .target(
            name: "MTHColor",
            dependencies: [],
            path: "Sources/SwiftMTHColor"
        ),
        // Test targets
        .testTarget(
            name: "MTHTests",
            dependencies: ["MTH", "Cmth"]
        ),
        .testTarget(
            name: "MTHColorTests",
            dependencies: ["MTHColor", "CmthColor"]
        ),
    ]
)
