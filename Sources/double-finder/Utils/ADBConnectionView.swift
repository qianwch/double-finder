import AppKit

/// ADB has its own cancellable discovery/connection lifecycle, independent of MTP.
@MainActor
final class ADBConnectionView: NSStackView, NSTextFieldDelegate {
    var onDevices: (([ADBDevice], Bool) -> Void)?
    var onEdit: (() -> Void)?
    var onConnectionStarted: (() -> Void)?
    var onConnected: ((ADBSession, String) -> Void)?
    private let nameField = NSTextField(), hostField = NSTextField()
    private let pairPort = NSTextField(), connectPort = NSTextField()
    private let codeField = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let suggestions = NSPopUpButton()
    private var pairButton: NSButton!
    private var initialPath = "/sdcard"
    private var device: ADBDevice?
    private var services: [ADBService] = []
    private var scanTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var operationGeneration = 0
    private(set) var busy = false

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: tr("Name")), nameField],
            [NSTextField(labelWithString: tr("Host")), hostField],
            [NSTextField(labelWithString: tr("Connection port")), connectPort],
            [NSTextField(labelWithString: tr("Pairing port")), pairPort],
            [NSTextField(labelWithString: tr("Pairing code")), codeField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        for field in [nameField, hostField, pairPort, connectPort, codeField] { field.delegate = self }
        hostField.placeholderString = "192.168.1.2"
        pairButton = NSButton(title: tr("Pair"), target: self, action: #selector(pairClicked))
        let refresh = NSButton(title: tr("Refresh"), target: self, action: #selector(refreshClicked))
        let actions = NSStackView(views: [pairButton, refresh]); actions.spacing = 10
        addArrangedSubview(actions)
        suggestions.target = self; suggestions.action = #selector(useSuggestion)
        addArrangedSubview(suggestions); addArrangedSubview(status)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 4
        status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        populate(nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func populate(_ connection: ADBConnection?) {
        cancelOperation(); device = nil; initialPath = connection?.initialPath ?? "/sdcard"
        nameField.stringValue = connection?.name ?? ""
        hostField.stringValue = connection?.host ?? ""
        connectPort.stringValue = connection.map { String($0.port) } ?? ""
        pairPort.stringValue = ""; codeField.stringValue = ""
        for field in [nameField, hostField, connectPort, pairPort, codeField] { field.isEnabled = true }
        pairButton.isEnabled = true; suggestions.isEnabled = true
        status.stringValue = tr("Enable Wireless debugging on the phone. Pairing and connection use separate ports.")
    }
    func showDevice(_ device: ADBDevice) {
        cancelOperation(); initialPath = "/sdcard"; self.device = device; codeField.stringValue = ""
        for field in [nameField, hostField, connectPort, pairPort, codeField] { field.isEnabled = false }
        pairButton.isEnabled = false; suggestions.isEnabled = false
        status.stringValue = device.isAuthorized ? tr("Ready to connect.")
            : (device.state == "unauthorized" ? tr("Unlock the phone and allow USB debugging, then refresh.") : tr("Device is %@. Refresh after reconnecting it.", device.state))
    }
    func connection() -> ADBConnection? {
        guard device == nil, let port = Int(connectPort.stringValue),
              (try? ADBConnectionDraft.endpoint(host: hostField.stringValue, port: connectPort.stringValue)) != nil else { return nil }
        return ADBConnection(name: nameField.stringValue, host: hostField.stringValue, port: port, initialPath: initialPath)
    }
    func controlTextDidChange(_ notification: Notification) {
        if busy { cancelOperation(); status.stringValue = tr("Connection settings changed. Try again.") }
        if (notification.object as? NSTextField) !== codeField && (notification.object as? NSTextField) !== pairPort { onEdit?() }
    }
    private func executable() throws -> String {
        guard let path = ADBClient.resolveExecutable(configuredPath: UserDefaults.standard.string(forKey: "ADBExecutablePath")) else {
            throw ADBError.commandFailed("ADB not found. Install Android SDK platform-tools or choose adb in Settings.")
        }
        return path
    }
    func refresh() {
        scanTask?.cancel(); scanGeneration += 1
        let generation = scanGeneration
        onDevices?([], true)
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let path = try executable()
                let devices = try await ADBClient.devices(executablePath: path)
                guard !Task.isCancelled, generation == scanGeneration else { return }
                onDevices?(devices, false) // never wait for mDNS (or MTP) before showing devices
                let found = (try? await ADBClient.mdnsServices(executablePath: path)) ?? []
                guard !Task.isCancelled, generation == scanGeneration else { return }
                services = found; suggestions.removeAllItems(); suggestions.addItem(withTitle: tr("Wireless discovery"))
                for service in found {
                    suggestions.addItem(withTitle: "\(service.name) · \(service.kind == .pairing ? tr("Pair") : tr("Connect")) · \(service.endpoint)")
                }
            } catch {
                guard !Task.isCancelled, generation == scanGeneration else { return }
                onDevices?([], false); status.stringValue = tr(error.localizedDescription)
            }
        }
    }
    @objc private func refreshClicked() { refresh() }
    @objc private func useSuggestion() {
        if busy { cancelOperation() }
        let index = suggestions.indexOfSelectedItem - 1
        guard services.indices.contains(index) else { return }
        let service = services[index]
        guard let colon = service.endpoint.lastIndex(of: ":") else { return }
        let host = String(service.endpoint[..<colon])
        if host != hostField.stringValue {
            pairPort.stringValue = ""; connectPort.stringValue = ""; codeField.stringValue = ""
        }
        hostField.stringValue = host
        if service.kind == .pairing { pairPort.stringValue = String(service.endpoint[service.endpoint.index(after: colon)...]) }
        else { connectPort.stringValue = String(service.endpoint[service.endpoint.index(after: colon)...]); onEdit?() }
    }
    @objc private func pairClicked() {
        guard !busy else { return }
        do {
            let path = try executable()
            let endpoint = try ADBConnectionDraft.endpoint(host: hostField.stringValue, port: pairPort.stringValue)
            let code = codeField.stringValue
            codeField.stringValue = "" // secret exists only in the bounded pairing operation
            busy = true; operationGeneration += 1; let generation = operationGeneration
            status.stringValue = tr("Pairing…")
            operationTask = Task { [weak self] in
                do {
                    try await ADBClient.pair(executablePath: path, endpoint: endpoint, code: code)
                    guard let self, !Task.isCancelled, generation == self.operationGeneration else { return }
                    self.busy = false; self.status.stringValue = tr("Paired. Enter the connection port shown under Wireless debugging, then connect."); self.refresh()
                } catch {
                    guard let self, !Task.isCancelled, generation == self.operationGeneration else { return }
                    self.busy = false; self.status.stringValue = tr(error.localizedDescription)
                }
            }
        } catch { status.stringValue = tr(error.localizedDescription) }
    }
    func connect() {
        guard !busy else { return }
        do {
            let path = try executable()
            let selected = device
            guard selected?.isAuthorized != false else { return }
            let connection = self.connection()
            guard selected != nil || connection != nil else { throw ADBError.invalidArgument }
            let knownEndpoint = selected.flatMap { d in
                ADBConnectionDraft.networkEndpoint(serial: d.serial, services: services)
            }
            onConnectionStarted?() // capture active panel before the first await
            busy = true; operationGeneration += 1; let generation = operationGeneration
            status.stringValue = tr("Connecting…")
            operationTask = Task { [weak self] in
                do {
                    let session: ADBSession
                    if let selected { session = ADBSession(device: selected, executablePath: path, networkEndpoint: knownEndpoint) }
                    else if let connection {
                        try await ADBClient.connect(executablePath: path, endpoint: connection.endpoint)
                        let result = try await ADBClient.checked(executable: path, arguments: ["-s", connection.endpoint, "get-state"])
                        guard String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "device" else { throw ADBError.commandFailed("Device is not authorized or is offline.") }
                        session = ADBSession(device: ADBDevice(serial: connection.endpoint, model: connection.name, state: "device"), executablePath: path, networkEndpoint: connection.endpoint)
                    } else { throw ADBError.invalidArgument }
                    let initialPath = connection?.initialPath ?? "/sdcard"
                    _ = try await ADBClient(session: session).list(initialPath)
                    guard let self, !Task.isCancelled, generation == self.operationGeneration else { session.invalidate(); return }
                    self.busy = false
                    self.onConnected?(session, initialPath)
                } catch {
                    guard let self, !Task.isCancelled, generation == self.operationGeneration else { return }
                    self.busy = false; self.status.stringValue = tr(error.localizedDescription)
                }
            }
        } catch { status.stringValue = tr(error.localizedDescription) }
    }
    private func cancelOperation() { operationGeneration += 1; operationTask?.cancel(); operationTask = nil; busy = false }
    func cancelConnection() { cancelOperation(); codeField.stringValue = "" }
    func focusHost() { window?.makeFirstResponder(hostField) }
    func close() { scanGeneration += 1; scanTask?.cancel(); scanTask = nil; cancelOperation(); codeField.stringValue = "" }
}
