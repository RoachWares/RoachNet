import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

enum VaultPreviewAssetSupport {
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "json", "yaml", "yml", "toml", "ini", "cfg",
        "csv", "tsv", "xml", "html", "css", "js", "jsx", "ts", "tsx", "swift", "py",
        "rb", "sh", "bash", "zsh", "fish", "c", "h", "hpp", "cpp", "m", "mm", "java",
        "kt", "go", "rs", "cs", "php", "sql", "log", "plist"
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]

    static func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func fileSizeLabel(for url: URL) -> String? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize
        else {
            return nil
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(fileSize))
    }

    static func modifiedAtLabel(for url: URL) -> String? {
        guard
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
            let modifiedAt = values.contentModificationDate
        else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modifiedAt)
    }

    static func lineCount(for text: String) -> Int {
        max(text.components(separatedBy: .newlines).count, text.isEmpty ? 0 : 1)
    }

    static func wordCount(for text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func wikiLinks(in text: String) -> [String] {
        let pattern = #"\[\[([^\[\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let linkRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[linkRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum VaultPreviewKind: Equatable {
    case markdown
    case text
    case image
    case audio
    case video
    case pdf
    case book
    case folder
    case generic

    static func resolve(for url: URL) -> VaultPreviewKind {
        if url.hasDirectoryPath {
            return .folder
        }

        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return .markdown
        case let ext where VaultPreviewAssetSupport.textExtensions.contains(ext):
            return .text
        case let ext where VaultPreviewAssetSupport.imageExtensions.contains(ext):
            return .image
        case "mp3", "m4a", "wav", "flac", "ogg", "aac", "aiff":
            return .audio
        case "mp4", "m4v", "mov", "webm", "mkv":
            return .video
        case "pdf":
            return .pdf
        case "epub":
            return .book
        default:
            return .generic
        }
    }

    var shelfLabel: String {
        switch self {
        case .markdown:
            return "Notes Lane"
        case .text:
            return "Text Deck"
        case .image:
            return "Lightbox"
        case .audio:
            return "Listening Room"
        case .video:
            return "Screening Room"
        case .pdf, .book:
            return "Reader"
        case .folder:
            return "Shelf Folder"
        case .generic:
            return "Vault Preview"
        }
    }
}

enum RoachClawContextSupport {
    private static let excerptableExtensions = VaultPreviewAssetSupport.textExtensions.union(["rtf"])

    static func textExcerpt(for url: URL, maxCharacters: Int = 420) -> String? {
        guard !url.hasDirectoryPath else { return nil }

        let fileExtension = url.pathExtension.lowercased()

        if excerptableExtensions.contains(fileExtension) {
            guard let text = try? VaultPreviewAssetSupport.loadText(from: url), !text.isEmpty else {
                return nil
            }
            return normalizedExcerpt(text, maxCharacters: maxCharacters)
        }

        #if canImport(PDFKit)
        if fileExtension == "pdf", let text = PDFDocument(url: url)?.string {
            return normalizedExcerpt(text, maxCharacters: maxCharacters)
        }
        #endif

        return nil
    }

    static func normalizedExcerpt(_ text: String, maxCharacters: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let squashed = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !squashed.isEmpty else { return nil }
        guard squashed.count > maxCharacters else { return squashed }
        return String(squashed.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
