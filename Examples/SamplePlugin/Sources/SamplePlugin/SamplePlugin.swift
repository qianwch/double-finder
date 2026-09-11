import AppKit
import ImageIO
import DoubleFinderPluginKit

/// Principal class — named in Info.plist `NSPrincipalClass`. Must be an
/// `NSObject` subclass visible to Objective-C so `Bundle.principalClass` finds it.
@objc(SamplePlugin)
public final class SamplePlugin: NSObject, DFPlugin {
    public let info = PluginInfo(identifier: "net.qian.double-finder.sample",
                                 name: "Sample Plugin",
                                 version: "1.0",
                                 summary: "Scratch drive, CSV table viewer and a selection summary command",
                                 author: "Double Finder")

    private var host: PluginHost?
    private let scratch = ScratchDrivePlugin()
    private let csv = CSVTableViewer()
    private let summary = SelectionSummaryCommand()
    private let pak = PAKPacker()
    private let imageInfo = ImageDimensionsColumn()

    public required override init() { super.init() }

    public func activate(host: PluginHost) throws {
        self.host = host
        host.log("Sample plugin activated (UI language \(host.languageTag))")
    }

    public func deactivate() { host = nil }

    public var fileSystems: [FileSystemPlugin] { [scratch] }
    public var viewers: [ViewerPlugin] { [csv] }
    public var commands: [CommandPlugin] { [summary] }
    public var packers: [PackerPlugin] { [pak] }
    public var contentProviders: [ContentPlugin] { [imageInfo] }

    /// A tiny settings view, to show the hook: real plugins would persist into
    /// `host.storageDirectory(for:)`.
    public func makeSettingsView() -> NSView? {
        let label = NSTextField(wrappingLabelWithString:
            "Sample Plugin has nothing to configure.\nStorage: \(host?.storageDirectory(for: info).path ?? "-")")
        label.font = .systemFont(ofSize: 12)
        return label
    }
}

// MARK: - File system: an in-memory scratch drive

/// A drive that lives in RAM: upload files into it, make folders, rename,
/// download them again — everything a FileSystemPlugin can do, with no I/O.
final class ScratchDrivePlugin: FileSystemPlugin {
    let identifier = "scratch"
    let displayName = "Scratch Drive"
    let symbolName = "internaldrive"

    @MainActor
    func connect(host: PluginHost) async throws -> PluginFileSystemSession {
        ScratchSession()
    }
}

final class ScratchSession: PluginFileSystemSession {
    let label = "Scratch Drive"

    private enum Node {
        case file(Data, Date)
        case dir(Date)
    }

    private let lock = NSLock()
    /// All node access goes through here: NSLock's lock()/unlock() may not be
    /// called directly from async functions, a synchronous helper may.
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    private var nodes: [String: Node] = [
        "/README.txt": .file(Data("This drive lives in memory. Copy files here with F5; they vanish when you eject it.\n".utf8), Date()),
        "/Examples": .dir(Date()),
        "/Examples/table.csv": .file(Data("name,size,kind\nalpha,10,file\nbeta,20,folder\n".utf8), Date()),
    ]

    private func norm(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "/" : s
    }

    private func parent(_ p: String) -> String {
        let s = (p as NSString).deletingLastPathComponent
        return s.isEmpty ? "/" : s
    }

    func list(_ directory: String) async throws -> [PluginFileEntry] {
        let dir = norm(directory)
        return try sync {
        if dir != "/" {
            guard case .dir = nodes[dir] else { throw PluginError.failed("No such folder: \(dir)") }
        }
        return nodes.compactMap { path, node in
            guard parent(path) == dir, path != "/" else { return nil }
            let name = (path as NSString).lastPathComponent
            switch node {
            case .file(let data, let date):
                return PluginFileEntry(name: name, isDirectory: false, size: Int64(data.count), modified: date)
            case .dir(let date):
                return PluginFileEntry(name: name, isDirectory: true, modified: date)
            }
        }.sorted { $0.name < $1.name }
        }
    }

