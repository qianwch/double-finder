import Foundation

/// One row of the connection window's left rail.
///
/// Section headers, entries and placeholder lines are all rows so the rail can
/// be a flat `NSTableView`: nothing in it collapses, and the old split of
/// "Saved" and "Discovered" into two fixed-height scroll views is exactly what
/// this replaces — one list means whichever section has content gets the height.
enum ServerRailRow: Equatable {
    case header(String)
    case saved(ServerConnection)
    /// A plugged-in phone. `note` is the occupancy line captured at scan time
    /// ("in use by …"), empty when nothing holds it.
    case device(AndroidDevice, note: String)
    case discovered(NetworkBrowser.Service)
    /// Empty-state / progress line. Never selectable.
    case note(String)

    var isSelectable: Bool {
        switch self {
        case .saved, .device, .discovered: return true
        case .header, .note:               return false
        }
    }

    /// Title + subtitle the search field matches against.
    var searchText: String {
        switch self {
        case .saved(let c):          return c.name + " " + c.subtitle
        case .device(let d, _):      return d.displayName
        case .discovered(let s):     return s.name + " " + (s.host ?? "")
        case .header, .note:         return ""
        }
    }
}

@MainActor
enum ServerRail {
    /// Builds the rail's rows. Pure so the empty-state and filtering rules — the
    /// parts that are easy to get subtly wrong — can be tested without a window.
    ///
    /// While a filter is active only matching entries survive, headers included:
    /// a section header with nothing under it reads as "this section is empty",
    /// which would be a lie during a search.
    static func rows(saved: [ServerConnection],
                     devices: [(device: AndroidDevice, note: String)],
                     discovered: [NetworkBrowser.Service],
                     scanningDevices: Bool,
                     filter: String) -> [ServerRailRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let filtering = !needle.isEmpty
        func matches(_ row: ServerRailRow) -> Bool {
            !filtering || row.searchText.localizedCaseInsensitiveContains(needle)
        }

        var out: [ServerRailRow] = []

        func section(_ title: String, _ entries: [ServerRailRow], emptyNote: String?) {
            let kept = entries.filter(matches)
            if kept.isEmpty {
                // Placeholders are a no-filter affordance only.
                guard !filtering, let emptyNote = emptyNote else { return }
                out.append(.header(title))
                out.append(.note(emptyNote))
                return
            }
            out.append(.header(title))
            out += kept
        }

        section(tr("Saved"), saved.map { .saved($0) },
                emptyNote: tr("No saved connections yet. Use + below to add one."))

        // A phone is either plugged in or it isn't; an always-present empty
        // section would be noise, so this one shows up only when there is
        // something to say.
        let deviceRows: [ServerRailRow] = devices.map { .device($0.device, note: $0.note) }
        section(tr("Connected devices"), deviceRows,
                emptyNote: scanningDevices ? tr("Scanning…") : nil)

        section(tr("Discovered"), discovered.map { .discovered($0) },
                emptyNote: tr("Nothing shared on the local network."))

        if filtering && out.isEmpty { out = [.note(tr("No matches"))] }
        return out
    }

    /// "Last connected: …" for the detail header, or nil when it never was.
    /// Relative for the last week, absolute after that — a bare date is useless
    /// for something used daily, and "6 weeks ago" is useless for something used
    /// once a year.
    static func lastConnectedText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date = date else { return nil }
        let elapsed = now.timeIntervalSince(date)
        let formatter = DateFormatter()
        if elapsed >= 0 && elapsed < 7 * 24 * 3600 {
            let relative = RelativeDateTimeFormatter()
            relative.locale = Locale(identifier: Localizer.shared.current.jsonName ?? "en")
            return tr("Last connected: %@", relative.localizedString(for: date, relativeTo: now))
        }
        formatter.locale = Locale(identifier: Localizer.shared.current.jsonName ?? "en")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return tr("Last connected: %@", formatter.string(from: date))
    }
}
