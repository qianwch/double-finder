import AppKit

/// A bottom chrome bar (the command line, the function keys) that folds away by
/// animating its height constraint to zero.
///
/// `isHidden` is not just cosmetic here: a zero-height bar that stays visible
/// still holds a focusable text field, so a folded bar must end up hidden. But
/// it can only be hidden *after* the collapse finishes, and a reveal can land
/// mid-collapse (Cmd+L right after Esc) — so each run takes a serial number and
/// a completion that is no longer the newest keeps its hands off `isHidden`.
@MainActor
final class CollapsibleBar {
    private let view: NSView
    private let height: NSLayoutConstraint
    private let fullHeight: CGFloat
    private var token = 0

    static let duration = 0.16

    init(view: NSView, height: NSLayoutConstraint, fullHeight: CGFloat) {
        self.view = view
        self.height = height
        self.fullHeight = fullHeight
    }

    var isShown: Bool { height.constant > 0 }

    func set(shown: Bool, animated: Bool) {
        // Unhide first: a hidden view cannot take the keyboard focus, and Cmd+L
        // wants to focus the command line as it starts growing, not after.
        if shown { view.isHidden = false }
        token += 1
        let mine = token
        let target = shown ? fullHeight : 0

        guard animated else {
            height.constant = target
            view.isHidden = !shown
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true   // let the panels above slide too
            self.height.animator().constant = target
            self.view.superview?.layoutSubtreeIfNeeded()
        }, completionHandler: {
            // The completion handler is @Sendable, so it captures only the two
            // value bits and hops back to the main actor for the rest.
            Task { @MainActor [weak self] in
                guard let self, self.token == mine, !shown else { return }
                self.view.isHidden = true
            }
        })
    }
}
