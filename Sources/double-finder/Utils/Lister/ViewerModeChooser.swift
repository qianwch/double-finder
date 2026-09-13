import Foundation

/// `.plugin` = a `ViewerPlugin` claimed the file (PluginManager.viewer(for:)); it
/// is only reachable while such a plugin exists for the current file.
enum ViewerMode { case text, hex, preview, plugin }

/// Default-mode routing per file (design §3): media/PDF/Office → QL preview;
/// decodable text (no NULs, or has a BOM) → text; everything else → hex.
///
/// Rendered pages (Markdown, ebooks …) are NOT decided here any more: a
/// `PageViewerPlugin` that claims the file (built-in `MarkdownPreviewPlugin` /
/// `EbookReaderPlugin`, or a bundle) puts it in Preview; when no plugin claims
/// it, this routing is what the user gets — `.md` shows as highlighted text,
/// `.epub` goes to Quick Look.
enum ViewerModeChooser {
    static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "gif", "bmp", "tiff", "tif", "heic", "heif", "heics", "avif", "webp", "icns",
        "ico", "svg", "psd", "jp2", "exr", "hdr", "tga",
        // camera RAW — Quick Look renders these through the same Image I/O decoders
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2", "pef", "srw",
        "3fr", "fff", "erf", "kdc", "dcr", "mef", "mos", "mrw", "x3f", "raw", "rwl", "iiq",
        "mp4", "mov", "m4v", "avi", "mkv", "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg",
        "pdf", "rtf", "rtfd", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "key", "pages", "numbers", "epub",
    ]

    /// True when the sample decodes as text: no NUL bytes, or a UTF-8/16 BOM
    /// (UTF-16 legitimately contains NULs). Empty samples count as text.
    static func looksLikeText(_ sample: Data) -> Bool {
        guard !sample.isEmpty else { return true }
        let hasBOM = sample.starts(with: [0xEF, 0xBB, 0xBF])
            || sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF])
        return hasBOM || !sample.contains(0)
    }

    static func choose(fileExtension ext: String, sample: Data?)
        -> (mode: ViewerMode, encoding: String.Encoding?) {
        if previewExtensions.contains(ext.lowercased()) { return (.preview, nil) }
        guard let sample else { return (.preview, nil) }       // unreadable → old QL behavior
        guard !sample.isEmpty else { return (.text, .utf8) }   // empty file → empty text
        guard looksLikeText(sample) else { return (.hex, nil) }
        // No NULs (or has a BOM) → treat as text; detection picks the encoding
        // and its ISO-8859-1 fallback guarantees decodability.
        return (.text, EncodingDetector.detect(sample: sample))
    }
}
