// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StreamWebRTC",
    platforms: [.iOS(.v13)],
    products: [.library(name: "StreamWebRTC", targets: ["StreamWebRTC"])],
    targets: [.binaryTarget(name: "StreamWebRTC", path: "StreamWebRTC.xcframework")]
)
