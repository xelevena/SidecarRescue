// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SidecarRescue",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "sidecar-rescue", targets: ["SidecarRescue"])
    ],
    targets: [
        .executableTarget(
            name: "SidecarRescue",
            path: "Sources/SidecarRescue"
        )
    ]
)
