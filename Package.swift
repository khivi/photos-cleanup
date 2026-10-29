// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "photos-cleanup",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PhotosCleanupApp", targets: ["PhotosCleanupApp"])
    ],
    targets: [
        // No UI framework: PhotoKit, Vision, the passes, verdicts, job state and the review
        // screen's model. The tests drive it with fakes.
        .target(name: "PhotosCleanupCore"),
        // The SwiftUI app. Run as a bundle: `scripts/app.sh` assembles Info.plist into one.
        .executableTarget(
            name: "PhotosCleanupApp",
            dependencies: ["PhotosCleanupCore"],
            exclude: ["Info.plist", "PhotosCleanup.entitlements", "AppIcon.svg"]
        ),
        .testTarget(name: "PhotosCleanupCoreTests", dependencies: ["PhotosCleanupCore"]),
    ]
)
