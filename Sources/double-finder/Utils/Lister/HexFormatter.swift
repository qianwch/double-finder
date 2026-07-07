import Foundation

struct HexRow: Equatable {
    let offset: String   // fixed-width uppercase hex
    let hex: String      // "41 42 ... 48  49 ... 50 " — mid-gap after byte 8, tail padded
    let ascii: String    // printable 0x20–0x7E, "." otherwise
}

/// Pure formatting for one 16-byte hex row (design §2). The view draws rows;
/// this decides every character.
enum HexFormatter {
    static let bytesPerRow = 16

    static func offsetDigits(fileLength: UInt64) -> Int {
        max(8, String(max(fileLength, 1) - 1, radix: 16).count)
    }

    static func row(offset: UInt64, bytes: [UInt8], digits: Int) -> HexRow {
        var hex = ""; var ascii = ""
        for i in 0..<bytesPerRow {
            if i == 8 { hex += " " }
            if i < bytes.count {
                hex += String(format: "%02X ", bytes[i])
                ascii.append((0x20...0x7E).contains(bytes[i])
                             ? Character(UnicodeScalar(bytes[i])) : ".")
            } else {
                hex += "   "
            }
        }
        return HexRow(offset: String(format: "%0\(digits)llX", offset), hex: hex, ascii: ascii)
    }
}
