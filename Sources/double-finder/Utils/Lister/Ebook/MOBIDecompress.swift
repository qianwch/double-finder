import Foundation

/// Bounds-safe big-endian readers over a record's bytes. Out-of-range reads
/// yield 0 — ebook files are untrusted input and must never trap the viewer.
extension Array where Element == UInt8 {
    func be16(_ o: Int) -> Int {
        guard o >= 0, o + 2 <= count else { return 0 }
        return Int(self[o]) << 8 | Int(self[o + 1])
    }
    func be32(_ o: Int) -> Int {
        guard o >= 0, o + 4 <= count else { return 0 }
        return Int(self[o]) << 24 | Int(self[o + 1]) << 16 | Int(self[o + 2]) << 8 | Int(self[o + 3])
    }
    func be64(_ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(o + k < count && o + k >= 0 ? self[o + k] : 0) }
        return v
    }
    func slice(_ from: Int, _ to: Int) -> [UInt8] {
        let lo = Swift.max(0, Swift.min(from, count)), hi = Swift.max(lo, Swift.min(to, count))
        return Array(self[lo..<hi])
    }
    func hasPrefix(_ magic: String) -> Bool {
        let m = Array(magic.utf8)
        return count >= m.count && Array(self[0..<m.count]) == m
    }
}

/// The three text-record codecs a MOBI/AZW may use (PalmDOC header field 0).
enum MOBICompression: Int {
    case none = 1
    case palmDoc = 2
    case huffCdic = 17480
}

/// PalmDOC LZ77 (compression type 2).
enum PalmDoc {
    static func decompress(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 2)
        var i = 0
        let n = data.count
        while i < n {
            let c = Int(data[i]); i += 1
            if c >= 1 && c <= 8 {
                let end = Swift.min(n, i + c)
                out.append(contentsOf: data[i..<end]); i = end
            } else if c < 128 {
                out.append(UInt8(c))
            } else if c >= 192 {
                out.append(0x20); out.append(UInt8(c ^ 128))
            } else if i < n {
                let pair = c << 8 | Int(data[i]); i += 1
                let distance = (pair & 0x3FFF) >> 3
                let length = (pair & 7) + 3
                guard distance > 0, distance <= out.count else { continue }   // corrupt back-reference
                for _ in 0..<length { out.append(out[out.count - distance]) }
            }
        }
        return out
    }
}

/// HUFF/CDIC (compression type 17480) — a canonical Huffman code over a phrase
/// dictionary whose entries may themselves be Huffman-coded. Port of the
/// well-known reference decoder; every table lookup is range-checked so a
/// corrupt file yields nil instead of a trap.
final class HuffCdic {
    private struct Code { let length: Int; let terminal: Bool; let maxCode: UInt64 }
    private var dict1: [Code] = []
    private var minCode: [UInt64] = []            // index = code length 0…32
    private var maxCode: [UInt64] = []
    private var dictionary: [(bytes: [UInt8], isFinal: Bool)] = []
    private var unpacking: Set<Int> = []          // cycle guard for recursive phrases

    init?(huff: [UInt8], cdics: [[UInt8]]) {
        guard huff.hasPrefix("HUFF"), huff.count >= 24 else { return nil }
        let off1 = huff.be32(8), off2 = huff.be32(12)
        guard off1 + 256 * 4 <= huff.count, off2 + 64 * 4 <= huff.count else { return nil }
        for k in 0..<256 {
            let v = UInt64(huff.be32(off1 + k * 4))
            let len = Int(v & 0x1F)
            guard len > 0 else { return nil }
            let max = (((v >> 8) + 1) << UInt64(32 - len)) - 1
            dict1.append(Code(length: len, terminal: v & 0x80 != 0, maxCode: max))
        }
        minCode = [0]; maxCode = [0]
        for len in 1...32 {
            let mn = UInt64(huff.be32(off2 + (len - 1) * 8))
            let mx = UInt64(huff.be32(off2 + (len - 1) * 8 + 4))
            minCode.append(mn << UInt64(32 - len))
            maxCode.append(((mx + 1) << UInt64(32 - len)) - 1)
        }
        for cdic in cdics {
            guard cdic.hasPrefix("CDIC"), cdic.count >= 16 else { return nil }
            let phrases = cdic.be32(8), bits = cdic.be32(12)
            guard bits >= 0, bits < 31 else { return nil }
            let n = Swift.min(1 << bits, phrases - dictionary.count)
            guard n >= 0 else { return nil }
            for k in 0..<n {
                let off = cdic.be16(16 + k * 2)
                let blen = cdic.be16(16 + off)
                let start = 18 + off
                let len = blen & 0x7FFF
                guard start + len <= cdic.count else { return nil }
                dictionary.append((Array(cdic[start..<start + len]), blen & 0x8000 != 0))
            }
        }
        guard !dictionary.isEmpty else { return nil }
    }

