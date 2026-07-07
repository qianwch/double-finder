import Foundation

/// Encoding auto-detection + the manual-switch candidate set (design §5).
enum EncodingDetector {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5.rawValue)))
    static let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))

    /// Menu order = detection preference. Labels are shown verbatim (not tr()'d —
    /// encoding names are proper nouns, same in every language).
    static let candidates: [(encoding: String.Encoding, label: String)] = [
        (.utf8, "UTF-8"), (.utf16LittleEndian, "UTF-16 LE"), (.utf16BigEndian, "UTF-16 BE"),
        (gb18030, "GB18030"), (big5, "Big5"), (.shiftJIS, "Shift-JIS"), (eucKR, "EUC-KR"),
        (.isoLatin1, "ISO-8859-1"), (.windowsCP1252, "Windows-1252"),
    ]

    /// BOM first, then NSString detection restricted to the candidate set,
    /// fall back ISO-8859-1 (single-byte map — never fails). Empty → UTF-8.
    static func detect(sample: Data) -> String.Encoding {
        guard !sample.isEmpty else { return .utf8 }
        // BOM branches: a BOM is an explicit declaration, so accept it without the
        // strict-decode verification below — the downstream decoder's lossy fallback
        // handles any garbage that follows. Note FF FE is also the prefix of the
        // UTF-32LE BOM; UTF-32 is not in the candidate set, so treating it as
        // UTF-16LE is an accepted trade-off.
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if sample.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if sample.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        let allowed = candidates.map { NSNumber(value: $0.encoding.rawValue) }
        // The caller samples only the first N bytes of a file, which for large CJK
        // files almost always cuts a multi-byte character in half. NSString's detector
        // validates the WHOLE sample, so a truncated tail makes it skip the true
        // encoding and settle on a single-byte map (ISO-8859-1 → garbled page).
        // Fix: run detection on up-to-4-byte-trimmed variants too (max sequence length
        // across UTF-8/UTF-16/GB18030; also covers odd-length UTF-16) — same spirit as
        // TextChunkDecoder carrying incomplete trailing sequences over. Single-byte
        // results (isoLatin1/cp1252 decode ANY bytes, so they carry no confidence) are
        // deferred: a later trim may reveal the real multi-byte encoding. Trimming only
        // affects detection/verification; the returned encoding covers the full data.
        let singleByte: Set<String.Encoding> = [.isoLatin1, .windowsCP1252]
        var deferredSingleByte: String.Encoding?
        for back in 0...min(4, sample.count) {
            let trimmed = sample.prefix(sample.count - back)
            if trimmed.isEmpty { break }
            // Out parameters passed nil: we never read the converted string, and we
            // don't trust the lossy flag either — `usedLossyConversion` can be false
            // even when the strict (non-lossy) `String(data:encoding:)` decode used
            // elsewhere in the Lister would fail, so we verify by strict decode below.
            let raw = NSString.stringEncoding(
                for: trimmed,
                encodingOptions: [.suggestedEncodingsKey: allowed, .useOnlySuggestedEncodingsKey: true],
                convertedString: nil, usedLossyConversion: nil)
            guard raw != 0 else { continue }
            let enc = String.Encoding(rawValue: raw)
            guard String(data: trimmed, encoding: enc) != nil else { continue }
            if singleByte.contains(enc) {
                if deferredSingleByte == nil { deferredSingleByte = enc }
            } else {
                return enc
            }
        }
        // No multi-byte candidate survived strict decoding at any trim: use the
        // detector's single-byte pick, else ISO-8859-1 (single-byte map — never fails).
        return deferredSingleByte ?? .isoLatin1
    }
}
