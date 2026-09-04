import Foundation

/// Parses a Pack-dialog "Volume size" string into a byte count (7-Zip units:
/// k/m/g are powers of 1024, a bare number is bytes), or `.none` (no split) /
/// `.invalid`. Pure logic — unit-tested.
enum VolumeSize {
    enum Parsed: Equatable { case none; case bytes(Int64); case invalid }

    static func parse(_ raw: String) -> Parsed {
        // Strip any parenthetical note like "(CD)" then trim.
        var s = raw
        if let r = s.range(of: "(") { s = String(s[..<r.lowerBound]) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.lowercased() == "no split" { return .none }

        // Split into leading digits and an optional unit.
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), n > 0 else { return .invalid }
        let unitRaw = s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        let multiplier: Int64
        switch unitRaw {
        case "", "b":       multiplier = 1                      // bare number = bytes (7-Zip semantics)
        case "k", "kb":     multiplier = 1024
        case "m", "mb":     multiplier = 1024 * 1024
        case "g", "gb":     multiplier = 1024 * 1024 * 1024
        default:            return .invalid
        }
        return .bytes(Int64(n) * multiplier)
    }

    /// Same as `parse(_:)` but also treats `noSplitLabel` (the localized "No
    /// split" combo label) as `.none`, so a localized default selection isn't
    /// misread as an invalid size.
    static func parse(_ raw: String, noSplitLabel: String) -> Parsed {
        if raw.trimmingCharacters(in: .whitespaces) == noSplitLabel.trimmingCharacters(in: .whitespaces) {
            return .none
        }
        return parse(raw)
    }
}
