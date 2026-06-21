import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let path: String          // full absolute path
    let isDirectory: Bool
    let isArchive: Bool       // .zip .jar etc
    let size: Int64
    let modified: Date
    let isHidden: Bool
    let isSymlink: Bool
    var permissions: String   // "rwxr-xr-x"
    var calculatedSize: Int64? = nil   // recursive size once computed (Space / Calculate Size)
    var depth: Int = 0                 // indentation level when a folder is expanded in place
    var dateAdded: Date? = nil         // when added to its folder (optional column)
    var dateCreated: Date? = nil       // creation date (optional column)

    /// Human-readable file kind (optional "Kind" column).
    var kind: String {
        if isDirectory { return "Folder" }
        if isSymlink { return "Alias" }
        let ext = (name as NSString).pathExtension
        if ext.isEmpty { return "Document" }
        if let type = UTType(filenameExtension: ext), let desc = type.localizedDescription {
            return desc
        }
        return ext.uppercased() + " file"
    }

    /// Formats an optional date like the Modified column, or "--" when absent.
    func formatted(_ date: Date?) -> String {
        guard let date = date else { return "--" }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: date)
    }

    static func parentEntry(for path: String) -> FileItem {
        FileItem(
            id: UUID(),
            name: "..",
            path: (path as NSString).deletingLastPathComponent,
            isDirectory: true,
            isArchive: false,
            size: 0,
            modified: Date(),
            isHidden: false,
            isSymlink: false,
            permissions: "rwxr-xr-x"
        )
    }

    static let archiveExtensions: Set<String> = ["zip", "jar", "war", "ear", "ipa", "apk"]

    /// File-name suffixes treated as browsable/extractable archives (incl. compound
    /// like .tar.gz). Single-file compressors (.gz/.bz2/.xz/.zst) are not listed
    /// here because they aren't browsable containers.
    static let archiveSuffixes: [String] = [
        ".zip", ".jar", ".war", ".ear", ".ipa", ".apk", ".cbz",
        ".7z", ".rar", ".cbr",
        ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2",
        ".tar.xz", ".txz", ".tar.zst", ".tzst", ".tar.z",
        // bare single-file compressors (browsable as a one-file archive)
        ".gz", ".bz2", ".xz", ".zst", ".lz4"
    ]

    static func isArchiveFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return archiveSuffixes.contains { lower.hasSuffix($0) }
    }

    /// The archive file name with its archive extension removed — the default
    /// folder name to extract into. Strips the LONGEST matching archive suffix so
    /// "foo.tar.gz" → "foo" (not "foo.tar"), "foo.zip" → "foo".
    static func archiveBaseName(of name: String) -> String {
        let lower = name.lowercased()
        if let suffix = archiveSuffixes.filter({ lower.hasSuffix($0) }).max(by: { $0.count < $1.count }) {
            return String(name.dropLast(suffix.count))
        }
        return (name as NSString).deletingPathExtension
    }

    /// Size used for sorting/totals: the computed recursive size if available.
    var effectiveSize: Int64 { calculatedSize ?? size }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        if let computed = calculatedSize {
            return formatter.string(fromByteCount: computed)
        }
        if isDirectory { return "<DIR>" }
        return formatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: modified)
    }
}
