import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum FileTextExtractor {
    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.plainText]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        if let markdown = UTType(filenameExtension: "markdown") {
            types.append(markdown)
        }
        types.append(contentsOf: [.rtf, .pdf])
        return types
    }()

    static func extractText(from url: URL) throws -> String {
        let text: String

        switch url.pathExtension.lowercased() {
        case "txt", "text", "md", "markdown":
            text = try extractPlainText(from: url)
        case "rtf":
            text = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw ExtractionError.unreadablePDF
            }
            let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            text = pages.joined(separator: "\n")

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExtractionError.noSelectablePDFText
            }
        default:
            throw ExtractionError.unsupportedFileType
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw ExtractionError.noReadableText
        }
        return trimmedText
    }

    private static func extractPlainText(from url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }

        var detectedEncoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &detectedEncoding) {
            return text
        }

        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    private enum ExtractionError: LocalizedError {
        case unsupportedFileType
        case unreadablePDF
        case noSelectablePDFText
        case noReadableText

        var errorDescription: String? {
            switch self {
            case .unsupportedFileType:
                return "This file type is not supported"
            case .unreadablePDF:
                return "This PDF could not be opened"
            case .noSelectablePDFText:
                return "This PDF has no selectable text"
            case .noReadableText:
                return "No readable text in this file"
            }
        }
    }
}
