// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WallpaperVideo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WallpaperVideo",
            path: "Sources/WallpaperVideo"
        )
    ]
)
