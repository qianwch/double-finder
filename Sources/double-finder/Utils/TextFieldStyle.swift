import AppKit

extension NSTextField {
    /// Single-line input: text never wraps to extra lines; overflow scrolls
    /// horizontally with the caret instead. Programmatic NSTextField cells
    /// default to wraps=true, which makes long paths grow the field vertically.
    func useSingleLineScrolling() {
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
    }
}
