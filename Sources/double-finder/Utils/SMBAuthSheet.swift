import AppKit

/// In-app SMB credential prompt (no system dialog). Collects user/password,
/// guest, and "remember in Keychain". Shown by MainViewController when a server
/// has no saved credential or authentication failed.
final class SMBAuthSheet: NSWindowController {

    var onSubmit: ((_ user: String, _ password: String, _ guest: Bool, _ remember: Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let guestCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let rememberCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.title = tr("Connect to Server")
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(on parent: NSWindow?, host: String, errorMessage: String?) {
        titleLabel.stringValue = tr("Enter credentials for %@", host)
        errorLabel.stringValue = errorMessage ?? ""
        errorLabel.isHidden = (errorMessage == nil)
        passwordField.stringValue = ""
        guestCheck.state = .off
        updateGuest()
        guard let window = window else { return }
        if let parent = parent {
            var f = window.frame
            f.origin = NSPoint(x: parent.frame.midX - f.width / 2,
                               y: parent.frame.midY - f.height / 2)
            window.setFrame(f, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(userField.stringValue.isEmpty ? userField : passwordField)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        titleLabel.frame = NSRect(x: 20, y: 176, width: 340, height: 18)
        titleLabel.font = .boldSystemFont(ofSize: 12)
        content.addSubview(titleLabel)

        errorLabel.frame = NSRect(x: 20, y: 158, width: 340, height: 16)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        content.addSubview(errorLabel)

        let userLabel = NSTextField(labelWithString: tr("User name:"))
        userLabel.frame = NSRect(x: 20, y: 128, width: 90, height: 20)
        content.addSubview(userLabel)
        userField.frame = NSRect(x: 112, y: 126, width: 248, height: 24)
        content.addSubview(userField)

        let pwLabel = NSTextField(labelWithString: tr("Password:"))
        pwLabel.frame = NSRect(x: 20, y: 96, width: 90, height: 20)
        content.addSubview(pwLabel)
        passwordField.frame = NSRect(x: 112, y: 94, width: 248, height: 24)
        content.addSubview(passwordField)

        guestCheck.title = tr("Connect as guest")
        guestCheck.frame = NSRect(x: 112, y: 66, width: 248, height: 20)
        guestCheck.target = self; guestCheck.action = #selector(toggleGuest)
        content.addSubview(guestCheck)

        rememberCheck.title = tr("Remember in Keychain")
        rememberCheck.frame = NSRect(x: 112, y: 42, width: 248, height: 20)
        rememberCheck.state = .on
        content.addSubview(rememberCheck)

        let connect = NSButton(title: tr("Connect"), target: self, action: #selector(submit))
        connect.frame = NSRect(x: 268, y: 8, width: 92, height: 28)
        connect.bezelStyle = .rounded
        connect.keyEquivalent = "\r"
        content.addSubview(connect)

        let cancel = NSButton(title: tr("Cancel"), target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 172, y: 8, width: 92, height: 28)
        cancel.bezelStyle = .rounded
        content.addSubview(cancel)
    }

    @objc private func toggleGuest() { updateGuest() }

    private func updateGuest() {
        let guest = guestCheck.state == .on
        userField.isEnabled = !guest
        passwordField.isEnabled = !guest
    }

    @objc private func submit() {
        let guest = guestCheck.state == .on
        onSubmit?(userField.stringValue, passwordField.stringValue,
                  guest, rememberCheck.state == .on)
        window?.close()
    }

    @objc private func cancel() {
        onCancel?()
        window?.close()
    }
}
