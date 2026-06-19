// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "mac_ocr_cli",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MacOCRCore",
            targets: ["MacOCRCore"]
        ),
        .executable(
            name: "mac_ocr_cli",
            targets: ["mac_ocr_cli"]
        )
    ],
    targets: [
        .target(
            name: "MacOCRCore",
            path: "Sources/MacOCRCore"
        ),
        .executableTarget(
            name: "mac_ocr_cli",
            dependencies: ["MacOCRCore"],
            path: "Sources/mac_ocr_cli"
        ),
        .testTarget(
            name: "MacOCRCoreTests",
            dependencies: ["MacOCRCore"],
            path: "Tests/MacOCRCoreTests"
        )
    ]
)
