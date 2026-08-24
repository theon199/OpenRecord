// swift-tools-version: 6.0
import PackageDescription

// Command Line Tools ships Testing.framework here (not XCTest).
let developerDir = Context.environment["DEVELOPER_DIR"] ?? "/Library/Developer/CommandLineTools"
let testingFrameworksPath = "\(developerDir)/Library/Developer/Frameworks"
let testingInteropLibPath = "\(developerDir)/Library/Developer/usr/lib"
let testingMacrosPath = "\(developerDir)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

let appleFrameworks: [LinkerSetting] = [
    .linkedFramework("SwiftUI"),
    .linkedFramework("AppKit"),
    .linkedFramework("ScreenCaptureKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("CoreMedia"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreText"),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("UniformTypeIdentifiers"),
    .linkedFramework("CoreImage"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("Carbon"),
    .linkedFramework("VideoToolbox"),
    .linkedFramework("ApplicationServices"),
    .linkedFramework("ImageIO"),
    .linkedFramework("CoreVideo"),
]

let package = Package(
    name: "OpenRecord",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "OpenRecord", targets: ["OpenRecordApp"])
    ],
    targets: [
        // Contracts + stubs. Tests import this module (not the @main executable).
        .target(
            name: "OpenRecord",
            path: "Sources/OpenRecord",
            linkerSettings: appleFrameworks
        ),
        .executableTarget(
            name: "OpenRecordApp",
            dependencies: [
                "OpenRecord"
            ],
            path: "Sources/OpenRecordApp",
            linkerSettings: appleFrameworks
        ),
        .testTarget(
            name: "OpenRecordTests",
            dependencies: [
                "OpenRecord"
            ],
            path: "Tests/OpenRecordTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", testingFrameworksPath,
                    "-Xfrontend", "-load-plugin-library",
                    "-Xfrontend", testingMacrosPath,
                ])
            ],
            linkerSettings: [
                .linkedFramework("Testing"),
                .unsafeFlags([
                    "-F", testingFrameworksPath,
                    "-L", testingInteropLibPath,
                    "-Xlinker", "-rpath",
                    "-Xlinker", testingFrameworksPath,
                    "-Xlinker", "-rpath",
                    "-Xlinker", testingInteropLibPath,
                ]),
            ]
        ),
    ]
)
