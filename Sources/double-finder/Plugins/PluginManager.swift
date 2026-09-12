import AppKit
import DoubleFinderPluginKit

/// App-wide plugin registry: discovers `.dfplugin` bundles, instantiates their
/// principal class, activates each plugin and exposes the extensions it provides
/// (file systems / viewers / commands) to the rest of the app. Built-in plugins
/// (`BuiltInPlugins.all`) go through exactly the same path, so the app's own
/// code is the first consumer of the public API.
///
/// Every mutation posts `didChange` (drive bars, the Plugins menu and the
/// Settings pane rebuild from it). Bundles are never unloaded — dlclose of a
/// Swift image is unsafe — so "disable" deactivates the object and drops its
/// registrations while the code stays mapped.
@MainActor
final class PluginManager {
    static let shared = PluginManager()
    static let didChange = Notification.Name("PluginManagerDidChange")

    /// UserDefaults key: identifiers of plugins the user switched off.
    static let disabledKey = "DisabledPlugins"
    /// UserDefaults key: the bundle being loaded right now. Written before a
    /// bundle's code runs, cleared once it is installed — if it is still there
    /// at the next launch, that bundle took the app down and gets quarantined.
    static let loadingMarkerKey = "PluginLoadingBundle"
    /// UserDefaults key: bundle file names skipped after a crash during load.
    static let quarantineKey = "QuarantinedPlugins"

    enum Origin: Equatable {
        case builtIn
        case bundle(URL)
    }

    enum State: Equatable {
        case active
        case disabled
        case failed(String)
    }

    struct Record {
        let info: PluginInfo
        let origin: Origin
        var state: State
        /// nil when the bundle never yielded a plugin object (load failure).
        let plugin: DFPlugin?

        var isActive: Bool { state == .active }
    }

    /// A file-system extension together with the plugin it came from. `driveID`
    /// is the `RemoteSession` identity of the drive it opens.
    struct RegisteredFileSystem {
        let pluginID: String
        let pluginName: String
        let extensionObject: FileSystemPlugin
        var driveID: String { PluginManager.driveID(pluginID: pluginID, fsID: extensionObject.identifier) }
    }

    struct RegisteredViewer {
        let pluginID: String
        let extensionObject: ViewerPlugin
    }

    struct RegisteredPageViewer {
        let pluginID: String
        let extensionObject: PageViewerPlugin
    }

    struct RegisteredCommand {
        let pluginID: String
        let extensionObject: CommandPlugin
        var id: String { "\(pluginID)/\(extensionObject.identifier)" }
        /// Toolbar button / shortcut id.
        var toolbarID: String { "plugin." + id }
    }

    struct RegisteredPacker {
        let pluginID: String
        let extensionObject: PackerPlugin
    }

    struct RegisteredContent {
        let pluginID: String
        let extensionObject: ContentPlugin
    }

    let host = AppPluginHost()

    private(set) var records: [Record] = []
    private(set) var fileSystems: [RegisteredFileSystem] = []
    private(set) var viewers: [RegisteredViewer] = []
    private(set) var pageViewers: [RegisteredPageViewer] = []
    private(set) var commands: [RegisteredCommand] = []
    private(set) var packers: [RegisteredPacker] = []
    private(set) var contentProviders: [RegisteredContent] = []

    private init() {}

    // MARK: - Locations

    nonisolated static func driveID(pluginID: String, fsID: String) -> String { "plugin://\(pluginID)/\(fsID)" }

