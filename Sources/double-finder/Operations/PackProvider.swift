import Foundation

/// Pack locally, then import the finished output(s) into a remote destination.
/// A source FS is supplied only for remote or archive selections.
struct PackProvider {
    var sourceFS: VirtualFS? = nil
    let destinationFS: VirtualFS?

    static func isVolume(_ name: String, of archiveName: String) -> Bool {
        guard name.hasPrefix(archiveName + ".") else { return false }
        let suffix = name.dropFirst(archiveName.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }

    func existingNames(in directory: String) async throws -> Set<String> {
        if let destinationFS {
            return Set(try await destinationFS.listDirectory(directory).map(\.name))
        }
        return try await Task.detached(priority: .userInitiated) {
            Set(try FileManager.default.contentsOfDirectory(atPath: directory))
        }.value
    }

    func outputExists(at path: String) async throws -> Bool {
        if destinationFS != nil {
            return try await existingNames(in: (path as NSString).deletingLastPathComponent)
                .contains((path as NSString).lastPathComponent)
        }
        // Follow the actual volume's case and normalization semantics.
        return await Task.detached { FileManager.default.fileExists(atPath: path) }.value
    }

    func suggestedName(after base: String, extension ext: String, directory: String, split: Bool) async throws -> String {
        var index = 2
        while try await outputExists(at: (directory as NSString).appendingPathComponent(base + " \(index)" + ext + (split ? ".001" : ""))) {
            index += 1
        }
        return base + " \(index)"
    }

    @MainActor
    func makeOperation(archivePath: String, sources: [String], opts: PackSheet.Options,
                       baseDir: String?, total: Int64) -> FileOperation {
        let op = FileOperation(type: .copy, sources: [archivePath], destination: nil)
        op.customTitle = tr("Packing")
        op.totalBytes = total
        op.bytesTransferred = { [weak op] in op?.transferredBytes ?? 0 }
        op.suppressFailureReport = true
        let split = opts.volumeSize != nil
        op.perItemOperation = { [weak op] _ in
            guard let op else { return }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("df-pack-" + UUID().uuidString)
            let archiveName = (archivePath as NSString).lastPathComponent
            let output = destinationFS == nil ? archivePath : temp.appendingPathComponent("output/" + archiveName).path
            var startedPacking = false
            do {
                try Task.checkCancellation()
                guard !op.cancelRequested else { throw CancellationError() }
                var localSources = sources
                var localBase = baseDir
                if let sourceFS {
                    // Search results can contain same-named entries from several
                    // folders/archives even when they carry no expanded depth.
                    if localBase == nil, Set(sources.map { ($0 as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }).count != sources.count {
                        localBase = LocalFS.commonAncestor(of: sources)
                    }
                    let sourceBase = localBase
                    let root = temp.appendingPathComponent("sources")
                    localSources = []
                    for path in sources {
                        try Task.checkCancellation()
                        guard !op.cancelRequested else { throw CancellationError() }
                        let relative = sourceBase.map { LocalFS.relativePath(path, base: $0) }
                            ?? (path as NSString).lastPathComponent
                        let parent = (relative as NSString).deletingLastPathComponent
                        let directory = parent.isEmpty ? root : root.appendingPathComponent(parent)
                        try await FileContentTransfer.checkMaterializedExport(at: path, from: sourceFS, to: directory)
                        try await sourceFS.exportItem(at: path, toLocalDirectory: directory, progress: { _ in })
                        localSources.append(root.appendingPathComponent(relative).path)
                    }
                    localBase = sourceBase == nil ? nil : root.path
                    let captured = localSources
                    op.totalBytes = await Task.detached {
                        captured.reduce(Int64(0)) { $0 + FileOperation.sizeOnDisk($1) }
                    }.value
                }
                if destinationFS != nil {
                    try await LocalFS().createDirectory((output as NSString).deletingLastPathComponent)
                }
                try Task.checkCancellation()
                guard !op.cancelRequested else { throw CancellationError() }
                startedPacking = true
                switch opts.format {
                case .builtIn(let format):
                    try await LocalFS().createArchive(
                        sources: localSources, to: output, format: format, level: opts.level, password: opts.password,
                        baseDir: localBase, volumeSize: opts.volumeSize, totalSourceBytes: op.totalBytes,
                        progress: { op.reportBytes($0) }, shouldCancel: { op.cancelRequested })
                case .plugin(let reg):
                    try await PluginArchiveFS.createArchive(
                        sources: localSources, to: output, packer: reg.extensionObject, baseDir: localBase,
                        progress: { op.reportBytes($0) }, shouldCancel: { op.cancelRequested })
                }
                try Task.checkCancellation()
                guard !op.cancelRequested else { throw CancellationError() }
                if let destinationFS {
                    let directory = (archivePath as NSString).deletingLastPathComponent
                    let oldNames = split ? try await existingNames(in: directory) : []
                    let outputDirectory = URL(fileURLWithPath: output).deletingLastPathComponent()
                    let outputs = split ? try await FileContentTransfer.localChildren(outputDirectory)
                        .filter { Self.isVolume($0.lastPathComponent, of: archiveName) }
                        : [URL(fileURLWithPath: output)]
                    guard !outputs.isEmpty else { throw FSUnsupportedError(message: "Could not open the archive") }
                    for url in outputs {
                        try Task.checkCancellation()
                        guard !op.cancelRequested else { throw CancellationError() }
                        try await destinationFS.importItem(from: url,
                            toPath: (directory as NSString).appendingPathComponent(url.lastPathComponent), progress: { _ in })
                    }
                    // Remove stale trailing volumes only once all new volumes arrived.
                    let written = Set(outputs.map(\.lastPathComponent))
                    for name in oldNames.subtracting(written) where Self.isVolume(name, of: archiveName) {
                        try Task.checkCancellation()
                        guard !op.cancelRequested else { throw CancellationError() }
                        try await destinationFS.delete((directory as NSString).appendingPathComponent(name))
                    }
                }
            } catch {
                // Only local outputs belong to this operation; never interpret
                // a remote destination as a local cleanup path.
                let removeOutput = startedPacking
                await Task.detached {
                    if removeOutput { LocalFS.removePackOutputs(archivePath: output, split: split) }
                    try? FileManager.default.removeItem(at: temp)
                }.value
                if error is CancellationError || op.cancelRequested { return }
                throw error
            }
            await Task.detached { try? FileManager.default.removeItem(at: temp) }.value
        }
        return op
    }
}
