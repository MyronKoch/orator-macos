// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KokoroSpeak",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/mlalma/kokoro-ios.git", from: "1.0.0"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
    ],
    targets: [
        .executableTarget(
            name: "KokoroSpeak",
            dependencies: [
                .product(name: "KokoroSwift", package: "kokoro-ios"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
    ]
)
