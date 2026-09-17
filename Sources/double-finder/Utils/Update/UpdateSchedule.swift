import Foundation

/// Whether enough time has passed since the last automatic update check.
/// Pure logic — Settings ▸ Updates' interval popup and the launch-time hook
/// both go through this.
enum UpdateSchedule {
    static func isDue(lastChecked: Date?, intervalDays: Int, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        let interval = Double(max(intervalDays, 1)) * 86400
        return now.timeIntervalSince(lastChecked) >= interval
    }
}
