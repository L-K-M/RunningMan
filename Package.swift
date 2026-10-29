// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunningMan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RunningMan", targets: ["RunningMan"]),
        .executable(name: "RunningManWidgets", targets: ["RunningManWidgets"])
    ],
    targets: [
        .target(name: "RunningManCore"),
        .target(name: "RunningManServices", dependencies: ["RunningManCore"]),
        .target(name: "RunningManWidgetViews", dependencies: ["RunningManCore"],
                swiftSettings: [.unsafeFlags(["-application-extension"])]),
        // Start at NSExtensionMain like Xcode's app extensions; started at SwiftPM's
        // main, the widget extension traps in ExtensionFoundation (build-app.sh checks).
        .executableTarget(name: "RunningManWidgets", dependencies: ["RunningManCore", "RunningManWidgetViews"],
                          swiftSettings: [.unsafeFlags(["-application-extension"])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension",
                                                         "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .executableTarget(name: "RunningMan", dependencies: ["RunningManCore", "RunningManServices", "RunningManWidgetViews"]),
        .testTarget(name: "RunningManCoreTests", dependencies: ["RunningManCore"]),
        .testTarget(name: "RunningManServicesTests", dependencies: ["RunningManCore", "RunningManServices"]),
        .testTarget(name: "RunningManAppTests", dependencies: ["RunningMan", "RunningManCore"])
    ],
    swiftLanguageModes: [.v5]
)
