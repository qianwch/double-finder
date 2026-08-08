import Foundation

/// TC's Files ▸ Split / Combine: cut one file into fixed-size numbered parts
/// (`name.001`, `name.002`, …) plus a TC-compatible `.crc` summary, and glue
/// them back together with CRC32 verification. Pure logic + streaming file IO;
/// the dialogs live in MainViewController / SplitSheet.
enum FileSplit {
    // MARK: - Pure helpers (unit-tested)

    /// "100 MB" / "250m" / "1g" → byte count. Reuses the Pack dialog's size
    /// grammar (VolumeSize); empty or invalid input → nil.
    static func parseSize(_ raw: String) -> Int64? {
        guard case .token(let t) = VolumeSize.parse(raw) else { return nil }
        let digits = t.prefix { $0.isNumber }
        guard let n = Int64(digits), n > 0 else { return nil }
        switch t.suffix(1) {
        case "b": return n
        case "k": return n << 10
        case "m": return n << 20
        case "g": return n << 30
        default: return nil
        }
    }

    static func partCount(fileSize: Int64, partSize: Int64) -> Int {
        guard partSize > 0 else { return 0 }
        guard fileSize > 0 else { return 1 }   // empty file still yields one (empty) part
        return Int((fileSize + partSize - 1) / partSize)
    }

    /// "big.dat" + 1 → "big.dat.001"; part 1000 onward grows naturally.
    static func partName(base: String, index: Int) -> String {
        index < 1000 ? String(format: "%@.%03d", base, index) : "\(base).\(index)"
    }

    /// TC-compatible .crc summary (CRLF line ends, uppercase hex).
    static func crcFileContent(fileName: String, size: Int64, crcHex: String) -> String {
        "filename=\(fileName)\r\nsize=\(size)\r\ncrc32=\(crcHex.uppercased())\r\n"
    }

    struct CrcInfo: Equatable {
        var fileName: String?
        var size: Int64?
        var crcHex: String?
    }

    /// Parses a TC .crc file (key=value lines; unknown keys ignored).
    static func parseCrcFile(_ text: String) -> CrcInfo {
        var info = CrcInfo()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "filename": info.fileName = value
            case "size": info.size = Int64(value)
            case "crc32": info.crcHex = value.lowercased()
            default: break
            }
        }
        return info
    }

    /// All sequentially numbered parts starting at `firstPart` ("…/x.001").
    /// Returns [] if `firstPart` isn't a .001 file.
    static func partsList(firstPart: String) -> [String] {
        guard firstPart.hasSuffix(".001") else { return [] }
        let base = String(firstPart.dropLast(4))
        var parts: [String] = []
        var index = 1
        let fm = FileManager.default
        while true {
            let part = partName(base: base, index: index)
            guard fm.fileExists(atPath: part) else { break }
            parts.append(part)
            index += 1
        }
        return parts
    }

    // MARK: - Streaming IO

    /// Splits `path` into parts of `partSize` bytes inside `destDir`, writing a
    /// `.crc` summary next to them. Reports byte deltas, polls for cancel
    /// (throwing CancellationError; caller cleans partial outputs via
    /// `removeOutputs`). Returns all written paths (parts + crc file).
    static func split(path: String, destDir: String, partSize: Int64,
                      onBytes: ((Int64) -> Void)? = nil,
                      shouldCancel: (() -> Bool)? = nil) throws -> [String] {
        let name = (path as NSString).lastPathComponent
        guard let input = FileHandle(forReadingAtPath: path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open \(path)"])
        }
        defer { try? input.close() }

        let fm = FileManager.default
        var crc = CRC32Hasher()
        var totalSize: Int64 = 0
        var written: [String] = []
        var index = 0
        var partRemaining: Int64 = 0
        var output: FileHandle?
        defer { try? output?.close() }

        while true {
            if shouldCancel?() == true { throw CancellationError() }
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            // A read chunk may span part boundaries — distribute it. Parts open
            // lazily on first byte so an exact-multiple size never leaves a
            // trailing empty part.
            var offset = 0
            while offset < chunk.count {
                if partRemaining <= 0 {
                    try output?.close()
                    index += 1
                    let partPath = destDir + "/" + partName(base: name, index: index)
                    fm.createFile(atPath: partPath, contents: nil)
                    guard let handle = FileHandle(forWritingAtPath: partPath) else {
                        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                      userInfo: [NSLocalizedDescriptionKey: "Cannot create \(partPath)"])
                    }
                    output = handle
                    written.append(partPath)
                    partRemaining = partSize
                }
                let n = Int(min(Int64(chunk.count - offset), partRemaining))
                try output?.write(contentsOf: chunk.subdata(in: offset..<(offset + n)))
                offset += n
                partRemaining -= Int64(n)
            }
            crc.update(chunk)
            totalSize += Int64(chunk.count)
            onBytes?(Int64(chunk.count))
        }
        if written.isEmpty {   // empty source: still produce one empty part
            let partPath = destDir + "/" + partName(base: name, index: 1)
            fm.createFile(atPath: partPath, contents: Data())
            written.append(partPath)
        }

        let crcPath = destDir + "/" + name + ".crc"
        try crcFileContent(fileName: name, size: totalSize, crcHex: crc.digestHex)
            .write(toFile: crcPath, atomically: true, encoding: .utf8)
        written.append(crcPath)
        return written
    }

    struct CombineMismatchError: LocalizedError {
        var errorDescription: String? { "The combined file does not match the .crc summary." }
    }

    /// Concatenates `parts` into `destPath` and returns the streamed CRC32.
    /// If `expected` (from a .crc file) has size/crc they are verified —
    /// a mismatch throws CombineMismatchError after the file is written.
    static func combine(parts: [String], destPath: String, expected: CrcInfo?,
                        onBytes: ((Int64) -> Void)? = nil,
                        shouldCancel: (() -> Bool)? = nil) throws -> String {
        let fm = FileManager.default
        fm.createFile(atPath: destPath, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destPath) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create \(destPath)"])
        }
        defer { try? output.close() }

        var crc = CRC32Hasher()
        var totalSize: Int64 = 0
        for part in parts {
            guard let input = FileHandle(forReadingAtPath: part) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot open \(part)"])
            }
            defer { try? input.close() }
            while true {
                if shouldCancel?() == true { throw CancellationError() }
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                crc.update(chunk)
                totalSize += Int64(chunk.count)
                onBytes?(Int64(chunk.count))
            }
        }

        if let expected = expected {
            if let size = expected.size, size != totalSize { throw CombineMismatchError() }
            if let hex = expected.crcHex, hex != crc.digestHex { throw CombineMismatchError() }
        }
        return crc.digestHex
    }
}
