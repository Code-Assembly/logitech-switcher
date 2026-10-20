// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "logitech-switcher",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "LogiCore"),
        .target(name: "LogiHID", dependencies: ["LogiCore"]),
        .executableTarget(name: "logitech-switcher", dependencies: ["LogiCore", "LogiHID"]),
        .executableTarget(name: "spike", dependencies: ["LogiCore"]),
        .testTarget(name: "LogiCoreTests", dependencies: ["LogiCore"], exclude: ["Fixtures"]),
    ]
)
