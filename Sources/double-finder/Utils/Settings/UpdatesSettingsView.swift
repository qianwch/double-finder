import AppKit

/// Settings ▸ Updates: the auto-update switch + check interval, plus a manual
/// "Check Now…" button that goes straight through `AppUpdater` (the same
/// entry point as the menu item and the optional toolbar button).
final class UpdatesSettingsView: SettingsPaneView {
    private var enabledCheckbox: NSButton!
    private var intervalPopup: NSPopUpButton!
    private var lastCheckedLabel: NSTextField!

    /// Popup index → days, matching Daily / Weekly / Monthly.
    private static let intervalDays = [1, 7, 30]

    init() {
        super.init(labelTitles: [tr("Check frequency:")])

        let enabled = NSButton(checkboxWithTitle: tr("Automatically check for updates"),
                               target: self, action: #selector(toggleEnabled(_:)))
        enabled.state = AppSettings.autoUpdateEnabled ? .on : .off
        self.enabledCheckbox = enabled

        let popup = NSPopUpButton()
        popup.addItems(withTitles: [tr("Daily"), tr("Weekly"), tr("Monthly")])
        popup.selectItem(at: Self.intervalDays.firstIndex(of: AppSettings.autoUpdateIntervalDays) ?? 0)
        popup.isEnabled = AppSettings.autoUpdateEnabled
        popup.target = self; popup.action = #selector(changeInterval(_:))
        self.intervalPopup = popup

        let checkNow = NSButton(title: tr("Check Now…"), target: self, action: #selector(checkNowClicked))
        checkNow.bezelStyle = .rounded

        let last = NSTextField(labelWithString: "")
        last.textColor = .secondaryLabelColor
        last.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        self.lastCheckedLabel = last

        addCard(title: tr("Automatic Updates"), rows: [
            SettingsRow.control(enabled, labelWidth: labelWidth),
            SettingsRow.labeled(tr("Check frequency:"), popup, labelWidth: labelWidth),
        ])
        addCard(title: tr("Manual Check"), rows: [
            SettingsRow.labeled("", [checkNow, last], labelWidth: labelWidth),
        ])
        refreshLastChecked()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleEnabled(_ s: NSButton) {
        AppSettings.autoUpdateEnabled = (s.state == .on)
        intervalPopup.isEnabled = AppSettings.autoUpdateEnabled
    }

    @objc private func changeInterval(_ s: NSPopUpButton) {
        AppSettings.autoUpdateIntervalDays = Self.intervalDays[s.indexOfSelectedItem]
    }

    @objc private func checkNowClicked() {
        AppUpdater.shared.checkNow(host: window)
    }

    private func refreshLastChecked() {
        if let date = AppSettings.autoUpdateLastCheckedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lastCheckedLabel.stringValue = String(format: tr("Last checked: %@"), formatter.string(from: date))
        } else {
            lastCheckedLabel.stringValue = tr("Last checked: never")
        }
    }
}

extension UpdatesSettingsView: SettingsPaneReloadable {
    func reloadFromModel() {
        enabledCheckbox.state = AppSettings.autoUpdateEnabled ? .on : .off
        intervalPopup.isEnabled = AppSettings.autoUpdateEnabled
        intervalPopup.selectItem(at: Self.intervalDays.firstIndex(of: AppSettings.autoUpdateIntervalDays) ?? 0)
        refreshLastChecked()
    }
}
