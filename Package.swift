// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickUse",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "QuickUse",
            path: "Sources/QuickUse",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Security"),
                .linkedFramework("EventKit"),
            ]
        ),
        .testTarget(
            name: "QuickUseTests",
            dependencies: ["QuickUse"],
            path: "Tests/QuickUseTests"
        ),
    ]
)