    func download(_ path: String, to localURL: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        let node = sync { nodes[norm(path)] }
        guard case .file(let data, _)? = node else { throw PluginError.failed("No such file: \(path)") }
        try data.write(to: localURL)
        progress(Int64(data.count))
    }

    func upload(_ localURL: URL, to path: String,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        let data = try Data(contentsOf: localURL)
        sync { nodes[norm(path)] = .file(data, Date()) }
        progress(Int64(data.count))
    }

    func delete(_ path: String) async throws {
        let p = norm(path)
        try sync {
            guard nodes[p] != nil else { throw PluginError.failed("No such item: \(path)") }
            for key in nodes.keys where key == p || key.hasPrefix(p + "/") { nodes[key] = nil }
        }
    }

    func createDirectory(_ path: String) async throws {
        sync { nodes[norm(path)] = .dir(Date()) }
    }

    func rename(_ path: String, to newName: String) async throws {
        let p = norm(path)
        let target = (parent(p) as NSString).appendingPathComponent(newName)
        try sync {
            guard nodes[p] != nil else { throw PluginError.failed("No such item: \(path)") }
            for (key, node) in nodes where key == p || key.hasPrefix(p + "/") {
                nodes[target + key.dropFirst(p.count)] = node
                nodes[key] = nil
            }
        }
    }

    /// Server-side copy: cheap here, so implement it rather than letting the
    /// host relay through a temp file.
    func copy(_ path: String, toDirectory directory: String) async throws {
        let p = norm(path)
        let target = (norm(directory) as NSString).appendingPathComponent((p as NSString).lastPathComponent)
        try sync {
            guard nodes[p] != nil else { throw PluginError.failed("No such item: \(path)") }
            for (key, node) in nodes where key == p || key.hasPrefix(p + "/") {
                nodes[target + key.dropFirst(p.count)] = node
            }
        }
    }

    func disconnect() {
        sync { nodes.removeAll() }
    }
}

// MARK: - Viewer: CSV as a table

final class CSVTableViewer: ViewerPlugin {
    let identifier = "csv-table"
    let displayName = "CSV Table"

    func canView(url: URL, sample: Data) -> Bool {
        url.pathExtension.lowercased() == "csv" && !sample.contains(0)
    }

    @MainActor
    func makeView(for url: URL) throws -> NSView {
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = text.split(whereSeparator: \.isNewline).map { line in
            line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        }
        guard let header = rows.first else { throw PluginError.failed("Empty CSV") }
        let table = NSTableView()
        for (i, title) in header.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
            col.title = title
            col.width = 140
            table.addTableColumn(col)
        }
        table.usesAlternatingRowBackgroundColors = true
        let source = CSVSource(rows: Array(rows.dropFirst()))
        table.dataSource = source
        table.delegate = source
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        // Keep the data source alive as long as the view.
        objc_setAssociatedObject(scroll, &CSVSource.key, source, .OBJC_ASSOCIATION_RETAIN)
        return scroll
    }
}

private final class CSVSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static var key = 0
    let rows: [[String]]
    init(rows: [[String]]) { self.rows = rows }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let i = Int(col.identifier.rawValue) else { return nil }
        let value = rows[row].indices.contains(i) ? rows[row][i] : ""
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

// MARK: - Command: selection summary

final class SelectionSummaryCommand: CommandPlugin {
    let identifier = "selection-summary"
    let title = "Selection Summary…"
    let symbolName = "sum"

