import Foundation
import CryptoKit

/// Checksum creation / verification (TC's Create Checksum File / Verify
/// Checksums). Pure logic: algorithms, streaming file hashing, and the
/// .sfv / md5sum-style text formats. UI lives in ChecksumSheet.swift.
enum ChecksumAlgorithm: String, CaseIterable {
    case crc32, md5, sha1, sha256, sha512

    var displayName: String {
        switch self {
        case .crc32: return "CRC32 (SFV)"
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha512: return "SHA-512"
        }
    }

    /// Extension of the summary file this algorithm writes (and is detected from).
    var fileExtension: String { self == .crc32 ? "sfv" : rawValue }

    var digestHexLength: Int {
        switch self {
        case .crc32: return 8
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        case .sha512: return 128
        }
    }

    /// Algorithm implied by a checksum file's name, e.g. "photos.sfv" → .crc32.
    static func forFile(named name: String) -> ChecksumAlgorithm? {
        let ext = (name as NSString).pathExtension.lowercased()
        return allCases.first { $0.fileExtension == ext }
    }

    static func forDigestHexLength(_ length: Int) -> ChecksumAlgorithm? {
        allCases.first { $0.digestHexLength == length }
    }

    /// Streams the file through the hasher in 1MB chunks. `onBytes` receives
    /// per-chunk deltas (drives the progress bar); `shouldCancel` is polled per
    /// chunk and aborts with CancellationError.
    func hashFile(at path: String,
                  onBytes: ((Int64) -> Void)? = nil,
                  shouldCancel: (() -> Bool)? = nil) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open \(path)"])
        }
        defer { try? handle.close() }
        var hasher = ChecksumHasher(self)
        while true {
            if shouldCancel?() == true { throw CancellationError() }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(chunk)
            onBytes?(Int64(chunk.count))
        }
        return hasher.finalizeHex()
    }
}

/// Streaming CRC32 (IEEE 802.3, the SFV/zip polynomial).
struct CRC32Hasher {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    private var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var v = value
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for b in raw { v = CRC32Hasher.table[Int((v ^ UInt32(b)) & 0xFF)] ^ (v >> 8) }
        }
        value = v
    }

    var digestHex: String { String(format: "%08x", value ^ 0xFFFF_FFFF) }
}

/// One streaming hasher facade over CRC32 + the CryptoKit hash functions.
enum ChecksumHasher {
    case crc32(CRC32Hasher)
    case md5(Insecure.MD5)
    case sha1(Insecure.SHA1)
    case sha256(SHA256)
    case sha512(SHA512)

    init(_ algorithm: ChecksumAlgorithm) {
        switch algorithm {
        case .crc32: self = .crc32(CRC32Hasher())
        case .md5: self = .md5(Insecure.MD5())
        case .sha1: self = .sha1(Insecure.SHA1())
        case .sha256: self = .sha256(SHA256())
        case .sha512: self = .sha512(SHA512())
        }
    }

    mutating func update(_ data: Data) {
        switch self {
        case .crc32(var h): h.update(data); self = .crc32(h)
        case .md5(var h): h.update(data: data); self = .md5(h)
        case .sha1(var h): h.update(data: data); self = .sha1(h)
        case .sha256(var h): h.update(data: data); self = .sha256(h)
        case .sha512(var h): h.update(data: data); self = .sha512(h)
        }
    }

    func finalizeHex() -> String {
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
            digest.map { String(format: "%02x", $0) }.joined()
        }
        switch self {
        case .crc32(let h): return h.digestHex
        case .md5(let h): return hex(h.finalize())
        case .sha1(let h): return hex(h.finalize())
        case .sha256(let h): return hex(h.finalize())
        case .sha512(let h): return hex(h.finalize())
        }
    }
}

struct ChecksumEntry: Equatable {
    var fileName: String
    var hexDigest: String
}

/// The two on-disk text formats:
///   - SFV (crc32): `name HEXHEX8` per line, `;` comments — hex written uppercase.
///   - md5sum family: `hexdigest  name` per line (GNU coreutils layout, also
///     accepts the `*name` binary-mode marker), `#` comments.
enum ChecksumFile {
    static func serialize(_ entries: [ChecksumEntry], algorithm: ChecksumAlgorithm) -> String {
        var lines: [String] = []
        if algorithm == .crc32 {
            lines.append("; Generated by Double Finder")
            lines += entries.map { "\($0.fileName) \($0.hexDigest.uppercased())" }
        } else {
            lines += entries.map { "\($0.hexDigest.lowercased())  \($0.fileName)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parses either format (mixed lines are fine — each line is judged on its
    /// own shape). Digests are normalized to lowercase. Unparseable lines are
    /// skipped.
    static func parse(_ text: String) -> [ChecksumEntry] {
        var entries: [ChecksumEntry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }

            // md5sum style: leading hex token, then whitespace, then the name
            // (optionally prefixed with the "*" binary marker).
            if let range = line.rangeOfCharacter(from: .whitespaces) {
                let first = String(line[line.startIndex..<range.lowerBound])
                if isDigest(first) {
                    var name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if name.hasPrefix("*") { name.removeFirst() }
                    if !name.isEmpty {
                        entries.append(ChecksumEntry(fileName: name, hexDigest: first.lowercased()))
                        continue
                    }
                }
            }
            // SFV style: name (may contain spaces), whitespace, trailing CRC32 hex.
            if let range = line.range(of: " ", options: .backwards) {
                let last = String(line[range.upperBound...])
                let name = String(line[line.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if isDigest(last), !name.isEmpty {
                    entries.append(ChecksumEntry(fileName: name, hexDigest: last.lowercased()))
                }
            }
        }
        return entries
    }

    private static func isDigest(_ s: String) -> Bool {
        guard ChecksumAlgorithm.forDigestHexLength(s.count) != nil else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }
}
