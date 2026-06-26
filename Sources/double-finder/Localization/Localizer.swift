import Foundation

/// The UI languages Double Finder ships translations for.
/// `system` follows the macOS preferred-language order at launch.
enum Language: String, CaseIterable {
    case system, zhHans, ja, en, ko, de, fr

    /// JSON pack basename in Resources/Localization, or nil when no pack is
    /// needed (English uses the key itself; system resolves to a concrete case).
    var jsonName: String? {
        switch self {
        case .zhHans: return "zh-Hans"
        case .ja:     return "ja"
        case .ko:     return "ko"
        case .de:     return "de"
        case .fr:     return "fr"
        case .en, .system: return nil
        }
    }

    /// Name shown in the Settings popup (native autonym; `system` is localized).
    @MainActor var displayName: String {
        switch self {
        case .system: return tr("Follow System")
        case .zhHans: return "简体中文"
        case .ja:     return "日本語"
        case .en:     return "English"
        case .ko:     return "한국어"
        case .de:     return "Deutsch"
        case .fr:     return "Français"
        }
    }

    /// Map a `Locale.preferredLanguages`-style list to a concrete built-in
    /// language. Traditional Chinese and unsupported locales fall back to English.
    static func resolved(from preferred: [String]) -> Language {
        for tag in preferred {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh_hant") { return .en }
            if lower.hasPrefix("zh") { return .zhHans }
            if lower.hasPrefix("ja") { return .ja }
            if lower.hasPrefix("ko") { return .ko }
            if lower.hasPrefix("de") { return .de }
            if lower.hasPrefix("fr") { return .fr }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

extension Notification.Name {
    /// Posted after the active UI language changes; observers relocalize.
    static let localizerDidChange = Notification.Name("DoubleFinder.localizerDidChange")
}

/// Holds the active UI language and the loaded string table. `tr(_:)` reads it.
@MainActor
final class Localizer {
    static let shared = Localizer()

    /// The concrete language actually used for lookups (never `.system`).
    private(set) var current: Language = .en
    private var table: [String: String] = [:]

    private init() {
        reload()
    }

    /// Re-read the persisted setting, resolve `.system`, and load the pack.
    func reload() {
        let stored = UserDefaults.standard.string(forKey: "Language") ?? ""
        let selected = Language(rawValue: stored) ?? .system
        let concrete = (selected == .system)
            ? Language.resolved(from: Locale.preferredLanguages)
            : selected
        current = concrete
        table = Localizer.loadTable(for: concrete)
    }

    /// Persist a new selection, reload the table, and broadcast the change.
    func setLanguage(_ language: Language) {
        UserDefaults.standard.set(language.rawValue, forKey: "Language")
        reload()
        NotificationCenter.default.post(name: .localizerDidChange, object: nil)
    }

    /// The selection as stored (may be `.system`); used to preselect the popup.
    var storedSelection: Language {
        let stored = UserDefaults.standard.string(forKey: "Language") ?? ""
        return Language(rawValue: stored) ?? .system
    }

    /// Separator for context-disambiguated keys ("Base␄context"). Lets the same
    /// English word carry different translations by context — e.g. the "View" menu
    /// (视图) vs the F3 "View" file action (查看). A language without a specific
    /// entry falls back to the base part, so English (identity) still shows "View".
    nonisolated static let contextSeparator: Character = "\u{4}"

    func string(for key: String) -> String {
        if let v = table[key] { return v }
        if let sep = key.firstIndex(of: Self.contextSeparator) { return String(key[..<sep]) }
        return key
    }

    private static func loadTable(for language: Language) -> [String: String] {
        guard let name = language.jsonName,
              let url = Bundle.module.url(forResource: name,
                                          withExtension: "json",
                                          subdirectory: "Localization"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }
}

/// Translate an English source string to the active language (identity fallback).
@MainActor
func tr(_ key: String) -> String {
    return Localizer.shared.string(for: key)
}

/// Builds a context-disambiguated translation key ("base␄context"). English /
/// identity fallback shows just `base`; packs can translate (base, context) on its
/// own — for words that need different translations by context (e.g. "View" the
/// menu = 视图 vs the F3 "View"-a-file action = 查看).
func ctxKey(_ base: String, _ context: String) -> String {
    "\(base)\(Localizer.contextSeparator)\(context)"
}

/// Translate then apply printf-style arguments (placeholders preserved per language).
@MainActor
func tr(_ key: String, _ args: CVarArg...) -> String {
    return String(format: Localizer.shared.string(for: key), arguments: args)
}
