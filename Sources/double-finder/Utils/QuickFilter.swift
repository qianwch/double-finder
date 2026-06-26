import Foundation

/// Total-Commander-style quick search matching: case-insensitive **substring**
/// (matches anywhere, not just the start) on the literal name, OR on the name's
/// **pinyin-initial folding** so that e.g. typing "cs" matches "测试" (测=c, 试=s)
/// and "我的测试" too. Pure logic — unit-tested.
enum QuickFilter {
    /// True when `name` should be kept for quick-search text `query`. Empty query
    /// matches everything.
    static func matches(name: String, query: String) -> Bool {
        let q = query.lowercased()
        guard !q.isEmpty else { return true }
        if name.lowercased().contains(q) { return true }      // literal substring (incl. ASCII / typed CJK)
        return initials(of: name).contains(q)                 // pinyin-initial substring
    }

    /// Folds a name to a lowercase key for prefix matching: every CJK character →
    /// its Mandarin pinyin initial, every other character → itself lowercased.
    /// "测试" → "cs", "Resources" → "resources", "项目X" → "xmx".
    static func initials(of name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        for ch in name {
            if ch.isASCII { out += ch.lowercased() }
            else { out += pinyinInitial(ch) }
        }
        return out
    }

    /// First Latin letter of a character's Mandarin transliteration ("测" → "c"),
    /// or the character's own lowercase if it doesn't transliterate.
    private static func pinyinInitial(_ ch: Character) -> String {
        let s = NSMutableString(string: String(ch))
        CFStringTransform(s as CFMutableString, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s as CFMutableString, nil, kCFStringTransformStripDiacritics, false)
        let latin = (s as String).lowercased()
        return latin.first.map(String.init) ?? ch.lowercased()
    }
}
