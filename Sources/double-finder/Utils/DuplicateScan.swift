import Foundation

/// Duplicate-file grouping for Find Files' "Find duplicates" mode (TC's
/// duplicate search). Pure logic: callers walk the file system and hand in
/// (path, name, size) triples plus a lazy content-hash closure.
enum DuplicateScan {
    struct Options {
        var sameName: Bool
        var sameSize: Bool
        var sameContent: Bool
        /// No criterion → nothing to group by.
        var isEmpty: Bool { !sameName && !sameSize && !sameContent }
    }

    struct FileInfo: Equatable {
        var path: String
        var name: String
        var size: Int64
    }

    /// Groups files that match under all selected criteria; only groups with
    /// two or more members are duplicates. `hash` runs lazily and only for
    /// files that still share a bucket when content comparison is requested
    /// (content implies equal size, so size always pre-buckets it); returning
    /// nil drops the file (unreadable). Groups and members sort by path.
    static func group(_ files: [FileInfo], options: Options,
                      hash: (String) -> String? = { _ in nil },
                      isCancelled: () -> Bool = { false }) -> [[FileInfo]] {
        guard !options.isEmpty else { return [] }

        // Cheap criteria first: bucket on name and/or size.
        var buckets: [String: [FileInfo]] = [:]
        for f in files {
            var key = ""
            if options.sameName { key += f.name.lowercased() + "\u{1}" }
            if options.sameSize || options.sameContent { key += String(f.size) }
            buckets[key, default: []].append(f)
        }

        var groups: [[FileInfo]] = []
        for bucket in buckets.values where bucket.count >= 2 {
            if isCancelled() { return [] }
            if options.sameContent {
                var byDigest: [String: [FileInfo]] = [:]
                for f in bucket {
                    if isCancelled() { return [] }
                    guard let digest = hash(f.path) else { continue }
                    byDigest[digest, default: []].append(f)
                }
                groups += byDigest.values.filter { $0.count >= 2 }
            } else {
                groups.append(bucket)
            }
        }

        for i in groups.indices { groups[i].sort { $0.path < $1.path } }
        groups.sort { ($0.first?.path ?? "") < ($1.first?.path ?? "") }
        return groups
    }
}
