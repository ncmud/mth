// swift-tools-version:6.0
import PackageDescription

var products: [Product] = [
    .library(name: "MTH", targets: ["MTH"]),
    .library(name: "MTHClient", targets: ["MTHClient"]),
    .library(name: "MTHColor", targets: ["MTHColor"]),
]

var targets: [Target] = [
    // Thin C wrapper exposing system zlib to Swift.
    // zlib is present on macOS (SDK) and Linux (Swift toolchain dependency).
    .target(
        name: "CZlib",
        path: "Sources/CZlib",
        publicHeadersPath: "include",
        linkerSettings: [.linkedLibrary("z")]
    ),
    // Shared telnet constants, compression, and MTTS flags used by both server and client.
    .target(
        name: "MTHCore",
        dependencies: [
            .target(name: "CZlib", condition: .when(platforms: [.macOS, .linux, .iOS, .visionOS])),
        ],
        path: "Sources/SwiftMTHCore"
    ),
    // Server-side telnet session, MSDP, MSSP, and related protocols.
    .target(
        name: "MTH",
        dependencies: ["MTHCore"],
        path: "Sources/SwiftMTH"
    ),
    // Client-side telnet session for MUD clients.
    .target(
        name: "MTHClient",
        dependencies: ["MTHCore"],
        path: "Sources/SwiftMTHClient"
    ),
    .target(
        name: "MTHColor",
        dependencies: [],
        path: "Sources/SwiftMTHColor"
    ),
]

// C oracle targets require unix headers (sys/time.h, zlib.h) — exclude on Windows.
#if !os(Windows)
products += [
    .library(name: "Cmth", targets: ["Cmth"]),
    .library(name: "CmthColor", targets: ["CmthColor"]),
]
targets += [
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
    .testTarget(
        name: "MTHTests",
        dependencies: ["MTH", "MTHClient", "Cmth"]
    ),
    .testTarget(
        name: "MTHColorTests",
        dependencies: ["MTHColor", "CmthColor"]
    ),
]
#else
targets += [
    .testTarget(
        name: "MTHTests",
        dependencies: ["MTH", "MTHClient"]
    ),
    .testTarget(
        name: "MTHColorTests",
        dependencies: ["MTHColor"]
    ),
]
#endif

let package = Package(
    name: "mth",
    products: products,
    targets: targets
)
