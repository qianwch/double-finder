import Foundation

/// Where a Find Files search runs. Local keeps the FileManager walk; the remote
/// cases push as much of the work to the server as the backend allows (SFTP gets
/// a real `find`/`grep`, S3 has no server-side grep so candidates are fetched).
enum SearchEndpoint {
    case local(base: String)
    case sftp(SFTPConnection, base: String)
    /// `base` is the panel path ("/bucket/prefix") that hit paths are built from.
    case s3(S3Client, bucket: String, prefix: String, base: String)
    /// Android over MTP. `base` is a virtual `/[storage]/…` path.
    case android(AndroidDevice, label: String, base: String)

    var base: String {
        switch self {
        case .local(let b): return b
        case .sftp(_, let b): return b
        case .s3(_, _, _, let b): return b
        case .android(_, _, let b): return b
        }
    }

    var isRemote: Bool {
        if case .local = self { return false }
        return true
    }

    /// What the Find Files title bar shows — the remote cases name the host /
    /// store so two sheets open on the same-looking path stay distinguishable.
    var displayBase: String {
        switch self {
        case .local(let base): return base
        case .sftp(let conn, let base): return "\(conn.user)@\(conn.host):\(base)"
        case .s3(_, _, _, let base): return base
        case .android(_, let label, let base): return "\(label):\(base)"
        }
    }
}

/// One search hit. Size + mtime ride along because remote listings hand them
/// over for free and a per-file stat round-trip afterwards would not — the panel
/// needs them to show the results without re-querying the server.
struct SearchHit: Equatable {
    let path: String
    let size: Int64
    let modified: Date

    init(path: String, size: Int64 = 0, modified: Date = .distantPast) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

struct FileSearchQuery {
    var namePattern: String
    var content: String
    var subfolders: Bool
    var regexName: Bool
}

// MARK: - Pure matching logic (shared by every backend)

/// Filename matching, identical across backends: regex when asked, otherwise a
/// glob when the pattern carries `* ? [`, otherwise a case-insensitive substring
/// (TC behaviour — "技术架构" finds "MetaIT 技术架构_2025…").
struct SearchNameMatcher {
    /// Normalized pattern: "*" collapses to "" (match everything).
    let pattern: String
    let isRegex: Bool
    private let hasWildcard: Bool
    private let regex: NSRegularExpression?

    init(pattern: String, isRegex: Bool) {
        let normalized = (pattern == "*") ? "" : pattern
        self.pattern = normalized
        self.isRegex = isRegex
        self.hasWildcard = normalized.contains(where: { "*?[".contains($0) })
        self.regex = isRegex ? try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) : nil
    }

    var matchesEverything: Bool { !isRegex && pattern.isEmpty }

    func matches(_ fileName: String) -> Bool {
        if isRegex {
            guard let regex = regex else { return false }
            return regex.firstMatch(in: fileName,
                                    range: NSRange(fileName.startIndex..., in: fileName)) != nil
        }
        if pattern.isEmpty { return true }
        if hasWildcard { return fnmatch(pattern, fileName, FNM_CASEFOLD) == 0 }
        return fileName.localizedCaseInsensitiveContains(pattern)
    }

    /// The `find -iname` glob this pattern can be pushed down to, or nil when it
    /// can't be. Regex has no find equivalent, and a non-ASCII pattern is kept
    /// client-side on purpose: `-iname` compares bytes, while our substring test
    /// is Unicode-normalization aware, so pushing e.g. a CJK pattern down could
    /// drop hits. Filtering still runs locally either way — push-down is only a
    /// bandwidth optimisation, never the source of truth.
    var findGlob: String? {
        guard !isRegex, !pattern.isEmpty else { return nil }
        guard pattern.allSatisfy({ $0.isASCII }) else { return nil }
        return hasWildcard ? pattern : "*\(pattern)*"
    }
}

