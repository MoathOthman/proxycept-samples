// swift-tools-version: 5.9
import PackageDescription

// Repository-root facade lets Xcode/SwiftPM consume the public repository directly.
// The standalone package under sdks/swift remains usable as a local dependency.
let package = Package(
    name: "ProxyceptLogging",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ProxyceptLogging", targets: ["ProxyceptLogging"])],
    targets: [
        .target(name: "ProxyceptLogging", path: "sdks/swift/Sources/ProxyceptLogging"),
        .testTarget(name: "ProxyceptLoggingTests", dependencies: ["ProxyceptLogging"],
                    path: "sdks/swift/Tests/ProxyceptLoggingTests")
    ]
)
