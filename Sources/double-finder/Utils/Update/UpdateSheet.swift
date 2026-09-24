import AppKit

/// The one sheet the updater ever shows, in three states that replace its
/// content in place rather than stacking separate sheets (a window can only
/// host one sheet at a time — see spec/conventions.md — and swapping content
/// sidesteps having to wait out one sheet's close animation before opening
/// the next):
///   checking  → indeterminate spinner, shown only for a user-initiated check
///   progress  → determinate bar while the DMG downloads
///   ready     → release notes + Later / Restart & Install
/// A silent background check that finds nothing never creates this sheet at
/// all; one that finds an update jumps straight to `showReady`.
final class UpdateSheet: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 38, width: 380, height: 16))
    private let cancelButton = NSButton(title: tr("Cancel"), target: nil, action: nil)

    private let titleLabel = NSTextField(labelWithString: "")
    private let notesLabel = NSTextField(labelWithString: tr("What's new:"))
    private let scroll = NSScrollView(frame: NSRect(x: 20, y: 50, width: 380, height: 200))
    private let notesView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
    private let laterButton = NSButton(title: tr("Later"), target: nil, action: nil)
    private let installButton = NSButton(title: tr("Restart & Install"), target: nil, action: nil)

    var onCancel: (() -> Void)?
    var onInstall: (() -> Void)?
    var onLater: (() -> Void)?

    private static let width: CGFloat = 420
    private static let checkingHeight: CGFloat = 110
    private static let readyHeight: CGFloat = 320

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.checkingHeight),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.title = tr("Check for Updates")
        super.init(window: window)
        buildUI()
        showChecking()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        statusLabel.stringValue = tr("Checking for updates…")
        statusLabel.frame = NSRect(x: 20, y: 60, width: 380, height: 18)
        content.addSubview(statusLabel)

        bar.style = .bar
        content.addSubview(bar)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.frame = NSRect(x: 312, y: 8, width: 88, height: 30)
        content.addSubview(cancelButton)

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 20, y: 282, width: 380, height: 20)
        titleLabel.isHidden = true
        content.addSubview(titleLabel)

        notesLabel.textColor = .secondaryLabelColor
        notesLabel.frame = NSRect(x: 20, y: 256, width: 380, height: 16)
        notesLabel.isHidden = true
        content.addSubview(notesLabel)

        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.isHidden = true
        notesView.isEditable = false
        notesView.font = .systemFont(ofSize: 12)
        notesView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = notesView
        content.addSubview(scroll)

        laterButton.bezelStyle = .rounded
        laterButton.target = self
        laterButton.action = #selector(laterClicked)
        laterButton.frame = NSRect(x: 180, y: 12, width: 100, height: 30)
        laterButton.isHidden = true
        content.addSubview(laterButton)

        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.target = self
        installButton.action = #selector(installClicked)
        installButton.frame = NSRect(x: 288, y: 12, width: 132, height: 30)
        installButton.isHidden = true
        content.addSubview(installButton)
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void = {}) {
        guard let window else { return }
        parent.beginSheet(window) { [self] response in
            // Capture the action before completion releases the controller's
            // keepAlive slot. Termination must happen AFTER the modal sheet
            // has ended, on the next run-loop turn.
            let install = response == .OK ? onInstall : nil
            completion()
            if let install { DispatchQueue.main.async(execute: install) }
        }
    }

    func dismiss() {
        guard let window, window.sheetParent != nil else { return }
        window.sheetParent?.endSheet(window, returnCode: .cancel)
    }

    // MARK: - States

    func showChecking() {
        resize(to: Self.checkingHeight)
        statusLabel.stringValue = tr("Checking for updates…")
        statusLabel.isHidden = false
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        cancelButton.isHidden = false
        [titleLabel, notesLabel, scroll, laterButton, installButton].forEach { $0.isHidden = true }
    }

    /// 0...1. Switches the (already-visible) bar from indeterminate to
    /// determinate on the first call.
    func setDownloadProgress(_ fraction: Double) {
        if bar.isIndeterminate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            statusLabel.stringValue = tr("Downloading update…")
        }
        bar.doubleValue = fraction * 100
    }

    func showReady(version: String, notes: String) {
        resize(to: Self.readyHeight)
        [statusLabel, bar, cancelButton].forEach { $0.isHidden = true }
        titleLabel.stringValue = String(format: tr("Double Finder %@ is ready to install."), version)
        notesView.string = notes.isEmpty ? tr("No release notes provided.") : notes
        [titleLabel, notesLabel, scroll, laterButton, installButton].forEach { $0.isHidden = false }
    }

    private func resize(to height: CGFloat) {
        window?.setContentSize(NSSize(width: Self.width, height: height))
    }

    @objc private func cancelClicked() { onCancel?(); dismiss() }
    @objc private func installClicked() {
        guard let window, let parent = window.sheetParent else { return }
        installButton.isEnabled = false
        parent.endSheet(window, returnCode: .OK)
    }
    @objc private func laterClicked() { onLater?(); dismiss() }
}
