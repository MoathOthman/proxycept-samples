// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ProxyceptRNCore", platforms: [.macOS(.v12), .iOS(.v15)],
    products: [.library(name: "ProxyceptRNCore", targets: ["ProxyceptRNCore"])],
    targets: [
        .target(name: "ProxyceptRNCore", path: "Core"),
        .executableTarget(name: "ProxyceptRNSmoke", dependencies: ["ProxyceptRNCore"], path: "Smoke"),
        .testTarget(name: "ProxyceptRNCoreTests", dependencies: ["ProxyceptRNCore"], path: "Tests")
    ])
