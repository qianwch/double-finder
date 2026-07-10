import Foundation

/// TC-style parse of the Copy/Move confirm dialog's destination field.
///
/// The field is prefilled with `<destDir>/<name>` for a single item (editing the
/// last component renames on transfer) and `<destDir>/*.*` for multiple items.
/// Parsing recovers the destination directory plus an optional new name:
///
/// - trailing "/" → the whole input is the directory (explicit dir override)
/// - last component contains a wildcard → mask; stripped back to the parent
///   directory (only full-mask `*.*` semantics — partial masks are not applied)
/// - multiple items → the input IS the directory
/// - single item, last component == source name → unedited default; parent is
///   the directory (never dir-probed, so a same-named folder at the destination
///   means overwrite/merge, not nesting)
/// - single item, input is an existing directory → copy into it, keep the name
/// - single item otherwise → parent is the directory, last component is the new name
struct TransferDestination: Equatable {
    let dir: String
    /// Transfer the (single) item under this name instead of its own; nil keeps names.
    let renameTo: String?

    /// The filesystem leaf of a listing item's `name`. Virtual listings (search
    /// results, branch view) put a display *path* in `name` (e.g. "sub/f.docx")
    /// so files from different folders don't collide in the list — but the
    /// transfer's destination side only ever wants the final component. Without
    /// this, the prefilled "<destDir>/sub/f.docx" parses as a rename into a
    /// non-existent "<destDir>/sub" sub-folder and the copy fails.
    static func transferName(for itemName: String) -> String {
        itemName.contains("/") ? (itemName as NSString).lastPathComponent : itemName
    }

    /// - singleSourceName: the sole selected item's name, or nil when several are selected.
    /// - isExistingDir: backend-specific probe (local → FileManager; remote → `{ _ in false }`,
    ///   where only a trailing "/" can force directory mode).
    static func parse(_ input: String, singleSourceName: String?,
                      isExistingDir: (String) -> Bool) -> TransferDestination {
        func normalized(_ p: String) -> String {
            p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        }
        if input.count > 1 && input.hasSuffix("/") {
            return TransferDestination(dir: normalized(input), renameTo: nil)
        }
        let path = normalized(input)
        let last = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        if last.contains("*") || last.contains("?") {
            return TransferDestination(dir: parent, renameTo: nil)
        }
        guard let sourceName = singleSourceName else {
            return TransferDestination(dir: path, renameTo: nil)
        }
        if path == "/" || last == sourceName {
            return TransferDestination(dir: path == "/" ? "/" : parent, renameTo: nil)
        }
        if isExistingDir(path) {
            return TransferDestination(dir: path, renameTo: nil)
        }
        return TransferDestination(dir: parent, renameTo: last)
    }
}
