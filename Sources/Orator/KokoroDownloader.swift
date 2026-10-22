import CryptoKit
import Foundation

/// Downloads the optional Kokoro model (Phonon is the default engine, so Kokoro
/// no longer ships inside the app).
///
/// One 312 MB file from Hugging Face, pinned to a commit and checked against its
/// SHA-256 before it is moved into place, so a truncated or tampered download is
/// never loaded. The small voice table (voices.npz) still ships in the app.
enum KokoroDownloader {
    static let sourceURL = URL(string:
        "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/e02c9eada7ce7416798af36b190a8a2dd2ecd566/kokoro-v1_0.safetensors"
    )!
    static let sha256 = "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
    static let byteCount: Int64 = 327_115_152

    static var installedURL: URL {
        OratorEngine.modelsDirectory.appendingPathComponent("kokoro/kokoro-v1_0.safetensors")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// Download, verify and install. `progress` gets 0...1 on the main actor.
    /// Cancelling the calling task cancels the download.
    static func download(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        let temporary = try await fetch(progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard try sha256Hex(of: temporary) == sha256 else { throw KokoroDownloadError.checksum }

        let destination = installedURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        await progress(1)
        return destination
    }

    /// A plain download task, observed through its `Progress`: the async
    /// `download(from:)` API does not report progress to a session delegate.
    private static func fetch(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: sourceURL) { location, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let location else {
                        continuation.resume(throwing: KokoroDownloadError.http((response as? HTTPURLResponse)?.statusCode ?? -1))
                        return
                    }
                    // The system deletes `location` when this handler returns, so keep a copy.
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("kokoro-\(UUID().uuidString).safetensors")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: kept)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { observed, _ in
                    // Hold back the last 2% for the checksum and the move into place.
                    let fraction = min(0.98, observed.fractionCompleted * 0.98)
                    Task { @MainActor in progress(fraction) }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }

    /// Delete the downloaded model. The engine must be told first (`uninstallKokoro`).
    static func remove() throws {
        try FileManager.default.removeItem(at: installedURL.deletingLastPathComponent())
    }

    /// Streamed, so hashing 312 MB never holds the whole file in memory.
    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 4 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum KokoroDownloadError: LocalizedError {
    case http(Int)
    case checksum

    var errorDescription: String? {
        switch self {
        case .http(let code): return "The Kokoro download failed (HTTP \(code))."
        case .checksum: return "The Kokoro download was incomplete or damaged. Please try again."
        }
    }
}
