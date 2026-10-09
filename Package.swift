// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nodither",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "nodither")]
)
