// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ShadeCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "ShadeCore", targets: ["ShadeCore"])], targets: [.target(name: "ShadeCore"), .testTarget(name: "ShadeCoreTests", dependencies: ["ShadeCore"])])
