import Foundation

/// A virtual path into an MTP device: `/<storage>/<dir>/<file>`.
///
/// MTP addresses objects by `(storage_id, object_id)` — it has no paths at all.
/// The whole UI (`FileItem.path`, history, favorites, the path bar) works in
/// strings, so this virtual mapping bridges the two: the device root `/` lists
/// the storages as if they were folders, which keeps `cd ..` semantics natural
/// and means a phone with an SD card needs no second "drive".
///
/// Pure value type — no libmtp involved, fully unit-tested. Device-supplied
/// storage descriptions are arbitrary text (a real Galaxy reports "内部存储"),
/// so names are never trimmed or transliterated; only "/" is replaced, since it
/// would otherwise break path splitting.
struct MTPPath: Equatable {
    /// Normalized path: no trailing slash, no empty components.
    let raw: String
    /// Path components below the device root; the first one is the storage name.
    private let parts: [String]

    init(_ path: String) {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        self.parts = comps
        self.raw = comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
    }

    /// `/` — lists the device's storages.
    var isDeviceRoot: Bool { parts.isEmpty }
    /// `/<storage>` — the top of one storage.
    var isStorageRoot: Bool { parts.count == 1 }
    var storageName: String? { parts.first }
    /// Components below the storage root.
    var segments: [String] { Array(parts.dropFirst()) }
    var name: String { parts.last ?? "/" }

    var parent: MTPPath? {
        guard !parts.isEmpty else { return nil }
        return MTPPath("/" + parts.dropLast().joined(separator: "/"))
    }

    func appending(_ component: String) -> MTPPath {
        MTPPath(raw == "/" ? "/\(component)" : "\(raw)/\(component)")
    }

    /// Storage descriptions come straight from the device and may contain "/",
    /// which would split into bogus path components. Callers must run
    /// device-supplied storage names through this before building paths.
    static func sanitizeStorageName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
    }
}
