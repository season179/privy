// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Privy",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "COpus", path: "Libraries/COpus", pkgConfig: "opus", providers: [.brew(["opus"])]),
        .systemLibrary(name: "COgg", path: "Libraries/COgg", pkgConfig: "ogg", providers: [.brew(["libogg"])]),
        .target(name: "OpusShim", dependencies: ["COpus"]),
        .target(name: "OpusIO", dependencies: ["COpus", "COgg", "OpusShim"]),
        .executableTarget(name: "Privy", dependencies: ["OpusIO"], path: "Sources/Privy"),
        .executableTarget(name: "OpusSpike", dependencies: ["OpusIO"], path: "Sources/OpusSpike"),
    ]
)
