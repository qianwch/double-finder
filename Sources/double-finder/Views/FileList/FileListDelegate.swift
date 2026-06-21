import AppKit

/// Interaction delegate for the owner-drawn `FileListBodyView` / `FileListView`.
/// The `tableView` parameter is typed as `NSView` (generalised in Task 6) so the
/// callback surface is view-implementation agnostic.  `PanelViewController` conforms
/// and ignores the `NSView` argument.
///
/// (Historically shared with the now-deleted NSTableView-backed `FileTableView`;
/// the protocol name is kept to minimise churn.)
protocol FileTableViewDelegate: AnyObject {
    func fileTableView(_ tableView: NSView, didDoubleClickItem item: FileItem)
    func fileTableView(_ tableView: NSView, didPressEnterOnItem item: FileItem)
    func fileTableViewDidChangeCursor(_ tableView: NSView, to index: Int)
    func fileTableView(_ tableView: NSView, didClickRow row: Int, extend: Bool, toggle: Bool)
    func fileTableViewWantsActivation(_ tableView: NSView)
    func fileTableView(_ tableView: NSView, didPressSpaceOnIndex index: Int)
    func fileTableView(_ tableView: NSView, didClickColumn identifier: String)
    func fileTableView(_ tableView: NSView, didToggleExpand item: FileItem)
    func fileTableView(_ tableView: NSView, didRename item: FileItem, to newName: String)
    func fileTableView(_ tableView: NSView, didDropFiles urls: [URL], move: Bool)
}
