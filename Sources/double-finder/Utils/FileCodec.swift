import Foundation

/// TC's Files ▸ Encode / Decode: MIME Base64 and UUEncode text transports.
/// Pure logic — file IO and dialogs live in MainViewController/EncodeSheet.
enum FileCodec {
    struct DecodeError: LocalizedError {
        var errorDescription: String? {
            "The file could not be decoded (not valid Base64 or UUEncode data)."
        }
    }

    enum Encoding: CaseIterable {
        case base64, uuencode

        var displayName: String {
            switch self {
            case .base64: return "MIME (Base64)"
            case .uuencode: return "UUEncode"
            }
        }

        var fileExtension: String {
            switch self {
            case .base64: return "b64"
            case .uuencode: return "uue"
            }
        }
    }

    // MARK: - Encode

    /// RFC 2045 style: base64 wrapped at 76 characters.
    static func encodeBase64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            + "\n"
    }

    /// Classic uuencode: `begin 644 name` header, 45-byte lines, backtick for
    /// zero (the historic space is accepted on decode), `` ` `` + `end` trailer.
    static func uuencode(_ data: Data, fileName: String, mode: String = "644") -> String {
        var out = "begin \(mode) \(fileName)\n"
        var index = 0
        let bytes = [UInt8](data)
        while index < bytes.count {
            let lineBytes = Array(bytes[index..<min(index + 45, bytes.count)])
            out += encodeUULine(lineBytes) + "\n"
            index += 45
        }
        out += "`\nend\n"
        return out
    }

    private static func uuChar(_ value: UInt8) -> Character {
        value == 0 ? "`" : Character(UnicodeScalar(value + 32))
    }

    private static func encodeUULine(_ bytes: [UInt8]) -> String {
        var line = String(uuChar(UInt8(bytes.count)))
        var index = 0
        while index < bytes.count {
            let b0 = bytes[index]
            let b1 = index + 1 < bytes.count ? bytes[index + 1] : 0
            let b2 = index + 2 < bytes.count ? bytes[index + 2] : 0
            line.append(uuChar(b0 >> 2))
            line.append(uuChar(((b0 << 4) | (b1 >> 4)) & 0x3F))
            line.append(uuChar(((b1 << 2) | (b2 >> 6)) & 0x3F))
            line.append(uuChar(b2 & 0x3F))
            index += 3
        }
        return line
    }

    // MARK: - Decode

    /// A `begin <mode> <name>` header marks uuencoded text; anything else is
    /// treated as base64 (with whitespace/headers tolerated).
    static func detect(_ text: String) -> Encoding {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("begin ") { return .uuencode }
        }
        return .base64
    }

    /// Decodes uuencoded text; returns the embedded file name and payload.
    static func uudecode(_ text: String) -> (fileName: String, data: Data)? {
        var data = Data()
        var fileName: String?
        var inBody = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .init(charactersIn: "\r"))
            if !inBody {
                if line.hasPrefix("begin ") {
                    let parts = line.split(separator: " ", maxSplits: 2)
                    guard parts.count == 3 else { return nil }
                    fileName = String(parts[2])
                    inBody = true
                }
                continue
            }
            if line == "end" { break }
            if line.isEmpty { continue }
            guard let decoded = decodeUULine(line) else { return nil }
            if decoded.isEmpty { continue }   // "`" / space terminator line
            data.append(contentsOf: decoded)
        }
        guard inBody, let name = fileName else { return nil }
        return (name, data)
    }

    private static func uuValue(_ char: Character) -> UInt8? {
        guard let ascii = char.asciiValue else { return nil }
        if ascii == 96 { return 0 }                      // "`" = zero
        guard ascii >= 32, ascii < 96 else { return nil }
        return ascii - 32
    }

    private static func decodeUULine(_ line: String) -> [UInt8]? {
        let chars = Array(line)
        guard let first = chars.first, let count = uuValue(first) else { return nil }
        guard count > 0 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(Int(count))
        var index = 1
        while out.count < Int(count) {
            // Historic encoders sometimes strip trailing spaces; treat missing
            // trailing characters as zero.
            func value(_ offset: Int) -> UInt8? {
                offset < chars.count ? uuValue(chars[offset]) : 0
            }
            guard let c0 = value(index), let c1 = value(index + 1),
                  let c2 = value(index + 2), let c3 = value(index + 3) else { return nil }
            let needed = Int(count) - out.count
            out.append((c0 << 2) | (c1 >> 4))
            if needed > 1 { out.append((c1 << 4) | (c2 >> 2)) }
            if needed > 2 { out.append((c2 << 6) | c3) }
            index += 4
        }
        return out
    }

    /// Decodes base64 text, ignoring whitespace and skipping obvious header
    /// lines (anything containing characters outside the base64 alphabet).
    static func decodeBase64(_ text: String) -> Data? {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let body = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.allSatisfy { alphabet.contains($0) } }
            .joined()
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: body)
    }
}
