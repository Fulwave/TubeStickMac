// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TubeStickMac",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "TubeStickKit", targets: ["TubeStickKit"]),
        .executable(name: "tubestick", targets: ["tubestick"]),
        .executable(name: "TubeStickMenu", targets: ["TubeStickMenu"]),
    ],
    targets: [
        // Hardware access (IOKit control path, IOUSBHost isochronous stream) and MPEG-TS/PSIP parsing.
        .target(
            name: "CTubeStick",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Swift API: channel scanning, saved channel list, UDP relay, VLC launching.
        .target(name: "TubeStickKit", dependencies: ["CTubeStick"]),
        // Command line tool: scan, list, watch, record, analyze.
        .executableTarget(name: "tubestick", dependencies: ["TubeStickKit"]),
        // Menu bar app.
        .executableTarget(name: "TubeStickMenu", dependencies: ["TubeStickKit"]),
        .testTarget(name: "TubeStickKitTests", dependencies: ["TubeStickKit", "CTubeStick"]),
    ]
)
