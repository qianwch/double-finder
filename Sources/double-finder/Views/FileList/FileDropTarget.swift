import Foundation

/// Pure drop-target logic for the file list — no AppKit view state, so it can be
/// unit-tested.
///
/// Scope note: this type only answers "where would this drop land". Whether the
/// drop is *legal* (a folder onto itself, into its own subtree, or back into its
/// own parent) is `FileOperation.selfTransferSources` — that guard already exists
/// for F5/F6 and must not be duplicated here. Nor is the returned directory
/// checked for existence or writability: a resolved path is a target, not a
/// promise, and the caller still has to handle a refusal.
enum FileDropTarget {

    /// Resolves the directory a drop should land in from the hovered row.
    ///
    /// - A folder row (other than "..") → that folder.
    /// - The ".." row → the parent of `currentPath`. Deliberately derived from
    ///   `currentPath`, not from the row's own `path`: the row is a synthetic
    ///   entry and `currentPath` is the authoritative source.
    /// - A package bundle (.app/.framework/…) → NOT a target. It is a directory,
    ///   but dropping files inside would corrupt the bundle (and break its
    ///   signature), so it falls back to `currentPath` like a plain file.
    ///   The test is `FileItem.isPackageFileName`, which is extension-based and
    ///   deliberately approximate — it covers every signed bundle type but will
    ///   miss an exotic one, and a plain folder named `Foo.bundle` is treated as
    ///   a package. Erring toward "not a target" only costs a drop that lands in
    ///   `currentPath` instead; the reverse would corrupt a bundle.
    /// - A file row, empty space (`row == nil`), or an out-of-range row → `currentPath`.
    static func dropDestinationDir(row: Int?, items: [FileItem], currentPath: String) -> String {
        guard let row = row, row >= 0, row < items.count else { return currentPath }
        let item = items[row]
        if item.name == ".." {
            return (currentPath as NSString).deletingLastPathComponent
        }
        guard item.isDirectory, !FileItem.isPackageFileName(item.name) else { return currentPath }
        return item.path
    }
}