    /// `~/Library/Application Support/Double Finder/Plugins` — the user's drop
    /// folder (created on first access so "Open Plugins Folder" always works).
    nonisolated static var userPluginsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Double Finder/Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Bundled plugins shipped inside the .app (`Contents/PlugIns`). nil for the
    /// bare development executable.
    static var builtInPluginsDirectory: URL? {
        Bundle.main.builtInPlugInsURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    // MARK: - Enable / disable persistence

    var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.disabledKey) }
    }

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    var quarantined: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.quarantineKey) ?? []) }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: Self.quarantineKey) }
            else { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.quarantineKey) }
        }
    }

    /// Launch-time check: a leftover loading marker means the last launch died
    /// inside that bundle. Quarantine it so the app comes up; Settings ▸ Plugins
    /// ▸ Rescan is the explicit retry.
    func quarantineCrashedBundleIfAny() {
        guard let name = UserDefaults.standard.string(forKey: Self.loadingMarkerKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.loadingMarkerKey)
        var q = quarantined
        q.insert(name)
        quarantined = q
        host.log("\(name) crashed while loading last time; quarantined")
    }

    // MARK: - Loading

    /// Called once at launch: built-in plugins first, then every bundle found in
    /// the app's PlugIns folder and the user's Plugins folder.
    func loadAll() {
        quarantineCrashedBundleIfAny()
        for type in BuiltInPlugins.all {
            load(builtIn: type)
        }
        rescanBundles()
    }

    /// Loads bundles that appeared since the last scan (already-loaded ones are
    /// skipped — a bundle can't be reloaded without a restart). With
    /// `retryQuarantined` (the Settings Rescan button) quarantined bundles get
    /// one more chance — the loading marker protects the next launch again.
    func rescanBundles(retryQuarantined: Bool = false) {
        if retryQuarantined, !quarantined.isEmpty {
            let names = quarantined
            quarantined = []
            records.removeAll { rec in
                if case .bundle(let url) = rec.origin, names.contains(url.lastPathComponent), rec.plugin == nil { return true }
                return false
            }
        }
        var urls: [URL] = []
        for dir in [Self.builtInPluginsDirectory, Self.userPluginsDirectory].compactMap({ $0 }) {
            let found = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            urls += found.filter { $0.pathExtension == PluginKit.bundleExtension }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var changed = false
        for url in urls where !records.contains(where: { $0.origin == .bundle(url) }) {
            load(bundleAt: url)
            changed = true
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// Instantiates and activates a plugin type compiled into the app.
    @discardableResult
    func load(builtIn type: DFPlugin.Type) -> Record {
        let plugin = type.init()
        return install(plugin, origin: .builtIn)
    }

    /// Loads one `.dfplugin` bundle. Any failure is recorded (Settings ▸ Plugins
    /// shows it) instead of thrown — a broken plugin must never take the app down.
    @discardableResult
    func load(bundleAt url: URL) -> Record {
        let name = url.deletingPathExtension().lastPathComponent
        func failure(_ message: String) -> Record {
            let rec = Record(info: PluginInfo(identifier: url.lastPathComponent, name: name),
                             origin: .bundle(url), state: .failed(message), plugin: nil)
            records.append(rec)
            host.log("\(url.lastPathComponent): \(message)")
            return rec
        }
        if quarantined.contains(url.lastPathComponent) {
            return failure(tr("Crashed while loading last time — Rescan retries it"))
        }
        guard let bundle = Bundle(url: url) else { return failure("Not a valid bundle") }
        guard let declared = bundle.object(forInfoDictionaryKey: PluginKit.apiVersionInfoKey) as? Int else {
            return failure("Info.plist lacks \(PluginKit.apiVersionInfoKey)")
        }
        guard declared == PluginKit.apiVersion else {
            return failure("Built for plugin API \(declared); this app provides \(PluginKit.apiVersion)")
        }
        // From here on the bundle's own code runs (static initializers, init,
        // activate). Leave a marker so a crash in there is attributed next launch.
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.loadingMarkerKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.loadingMarkerKey) }
        do {
            try bundle.loadAndReturnError()
        } catch {
            return failure(error.localizedDescription)
        }
        guard let type = bundle.principalClass as? DFPlugin.Type else {
            return failure("Principal class does not conform to DFPlugin")
        }
        return install(type.init(), origin: .bundle(url))
    }

    private func install(_ plugin: DFPlugin, origin: Origin) -> Record {
        let info = plugin.info
        if records.contains(where: { $0.info.identifier == info.identifier }) {
            let rec = Record(info: info, origin: origin,
                             state: .failed("Another plugin with identifier \(info.identifier) is already loaded"),
                             plugin: nil)
            records.append(rec)
            return rec
        }
        var rec = Record(info: info, origin: origin, state: .disabled, plugin: plugin)
        if isEnabled(info.identifier) {
            rec.state = activate(plugin)
        }
        records.append(rec)
        return rec
    }

    private func activate(_ plugin: DFPlugin) -> State {
        let id = plugin.info.identifier
        do {
            try plugin.activate(host: host)
        } catch {
            host.log("\(id): activation failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
        for fs in plugin.fileSystems {
            fileSystems.append(RegisteredFileSystem(pluginID: id, pluginName: plugin.info.name, extensionObject: fs))
        }
        for v in plugin.viewers { viewers.append(RegisteredViewer(pluginID: id, extensionObject: v)) }
        for v in plugin.pageViewers { pageViewers.append(RegisteredPageViewer(pluginID: id, extensionObject: v)) }
        for c in plugin.commands { commands.append(RegisteredCommand(pluginID: id, extensionObject: c)) }
        for p in plugin.packers { packers.append(RegisteredPacker(pluginID: id, extensionObject: p)) }
        for c in plugin.contentProviders { contentProviders.append(RegisteredContent(pluginID: id, extensionObject: c)) }
        publishNonisolatedRegistries()
        return .active
    }

    /// Packer suffixes and content columns are read from background threads
    /// (`FileItem.isArchiveFileName`, the list's draw loop), so they live in
    /// lock-guarded `nonisolated` registries mirrored from here.
    private func publishNonisolatedRegistries() {
        ArchivePluginRegistry.replace(with: packers.map { $0.extensionObject })
        PluginColumnRegistry.replace(with: contentProviders.map { ($0.pluginID, $0.extensionObject) })
    }

    private func deactivate(_ plugin: DFPlugin) {
        let id = plugin.info.identifier
        // Drives opened through this plugin go first: the session objects belong
        // to code that is about to be told to release everything.
        let store = RemoteSessionStore.shared
        for s in store.sessions {
            if case .plugin(let d) = s, d.pluginID == id { store.remove(id: s.id) }
        }
        fileSystems.removeAll { $0.pluginID == id }
        viewers.removeAll { $0.pluginID == id }
        pageViewers.removeAll { $0.pluginID == id }
        commands.removeAll { $0.pluginID == id }
        packers.removeAll { $0.pluginID == id }
        contentProviders.removeAll { $0.pluginID == id }
        publishNonisolatedRegistries()
        plugin.deactivate()
    }

    /// Settings toggle. Enabling activates immediately; disabling ejects the
    /// plugin's drives, drops its extensions and calls `deactivate`.
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let i = records.firstIndex(where: { $0.info.identifier == id }) else { return }
        var ids = disabledIDs
        if enabled { ids.remove(id) } else { ids.insert(id) }
        disabledIDs = ids
        if let plugin = records[i].plugin {
            if enabled, !records[i].isActive {
                records[i].state = activate(plugin)
            } else if !enabled, records[i].isActive {
                deactivate(plugin)
                records[i].state = .disabled
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Tests only: forget a plugin entirely (deactivating it first).
    func unload(id: String) {
        guard let i = records.firstIndex(where: { $0.info.identifier == id }) else { return }
        if records[i].isActive, let plugin = records[i].plugin { deactivate(plugin) }
        records.remove(at: i)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// App quit: give every active plugin its `deactivate`.
    func deactivateAll() {
        for rec in records where rec.isActive {
            if let plugin = rec.plugin { deactivate(plugin) }
        }
        for i in records.indices where records[i].isActive { records[i].state = .disabled }
    }

    // MARK: - Diagnostics

    /// `NC_PLUGIN_DIAG=1` — load everything and print the outcome to stdout.
    static func runDiagnostic() {
        let m = PluginManager.shared
        print("PluginKit API version: \(PluginKit.apiVersion)")
        print("User plugins folder:   \(userPluginsDirectory.path)")
        print("App PlugIns folder:    \(builtInPluginsDirectory?.path ?? "(none — bare executable)")")
        print("Disabled:              \(m.disabledIDs.sorted())")
        print("Quarantined:           \(m.quarantined.sorted())")
        m.loadAll()
        if m.records.isEmpty { print("No plugins found.") }
        for rec in m.records {
            let origin: String
            switch rec.origin {
            case .builtIn: origin = "built-in"
            case .bundle(let url): origin = url.path
            }
            print("- \(rec.info.identifier) \(rec.info.version) (\(rec.info.name)) [\(origin)]")
            switch rec.state {
            case .active: print("    active: \(m.provides(rec))")
            case .disabled: print("    disabled")
            case .failed(let why): print("    FAILED: \(why)")
            }
            if let p = rec.plugin, rec.isActive {
                for fs in p.fileSystems { print("    fs      \(fs.identifier) — \(fs.displayName)") }
                for v in p.viewers { print("    viewer  \(v.identifier) — \(v.displayName)") }
                for v in p.pageViewers { print("    page    \(v.identifier) — \(v.displayName)") }
                for c in p.commands { print("    command \(c.identifier) — \(c.title)") }
                for k in p.packers { print("    packer  \(k.identifier) — \(k.displayName) [\(k.fileExtensions.joined(separator: ", "))]") }
                for c in p.contentProviders { print("    columns \(c.identifier) — \(c.columns.map { $0.title }.joined(separator: ", "))") }
            }
        }
        m.deactivateAll()
    }

    // MARK: - Lookups

    func fileSystem(driveID: String) -> RegisteredFileSystem? {
        fileSystems.first { $0.driveID == driveID }
    }

    func command(id: String) -> RegisteredCommand? {
        commands.first { $0.id == id }
    }

    /// Toolbar / shortcut id ("plugin.<pluginID>/<cmd>") → command.
    func command(toolbarID: String) -> RegisteredCommand? {
        commands.first { $0.toolbarID == toolbarID }
    }

    /// First viewer plugin that claims the file, in load order.
    func viewer(for url: URL, sample: Data) -> ViewerPlugin? {
        viewers.first { $0.extensionObject.canView(url: url, sample: sample) }?.extensionObject
    }

    /// First page viewer that claims the file, in load order (built-ins first,
    /// so a bundle cannot silently take Markdown / ebooks over — disable the
    /// built-in in Settings to let one through).
    func pageViewer(for url: URL, sample: Data) -> PageViewerPlugin? {
        pageViewers.first { $0.extensionObject.canRender(url: url, sample: sample) }?.extensionObject
    }

    /// One-line "what it provides" for the Settings table.
    func provides(_ rec: Record) -> String {
        guard let plugin = rec.plugin else { return "" }
        var parts: [String] = []
        let fs = plugin.fileSystems.count, v = plugin.viewers.count + plugin.pageViewers.count, c = plugin.commands.count
        let pk = plugin.packers.count, cols = plugin.contentProviders.reduce(0) { $0 + $1.columns.count }
        if fs > 0 { parts.append(fs == 1 ? tr("File system") : tr("%d file systems", fs)) }
        if v > 0 { parts.append(v == 1 ? tr("Viewer") : tr("%d viewers", v)) }
        if pk > 0 { parts.append(pk == 1 ? tr("Archive format") : tr("%d archive formats", pk)) }
        if cols > 0 { parts.append(cols == 1 ? tr("Column") : tr("%d columns", cols)) }
        if c > 0 { parts.append(c == 1 ? tr("Command") : tr("%d commands", c)) }
        return parts.joined(separator: " · ")
    }
}
