import Foundation

/// One entry of a MOBI INDX index: its label bytes and the tag → values map.
struct MOBIIndexEntry {
    let label: [UInt8]
    let tags: [Int: [Int]]

    var labelString: String { String(decoding: label, as: UTF8.self) }
    func value(_ tag: Int, _ k: Int = 0) -> Int? {
        guard let v = tags[tag], k < v.count else { return nil }
        return v[k]
    }
}

/// Parsed INDX index (NCX table of contents, KF8 skeleton / fragment tables).
struct MOBIIndex {
    let entries: [MOBIIndexEntry]
    /// CNCX string pool: offset → UTF-8 bytes (labels of TOC entries etc.).
    let cncx: [Int: [UInt8]]

    func cncxString(_ offset: Int?) -> String? {
        guard let o = offset, let b = cncx[o] else { return nil }
        return String(decoding: b, as: UTF8.self)
    }

    /// Reads the index whose header record is `headerIndex` (absolute record
    /// number). Layout: header INDX (with TAGX) → `count` data INDX records →
    /// `nctoc` CNCX string records. Returns nil for anything malformed.
    static func read(headerIndex: Int, record: (Int) -> [UInt8]?) -> MOBIIndex? {
        guard headerIndex >= 0, let header = record(headerIndex), header.hasPrefix("INDX") else { return nil }
        let headerLength = header.be32(4)
        let count = header.be32(0x18)
        let cncxCount = header.be32(0x34)
        guard count >= 0, count < 4096, cncxCount >= 0, cncxCount < 64 else { return nil }
        // TAGX: (tag, valuesPerEntry, mask, endOfControlBytes) quads
        guard header.slice(headerLength, headerLength + 4).hasPrefix("TAGX") else { return nil }
        let firstEntry = header.be32(headerLength + 4)
        let controlByteCount = header.be32(headerLength + 8)
        var tagx: [(tag: Int, values: Int, mask: Int, end: Bool)] = []
        var p = headerLength + 12
        while p + 4 <= headerLength + firstEntry, p + 4 <= header.count {
            tagx.append((Int(header[p]), Int(header[p + 1]), Int(header[p + 2]), header[p + 3] == 1))
            p += 4
        }
        guard controlByteCount >= 0, controlByteCount < 16 else { return nil }

        var cncx: [Int: [UInt8]] = [:]
        var base = 0
        for j in 0..<cncxCount {
            guard let rec = record(headerIndex + count + 1 + j) else { break }
            var off = 0
            while off < rec.count, rec[off] != 0 {
                let key = off
                guard let (len, consumed) = MOBIVarint.read(rec, at: off) else { break }
                off += consumed
                guard len >= 0, off + len <= rec.count else { break }
                cncx[key + base] = Array(rec[off..<off + len])
                off += len
            }
            base += 0x10000
        }

        var entries: [MOBIIndexEntry] = []
        for i in stride(from: 1, through: count, by: 1) {
            guard let data = record(headerIndex + i), data.hasPrefix("INDX") else { return nil }
            let idxt = data.be32(0x14)
            let entryCount = data.be32(0x18)
            guard data.slice(idxt, idxt + 4).hasPrefix("IDXT"), entryCount >= 0, entryCount < 65536 else { return nil }
            var offsets: [Int] = []
            for j in 0..<entryCount { offsets.append(data.be16(idxt + 4 + 2 * j)) }
            for j in 0..<entryCount {
                let start = offsets[j]
                let end = j + 1 < entryCount ? offsets[j + 1] : idxt
                guard start >= 0, start < data.count, end <= data.count, end >= start else { continue }
                let labelLen = Int(data[start])
                let labelStart = start + 1
                guard labelStart + labelLen <= end else { continue }
                let label = Array(data[labelStart..<labelStart + labelLen])
                let tags = tagMap(data, controlBytes: controlByteCount, tagx: tagx,
                                  from: labelStart + labelLen, to: end)
                entries.append(MOBIIndexEntry(label: label, tags: tags))
            }
        }
        return MOBIIndex(entries: entries, cncx: cncx)
    }

    /// Decodes one entry's control bytes + variable-width values per the TAGX table.
    private static func tagMap(_ data: [UInt8], controlBytes: Int,
                               tagx: [(tag: Int, values: Int, mask: Int, end: Bool)],
                               from start: Int, to end: Int) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        var pending: [(tag: Int, count: Int?, bytes: Int?, perEntry: Int)] = []
        var controlIndex = 0
        var cursor = start + controlBytes
        for t in tagx {
            if t.end { controlIndex += 1; continue }
            guard start + controlIndex < data.count, start + controlIndex < end else { break }
            let value = Int(data[start + controlIndex]) & t.mask
            guard value != 0 else { continue }
            if value == t.mask {
                if t.mask.nonzeroBitCount > 1 {
                    // All mask bits set: a varint follows giving the BYTE length of the values.
                    guard let (v, consumed) = MOBIVarint.read(data, at: cursor) else { break }
                    cursor += consumed
                    pending.append((t.tag, nil, v, t.values))
                } else {
                    pending.append((t.tag, 1, nil, t.values))
                }
            } else {
                var mask = t.mask, v = value
                while mask & 1 == 0 { mask >>= 1; v >>= 1 }
                pending.append((t.tag, v, nil, t.values))
            }
        }
        for p in pending {
            var values: [Int] = []
            if let c = p.count {
                for _ in 0..<(c * p.perEntry) {
                    guard cursor < end, let (v, consumed) = MOBIVarint.read(data, at: cursor) else { break }
                    cursor += consumed
                    values.append(v)
                }
            } else if let total = p.bytes {
                var consumedTotal = 0
                while consumedTotal < total, cursor < end {
                    guard let (v, consumed) = MOBIVarint.read(data, at: cursor) else { break }
                    cursor += consumed
                    consumedTotal += consumed
                    values.append(v)
                }
            }
            result[p.tag] = values
        }
        return result
    }
}
