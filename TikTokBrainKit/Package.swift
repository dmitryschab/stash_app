// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TikTokBrainKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TikTokBrainKit", targets: ["TikTokBrainKit"])],
    targets: [
        .target(name: "TikTokBrainKit"),
        .testTarget(name: "TikTokBrainKitTests", dependencies: ["TikTokBrainKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
