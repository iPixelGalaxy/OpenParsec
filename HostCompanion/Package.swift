// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "OpenParsecHost",
    platforms: [.macOS(.v10_15)],
    targets: [.target(name: "OpenParsecHost", path: "Sources")]
)
