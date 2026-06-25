import Foundation

/// Parses a Pack-dialog "Volume size" string into a 7zz `-v` suffix token
/// (e.g. "100m"), or `.none` (no split) / `.invalid`. Pure logic — unit-tested.
enum VolumeSize {
    enum Parsed: Equatable { case none; case token(String); case invalid }

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
        let unit: String
        switch unitRaw {
        case "":            unit = "b"   // bare number = bytes (7zz semantics)
        case "b":           unit = "b"
        case "k", "kb":     unit = "k"
        case "m", "mb":     unit = "m"
        case "g", "gb":     unit = "g"
        default:            return .invalid
        }
        return .token("\(n)\(unit)")
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
