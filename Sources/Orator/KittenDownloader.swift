import Foundation

actor KittenDownloader {

    private static let shared = KittenDownloader()
    private static let modelDirectoryName = "kitten-mini-en-v0_8"
    private static let archives = [
        (
            name: "KittenTTS model",
            url: URL(
                string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kitten-mini-en-v0_8.tar.bz2"
            )!
        ),
        (
            name: "eSpeak NG data",
            url: URL(
                string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/espeak-ng-data.tar.bz2"
            )!
        ),
    ]

    static func download(
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        try await shared.performDownload(progress: progress)
    }

    private func performDownload(
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let modelsDirectory = OratorEngine.modelsDirectory
        let finalModelDirectory = modelsDirectory.appendingPathComponent(
            Self.modelDirectoryName,
            isDirectory: true
        )
        let finalModel = finalModelDirectory.appendingPathComponent("model.onnx")
        guard !fileManager.fileExists(atPath: finalModel.path) else { return }

        do {
            try fileManager.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw KittenDownloadError.fileOperation(
                "Could not create the Orator models directory",
                error
            )
        }

        let temporaryDirectory = modelsDirectory.appendingPathComponent(
            ".kitten-download-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw KittenDownloadError.fileOperation(
                "Could not create a temporary KittenTTS download directory",
                error
            )
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        await progress(0)
        var archiveURLs: [URL] = []
        for (index, archive) in Self.archives.enumerated() {
            let destination = temporaryDirectory.appendingPathComponent(
                archive.url.lastPathComponent
            )
            do {
                try await download(
                    archive.url,
                    to: destination,
                    baseProgress: Double(index) / Double(Self.archives.count),
                    progressWeight: 1.0 / Double(Self.archives.count),
                    progress: progress
                )
            } catch let error as KittenDownloadError {
                throw error
            } catch {
                throw KittenDownloadError.downloadFailed(archive.name, error)
            }
            archiveURLs.append(destination)
        }

        let stagingDirectory = temporaryDirectory.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
            try extract(
                archiveURLs[0],
                named: Self.archives[0].name,
                to: stagingDirectory
            )
            try extract(
                archiveURLs[1],
                named: Self.archives[1].name,
                to: stagingDirectory
            )
        } catch let error as KittenDownloadError {
            throw error
        } catch {
            throw KittenDownloadError.fileOperation(
                "Could not stage the KittenTTS model",
                error
            )
        }

        let stagedModelDirectory = stagingDirectory.appendingPathComponent(
            Self.modelDirectoryName,
            isDirectory: true
        )
        let stagedEspeakDirectory = stagingDirectory.appendingPathComponent(
            "espeak-ng-data",
            isDirectory: true
        )
        let modelEspeakDirectory = stagedModelDirectory.appendingPathComponent(
            "espeak-ng-data",
            isDirectory: true
        )

        guard fileManager.fileExists(
            atPath: stagedModelDirectory.appendingPathComponent("model.onnx").path
        ) else {
            throw KittenDownloadError.missingRequiredFile("model.onnx")
        }
        for filename in ["voices.bin", "tokens.txt"] {
            guard fileManager.fileExists(
                atPath: stagedModelDirectory.appendingPathComponent(filename).path
            ) else {
                throw KittenDownloadError.missingRequiredFile(filename)
            }
        }
        guard fileManager.fileExists(atPath: stagedEspeakDirectory.path) else {
            throw KittenDownloadError.missingRequiredFile("espeak-ng-data")
        }

        do {
            if fileManager.fileExists(atPath: modelEspeakDirectory.path) {
                try fileManager.removeItem(at: modelEspeakDirectory)
            }
            try fileManager.moveItem(
                at: stagedEspeakDirectory,
                to: modelEspeakDirectory
            )

            if fileManager.fileExists(atPath: finalModelDirectory.path) {
                let previousDirectory = temporaryDirectory.appendingPathComponent(
                    "previous-model",
                    isDirectory: true
                )
                try fileManager.moveItem(
                    at: finalModelDirectory,
                    to: previousDirectory
                )
                do {
                    try fileManager.moveItem(
                        at: stagedModelDirectory,
                        to: finalModelDirectory
                    )
                } catch {
                    try? fileManager.moveItem(
                        at: previousDirectory,
                        to: finalModelDirectory
                    )
                    throw error
                }
            } else {
                try fileManager.moveItem(
                    at: stagedModelDirectory,
                    to: finalModelDirectory
                )
            }
        } catch {
            throw KittenDownloadError.fileOperation(
                "Could not install the KittenTTS model",
                error
            )
        }

        guard fileManager.fileExists(atPath: finalModel.path) else {
            throw KittenDownloadError.missingRequiredFile("model.onnx")
        }
        await progress(1)
    }

    private func download(
        _ source: URL,
        to destination: URL,
        baseProgress: Double,
        progressWeight: Double,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: source)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw KittenDownloadError.httpFailure(source, status)
        }

        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil
        ) else {
            throw KittenDownloadError.fileOperation(
                "Could not create \(destination.lastPathComponent)",
                nil
            )
        }

        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        let expectedLength = response.expectedContentLength
        var receivedLength: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            receivedLength += 1
            if buffer.count >= 64 * 1024 {
                try file.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if expectedLength > 0 {
                    let fraction = min(
                        1,
                        Double(receivedLength) / Double(expectedLength)
                    )
                    await progress(baseProgress + fraction * progressWeight)
                }
            }
        }
        if !buffer.isEmpty {
            try file.write(contentsOf: buffer)
        }
        await progress(baseProgress + progressWeight)
    }

    private func extract(_ archive: URL, named name: String, to destination: URL) throws {
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xf", archive.path, "-C", destination.path]
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw KittenDownloadError.extractionLaunchFailed(name, error)
        }

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw KittenDownloadError.extractionFailed(
                name,
                process.terminationStatus,
                detail
            )
        }
    }
}

private enum KittenDownloadError: LocalizedError {
    case downloadFailed(String, Error)
    case httpFailure(URL, Int)
    case extractionLaunchFailed(String, Error)
    case extractionFailed(String, Int32, String?)
    case missingRequiredFile(String)
    case fileOperation(String, Error?)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let name, let error):
            return "Could not download \(name): \(error.localizedDescription)"
        case .httpFailure(let url, let status):
            return "Could not download \(url.lastPathComponent): the server returned HTTP \(status)"
        case .extractionLaunchFailed(let name, let error):
            return "Could not start tar for \(name): \(error.localizedDescription)"
        case .extractionFailed(let name, let status, let detail):
            let suffix = detail.map { ": \($0)" } ?? ""
            return "Could not extract \(name) - tar exited with status \(status)\(suffix)"
        case .missingRequiredFile(let filename):
            return "The downloaded KittenTTS archive is missing \(filename)"
        case .fileOperation(let message, let error):
            guard let error else { return message }
            return "\(message): \(error.localizedDescription)"
        }
    }
}
