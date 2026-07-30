import Foundation

actor KittenDownloader {

    private static let shared = KittenDownloader()
    private static let releaseBaseURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/"
    )!

    static func download(
        _ model: CatalogModel,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        try await shared.performDownload(model, progress: progress)
    }

    private func performDownload(
        _ model: CatalogModel,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let modelsDirectory = OratorEngine.modelsDirectory
        let finalModelDirectory = VoiceCatalog.installDir(for: model)
        guard !containsModel(at: finalModelDirectory) else { return }

        do {
            try fileManager.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw CatalogDownloadError.fileOperation(
                "Could not create the Orator models directory",
                error
            )
        }

        let temporaryDirectory = modelsDirectory.appendingPathComponent(
            ".catalog-download-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw CatalogDownloadError.fileOperation(
                "Could not create a temporary model download directory",
                error
            )
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let modelArchive = Archive(
            name: model.archive,
            url: Self.releaseBaseURL.appendingPathComponent(
                "\(model.archive).tar.bz2"
            )
        )
        var archives = [modelArchive]
        if model.needsEspeakData {
            archives.append(
                Archive(
                    name: "eSpeak NG data",
                    url: Self.releaseBaseURL.appendingPathComponent(
                        "espeak-ng-data.tar.bz2"
                    )
                )
            )
        }

        await progress(0)
        var downloadedArchives: [URL] = []
        for (index, archive) in archives.enumerated() {
            let destination = temporaryDirectory.appendingPathComponent(
                archive.url.lastPathComponent
            )
            do {
                try await download(
                    archive.url,
                    to: destination,
                    baseProgress: Double(index) / Double(archives.count),
                    progressWeight: 1.0 / Double(archives.count),
                    progress: progress
                )
            } catch let error as CatalogDownloadError {
                throw error
            } catch {
                throw CatalogDownloadError.downloadFailed(archive.name, error)
            }
            downloadedArchives.append(destination)
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
            for (archive, downloadedArchive) in zip(
                archives,
                downloadedArchives
            ) {
                try extract(
                    downloadedArchive,
                    named: archive.name,
                    to: stagingDirectory
                )
            }
        } catch let error as CatalogDownloadError {
            throw error
        } catch {
            throw CatalogDownloadError.fileOperation(
                "Could not stage \(model.archive)",
                error
            )
        }

        let stagedModelDirectory = stagingDirectory.appendingPathComponent(
            model.archive,
            isDirectory: true
        )
        guard containsModel(at: stagedModelDirectory) else {
            throw CatalogDownloadError.missingRequiredFile(
                "\(model.archive)/*.onnx"
            )
        }

        if model.needsEspeakData {
            let stagedEspeakDirectory = stagingDirectory.appendingPathComponent(
                "espeak-ng-data",
                isDirectory: true
            )
            let modelEspeakDirectory = stagedModelDirectory.appendingPathComponent(
                "espeak-ng-data",
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: stagedEspeakDirectory.path) else {
                throw CatalogDownloadError.missingRequiredFile("espeak-ng-data")
            }
            do {
                if fileManager.fileExists(atPath: modelEspeakDirectory.path) {
                    try fileManager.removeItem(at: modelEspeakDirectory)
                }
                try fileManager.moveItem(
                    at: stagedEspeakDirectory,
                    to: modelEspeakDirectory
                )
            } catch {
                throw CatalogDownloadError.fileOperation(
                    "Could not install eSpeak NG data into \(model.archive)",
                    error
                )
            }
        }

        do {
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
            throw CatalogDownloadError.fileOperation(
                "Could not install \(model.archive)",
                error
            )
        }

        guard containsModel(at: finalModelDirectory) else {
            throw CatalogDownloadError.missingRequiredFile(
                "\(model.archive)/*.onnx"
            )
        }
        await progress(1)
    }

    private func containsModel(at directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.pathExtension.lowercased() == "onnx" }
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
            throw CatalogDownloadError.httpFailure(source, status)
        }

        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil
        ) else {
            throw CatalogDownloadError.fileOperation(
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

    private func extract(
        _ archive: URL,
        named name: String,
        to destination: URL
    ) throws {
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xf", archive.path, "-C", destination.path]
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CatalogDownloadError.extractionLaunchFailed(name, error)
        }

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CatalogDownloadError.extractionFailed(
                name,
                process.terminationStatus,
                detail
            )
        }
    }

    private struct Archive {
        let name: String
        let url: URL
    }
}

private enum CatalogDownloadError: LocalizedError {
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
            return "The downloaded model archive is missing \(filename)"
        case .fileOperation(let message, let error):
            guard let error else { return message }
            return "\(message): \(error.localizedDescription)"
        }
    }
}
