import Foundation

/// A user-defined toolbar button (TC-style): runs a shell command with
/// TC parameter placeholders, shown with a chosen SF Symbol.
struct CustomToolbarButton: Equatable {
    var id: String        // "custom.<uuid>" — lives alongside built-in ids in ToolbarConfig
    var title: String     // tooltip / settings label
    var symbol: String    // SF Symbol name (empty or unknown → fallback glyph)
    var command: String   // shell command with %P %T %N %S %% placeholders

    var asDictionary: [String: String] {
        ["id": id, "title": title, "symbol": symbol, "command": command]
    }

    init(id: String = "custom." + UUID().uuidString,
         title: String, symbol: String, command: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.command = command
    }

    init?(dictionary: [String: String]) {
        guard let id = dictionary["id"], id.hasPrefix("custom."),
              let title = dictionary["title"], !title.isEmpty,
              let command = dictionary["command"], !command.isEmpty else { return nil }
        self.init(id: id, title: title, symbol: dictionary["symbol"] ?? "", command: command)
    }
}

/// Storage for custom toolbar buttons (UserDefaults "CustomToolbarButtons").
enum CustomToolbarButtons {
    private static let key = "CustomToolbarButtons"

    static func all() -> [CustomToolbarButton] {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: String]] else { return [] }
        return raw.compactMap { CustomToolbarButton(dictionary: $0) }
    }

    static func setAll(_ buttons: [CustomToolbarButton]) {
        UserDefaults.standard.set(buttons.map { $0.asDictionary }, forKey: key)
    }

    static func add(_ button: CustomToolbarButton) {
        setAll(all() + [button])
    }

    static func remove(id: String) {
        setAll(all().filter { $0.id != id })
    }
}

/// TC parameter-placeholder expansion for custom commands. Pure logic.
enum ToolbarCommand {
    /// Expands the TC placeholders, shell-quoting every substitution:
    ///   %P  active panel's directory
    ///   %T  other panel's directory
    ///   %N  file name under the cursor
    ///   %S  all selected paths, quoted and space-joined
    ///   %%  literal percent sign
    /// Unknown %x sequences pass through unchanged.
    static func expand(_ template: String, activeDir: String, otherDir: String,
                       cursorName: String, selectedPaths: [String]) -> String {
        var out = ""
        var iterator = template.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? iterator.next() {
            pending = nil
            guard ch == "%" else { out.append(ch); continue }
            guard let code = iterator.next() else { out.append(ch); break }
            switch code {
            case "P": out += shellQuote(activeDir)
            case "T": out += shellQuote(otherDir)
            case "N": out += shellQuote(cursorName)
            case "S": out += selectedPaths.map(shellQuote).joined(separator: " ")
            case "%": out.append("%")
            default:
                out.append("%")
                pending = code   // re-examine (handles "%%P" → "%" + expanded %P)
            }
        }
        return out
    }

    /// Single-quote shell escaping: safe for any byte except that embedded
    /// single quotes close/reopen the quoting ('\'' dance).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
