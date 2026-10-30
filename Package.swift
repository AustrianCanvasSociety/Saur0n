// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "Saur0n",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "saur0n", targets: ["saur0n"]),
    ],
    targets: [
        .target(
            name: "Saur0nCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "saur0n",
            dependencies: ["Saur0nCore"]
        ),
        // The window app. Not `Saur0n`: on a case-insensitive disk it would overwrite the CLI `saur0n`.
        .executableTarget(
            name: "Saur0nApp",
            dependencies: ["Saur0nCore"]
        ),
        .testTarget(
            name: "Saur0nCoreTests",
            dependencies: ["Saur0nCore"]
        ),
    ]
)
