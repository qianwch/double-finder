import Foundation

/// Chunked random-access reader over a local file — the ONLY file-reading layer
/// for the Lister. Thread-safe (search scans from a background task while the
/// UI reads pages). Read errors surface as nil; reads past EOF clamp.
final class ListerSource: @unchecked Sendable {   // lock-guarded; detached search tasks capture it
    let url: URL
    let length: UInt64
    private let handle: FileHandle
    private let lock = NSLock()

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        self.url = url
        self.handle = h
        self.length = (try? h.seekToEnd()) ?? 0
    }

    deinit { try? handle.close() }

    func read(offset: UInt64, count: Int) -> Data? {
        guard offset <= length else { return nil }
        guard offset < length else { return Data() }
        lock.lock(); defer { lock.unlock() }
        do {
            try handle.seek(toOffset: offset)
            let want = Int(min(UInt64(count), length - offset))
            return try handle.read(upToCount: want) ?? Data()
        } catch { return nil }
    }
}

/// Decodes a byte stream chunk-by-chunk, carrying incomplete trailing multi-byte
/// sequences (≤4 bytes: UTF-8/16, GB18030 max) over to the next chunk.
struct TextChunkDecoder {
    let encoding: String.Encoding
    private var carry = Data()
    /// Bytes held over awaiting the next chunk — the Lister's byte/char anchors
    /// must subtract this to stay on character boundaries.
    var carryCount: Int { carry.count }
    /// Set once any chunk fell back to lossy ISO-8859-1; the controller reports
    /// it and re-points the encoding popup (design §5/§8).
    private(set) var usedFallback = false

    init(encoding: String.Encoding) { self.encoding = encoding }

    mutating func decode(_ chunk: Data, isFinal: Bool) -> String {
        var data = carry; data.append(chunk); carry = Data()
        if isFinal {
            if let s = String(data: data, encoding: encoding) { return s }
            usedFallback = true
            return String(data: data, encoding: .isoLatin1) ?? ""
        }
        for back in 0...min(4, data.count) {
            if let s = String(data: data.prefix(data.count - back), encoding: encoding) {
                carry = Data(data.suffix(back))
                return s
            }
        }
        // Undecodable even after backoff — decode this chunk lossily via Latin-1.
        usedFallback = true
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
