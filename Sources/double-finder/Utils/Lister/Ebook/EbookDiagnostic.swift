import Foundation

/// Headless `NC_EBOOK_DUMP` entry (see main.swift): parses one book exactly as
/// F3 would and prints what came out — for debugging a file that renders wrong.
enum EbookDiagnostic {
    static func run(path: String, out: String?) {
        let url = URL(fileURLWithPath: path)
        let started = Date()
        do {
            let book = url.pathExtension.lowercased() == "epub"
                ? try EPUBReader.read(url: url) : try MOBIReader.read(url: url)
            let html = EbookHTML.page(for: book)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("format:   \(book.formatName)")
            print("title:    \(book.title)")
            print("author:   \(book.author ?? "-")")
            print("cover:    \(book.coverDataURI.map { "\($0.utf8.count) bytes" } ?? "none")")
            print("css:      \(book.css.count) sheet(s), \(book.css.reduce(0) { $0 + $1.utf8.count }) bytes")
            print("chapters: \(book.chapters.count)")
            for c in book.chapters.prefix(12) {
                let preview = c.html.replacingOccurrences(of: "\n", with: " ").prefix(90)
                print("  [\(c.index)] \(c.html.utf8.count) bytes  \(preview)")
            }
            if book.chapters.count > 12 { print("  …") }
            print("toc:      \(book.toc.count) entries")
            for t in book.toc.prefix(40) {
                print("  " + String(repeating: "  ", count: t.depth) + "\(t.title) → #\(t.anchor)")
            }
            if book.toc.count > 40 { print("  …") }
            print("page:     \(html.utf8.count) bytes, \(ms) ms")
            if let out {
                try html.write(toFile: out, atomically: true, encoding: .utf8)
                print("written:  \(out)")
            }
        } catch EbookError.drm {
            print("FAILED: DRM-protected")
        } catch EbookError.unsupported(let what) {
            print("FAILED: unsupported (\(what))")
        } catch EbookError.corrupt(let what) {
            print("FAILED: corrupt (\(what))")
        } catch {
            print("FAILED: \(error)")
        }
    }
}