/// "Containing text" matching. Only *text* files can match: a NUL byte in the
/// first 8 KiB means binary (the rule `grep -I` and the Lister's mode chooser
/// both use). The encoding is auto-detected, so a GB18030 log matches a Chinese
/// needle just as a UTF-8 one does.
enum SearchContentMatcher {
    /// Files larger than this are skipped entirely (same cap the local search
    /// has always used) — content search is not meant to stream disk images.
    static let maxBytes = 8_000_000

    static func isBinary(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        // A BOM is an explicit "this is text" declaration; UTF-16 is full of NULs.
        if head.starts(with: [0xEF, 0xBB, 0xBF]) || head.starts(with: [0xFF, 0xFE])
            || head.starts(with: [0xFE, 0xFF]) { return false }
        return head.contains(0)
    }

    static func matches(_ data: Data, needle: String) -> Bool {
        if needle.isEmpty { return true }
        if isBinary(data) { return false }
        let encoding = EncodingDetector.detect(sample: data.prefix(64 * 1024))
        guard let text = String(data: data, encoding: encoding)
                ?? String(data: data, encoding: .isoLatin1) else { return false }
        return text.localizedCaseInsensitiveContains(needle)
    }
}

/// The remote shell commands the SFTP backend runs. Pure string building so the
/// quoting and the `find` grammar are unit-testable without a server.
enum SFTPSearchCommand {
    private static func finder(base: String, glob: String?, subfolders: Bool) -> String {
        var cmd = "find \(SFTPFS.shellQuote(base))"
        if !subfolders { cmd += " -maxdepth 1" }       // must precede the tests in GNU find
        cmd += " -type f"
        if let glob = glob { cmd += " -iname \(SFTPFS.shellQuote(glob))" }
        return cmd
    }

    /// Candidate listing with size + mtime (GNU `find -printf`).
    static func list(base: String, glob: String?, subfolders: Bool) -> String {
        finder(base: base, glob: glob, subfolders: subfolders)
            + " -printf '%s\\t%T@\\t%p\\n' 2>/dev/null"
    }

    /// Fallback for a `find` without `-printf` (BusyBox): paths only, no metadata.
    static func listPlain(base: String, glob: String?, subfolders: Bool) -> String {
        finder(base: base, glob: glob, subfolders: subfolders) + " -print 2>/dev/null"
    }

    /// Server-side content scan. `-exec … {} +` is POSIX (works on BusyBox too,
    /// unlike `xargs -r`), `-l` lists names, `-I` skips binaries, `-i` folds case
    /// and `-F` keeps the needle a literal instead of a regex.
    static func grep(base: String, glob: String?, subfolders: Bool, text: String) -> String {
        finder(base: base, glob: glob, subfolders: subfolders)
            + " -exec grep -l -I -i -F -e \(SFTPFS.shellQuote(text)) -- {} + 2>/dev/null"
    }

    /// Parses one `size\tepoch\tpath` line. The path is taken as everything after
    /// the second tab, so names containing tabs survive.
    static func parseListLine(_ line: String) -> SearchHit? {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let size = Int64(parts[0]), let epoch = Double(parts[1]) else { return nil }
        let path = String(parts[2])
        guard !path.isEmpty else { return nil }
        return SearchHit(path: path, size: size, modified: Date(timeIntervalSince1970: epoch))
    }
}

// MARK: - Progress reporting

/// Throttled progress sink. Each search owns one and touches it from a single
/// thread at a time (the walk loop, or the parent task draining a task group).
final class SearchProgress {
    private let report: ([SearchHit], Int) -> Void
    private var lastReport = Date.distantPast
    private(set) var scanned = 0
    private(set) var hits: [SearchHit] = []

    init(report: @escaping ([SearchHit], Int) -> Void) { self.report = report }

    func bumpScanned(_ n: Int = 1) {
        scanned += n
        flushIfDue()
    }

    func add(_ hit: SearchHit) {
        hits.append(hit)
        flushIfDue()
    }

