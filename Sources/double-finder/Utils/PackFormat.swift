import Foundation

/// A format the Pack dialog can write: a built-in `ArchiveFormat` (libarchive /
/// 7-Zip engine) or a packer plugin that implements `create`.
enum PackFormat {
    case builtIn(ArchiveFormat)
    case plugin(PluginManager.RegisteredPacker)

    var fileExtension: String {
        switch self {
        case .builtIn(let f): return f.fileExtension
        case .plugin(let reg): return reg.extensionObject.fileExtensions.first ?? "bin"
        }
    }

    /// Popup title (built-ins are English source strings, translated at display
    /// time; plugin names come as-is).
    var displayName: String {
        switch self {
        case .builtIn(let f): return f.displayName
        case .plugin(let reg): return "\(reg.extensionObject.displayName) (.\(fileExtension))"
        }
    }

    var supportsEncryption: Bool {
        if case .builtIn(let f) = self { return f.supportsEncryption }
        return false
    }

    var supportsSplit: Bool {
        if case .builtIn(let f) = self { return f.supportsSplit }
        return false
    }

    /// Everything Pack offers right now: the built-ins, then plugin formats
    /// whose packer can create.
    @MainActor static var all: [PackFormat] {
        ArchiveFormat.allCases.map { .builtIn($0) }
            + PluginManager.shared.packers.filter { $0.extensionObject.canCreate }.map { .plugin($0) }
    }
}
