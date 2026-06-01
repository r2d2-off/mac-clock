// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DualTimeMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DualTimeMenuBar", targets: ["DualTimeMenuBar"]),
        .executable(name: "IPTimeDaemon", targets: ["IPTimeDaemon"])
    ],
    targets: [
        .executableTarget(name: "DualTimeMenuBar"),
        .executableTarget(
            name: "IPTimeDaemon",
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
