// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "photos-cleanup",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "photos-cleanup", targets: ["PhotosCleanup"]),
        .executable(name: "PhotosCleanupApp", targets: ["PhotosCleanupApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // Pure Swift, no web framework: PhotoKit, Vision, the passes, verdicts and job state.
        // A native app could import this as is.
        .target(name: "PhotosCleanupCore"),
        // The HTTP API over Core (Hummingbird): routes, JSON shapes, static UI files.
        .target(
            name: "PhotosCleanupServer",
            dependencies: [
                "PhotosCleanupCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        // The `photos-cleanup` command: startup checks, then the server. The built UI ships
        // as a resource (`pnpm build` writes it to Sources/PhotosCleanup/ui/dist).
        .executableTarget(
            name: "PhotosCleanup",
            dependencies: ["PhotosCleanupCore", "PhotosCleanupServer"],
            exclude: ["Info.plist"],
            resources: [.copy("ui")],
            // PhotoKit shows its permission prompt only with a usage string in Info.plist.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PhotosCleanup/Info.plist",
                ]),
            ]
        ),
        // The native SwiftUI app. Run as a bundle: `scripts/app.sh` assembles Info.plist into one.
        .executableTarget(
            name: "PhotosCleanupApp",
            dependencies: ["PhotosCleanupCore"],
            exclude: ["Info.plist", "PhotosCleanup.entitlements", "AppIcon.svg"]
        ),
        .testTarget(name: "PhotosCleanupCoreTests", dependencies: ["PhotosCleanupCore"]),
        .testTarget(
            name: "PhotosCleanupServerTests",
            dependencies: [
                "PhotosCleanupServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
