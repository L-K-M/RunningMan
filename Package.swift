// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunningMan",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RunningMan", targets: ["RunningMan"])],
    targets: [
        .target(name: "RunningManCore"),
        .target(name: "RunningManServices", dependencies: ["RunningManCore"]),
        .executableTarget(name: "RunningMan", dependencies: ["RunningManCore", "RunningManServices"]),
        .testTarget(name: "RunningManCoreTests", dependencies: ["RunningManCore"]),
        .testTarget(name: "RunningManServicesTests", dependencies: ["RunningManCore", "RunningManServices"]),
        .testTarget(name: "RunningManAppTests", dependencies: ["RunningMan", "RunningManCore"])
    ],
    swiftLanguageModes: [.v5]
)