    func unpack(_ data: [UInt8]) -> [UInt8]? { unpack(data, depth: 0) }

    private func unpack(_ input: [UInt8], depth: Int) -> [UInt8]? {
        guard depth < 32 else { return nil }
        var bitsLeft = input.count * 8
        var data = input
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))
        var pos = 0
        var x = data.be64(pos)
        var n = 32
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 3)
        while true {
            if n <= 0 {
                pos += 4
                x = data.be64(pos)
                n += 32
            }
            let code = UInt64((x >> UInt64(n)) & 0xFFFF_FFFF)
            let entry = dict1[Int(code >> 24)]
            var len = entry.length
            var max = entry.maxCode
            if !entry.terminal {
                while len <= 32, code < minCode[len] { len += 1 }
                guard len <= 32 else { return nil }
                max = maxCode[len]
            }
            n -= len
            bitsLeft -= len
            if bitsLeft < 0 { break }
            guard max >= code else { return nil }
            let r = Int((max - code) >> UInt64(32 - len))
            guard r < dictionary.count else { return nil }
            var phrase = dictionary[r]
            if !phrase.isFinal {
                guard !unpacking.contains(r) else { return nil }
                unpacking.insert(r)
                guard let expanded = unpack(phrase.bytes, depth: depth + 1) else { return nil }
                unpacking.remove(r)
                phrase = (expanded, true)
                dictionary[r] = phrase
            }
            out.append(contentsOf: phrase.bytes)
        }
        return out
    }
}

/// Trailing-entry accounting for text records (MOBI header "extra record data
/// flags"): multibyte overlap bytes + TBS indexing data hang off the end of
/// each record and must be dropped before decompression.
enum MOBITrailing {
    static func size(of data: [UInt8], flags: Int) -> Int {
        let size = data.count
        var num = 0
        var test = flags >> 1
        while test != 0 {
            if test & 1 != 0 { num += trailingEntry(data, size: size - num) }
            test >>= 1
        }
        if flags & 1 != 0, size - num - 1 >= 0, size - num - 1 < size {
            num += Int(data[size - num - 1] & 0x3) + 1
        }
        return Swift.min(num, size)
    }

    private static func trailingEntry(_ data: [UInt8], size: Int) -> Int {
        var bitpos = 0, result = 0, sz = size
        while sz > 0 {
            let v = Int(data[sz - 1])
            result |= (v & 0x7F) << bitpos
            bitpos += 7
            sz -= 1
            if v & 0x80 != 0 || bitpos >= 28 { break }
        }
        return result
    }
}

/// Forward variable-width integer (7 bits per byte, high bit marks the LAST byte).
enum MOBIVarint {
    static func read(_ data: [UInt8], at offset: Int) -> (value: Int, consumed: Int)? {
        var value = 0, consumed = 0
        while offset + consumed < data.count, consumed < 8 {
            let b = Int(data[offset + consumed]); consumed += 1
            value = value << 7 | (b & 0x7F)
            if b & 0x80 != 0 { return (value, consumed) }
        }
        return nil
    }
}

/// Kindle's base-32 ("0123456789ABCDEFGHIJKLMNOPQRSTUV") used in
/// `kindle:embed:XXXX` / `kindle:flow:XXXX` / `kindle:pos:fid:XXXX` references.
enum KindleBase32 {
    static func decode(_ s: String) -> Int? {
        var v = 0
        for ch in s.uppercased().unicodeScalars {
            let d: Int
            switch ch.value {
            case 0x30...0x39: d = Int(ch.value - 0x30)
            case 0x41...0x56: d = Int(ch.value - 0x41) + 10
            default: return nil
            }
            v = v * 32 + d
            if v > 1 << 40 { return nil }
        }
        return s.isEmpty ? nil : v
    }
}
