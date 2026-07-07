import Foundation

/// Forward-only streaming byte search with a growing match-offset cache
/// (design §6). One instance = one cache key (file + pattern + encoding +
/// match-case); the caller builds a fresh instance when any of those change.
/// Find Previous never scans — it only walks the cache (offsets before the
/// current position are guaranteed already scanned).
///
/// @unchecked Sendable: captured by ONE detached search task at a time; the
/// controller awaits the previous task before starting the next.
final class ListerSearch: @unchecked Sendable {
    let pattern: [UInt8]
    let foldCase: Bool
    private let foldedPattern: [UInt8]
    private(set) var matches: [UInt64] = []
    private(set) var scannedUpTo: UInt64 = 0
    private(set) var reachedEOF = false
    private var carry: [UInt8] = []              // last pattern.count-1 scanned bytes

    init(pattern: [UInt8], foldCase: Bool) {
        self.pattern = pattern
        self.foldCase = foldCase
        self.foldedPattern = pattern.map { Self.fold($0, foldCase) }
    }

    private static func fold(_ b: UInt8, _ on: Bool) -> UInt8 {
        (on && b >= 0x41 && b <= 0x5A) ? b &+ 0x20 : b
    }

    /// "4D 5A" / "4d5a" → bytes; nil on empty/odd-length/non-hex input.
    static func parseHexPattern(_ s: String) -> [UInt8]? {
        let cleaned = s.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            guard let b = UInt8(cleaned[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    /// First match strictly after `after` — from cache if available, else scan
    /// forward until found / EOF / cancelled. `read` is ListerSource.read-shaped.
    func nextMatch(after: UInt64, fileLength: UInt64, chunkSize: Int = 1 << 20,
                   isCancelled: () -> Bool = { false },
                   read: (UInt64, Int) -> Data?) -> UInt64? {
        if let hit = matches.first(where: { $0 > after }) { return hit }
        guard !pattern.isEmpty else { return nil }
        while !reachedEOF {
            if isCancelled() { return nil }
            guard let chunk = read(scannedUpTo, chunkSize), !chunk.isEmpty else {
                reachedEOF = true; break
            }
            let windowStart = scannedUpTo - UInt64(carry.count)
            var window = carry; window.append(contentsOf: chunk)
            let folded = foldCase ? window.map { Self.fold($0, true) } : window
            if window.count >= pattern.count {
                for p in 0...(window.count - pattern.count) {
                    var ok = true
                    for j in 0..<foldedPattern.count where folded[p + j] != foldedPattern[j] {
                        ok = false; break
                    }
                    if ok { matches.append(windowStart + UInt64(p)) }
                }
            }
            scannedUpTo += UInt64(chunk.count)
            if scannedUpTo >= fileLength { reachedEOF = true }
            carry = Array(window.suffix(max(0, pattern.count - 1)))
            if let hit = matches.first(where: { $0 > after }) { return hit }
        }
        return matches.first(where: { $0 > after })
    }

    /// Cache-only. Last cached match strictly before `before`; nil = caller beeps.
    func previousMatch(before: UInt64) -> UInt64? {
        matches.last(where: { $0 < before })
    }
}
