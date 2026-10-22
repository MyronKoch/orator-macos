// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orator",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/mlalma/kokoro-ios.git", from: "1.0.0"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
        // Sparkle 2 for direct-distribution auto-updates (PRD 23). Pure
        // framework, no mlx-swift dependency, so it resolves cleanly alongside
        // KokoroSwift's exact 0.30.2 pin.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Phonon TTS (Gradium, Apache-2.0). No SwiftPM dependencies of its own - a prebuilt
        // binary core plus Apple frameworks - so it cannot disturb the exact mlx-swift pin.
        .package(url: "https://github.com/gradium-ai/xn-ptts.git", exact: "0.4.0"),
    ],
    targets: [
        // sherpa-onnx ONNX voice engine, delivered as prebuilt STATIC
        // xcframeworks pulled by URL (they stay OUT of the repo). onnxruntime
        // ships separately from the sherpa framework. Both are onnxruntime-based
        // and carry no mlx-swift dependency, so the exact 0.30.2 pin is
        // untouched. The wrapper lives in Sources/Orator/SherpaOnnx.swift and
        // imports the `SherpaOnnxC` module vended by the sherpa xcframework.
        .binaryTarget(
            name: "SherpaOnnxMacOS",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.4/sherpa-onnx-v1.13.4-macos.xcframework.zip",
            checksum: "4325d8aed99b94be58969005b19f9626f3f3afc4ebd42378b0aad2b84e233552"
        ),
        .binaryTarget(
            name: "OnnxruntimeMacOS",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-macos-static-xcframework-1.27.1.xcframework.zip",
            checksum: "89769c25a63985e2ab7a12e72215c173c5078e49dc4a2273cb84b75e587d7b96"
        ),
        .executableTarget(
            name: "Orator",
            dependencies: [
                .product(name: "KokoroSwift", package: "kokoro-ios"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "ptts", package: "xn-ptts"),
                "SherpaOnnxMacOS",
                "OnnxruntimeMacOS",
            ],
            linkerSettings: [
                // sherpa-onnx / onnxruntime are C++; link the C++ runtime.
                .linkedLibrary("c++"),
            ]
        ),
        // SPIKE (temporary): load Phonon and write a WAV, to prove it runs beside MLX
        // before it becomes Orator's default engine. Delete once PhononProvider lands.
        .executableTarget(
            name: "PhononSmoke",
            dependencies: [.product(name: "ptts", package: "xn-ptts")]
        ),
    ]
)