    var reachedLimit: Bool { hits.count >= FileSearch.maxResults }

    private func flushIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.15 else { return }
        lastReport = now
        report(hits, scanned)
    }

    func flush() {
        lastReport = Date()
        report(hits, scanned)
    }
}

// MARK: - Runner

enum FileSearch {
    /// Same backstop the local walk has always had — a runaway tree must not
    /// fill the results table (or the panel it gets fed into) with 500k rows.
    static let maxResults = 5000
    /// Candidate cap for the remote listing phase.
    static let maxCandidates = 200_000

    /// Runs a name (and optionally content) search against `endpoint`.
    /// `report` is called at most a few times a second with the hits found so
    /// far and the number of files examined, so a slow remote scan shows life
    /// and the user can stop it. Cancelling the surrounding Task really stops
    /// the work: the ssh process is killed, the S3 requests are cancelled.
    nonisolated static func run(endpoint: SearchEndpoint, query: FileSearchQuery,
                                report: @escaping ([SearchHit], Int) -> Void) async throws -> [SearchHit] {
        let progress = SearchProgress(report: report)
        let matcher = SearchNameMatcher(pattern: query.namePattern, isRegex: query.regexName)
        switch endpoint {
        case .local(let base):
            runLocal(base: base, query: query, matcher: matcher, progress: progress)
        case .sftp(let conn, let base):
            try await runSFTP(conn: conn, base: base, query: query, matcher: matcher, progress: progress)
        case .s3(let client, let bucket, let prefix, _):
            try await runS3(client: client, bucket: bucket, prefix: prefix,
                            query: query, matcher: matcher, progress: progress)
        case .android(let device, _, let base):
            try await runAndroid(device: device, base: base,
                                 query: query, matcher: matcher, progress: progress)
        }
        progress.flush()
        return progress.hits.sorted { $0.path < $1.path }
    }

    // MARK: Local

    private nonisolated static func runLocal(base: String, query: FileSearchQuery,
                                             matcher: SearchNameMatcher, progress: SearchProgress) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        func consider(_ url: URL) -> Bool {
            progress.bumpScanned()
            guard matcher.matches(url.lastPathComponent) else { return true }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if !query.content.isEmpty {
                let size = Int64(values?.fileSize ?? 0)
                guard size <= SearchContentMatcher.maxBytes,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      SearchContentMatcher.matches(data, needle: query.content) else { return true }
            }
            progress.add(SearchHit(path: url.path, size: Int64(values?.fileSize ?? 0),
                                   modified: values?.contentModificationDate ?? .distantPast))
            return !progress.reachedLimit
        }

