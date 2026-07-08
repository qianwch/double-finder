import Foundation

enum ViewerMode { case text, hex, preview }

/// Default-mode routing per file (design §3): media/PDF/Office → QL preview;
/// decodable text (no NULs, or has a BOM) → text; everything else → hex.
enum ViewerModeChooser {
    static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "icns", "svg",
        "mp4", "mov", "m4v", "avi", "mkv", "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg",
        "pdf", "rtf", "rtfd", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "key", "pages", "numbers", "epub",
    ]

    static func choose(fileExtension ext: String, sample: Data?)
        -> (mode: ViewerMode, encoding: String.Encoding?) {
        if previewExtensions.contains(ext.lowercased()) { return (.preview, nil) }
        guard let sample else { return (.preview, nil) }       // unreadable → old QL behavior
        guard !sample.isEmpty else { return (.text, .utf8) }   // empty file → empty text
        let hasBOM = sample.starts(with: [0xEF, 0xBB, 0xBF])
            || sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF])
        if !hasBOM && sample.contains(0) { return (.hex, nil) }
        // No NULs (or has a BOM) → treat as text; detection picks the encoding
        // and its ISO-8859-1 fallback guarantees decodability.
        let enc = EncodingDetector.detect(sample: sample)
        // Markdown routes to preview (rendered by ListerWebView, §4.1) but MUST
        // keep the detected encoding — pressing 1 shows correctly-decoded source.
        if ["md", "markdown"].contains(ext.lowercased()) { return (.preview, enc) }
        return (.text, enc)
    }
}
