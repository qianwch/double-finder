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
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if sample.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if sample.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        var converted: NSString?
        var lossy: ObjCBool = false
        let allowed = candidates.map { NSNumber(value: $0.encoding.rawValue) }
        let raw = NSString.stringEncoding(
            for: sample,
            encodingOptions: [.suggestedEncodingsKey: allowed, .useOnlySuggestedEncodingsKey: true],
            convertedString: &converted, usedLossyConversion: &lossy)
        // `usedLossyConversion` can be true even when the strict (non-lossy) `String(data:encoding:)`
        // decode used elsewhere in the Lister would fail outright — verify it actually round-trips
        // before trusting it, otherwise fall back to ISO-8859-1 (single-byte map — never fails).
        if raw != 0 {
            let candidate = String.Encoding(rawValue: raw)
            if String(data: sample, encoding: candidate) != nil { return candidate }
        }
        return .isoLatin1
    }
}