        let startURL = URL(fileURLWithPath: base)
        if query.subfolders {
            guard let en = fm.enumerator(at: startURL, includingPropertiesForKeys: keys,
                                         options: [], errorHandler: { _, _ in true }) else { return }
            while let url = en.nextObject() as? URL {
                if Task.isCancelled { return }
                if !consider(url) { return }
            }
        } else {
            for url in (try? fm.contentsOfDirectory(at: startURL, includingPropertiesForKeys: keys)) ?? [] {
                if Task.isCancelled { return }
                if !consider(url) { return }
            }
        }
    }

    // MARK: SFTP

    /// Two remote commands at most: one `find` that lists the candidates (with
    /// size + mtime), then — only when content was asked for — one `find … -exec
    /// grep -l` so the *server* reads the file bodies and just the matching paths
    /// come back over the wire.
    private nonisolated static func runSFTP(conn: SFTPConnection, base: String, query: FileSearchQuery,
                                            matcher: SearchNameMatcher, progress: SearchProgress) async throws {
        let fs = SFTPFS(connection: conn)
        let glob = matcher.findGlob
        var candidates: [String: SearchHit] = [:]
        var order: [String] = []
        var lines = 0

        func collect(_ line: String, metadata: Bool) {
            guard candidates.count < maxCandidates else { return }
            lines += 1
            let hit = metadata ? SFTPSearchCommand.parseListLine(line) : SearchHit(path: line)
            guard let hit = hit else { return }
            progress.bumpScanned()
            guard matcher.matches((hit.path as NSString).lastPathComponent),
                  candidates[hit.path] == nil else { return }
            candidates[hit.path] = hit
            order.append(hit.path)
        }

        try await fs.streamCommand(SFTPSearchCommand.list(base: base, glob: glob,
                                                          subfolders: query.subfolders)) {
            collect($0, metadata: true)
        }
        // No output at all (rather than "no matches") means `find -printf` isn't
        // there — BusyBox. Retry without it and live without size/mtime.
        if lines == 0 {
            try Task.checkCancellation()
            try await fs.streamCommand(SFTPSearchCommand.listPlain(base: base, glob: glob,
                                                                   subfolders: query.subfolders)) {
                collect($0, metadata: false)
            }
        }
        try Task.checkCancellation()

        guard !query.content.isEmpty else {
            for path in order.prefix(maxResults) {
                if let hit = candidates[path] { progress.add(hit) }
            }
            return
        }
        guard !candidates.isEmpty else { return }

        // The grep pass re-walks the tree server-side rather than shipping the
        // candidate list back up: intersecting its output with the names we
        // already matched keeps regex patterns (which can't be pushed into
        // `find -iname`) exact.
        var matched: Set<String> = []
        try await fs.streamCommand(SFTPSearchCommand.grep(base: base, glob: glob,
                                                          subfolders: query.subfolders,
                                                          text: query.content)) { line in
            guard let hit = candidates[line], !matched.contains(line),
                  !progress.reachedLimit else { return }
            matched.insert(line)
            progress.add(hit)
        }
    }

    // MARK: S3

    /// Name-filters one page of an S3 listing into hits. Pure so the path model
    /// (/bucket/<full key>, never base + rel) stays unit-testable — getting it
    /// wrong doubles the prefix and every hit points at a key that isn't there.
    static func s3Candidates(_ objects: [S3ObjectInfo], bucket: String, prefix: String,
                             matcher: SearchNameMatcher, subfolders: Bool) -> [SearchHit] {
        var hits: [SearchHit] = []
        for object in objects {
            guard object.key.hasPrefix(prefix) else { continue }
            let rel = String(object.key.dropFirst(prefix.count))
            guard !rel.isEmpty, !rel.hasSuffix("/") else { continue }   // folder markers
            if !subfolders && rel.contains("/") { continue }
            guard matcher.matches((rel as NSString).lastPathComponent) else { continue }
            hits.append(SearchHit(path: "/" + bucket + "/" + object.key,
                                  size: object.size, modified: object.modified))
        }
        return hits
    }

    /// S3 has no server-side search, so the object listing does the name work and
    /// content matching fetches each surviving candidate (≤ 8 MB, 6 at a time).
    private nonisolated static func runS3(client: S3Client, bucket: String, prefix: String,
                                          query: FileSearchQuery, matcher: SearchNameMatcher,
                                          progress: SearchProgress) async throws {
        // Hit paths follow S3FS's model: /bucket/<full key>, NOT base + rel —
        // the panel path may already sit inside the prefix.
        let root = "/" + bucket
        var candidates: [SearchHit] = []
        _ = try await client.listAllObjects(bucket: bucket, prefix: prefix) { page in
            guard candidates.count < maxCandidates else { return }
            progress.bumpScanned(page.count)
            candidates += s3Candidates(page, bucket: bucket, prefix: prefix,
                                       matcher: matcher, subfolders: query.subfolders)
        }
        try Task.checkCancellation()

        guard !query.content.isEmpty else {
            for hit in candidates.prefix(maxResults) { progress.add(hit) }
            return
        }

        let scannable = candidates.filter { $0.size <= SearchContentMatcher.maxBytes }
        let needle = query.content
        var next = 0
        try await withThrowingTaskGroup(of: (SearchHit, Bool).self) { group in
            func schedule() {
                guard next < scannable.count else { return }
                let hit = scannable[next]
                next += 1
                let key = String(hit.path.dropFirst(root.count + 1))
                group.addTask {
                    let data = try? await client.getObjectData(bucket: bucket, key: key)
                    guard let data = data else { return (hit, false) }
                    return (hit, SearchContentMatcher.matches(data, needle: needle))
                }
            }
            for _ in 0..<min(6, scannable.count) { schedule() }
            while let (hit, isMatch) = try await group.next() {
                if isMatch { progress.add(hit) }
                if progress.reachedLimit { group.cancelAll(); break }
                try Task.checkCancellation()
                schedule()
            }
        }
    }

    /// Depth-first name walk over any backend that can only list one directory at
    /// a time. Backend-agnostic (the lister is injected) so the traversal rules —
    /// the subfolders flag, the candidate cap, matching on the leaf name, and
    /// "the first listing must throw but deeper ones are best-effort" — are
    /// unit-testable without a device attached.
    static func walk(base: String, subfolders: Bool, matcher: SearchNameMatcher,
                     progress: SearchProgress,
                     list: (String) async throws -> [FileItem]) async throws -> [SearchHit] {
        var candidates: [SearchHit] = []
        var stack = [base]
        var isFirst = true

        while let dir = stack.popLast() {
            try Task.checkCancellation()
            guard candidates.count < maxCandidates else { break }
            let items: [FileItem]
            do {
                items = try await list(dir)
            } catch {
                // The first listing failing means the device is gone / the path is
                // bad — that must surface. Deeper folders are best-effort: one
                // unreadable folder must not abort the whole search.
                if isFirst { throw error }
                continue
            }
            isFirst = false
            for item in items {
                if item.isDirectory {
                    if subfolders { stack.append(item.path) }
                    continue
                }
                progress.bumpScanned()
                guard matcher.matches(item.name) else { continue }
                candidates.append(SearchHit(path: item.path, size: item.size,
                                            modified: item.modified))
            }
        }
        return candidates
    }

    // MARK: Android (MTP)

    /// MTP has no shell and no recursive listing call, so the walk is one
    /// `listDirectory` per folder — which is exactly the right granularity here:
    /// libmtp is single-threaded behind `AndroidDeviceRegistry`'s per-device
    /// serial queue, and going a folder at a time hands that queue back between
    /// USB round-trips, so the panel stays usable and cancellation lands within
    /// one directory instead of after the whole tree.
    private nonisolated static func runAndroid(device: AndroidDevice, base: String,
                                               query: FileSearchQuery, matcher: SearchNameMatcher,
                                               progress: SearchProgress) async throws {
        let fs = AndroidFS(device: device, currentPath: base)
        let candidates = try await walk(base: base, subfolders: query.subfolders,
                                        matcher: matcher, progress: progress) {
            try await fs.listDirectory($0)
        }

        guard !query.content.isEmpty else {
            for hit in candidates.prefix(maxResults) { progress.add(hit) }
            return
        }

        // Content matching means pulling each candidate over USB — no server-side
        // grep, no ranged reads. Strictly serial (the device queue is), size-capped,
        // and each temp copy is deleted as soon as it has been scanned.
        let temp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("DoubleFinder-Search-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: temp) }

        for hit in candidates where hit.size <= SearchContentMatcher.maxBytes {
            try Task.checkCancellation()
            if progress.reachedLimit { break }
            let local = (temp as NSString).appendingPathComponent(MTPPath(hit.path).name)
            try? FileManager.default.removeItem(atPath: local)
            guard (try? await fs.copy(from: hit.path, to: temp)) != nil,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: local)) else { continue }
            if SearchContentMatcher.matches(data, needle: query.content) { progress.add(hit) }
            try? FileManager.default.removeItem(atPath: local)
        }
    }
}
