// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Privy",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .systemLibrary(name: "COpus", path: "Libraries/COpus", pkgConfig: "opus", providers: [.brew(["opus"])]),
        .systemLibrary(name: "COgg", path: "Libraries/COgg", pkgConfig: "ogg", providers: [.brew(["libogg"])]),
        .target(name: "OpusShim", dependencies: ["COpus"]),
        .target(name: "OpusIO", dependencies: ["COpus", "COgg", "OpusShim"]),
        .executableTarget(
            name: "Privy",
            dependencies: [
                "OpusIO",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Privy"
        ),
        .testTarget(name: "PrivyTests", dependencies: ["Privy", "OpusIO"]),
        .executableTarget(name: "OpusSpike", dependencies: ["OpusIO"], path: "Sources/OpusSpike"),
    ]
)