    @MainActor
    func perform(_ context: PluginCommandContext) async throws {
        var files = 0, folders = 0
        var bytes: Int64 = 0
        for path in context.selectedPaths where context.sourceIsLocal {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders += 1 } else {
                files += 1
                bytes += (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            }
        }
        let alert = NSAlert()
        alert.messageText = "Selection Summary"
        alert.informativeText = context.sourceIsLocal
            ? "\(files) file(s), \(folders) folder(s), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\nSource: \(context.sourceDirectory)\nTarget: \(context.targetDirectory)"
            : "\(context.selectedPaths.count) item(s) on a non-local source\nSource: \(context.sourceDirectory)"
        if let window = context.host.mainWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Packer: Quake PAK (read-only)
//
// The simplest real archive format around: 12-byte header ("PACK", directory
// offset, directory size), then a directory of 64-byte entries (56-byte
// NUL-padded path, offset, size). Paths use "/" so folders show up naturally.

final class PAKPacker: PackerPlugin {
    let identifier = "quake-pak"
    let displayName = "Quake PAK"
    let fileExtensions = ["pak"]

    func open(_ url: URL) throws -> PluginArchiveSession {
        try PAKSession(url: url)
    }

    let canCreate = true

    /// Writes a PAK: header, then every file's bytes, then the 64-byte directory
    /// entries. Names longer than 55 bytes don't fit the format and are refused.
    func create(_ url: URL, sources: [PluginArchiveSource],
                progress: @escaping @Sendable (Int64) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) throws {
        var blob = Data()
        var dir = Data()
        var done: Int64 = 0
        for s in sources {
            if isCancelled() { throw CancellationError() }
            guard let name = s.entryPath.data(using: .utf8), name.count <= 55 else {
                throw PluginError.failed("PAK entry names are limited to 55 bytes: \(s.entryPath)")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: s.localPath))
            var entry = name; entry.append(Data(count: 56 - name.count))
            entry.append(UInt32(12 + blob.count).le); entry.append(UInt32(data.count).le)
            dir.append(entry)
            blob.append(data)
            done += Int64(data.count); progress(done)
        }
        var out = Data("PACK".utf8)
        out.append(UInt32(12 + blob.count).le); out.append(UInt32(dir.count).le)
        out.append(blob); out.append(dir)
        try out.write(to: url, options: .atomic)
    }
}

private extension UInt32 {
    var le: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

final class PAKSession: PluginArchiveSession {
    private let handle: FileHandle
    private var directory: [(path: String, offset: UInt32, size: UInt32)] = []

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12, header.prefix(4) == Data("PACK".utf8) else {
            throw PluginError.failed("Not a PAK file")
        }
        let dirOffset = header.le32(at: 4), dirSize = header.le32(at: 8)
        try handle.seek(toOffset: UInt64(dirOffset))
        let dir = try handle.read(upToCount: Int(dirSize)) ?? Data()
        guard dir.count == Int(dirSize), dirSize % 64 == 0 else { throw PluginError.failed("Corrupt PAK directory") }
        for i in stride(from: 0, to: dir.count, by: 64) {
            let nameBytes = dir[dir.startIndex + i ..< dir.startIndex + i + 56].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            directory.append((name, dir.le32(at: i + 56), dir.le32(at: i + 60)))
        }
    }

    func entries() throws -> [PluginArchiveEntry] {
        directory.map { PluginArchiveEntry(path: $0.path, size: Int64($0.size)) }
    }

    func extract(_ entryPath: String, to localURL: URL) throws {
        guard let e = directory.first(where: { $0.path == entryPath }) else {
            throw PluginError.failed("No such entry: \(entryPath)")
        }
        try handle.seek(toOffset: UInt64(e.offset))
        let data = try handle.read(upToCount: Int(e.size)) ?? Data()
        try data.write(to: localURL)
    }

    func close() { try? handle.close() }
}

private extension Data {
    func le32(at i: Int) -> UInt32 {
        let b = self[startIndex + i ..< startIndex + i + 4]
        return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
}

// MARK: - Content: image dimensions column

final class ImageDimensionsColumn: ContentPlugin {
    let identifier = "image-info"
    let columns = [PluginColumn(id: "dimensions", title: "Dimensions", defaultWidth: 100)]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp"]

    func value(column: String, path: String, isDirectory: Bool) -> String? {
        guard !isDirectory,
              Self.imageExtensions.contains((path as NSString).pathExtension.lowercased()),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) × \(h)"
    }
}
