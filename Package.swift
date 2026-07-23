// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WallpaperVideo",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "WallpaperVideo",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/WallpaperVideo"
        )
    ]
)
