// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Privy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Privy", targets: ["Privy"]),
        .library(name: "PrivyCore", targets: ["PrivyCore"]),
        .executable(name: "OpusSpike", targets: ["OpusSpike"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .systemLibrary(name: "COpus", path: "Libraries/COpus", pkgConfig: "opus", providers: [.brew(["opus"])]),
        .systemLibrary(name: "COgg", path: "Libraries/COgg", pkgConfig: "ogg", providers: [.brew(["libogg"])]),
        .target(name: "OpusShim", dependencies: ["COpus"]),
        .target(name: "OpusIO", dependencies: ["COpus", "COgg", "OpusShim"]),
        .target(
            name: "PrivyCore",
            dependencies: [
                "OpusIO",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "Sources/PrivyCore"
        ),
        .executableTarget(name: "Privy", dependencies: ["PrivyCore"], path: "Sources/Privy"),
        .testTarget(
            name: "PrivyCoreTests",
            dependencies: ["PrivyCore", "OpusIO"],
            path: "Tests/PrivyTests"
        ),
        .executableTarget(name: "OpusSpike", dependencies: ["OpusIO"], path: "Sources/OpusSpike"),
    ]
)
