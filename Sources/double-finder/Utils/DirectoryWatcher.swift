import Foundation

/// Watches a single local directory for content changes (entries added, removed
/// or renamed) via a kqueue-backed dispatch source, then invokes `onChange` —
/// debounced and delivered on the main queue. Re-`watch`ing the same path is a
/// no-op; non-local paths (e.g. inside an archive) are silently ignored.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var debounce: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ path: String) {
        if path == watchedPath { return }
        stop()
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }  // not a real local directory
        watchedPath = path

        // Deliberately omit `.attrib`: reading a directory can bump its access
        // time, which would otherwise feed back into an endless reload loop.
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .revoke],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.scheduleChange() }
        src.setCancelHandler { close(descriptor) }
        source = src
        src.resume()
    }

    func stop() {
        debounce?.cancel(); debounce = nil
        source?.cancel(); source = nil
        watchedPath = nil
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
