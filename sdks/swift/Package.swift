// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProxyceptLogging",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ProxyceptLogging", targets: ["ProxyceptLogging"])],
    targets: [
        .target(name: "ProxyceptLogging"),
        .testTarget(name: "ProxyceptLoggingTests", dependencies: ["ProxyceptLogging"])
    ]
)
